import AppKit

@MainActor
enum MenuBarLauncher {
    static func launchIfNeeded() {
        guard let menuBarAppURL = bundledMenuBarAppURL() else {
            NSLog("CleanMacMenuBar.app not found in bundle hierarchy.")
            return
        }
        let bundleIdentifier = "com.zyb.CleanMac.MenuBar"

        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
        guard !isRunning else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: menuBarAppURL, configuration: configuration) { _, error in
            if let error {
                NSLog("Failed to launch CleanMacMenuBar: %@", error.localizedDescription)
            }
        }
    }

    private static func bundledMenuBarAppURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let candidates: [URL] = [
            contentsURL.appendingPathComponent("Resources/CleanMacMenuBar.app", isDirectory: true),
            contentsURL.appendingPathComponent("Applications/CleanMacMenuBar.app", isDirectory: true),
            contentsURL.appendingPathComponent("Library/LoginItems/CleanMacMenuBar.app", isDirectory: true),
            bundleURL.deletingLastPathComponent().appendingPathComponent("CleanMacMenuBar.app", isDirectory: true),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMacMenuBar.app", isDirectory: true),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMacMenuBar.app", isDirectory: true)
        ]

        let fileManager = FileManager.default
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
