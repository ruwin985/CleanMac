import AppKit
import ServiceManagement

@MainActor
enum LoginItemRegistrar {
    private static let defaultsKey = "launchMenuBarAtLogin"

    static var launchMenuBarAtLogin: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            applyLaunchPreference(enabled: newValue)
        }
    }

    static func registerMenuBarAppIfPossible() {
        applyLaunchPreference(enabled: launchMenuBarAtLogin)
    }

    static func applyLaunchPreference(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.loginItem(identifier: "com.zyb.CleanMac.MenuBar")

        do {
            switch (enabled, service.status) {
            case (true, .enabled), (true, .requiresApproval), (false, .notRegistered):
                break
            case (true, .notRegistered):
                try service.register()
            case (true, .notFound):
                NSLog("CleanMacMenuBar login item not found in app bundle.")
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            case (false, .notFound):
                break
            @unknown default:
                break
            }
        } catch {
            NSLog("Failed to update login item state: %@", error.localizedDescription)
        }
    }
}
