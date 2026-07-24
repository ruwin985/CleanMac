import SwiftUI
import AppKit

struct SettingsMenuButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "设置")
        button.contentTintColor = .labelColor
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        @objc
        func showMenu(_ sender: NSButton) {
            MenuBarController.shared.showSettingsMenu(relativeTo: sender)
        }
    }
}
