import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders the effect at a set of lid angles to PNG files, from the current
/// desktop wallpaper when it can be read and a drawn test scene otherwise.
enum RenderDemo {
    static func run(outputDirectory: String) {
        guard let renderer = FoldRenderer() else { print("no Metal device"); return }
        let useScene = ProcessInfo.processInfo.environment["LIDFOLD_DEMO_SCENE"] != nil
        let image = (useScene ? nil : wallpaperImage()) ?? testScene(width: 2560, height: 1664)
        do { try renderer.setContent(image) } catch { print("texture load failed: \(error)"); return }
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let angles: [Double] = [110, 95, 85, 70, 55, 40, 25, 12]
        for angle in angles {
            let params = FoldModel.params(angle: angle)
            guard let out = renderer.renderImage(params: params, width: 1600, height: 1040) else { continue }
            let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(String(format: "lid-%03d.png", Int(angle)))
            write(out, to: url)
            print(String(format: "lid %3.0f°  tilt %5.1f°  blur %.2f  dim %.2f  fade %.2f  -> %@", angle, params.tilt * 180 / .pi,
                         params.blurStrength, params.dim, params.finalFade, url.path))
        }
    }

    static func wallpaperImage() -> CGImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// A stand-in desktop: dusk sky, ridgelines, lake, clock. Roughly the
    /// scene Bendover draws on its landing page.
    static func testScene(width: Int, height: Int) -> CGImage {
        let W = CGFloat(width), H = CGFloat(height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
        }
        let sky = CGGradient(colorsSpace: cs, colors: [color(0x121738), color(0x5c3873), color(0xf5946b), color(0xfdcf95)] as CFArray,
                             locations: [0, 0.4, 0.75, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.38), options: [.drawsAfterEndLocation])
        let sun = CGGradient(colorsSpace: cs, colors: [color(0xfff4d6), color(0xffdca0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(sun, startCenter: CGPoint(x: W * 0.64, y: H * 0.5), startRadius: 6, endCenter: CGPoint(x: W * 0.64, y: H * 0.5), endRadius: W * 0.12, options: [])
        let layers: [(CGFloat, CGFloat, UInt32)] = [(0.50, 0.11, 0x8c6698), (0.56, 0.14, 0x61427a), (0.62, 0.10, 0x38264e)]
        for (i, l) in layers.enumerated() {
            let f = CGFloat(i + 1)
            ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: 0))
            for k in 0...80 {
                let x = CGFloat(k) / 80
                let y = l.0 + l.1 * (0.55 * sin(x * 6.2 * f + f) + 0.30 * sin(x * 15 + 2 * f) + 0.15 * sin(x * 33 + 3 * f))
                ctx.addLine(to: CGPoint(x: x * W, y: H - y * H))
            }
            ctx.addLine(to: CGPoint(x: W, y: 0)); ctx.closePath(); ctx.setFillColor(color(l.2)); ctx.fillPath()
        }
        let lakeTop = H * 0.28
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: lakeTop))
        let lake = CGGradient(colorsSpace: cs, colors: [color(0x9e6680), color(0x1a1a3d)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(lake, start: CGPoint(x: 0, y: lakeTop), end: CGPoint(x: 0, y: 0), options: [])
        ctx.restoreGState()
        // Clock, drawn with Core Text through NSAttributedString.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let shadow = NSShadow(); shadow.shadowBlurRadius = 18; shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
        let date = NSAttributedString(string: DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none),
                                      attributes: [.font: NSFont.systemFont(ofSize: H * 0.045, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.95), .paragraphStyle: para, .shadow: shadow])
        date.draw(in: CGRect(x: 0, y: H * 0.82, width: W, height: H * 0.08))
        let time = NSAttributedString(string: "9:41", attributes: [.font: NSFont.systemFont(ofSize: H * 0.2, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.95), .paragraphStyle: para, .shadow: shadow])
        time.draw(in: CGRect(x: 0, y: H * 0.58, width: W, height: H * 0.26))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
