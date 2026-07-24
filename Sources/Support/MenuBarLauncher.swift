import AppKit

@MainActor
enum MenuBarLauncher {
    static func launchIfNeeded() {
        guard let menuBarAppURL = bundledMenuBarAppURL() else { return }
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
        let candidates: [URL?] = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("CleanMacMenuBar.app"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMacMenuBar.app"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMacMenuBar.app")
        ]

        let fileManager = FileManager.default
        return candidates.compactMap { $0 }.first { fileManager.fileExists(atPath: $0.path) }
    }
}
