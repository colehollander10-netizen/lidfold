import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    /// The MacBook's own panel, the only display the lid moves.
    static var builtIn: NSScreen? {
        screens.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }
}

/// Live capture of one display through ScreenCaptureKit. Frames are
/// IOSurface-backed, so wrapping one as a Metal texture copies nothing.
/// Starting takes a few hundred milliseconds, so the stream is started while
/// the lid is still above the activation angle.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State: Equatable { case idle, starting, streaming, failed(String) }

    /// Display P3 shares sRGB's transfer curve, so an sRGB texture format
    /// decodes it correctly and the overlay layer is tagged P3 to match.
    static let colorSpace = CGColorSpace.displayP3

    private(set) var state: State = .idle { didSet { if state != oldValue { DispatchQueue.main.async { self.onStateChange?(self.state) } } } }
    var onStateChange: ((State) -> Void)?

    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private let lock = NSLock()
    private var newest: CVMetalTexture?
    private var newestID: UInt64 = 0
    private var consumedID: UInt64 = 0
    private let queue = DispatchQueue(label: "lidfold.frames", qos: .userInteractive)

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    var isRunning: Bool { state == .starting || state == .streaming }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt the first time; later calls return immediately.
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func start(displayID: CGDirectDisplayID) {
        guard !isRunning else { return }
        state = .starting
        startTask = Task { [weak self] in await self?.begin(displayID: displayID) }
    }

    func stop() {
        startTask?.cancel(); startTask = nil
        let closing = stream
        stream = nil
        lock.lock(); newest = nil; newestID = 0; consumedID = 0; lock.unlock()
        state = .idle
        guard let closing else { return }
        Task { try? await closing.stopCapture() }
    }

    /// The newest frame, once. nil when nothing new arrived since the last call.
    func takeNewFrame() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let newest, newestID != consumedID else { return nil }
        consumedID = newestID
        return CVMetalTextureGetTexture(newest)
    }

    private func begin(displayID: CGDirectDisplayID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                state = .failed("Built-in display not found"); return
            }
            // Belt and braces: our windows are also marked sharingType = .none.
            let own = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = Self.colorSpace
            config.showsCursor = false
            config.queueDepth = 3
            config.scalesToFit = false
            let fresh = SCStream(filter: filter, configuration: config, delegate: self)
            try fresh.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await fresh.startCapture()
            guard !Task.isCancelled else { try? await fresh.stopCapture(); return }
            stream = fresh
            state = .streaming
            Log.write("stream started \(config.width)x\(config.height)")
        } catch {
            guard !Task.isCancelled else { return }
            Log.write("stream failed: \(error)")
            state = .failed(Self.hasPermission ? error.localizedDescription : "Screen Recording permission needed")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("stream stopped: \(error)")
        self.stream = nil
        state = .failed(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let cache,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVMetalTextureCacheFlush(cache, 0)
        var wrapped: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, nil, FoldRenderer.pixelFormat,
                                                               CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &wrapped)
        guard result == kCVReturnSuccess, let wrapped else { return }
        lock.lock(); newest = wrapped; newestID &+= 1; lock.unlock()
    }
}
