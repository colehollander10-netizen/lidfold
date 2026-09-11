import AppKit
import Combine
import Metal

/// Turns the sensor's ~10 Hz steps into a value that moves smoothly at the
/// display refresh rate. Semi-implicit Euler; stable while frequency * dt < 2.
struct CriticallyDampedSpring {
    var value: Double = 0
    var velocity: Double = 0
    var frequency: Double = 18
    mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }
    mutating func reset(to v: Double) { value = v; velocity = 0 }
}

/// Polls the lid sensor and runs the effect state machine.
///
/// idle    lid above the activation angle, nothing running
/// armed   lid closing toward the activation angle: overlay prepared
///         (transparent) and capture warming up, so the first visible frame
///         is ready when the angle is crossed
/// active  lid below the activation angle: overlay showing, following the lid
/// preview the --preview launch flag is driving the angle
final class LidMonitor: ObservableObject {
    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable: Bool = false
    @Published private(set) var statusText: String = "Starting"
    /// Set to a lid angle to show the effect on the desktop at that angle; nil ends the preview.
    @Published var previewAngle: Double? { didSet { previewChanged() } }

    enum Phase { case idle, armed, active, preview }
    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { Log.write("\(oldValue) -> \(phase) at \(String(format: "%.1f", rawAngle))°"); refreshStatus() } }
    }

    /// Debug only: replaces the sensor with a scripted angle over elapsed time.
    var simulatedAngle: ((CFTimeInterval) -> Double)? { didSet { if simulatedAngle != nil { isSensorAvailable = true } } }
    private let simulationStart = CACurrentMediaTime()
    private func readAngle() -> Double? {
        if let simulatedAngle { return simulatedAngle(CACurrentMediaTime() - simulationStart) }
        return sensor.angle()
    }
    /// The lid's own display; in simulation, whatever screen is there.
    private var targetScreen: NSScreen? { NSScreen.builtIn ?? (simulatedAngle != nil ? NSScreen.main : nil) }

    /// Degrees above the activation angle at which a closing lid arms capture.
    static let armMargin = 30.0
    /// Degrees above the activation angle the lid must reopen to end the effect.
    static let hysteresis = 3.0
    /// Angular speed (deg/s, negative is closing) that counts as closing.
    static let closingSpeed = -3.0
    /// Speed the lid must be closing at when it crosses the activation angle
    /// for the effect to start. A nudge while typing is slower than this.
    static let deliberateSpeed = -8.0
    static let pollInterval = 0.02
    /// Seconds an armed lid may rest without closing before capture stops.
    static let armedTimeout = 2.5

    private let preferences: Preferences
    private let sensor = LidAngleSensor()
    private let renderer: FoldRenderer?
    private let streamer: ScreenStreamer?
    private let overlay: OverlayWindowController?
    private var pollTimer: Timer?
    private var rawAngle: Double = 0
    private var previousRaw: Double?
    private var velocity: Double = 0
    private var lastChange: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0
    private var armedSince: CFTimeInterval = 0
    private var spring = CriticallyDampedSpring()
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(preferences: Preferences) {
        self.preferences = preferences
        renderer = FoldRenderer()
        streamer = renderer.map { ScreenStreamer(device: $0.device) }
        overlay = renderer.map { OverlayWindowController(renderer: $0) }
        isSensorAvailable = sensor.isAvailable
        if !sensor.isAvailable { NSLog("Lidfold: lid angle sensor not found") }
        if renderer == nil { NSLog("Lidfold: Metal renderer unavailable") }

        overlay?.paramsProvider = { [weak self] dt in self?.frameParams(dt: dt) ?? FoldParams() }
        overlay?.frameProvider = { [weak self] in self?.streamer?.takeNewFrame() }
        streamer?.onStateChange = { [weak self] _ in self?.refreshStatus() }

        preferences.$isEnabled.dropFirst().receive(on: RunLoop.main).sink { [weak self] on in
            guard let self else { return }
            if !on, self.phase != .preview { self.disarm() }
            self.refreshStatus()
        }.store(in: &bag)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.didWake() })
        }
        // With a monitor attached the Mac stays awake when the lid shuts, the
        // built-in display disconnects, and macOS moves every window to the
        // monitor. The effect must end before the overlay lands there.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        })
    }

    private func screensChanged() {
        let names = NSScreen.screens.map(\.localizedName).joined(separator: ", ")
        Log.write("screens changed: [\(names)] builtIn=\(NSScreen.builtIn?.localizedName ?? "none")")
        guard simulatedAngle == nil, phase != .idle, phase != .preview else { return }
        if NSScreen.builtIn == nil { Log.write("built-in display gone, ending effect"); disarm() }
    }

    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) } }

    func start() {
        Log.write("start: sensor=\(sensor.isAvailable) permission=\(ScreenStreamer.hasPermission) builtIn=\(NSScreen.builtIn?.localizedName ?? "none") angle=\(readAngle() ?? -1)")
        if let a = readAngle() { rawAngle = a; currentAngle = a; spring.reset(to: a) }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refreshStatus()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        disarm()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling

    private func poll() {
        guard let a = readAngle() else { return }
        let now = CACurrentMediaTime()
        if let prev = previousRaw {
            if a != prev {
                let dt = max(now - lastChange, 0.02)
                velocity = velocity * 0.4 + ((a - prev) / dt) * 0.6
                lastChange = now
            } else if now - lastChange > 0.4 {
                velocity = 0
            }
        } else {
            lastChange = now
        }
        let prev = previousRaw
        previousRaw = a
        rawAngle = a
        if now - lastPublish > 0.1, abs(currentAngle - a) > 0.05 { currentAngle = a; lastPublish = now }

        guard overlay != nil, phase != .preview else { return }
        guard preferences.isEnabled else { if phase != .idle { disarm() }; return }
        if phase != .idle, targetScreen == nil { Log.write("no built-in display, ending effect"); disarm(); return }
        step(angle: a, previous: prev, now: now)
    }

    private func step(angle a: Double, previous: Double?, now: CFTimeInterval) {
        let act = Effect.activationAngle
        switch phase {
        case .idle:
            if let previous, previous >= act, a < act, velocity < Self.deliberateSpeed { arm(now); activate(); return }
            if a >= act, a < act + Self.armMargin, velocity < Self.closingSpeed { arm(now) }
        case .armed:
            if a < act { activate(); return }
            if velocity < Self.closingSpeed { armedSince = now }
            if a > act + Self.armMargin + 5 || now - armedSince > Self.armedTimeout { disarm() }
        case .active:
            if a >= act + Self.hysteresis { deactivate(now) }
        case .preview:
            break
        }
    }

    private func arm(_ now: CFTimeInterval) {
        guard let overlay, let streamer, let screen = targetScreen, let id = screen.displayID else { return }
        phase = .armed
        armedSince = now
        spring.reset(to: rawAngle)
        overlay.prepare(on: screen)
        if !ScreenStreamer.hasPermission { ScreenStreamer.requestPermission() }
        streamer.start(displayID: id)
    }

    private func activate() {
        guard let overlay, let screen = targetScreen else { return }
        overlay.prepare(on: screen)
        phase = .active
    }

    /// Lid reopened past the hysteresis: hide, but keep capture warm briefly
    /// in case it closes again.
    private func deactivate(_ now: CFTimeInterval) {
        overlay?.hide()
        phase = .armed
        armedSince = now
    }

    private func disarm() {
        overlay?.hide()
        streamer?.stop()
        phase = .idle
    }

    private func didWake() {
        previousRaw = nil
        velocity = 0
        if let a = readAngle() { rawAngle = a; currentAngle = a }
        // The stream rarely survives sleep; restart it if the effect is still on.
        if phase == .active || phase == .armed, let streamer, let id = targetScreen?.displayID {
            streamer.stop()
            streamer.start(displayID: id)
        }
    }

    // MARK: - Preview

    private func previewChanged() {
        if previewAngle != nil {
            if phase != .preview { beginPreview() }
        } else if phase == .preview {
            disarm()
        }
    }

    private func beginPreview() {
        guard let overlay, let streamer, let screen = NSScreen.builtIn ?? NSScreen.main, let id = screen.displayID else { return }
        spring.reset(to: previewAngle ?? Effect.activationAngle + 10)
        phase = .preview
        overlay.prepare(on: screen)
        if ScreenStreamer.hasPermission {
            streamer.start(displayID: id)
        } else {
            // Before permission is granted, preview on the wallpaper instead.
            ScreenStreamer.requestPermission()
            overlay.setStillContent(RenderDemo.wallpaperImage() ?? RenderDemo.testScene(width: 2560, height: 1664))
        }
    }

    // MARK: - Per-frame

    /// Runs on the main thread from the overlay's draw loop.
    private func frameParams(dt: CFTimeInterval) -> FoldParams {
        let now = CACurrentMediaTime()
        var target = rawAngle
        switch phase {
        case .preview:
            target = previewAngle ?? rawAngle
        default:
            // Extrapolate inside the sensor's ~100 ms update gap so a fast
            // close does not read as a staircase.
            let lead = min(now - lastChange, 0.12)
            target = max(0, rawAngle + max(min(velocity * lead, 12), -12))
        }
        spring.advance(to: target, dt: dt)
        if let overlay, phase == .active || phase == .preview, overlay.hasContent, !overlay.isVisible { overlay.reveal() }
        return FoldModel.params(angle: spring.value)
    }

    // MARK: - Status

    private func refreshStatus() {
        let text: String
        if renderer == nil { text = "Metal unavailable" }
        else if !isSensorAvailable, phase != .preview { text = "Lid sensor not found" }
        else if !preferences.isEnabled, phase != .preview { text = "Off" }
        else if case .failed(let why)? = streamer?.state { text = why }
        else if !ScreenStreamer.hasPermission { text = "Screen Recording permission needed" }
        else {
            switch phase {
            case .idle: text = "Waiting for the lid"
            case .armed: text = "Ready"
            case .active: text = "Following the lid"
            case .preview: text = "Previewing"
            }
        }
        if text != statusText { statusText = text }
    }
}
