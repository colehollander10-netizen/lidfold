import AppKit
// Lays PNGs side by side with a gap: compose.swift out.png a.png b.png c.png
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let images = args.dropFirst(2).compactMap { NSImage(contentsOfFile: $0) }
let gap = 24.0, targetW = 1000.0
let scale = targetW / images[0].size.width
let w = images[0].size.width * scale, h = images[0].size.height * scale
let total = NSSize(width: w * Double(images.count) + gap * Double(images.count - 1), height: h)
let canvas = NSImage(size: total, flipped: false) { _ in
    NSColor.black.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: total)).fill()
    for (i, img) in images.enumerated() {
        let r = NSRect(x: Double(i) * (w + gap), y: 0, width: w, height: h)
        NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).addClip()
        img.draw(in: r)
        NSGraphicsContext.current?.cgContext.resetClip()
    }
    return true
}
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: out)
