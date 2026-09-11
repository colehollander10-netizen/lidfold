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

/// One captured frame. Holds the CVMetalTexture so the IOSurface behind the
/// Metal texture stays alive until the GPU has finished reading it.
final class CapturedFrame {
    let texture: MTLTexture
    private let backing: CVMetalTexture
    init?(_ backing: CVMetalTexture) {
        guard let texture = CVMetalTextureGetTexture(backing) else { return nil }
        self.backing = backing
        self.texture = texture
    }
}

/// Live capture of one display through ScreenCaptureKit. Frames are
/// IOSurface-backed, so wrapping one as a Metal texture copies nothing.
/// Starting takes a few hundred milliseconds, so the stream is started while
/// the lid is still above the activation angle.
///
/// `start`, `stop`, `state` and `stream` are main-thread only. Frames arrive
/// on the capture queue and are handed over under a lock.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State: Equatable { case idle, starting, streaming, failed(String) }

    /// Display P3 shares sRGB's transfer curve, so an sRGB texture format
    /// decodes it correctly and the overlay layer is tagged P3 to match.
    static let colorSpace = CGColorSpace.displayP3

    private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    var onStateChange: ((State) -> Void)?

    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private var stream: SCStream?
    private var generation = 0
    private let lock = NSLock()
    private var newest: CapturedFrame?
    private var newestID: UInt64 = 0
    private var consumedID: UInt64 = 0
    private var wrapFailures = 0
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
        generation += 1
        let mine = generation
        state = .starting
        Task { @MainActor [weak self] in await self?.begin(displayID: displayID, generation: mine) }
    }

    func stop() {
        generation += 1
        let closing = stream
        stream = nil
        lock.lock(); newest = nil; newestID = 0; consumedID = 0; lock.unlock()
        state = .idle
        guard let closing else { return }
        Task { try? await closing.stopCapture() }
    }

    /// The newest frame, once. nil when nothing new arrived since the last call.
    func takeNewFrame() -> CapturedFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let newest, newestID != consumedID else { return nil }
        consumedID = newestID
        return newest
    }

    @MainActor
    private func begin(displayID: CGDirectDisplayID, generation mine: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard mine == generation else { return }
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
            guard mine == generation else { try? await fresh.stopCapture(); return }
            stream = fresh
            state = .streaming
            Log.write("stream started \(config.width)x\(config.height)")
        } catch {
            guard mine == generation else { return }
            Log.write("stream failed: \(error)")
            state = .failed(Self.hasPermission ? error.localizedDescription : "Needs Screen Recording: grant it, then quit and reopen")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            Log.write("stream stopped: \(error)")
            self.stream = nil
            self.state = .failed(error.localizedDescription)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let cache,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVMetalTextureCacheFlush(cache, 0)
        var wrapped: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, nil, FoldRenderer.pixelFormat,
                                                               CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &wrapped)
        guard result == kCVReturnSuccess, let wrapped, let frame = CapturedFrame(wrapped) else {
            wrapFailures += 1
            if wrapFailures == 1 { Log.write("frame wrap failed: CVReturn \(result)") }
            return
        }
        lock.lock(); newest = frame; newestID &+= 1; lock.unlock()
    }
}
