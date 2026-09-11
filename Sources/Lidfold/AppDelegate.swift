import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private var monitor: LidMonitor!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = LidMonitor(preferences: preferences)
        if simulateClose {
            monitor.simulatedAngle = { t in
                switch t {
                case ..<3: return 120 - 120 * (t / 3)
                case ..<5: return 0
                case ..<8: return 120 * ((t - 5) / 3)
                default: return 120
                }
            }
        }
        statusItem = StatusItemController(preferences: preferences, monitor: monitor)
        monitor.start()
        // First launch: the system asks for Screen Recording once, then the
        // menu shows a shortcut to the setting until it is granted.
        if !ScreenStreamer.hasPermission { ScreenStreamer.requestPermission() }
        if let angle = launchPreviewAngle { monitor.previewAngle = angle }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}
