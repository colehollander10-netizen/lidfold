import Foundation
import Metal
import MetalKit
import simd
import CoreGraphics

/// What the shader needs for one frame, derived from a lid angle and the
/// user's sliders by `FoldModel`.
struct FoldParams {
    var tilt: Double = 0            // radians the glass has rotated about the hinge toward the viewer
    var eyeDistance: Double = 2.8   // in screen heights
    var eyeHeight: Double = 1.1     // in screen heights above the hinge
    var blurStrength: Double = 0    // 0...1
    var blurFloor: Double = 0.12    // share of the blur that reaches the hinge edge
    var maxBlurRadius: Double = 0.06 // fraction of content height, in texels at level 0
    var dim: Double = 0             // 0...1 gradient darkening toward the far edge
    var cornerShadow: Double = 0    // 0...1
    var finalFade: Double = 0       // 0...1 fade to black at the very end

    var isIdentity: Bool { tilt <= 0 && blurStrength <= 0 && dim <= 0 && cornerShadow <= 0 && finalFade <= 0 }
}

/// Turns a lid angle plus preferences into shader parameters.
enum FoldModel {
    static func params(angle: Double) -> FoldParams {
        let a0 = Effect.activationAngle, a1 = Effect.endAngle
        let travel = max(0, a0 - angle)
        let progress = min(max(travel / max(a0 - a1, 1), 0), 1)
        var f = FoldParams()
        // The receding picture follows a share of the hinge rotation; the
        // anchored glass follows it exactly.
        f.tilt = min(travel * (Effect.anchored ? 1.0 : 0.74), 85) * .pi / 180
        f.eyeDistance = Effect.eyeDistance
        f.eyeHeight = Effect.eyeHeight
        f.blurStrength = Effect.blur * pow(progress, 1.35)
        f.dim = Effect.shadow * pow(progress, 0.9)
        f.cornerShadow = Effect.shadow * progress * 0.8
        f.finalFade = smoothstep(0.86, 1.0, progress)
        return f
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Glass-uv (y down) to desktop-uv (y down) homography.
    ///
    /// The desktop is a plane fixed in space where the open screen was. The
    /// glass rotates about the hinge (bottom edge) toward a viewer sitting
    /// `eyeDistance` heights in front of it, `eyeHeight` above the hinge. Each
    /// glass point shows whatever the viewer's ray through it hits on the fixed
    /// desktop, so from the viewer's seat the desktop appears to stay put while
    /// the lid sweeps over it. Height above the hinge maps to more magnification
    /// as the glass comes closer, so the picture stretches and its top leaves
    /// through the top of the glass.
    static func screenToContent(aspect A: Double, tilt t: Double, eyeDistance D: Double, eyeHeight ey: Double) -> simd_double3x3 {
        guard Effect.anchored else { return recedingScreenToContent(aspect: A, tilt: t, eyeDistance: D) }
        func hit(_ u: Double, _ v: Double) -> SIMD2<Double> {
            // Glass point at height v sits at (u, v cos t, v sin t); the ray from
            // the eye at (A/2, ey, D) meets the desktop plane z = 0 at scale s.
            let s = D / max(D - v * sin(t), 0.05)
            let x = A / 2 + (u - A / 2) * s
            let y = ey + (v * cos(t) - ey) * s
            return SIMD2(x / A, 1 - y)   // desktop uv, y down
        }
        // Glass uv corners (0,0) top-left, (1,0) top-right, (1,1) bottom-right, (0,1) bottom-left;
        // glass height v is 1 at the top row and 0 at the hinge.
        return squareToQuad([hit(0, 1), hit(A, 1), hit(A, 0), hit(0, 0)])
    }

    /// The other reading of the effect: the picture itself rotates away from
    /// the viewer about the hinge and is projected onto the open screen, so
    /// the whole desktop stays visible and its far edge recedes.
    static func recedingScreenToContent(aspect A: Double, tilt t: Double, eyeDistance D: Double) -> simd_double3x3 {
        func project(_ u: Double, _ v: Double) -> SIMD2<Double> {
            let s = D / (D + v * sin(t))
            return SIMD2((A / 2 + (u - A / 2) * s) / A, 1 - (0.5 + (v * cos(t) - 0.5) * s))
        }
        return squareToQuad([project(0, 1), project(A, 1), project(A, 0), project(0, 0)]).inverse
    }

    /// Heckbert's unit-square to quadrilateral mapping. Corners are for
    /// (0,0), (1,0), (1,1), (0,1). Column-vector convention.
    static func squareToQuad(_ q: [SIMD2<Double>]) -> simd_double3x3 {
        let (x0, y0) = (q[0].x, q[0].y), (x1, y1) = (q[1].x, q[1].y)
        let (x2, y2) = (q[2].x, q[2].y), (x3, y3) = (q[3].x, q[3].y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g = 0.0, h = 0.0
        let det = dx1 * dy2 - dx2 * dy1
        if (abs(dx3) > 1e-12 || abs(dy3) > 1e-12), abs(det) > 1e-14 {
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
        return simd_double3x3(columns: (SIMD3(a, d, g), SIMD3(b, e, h), SIMD3(c, f, 1)))
    }
}

/// Owns the Metal pipeline, the mipmapped copy of the captured picture, and
/// the per-frame encode.
final class FoldRenderer {
    struct Uniforms {
        var c0 = SIMD4<Float>(1, 0, 0, 0), c1 = SIMD4<Float>(0, 1, 0, 0), c2 = SIMD4<Float>(0, 0, 1, 0)
        var blur = SIMD4<Float>(0, 0, 0, 0), dim = SIMD4<Float>(0, 0, 0, 1), size = SIMD4<Float>(1, 1, 1, 1)
    }

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var content: MTLTexture?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            let library = try device.makeLibrary(source: FoldShader.source, options: options)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "foldVertex")
            desc.fragmentFunction = library.makeFunction(name: "foldFragment")
            desc.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Lidfold: shader compile failed: \(error)")
            return nil
        }
    }

    /// Copies a captured frame into the mipmapped content texture.
    func updateContent(from source: MTLTexture, commandBuffer: MTLCommandBuffer) {
        if content == nil || content!.width != source.width || content!.height != source.height {
            content = makeContentTexture(width: source.width, height: source.height)
        }
        guard let content, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: content, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.generateMipmaps(for: content)
        blit.endEncoding()
    }

    /// Loads a still image as the content, for previews and the demo.
    func setContent(_ image: CGImage) throws {
        let loader = MTKTextureLoader(device: device)
        let tex = try loader.newTexture(cgImage: image, options: [
            .SRGB: true, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
        content = tex
    }

    private func makeContentTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: true)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    func uniforms(for params: FoldParams, outputWidth: Int, outputHeight: Int) -> Uniforms {
        var u = Uniforms()
        let aspect = Double(outputWidth) / Double(outputHeight)
        let M = FoldModel.screenToContent(aspect: aspect, tilt: params.tilt, eyeDistance: params.eyeDistance, eyeHeight: params.eyeHeight)
        u.c0 = SIMD4<Float>(Float(M.columns.0.x), Float(M.columns.0.y), Float(M.columns.0.z), 0)
        u.c1 = SIMD4<Float>(Float(M.columns.1.x), Float(M.columns.1.y), Float(M.columns.1.z), 0)
        u.c2 = SIMD4<Float>(Float(M.columns.2.x), Float(M.columns.2.y), Float(M.columns.2.z), 0)
        let cw = content?.width ?? outputWidth, ch = content?.height ?? outputHeight
        let maxLod = Float(max((content?.mipmapLevelCount ?? 1) - 1, 0))
        u.blur = SIMD4<Float>(Float(params.maxBlurRadius * Double(ch)), Float(params.blurStrength), Float(params.blurFloor), min(maxLod, 6))
        u.dim = SIMD4<Float>(Float(params.dim), Float(params.cornerShadow), Float(params.finalFade), Float(aspect))
        u.size = SIMD4<Float>(Float(cw), Float(ch), Float(outputWidth), Float(outputHeight))
        return u
    }

    /// Draws the effect into `target`.
    func encode(params: FoldParams, into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        guard let content else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms(for: params, outputWidth: target.width, outputHeight: target.height)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(content, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Renders offscreen and returns the pixels as an image. Used by the demo.
    func renderImage(params: FoldParams, width: Int, height: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let cb = commandQueue.makeCommandBuffer() else { return nil }
        encode(params: params, into: cb, target: target)
        cb.commit()
        cb.waitUntilCompleted()
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { ptr in
            target.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
