import AppKit
import Metal
import MetalKit

/// A borderless, click-through window covering the built-in display, drawing
/// the fold effect with Metal. It sits at screen-saver level so it covers the
/// menu bar and Dock, and is excluded from screen capture so it never feeds
/// back into its own picture.
final class OverlayWindowController: NSObject, MTKViewDelegate {
    static let level = NSWindow.Level.screenSaver
    /// Debug only: lets `screencapture` see the overlay. Normally the window
    /// is excluded from every capture, including its own.
    static var capturableForDebugging = false

    let renderer: FoldRenderer
    private(set) var window: NSWindow?
    private var view: MTKView?
    private var lastDraw: CFTimeInterval = 0
    private(set) var hasContent = false

    /// Called once per frame with the elapsed time; returns what to draw.
    var paramsProvider: ((CFTimeInterval) -> FoldParams)?
    /// Called once per frame; a non-nil texture replaces the picture.
    var frameProvider: (() -> MTLTexture?)?

    var isVisible: Bool { window?.isVisible == true && (window?.alphaValue ?? 0) > 0 }

    init(renderer: FoldRenderer) {
        self.renderer = renderer
        super.init()
    }

    /// Creates the window on `screen`, ordered in but fully transparent, and
    /// starts the draw loop so the first captured frame is ready to show.
    func prepare(on screen: NSScreen) {
        if window == nil { makeWindow() }
        guard let window, let view else { return }
        window.setFrame(screen.frame, display: false)
        view.frame = window.contentView!.bounds
        let scale = screen.backingScaleFactor
        view.drawableSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        if !window.isVisible { window.alphaValue = 0; window.orderFrontRegardless() }
        lastDraw = 0
        view.isPaused = false
    }

    func reveal() {
        guard let window else { return }
        Log.write("overlay revealed on \(window.screen?.localizedName ?? "?")")
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    func hide() {
        guard let window else { return }
        if window.isVisible { Log.write("overlay hidden") }
        window.alphaValue = 0
        window.orderOut(nil)
        view?.isPaused = true
        hasContent = false
    }

    func setStillContent(_ image: CGImage) {
        try? renderer.setContent(image)
        hasContent = renderer.content != nil
    }

    private func makeWindow() {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = Self.level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.sharingType = Self.capturableForDebugging ? .readOnly : .none
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = FoldRenderer.pixelFormat
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 120
        v.autoResizeDrawable = false
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        v.delegate = self
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: ScreenStreamer.colorSpace)
        w.contentView = v
        window = w
        view = v
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastDraw == 0 ? 1.0 / 60 : min(now - lastDraw, 1.0 / 20)
        lastDraw = now
        guard let params = paramsProvider?(dt), let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
        if let fresh = frameProvider?() {
            renderer.updateContent(from: fresh, commandBuffer: commandBuffer)
            hasContent = true
        }
        guard hasContent, let drawable = view.currentDrawable else { commandBuffer.commit(); return }
        renderer.encode(params: params, into: commandBuffer, target: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
