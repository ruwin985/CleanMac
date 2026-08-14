import AppKit
import SwiftUI
import Darwin.Mach

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let memoryMonitor = MemoryMonitor()
    private var popover: NSPopover?

    private override init() {
        super.init()
        configureStatusItem()
    }

    func start() {
        memoryMonitor.start()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        if let icon = NSImage(named: "AppIcon") {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            button.image = icon
        }
        button.title = ""
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 180)
        popover.contentViewController = NSHostingController(rootView: MenuBarPanelView(memoryMonitor: memoryMonitor) {
            self.openMainWindow()
        })
        self.popover = popover
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openMainWindow() {
        popover?.performClose(nil)
        for window in NSApp.windows where window !== FeedbackWindowController.shared.window {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var availableMemoryBytes: UInt64 = 0

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var availableMemoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(availableMemoryBytes), countStyle: .memory)
    }

    private func refresh() {
        availableMemoryBytes = Self.readAvailableMemoryBytes() ?? 0
    }

    private static func readAvailableMemoryBytes() -> UInt64? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        let free = UInt64(stats.free_count) * UInt64(pageSize)
        let inactive = UInt64(stats.inactive_count) * UInt64(pageSize)
        let speculative = UInt64(stats.speculative_count) * UInt64(pageSize)
        return free + inactive + speculative
    }
}

struct MenuBarPanelView: View {
    @ObservedObject var memoryMonitor: MemoryMonitor
    let openApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: openApp) {
                HStack(spacing: 12) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CleanMac")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyleCompat(.primary)
                        Text("点击打开 CleanMac")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyleCompat(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyleCompat(.secondary)
                }
                .padding(14)
                .backgroundThinMaterialCompat(fallback: Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("当前可用内存")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyleCompat(.secondary)
                Text(memoryMonitor.availableMemoryText)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyleCompat(.primary)
//                Text("每 2 秒自动刷新")
//                    .font(.system(size: 12, weight: .medium, design: .rounded))
//                    .foregroundStyleCompat(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .backgroundRegularMaterialCompat(fallback: Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer(minLength: 0)
        }
                    HStack {
                Spacer()
                Button("退出 CleanMac") {
                    MenuBarController.shared.quitApp()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyleCompat(.secondary)
                .buttonStyle(.plain)
            }
        .padding(16)
        .frame(width: 300, height: 220)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
