import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private var monitor: LidMonitor!
    private var statusItem: StatusItemController!
    private var permissionTimer: Timer?

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
        // First launch: the system asks for Screen Recording once. macOS only
        // applies the grant to a fresh process, so the app relaunches itself
        // as soon as the grant appears instead of asking anyone to quit.
        if !ScreenStreamer.hasPermission {
            ScreenStreamer.requestPermission()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard ScreenStreamer.hasPermission else { return }
                Log.write("Screen Recording granted, relaunching to apply it")
                self?.relaunch()
            }
        }
        if let angle = launchPreviewAngle { monitor.previewAngle = angle }
    }

    private func relaunch() {
        permissionTimer?.invalidate(); permissionTimer = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Log.write("relaunch failed: \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}
