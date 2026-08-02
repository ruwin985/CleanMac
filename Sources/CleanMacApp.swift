import SwiftUI
import AppKit

@main
struct CleanMacApp: App {
    @StateObject private var viewModel = StorageDashboardViewModel()
    @StateObject private var licenseManager = LicenseManager()

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
