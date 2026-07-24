import AppKit

final class AppLifecycleController: NSObject, NSApplicationDelegate {
    static let shared = AppLifecycleController()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    @objc
    func hideMainWindow() {
        NSApp.keyWindow?.close()
        NSApp.mainWindow?.orderOut(nil)
        NSApp.hide(nil)
    }

    @objc
    func quitApp() {
        NSApp.terminate(nil)
    }
}
