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
        let protectedDirectories = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/CallHistoryDB", isDirectory: true)
        ]

        if protectedDirectories.contains(where: canEnumerateProtectedDirectory) {
            return true
        }

        let protectedFiles = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        ]

        return protectedFiles.contains(where: canReadProtectedFile)
    }

    private func canEnumerateProtectedDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return !contents.isEmpty || canOpenDirectoryStream(at: url)
        } catch {
            return false
        }
    }

    private func canOpenDirectoryStream(at url: URL) -> Bool {
        let handle = opendir(url.path)
        guard let handle else { return false }
        closedir(handle)
        return true
    }

    private func canReadProtectedFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? Data(contentsOf: url, options: [.mappedIfSafe])) != nil
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
