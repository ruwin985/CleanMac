import SwiftUI
import AppKit

@main
struct CleanMacApp: App {
    @StateObject private var viewModel = StorageDashboardViewModel()
    @StateObject private var licenseManager = LicenseManager()

    private static let privacyPolicyURL = URL(string: "https://ruwin985.github.io/CleanMac/legal/privacy/")!
    private static let termsOfServiceURL = URL(string: "https://ruwin985.github.io/CleanMac/legal/terms/")!

    private static func showSettingsFromLaunchArgumentIfNeeded() {
        let wantsSettings = CommandLine.arguments.contains("--show-settings")
        let wantsFeedback = CommandLine.arguments.contains("--show-feedback")
        guard wantsSettings || wantsFeedback else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            for window in NSApp.windows {
                window.orderOut(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            if wantsSettings {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else if wantsFeedback {
                FeedbackWindowController.shared.showWindowAndActivate()
            }
        }
    }

    init() {
        LoginItemRegistrar.registerMenuBarAppIfPossible()
        MenuBarLauncher.launchIfNeeded()
        Self.showSettingsFromLaunchArgumentIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            StorageDashboardView(viewModel: viewModel)
                .frame(minWidth: 1100, minHeight: 760)
                .environmentObject(licenseManager)
                .background(MainWindowConfigurator())
                .taskCompat {
                    await AppUpdateController.shared.checkForUpdatesIfNeeded()
                }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            AppSettingsView()
                .environmentObject(licenseManager)
        }

        .commands {
            CommandGroup(after: .appSettings) {
                Button("检查更新…") {
                    Task {
                        await AppUpdateController.shared.checkForUpdates(userInitiated: true)
                    }
                }

                Divider()

                Button("设置…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])

                Divider()

                Button("隐私政策") {
                    NSWorkspace.shared.open(Self.privacyPolicyURL)
                }

                Button("服务条款") {
                    NSWorkspace.shared.open(Self.termsOfServiceURL)
                }

                Button("退款政策 / 申请退款") {
                    licenseManager.openRefundPage()
                }
            }

            CommandGroup(after: .help) {
                Divider()
                Button("提供反馈…") {
                    FeedbackWindowController.shared.showWindowAndActivate()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 1100, height: 760)
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}

@MainActor
private final class AppUpdateController {
    static let shared = AppUpdateController()

    private let manifestURL = URL(string: "https://ruwin985.github.io/CleanMac/updates/cleanmac.json")!
    private let promptedVersionKey = "CleanMacLastPromptedUpdateVersion"
    private let promptedDateKey = "CleanMacLastPromptedUpdateDate"
    private let promptInterval: TimeInterval = 24 * 60 * 60
    private var hasCheckedAutomatically = false
    private var isChecking = false

    func checkForUpdatesIfNeeded() async {
        guard !hasCheckedAutomatically else { return }
        hasCheckedAutomatically = true
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let manifest = try await AppUpdateManifest.fetch(from: manifestURL)
            let currentVersion = AppVersion.current
            let latestVersion = AppVersion(version: manifest.version, build: manifest.build)

            guard latestVersion > currentVersion else {
                if userInitiated {
                    showMessage(
                        title: "CleanMac 已是最新版本",
                        message: "当前版本：\(currentVersion.displayText)"
                    )
                }
                return
            }

            guard manifest.isCompatibleWithCurrentSystem else {
                if userInitiated {
                    showMessage(
                        title: "发现新版本，但当前系统暂不支持",
                        message: "CleanMac \(latestVersion.displayText) 需要 macOS \(manifest.minimumSystemVersion ?? "更高版本") 或更高版本。"
                    )
                }
                return
            }

            guard userInitiated || shouldPrompt(for: manifest) else { return }
            recordPrompt(for: manifest)
            showUpdatePrompt(manifest: manifest, currentVersion: currentVersion, latestVersion: latestVersion)
        } catch {
            if userInitiated {
                showMessage(
                    title: "暂时无法检查更新",
                    message: "请稍后重试，或前往 CleanMac 官网下载最新版本。"
                )
            }
        }
    }

    private func shouldPrompt(for manifest: AppUpdateManifest) -> Bool {
        if manifest.isCritical { return true }

        let defaults = UserDefaults.standard
        let lastVersion = defaults.string(forKey: promptedVersionKey)
        let lastDate = defaults.object(forKey: promptedDateKey) as? Date

        guard lastVersion == manifest.identifier, let lastDate else { return true }
        return Date().timeIntervalSince(lastDate) >= promptInterval
    }

    private func recordPrompt(for manifest: AppUpdateManifest) {
        let defaults = UserDefaults.standard
        defaults.set(manifest.identifier, forKey: promptedVersionKey)
        defaults.set(Date(), forKey: promptedDateKey)
    }

    private func showUpdatePrompt(manifest: AppUpdateManifest, currentVersion: AppVersion, latestVersion: AppVersion) {
        let alert = NSAlert()
        alert.alertStyle = manifest.isCritical ? .critical : .informational
        alert.messageText = manifest.title ?? "发现 CleanMac 新版本"

        var messageLines = [
            "当前版本：\(currentVersion.displayText)",
            "最新版本：\(latestVersion.displayText)"
        ]

        if let summary = manifest.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            messageLines.append("")
            messageLines.append(summary)
        }

        if manifest.isCritical {
            messageLines.append("")
            messageLines.append("此版本包含重要修复，建议尽快更新。")
        }

        alert.informativeText = messageLines.joined(separator: "\n")
        alert.addButton(withTitle: "立即下载")
        alert.addButton(withTitle: "稍后提醒")
        if manifest.releaseNotesURL != nil {
            alert.addButton(withTitle: "查看更新说明")
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(manifest.downloadURL)
        case .alertThirdButtonReturn:
            if let releaseNotesURL = manifest.releaseNotesURL {
                NSWorkspace.shared.open(releaseNotesURL)
            }
        default:
            break
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

private struct AppUpdateManifest: Decodable {
    let version: String
    let build: Int
    let minimumSystemVersion: String?
    let downloadURL: URL
    let releaseNotesURL: URL?
    let title: String?
    let summary: String?
    let isCritical: Bool

    var identifier: String {
        "\(version)-\(build)"
    }

    var isCompatibleWithCurrentSystem: Bool {
        guard let minimumSystemVersion else { return true }
        return AppVersion.currentSystem >= AppVersion(version: minimumSystemVersion, build: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case minimumSystemVersion
        case downloadURL
        case releaseNotesURL
        case title
        case summary
        case isCritical
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        build = try container.decode(Int.self, forKey: .build)
        minimumSystemVersion = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        releaseNotesURL = try container.decodeIfPresent(URL.self, forKey: .releaseNotesURL)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        isCritical = try container.decodeIfPresent(Bool.self, forKey: .isCritical) ?? false
    }

    static func fetch(from url: URL) async throws -> AppUpdateManifest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(AppUpdateManifest.self, from: data)
    }
}

private struct AppVersion: Comparable {
    let version: String
    let components: [Int]
    let build: Int

    var displayText: String {
        build > 0 ? "\(version) (\(build))" : version
    }

    init(version: String, build: Int) {
        self.version = version
        components = version
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        self.build = build
    }

    static var current: AppVersion {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return AppVersion(version: version, build: Int(buildString) ?? 0)
    }

    static var currentSystem: AppVersion {
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        return AppVersion(version: version, build: 0)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return lhs.build < rhs.build
    }
}
