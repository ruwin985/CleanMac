import AppKit
import Foundation

@MainActor
final class DiskAuthorizationManager {
    static let shared = DiskAuthorizationManager()

    private let defaults = UserDefaults.standard
    private let hasPromptedKey = "diskAuthorization.hasPromptedForFullDiskAccess"

    private init() {}

    var hasPromptedForFullDiskAccess: Bool {
        defaults.bool(forKey: hasPromptedKey)
    }

    var hasFullDiskAccess: Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let protectedCandidates = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
        ]

        for url in protectedCandidates where fileManager.fileExists(atPath: url.path) {
            if canEnumerateProtectedDirectory(at: url) {
                return true
            }
        }

        return false
    }

    private func canEnumerateProtectedDirectory(at url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else {
            return false
        }

        for case let itemURL as URL in enumerator {
            _ = itemURL.path
            return true
        }

        return false
    }

    func markPromptedForFullDiskAccess() {
        defaults.set(true, forKey: hasPromptedKey)
    }

    func openFullDiskAccessSettings() {
        markPromptedForFullDiskAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
