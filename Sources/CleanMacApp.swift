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
        }
        .windowResizability(.contentSize)

        Settings {
            AppSettingsView()
                .environmentObject(licenseManager)
        }

        .commands {
            CommandGroup(after: .appSettings) {
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
