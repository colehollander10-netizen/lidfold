import AppKit

// Draws the app icon: a dark rounded square with a desktop tile tilting away
// from a hinge at the bottom, the way the effect looks mid-close.
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 180, yRadius: 180)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.13, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.03, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // Tilted screen: bottom edge wide and pinned, top edge narrower and higher.
    let tile = NSBezierPath()
    tile.move(to: CGPoint(x: 220, y: 250))
    tile.line(to: CGPoint(x: 804, y: 250))
    tile.line(to: CGPoint(x: 712, y: 690))
    tile.line(to: CGPoint(x: 312, y: 690))
    tile.close()
    ctx.saveGState()
    tile.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.99, green: 0.81, blue: 0.58, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.22, alpha: 0.35),
    ], atLocations: [0, 0.35, 0.75, 1], colorSpace: .deviceRGB)!.draw(in: tile.bounds, angle: 90)
    ctx.restoreGState()
    // Hinge line.
    NSColor(white: 1, alpha: 0.35).setStroke()
    let hinge = NSBezierPath()
    hinge.move(to: CGPoint(x: 220, y: 250)); hinge.line(to: CGPoint(x: 804, y: 250))
    hinge.lineWidth = 10; hinge.lineCapStyle = .round; hinge.stroke()
    return true
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let tiff = image.tiffRepresentation!, rep = NSBitmapImageRep(data: tiff)!
try! rep.representation(using: .png, properties: [:])!.write(to: out)
