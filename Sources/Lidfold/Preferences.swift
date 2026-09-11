import Foundation
import ServiceManagement
import Combine

/// The fixed look of the effect. Tuned once; no sliders.
enum Effect {
    /// Below this lid angle the effect is visible.
    static let activationAngle = 100.0
    /// At this lid angle the picture has fully dissolved into black.
    static let endAngle = 8.0
    /// Share of the physical hinge rotation the picture follows (0...1).
    static let perspective = 0.6
    static let blur = 0.7
    static let shadow = 0.5
}

/// The two switches that persist: on/off and launch at login.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: "isEnabled") } }

    /// Backed by SMAppService; setting it registers or unregisters the login item.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Lidfold: launch at login failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: ["isEnabled": true])
        isEnabled = UserDefaults.standard.bool(forKey: "isEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
