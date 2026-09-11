import AppKit
import Combine

/// The menu bar item: status, live angle, on/off, login item, quit.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let preferences: Preferences
    private let monitor: LidMonitor
    private var bag = Set<AnyCancellable>()

    init(preferences: Preferences, monitor: LidMonitor) {
        self.preferences = preferences
        self.monitor = monitor
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Lidfold")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        monitor.$currentAngle.combineLatest(monitor.$isSensorAvailable)
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] angle, available in
                self?.item.button?.title = available ? String(format: " %.0f°", angle) : ""
            }
            .store(in: &bag)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: monitor.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !ScreenStreamer.hasPermission {
            let grant = NSMenuItem(title: "Open Screen Recording Settings…", action: #selector(openPermission), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        menu.addItem(.separator())
        let follow = NSMenuItem(title: "Follow the Lid", action: #selector(toggleEnabled), keyEquivalent: "")
        follow.target = self
        follow.state = preferences.isEnabled ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = preferences.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lidfold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() { preferences.isEnabled.toggle() }
    @objc private func toggleLogin() { preferences.launchAtLogin.toggle() }
    @objc private func openPermission() { monitor.openScreenRecordingSettings() }
}
