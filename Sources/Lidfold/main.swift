import AppKit

let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "--probe" {
    let sensor = LidAngleSensor()
    guard sensor.isAvailable, let res = sensor.resolution else {
        print("lid angle sensor not found (status \(sensor.lastStatus))"); exit(1)
    }
    print("sensor: \(res.label)")
    let seconds = Double(arguments.dropFirst().first ?? "3") ?? 3
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let a = sensor.angle() { print(String(format: "%.2f°", a)) } else { print("read failed") }
        Thread.sleep(forTimeInterval: 0.2)
    }
    exit(0)
}

if arguments.first == "--render-demo" {
    let outDir = arguments.dropFirst().first ?? FileManager.default.temporaryDirectory.appendingPathComponent("lidfold-demo").path
    RenderDemo.run(outputDirectory: outDir)
    exit(0)
}

/// `--preview <angle>` shows the effect at that lid angle right after launch.
var launchPreviewAngle: Double? = {
    guard let i = arguments.firstIndex(of: "--preview") else { return nil }
    return Double(arguments.dropFirst(i - arguments.startIndex + 1).first ?? "")
}()

/// `--simulate-close`: scripted lid, 120° -> 0° over 3 s, shut 2 s, back open over 3 s.
let simulateClose = arguments.contains("--simulate-close")

if arguments.contains("--capturable") { OverlayWindowController.capturableForDebugging = true }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
