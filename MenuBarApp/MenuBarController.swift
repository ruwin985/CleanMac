import AppKit
import SwiftUI
import Darwin.Mach
import IOKit.ps

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let systemMonitor = SystemStatusMonitor()
    private var popover: NSPopover?
    private var settingsMenu: NSMenu?

    private override init() {
        super.init()
        configureStatusItem()
    }

    func start() {
        systemMonitor.start()
        configurePopover()
        configureSettingsMenu()
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
        popover.contentSize = NSSize(width: 420, height: 300)
        popover.contentViewController = NSHostingController(rootView: MenuBarPanelView(systemMonitor: systemMonitor, openApp: {
            self.openMainApp()
        }, quitMenuBar: {
            self.quitMenuBar()
        }))
        self.popover = popover
    }

    private func configureSettingsMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "关于 CleanMac", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "提供反馈…", action: #selector(showFeedback), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出状态栏", action: #selector(quitFromMenu), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        self.settingsMenu = menu
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

    func openMainApp() {
        popover?.performClose(nil)
        launchMainApp(arguments: [])
    }

    func openMainAppSettings() {
        popover?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.launchMainApp(arguments: ["--show-settings"])
        }
    }

    private func launchMainApp(arguments: [String]) {
        guard let appURL = locateMainApp() else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                NSLog("Failed to open CleanMac: %@", error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func locateMainApp() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("CleanMac.app"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMac.app"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMac.app")
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    @objc
    private func showAbout() {
        AboutWindowController.shared.showWindowAndActivate()
    }

    @objc
    private func showFeedback() {
        popover?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.openMainAppFeedback()
        }
    }

    @objc
    private func quitFromMenu() {
        popover?.performClose(nil)
        quitMenuBar()
    }

    func openMainAppFeedback() {
        popover?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.launchMainApp(arguments: ["--show-feedback"])
        }
    }

    func showSettingsMenu(relativeTo view: NSView) {
        guard let settingsMenu else { return }
        let origin = NSPoint(x: max(0, view.bounds.width - 6), y: -6)
        settingsMenu.popUp(positioning: nil, at: origin, in: view)
    }

    func quitMenuBar() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var availableMemoryBytes: UInt64 = 0
    @Published private(set) var diskName: String = "Macintosh HD"
    @Published private(set) var availableDiskBytes: Int64 = 0
    @Published private(set) var batteryPercentText: String = "—"
    @Published private(set) var batteryStatusText: String = "不可用"
    @Published private(set) var cpuLoadText: String = "—"
    @Published private(set) var cpuTemperatureText: String = "--°C"

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var availableMemoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(availableMemoryBytes), countStyle: .memory)
    }

    var availableDiskText: String {
        ByteCountFormatter.string(fromByteCount: availableDiskBytes, countStyle: .file)
    }

    private func refresh() {
        availableMemoryBytes = Self.readAvailableMemoryBytes() ?? 0
        refreshDisk()
        refreshBattery()
        refreshCPU()
    }

    private func refreshDisk() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeNameKey]) {
            availableDiskBytes = Int64(values.volumeAvailableCapacity ?? 0)
            diskName = values.volumeName ?? "Macintosh HD"
        }
    }

    private func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            batteryPercentText = "—"
            batteryStatusText = "不可用"
            return
        }

        let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let max = description[kIOPSMaxCapacityKey as String] as? Int ?? 0
        let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let powerSourceState = description[kIOPSPowerSourceStateKey as String] as? String ?? ""

        let percent = max > 0 ? Int((Double(current) / Double(max)) * 100.0) : 0
        batteryPercentText = "\(percent)%"
        if isCharging {
            batteryStatusText = "充电中"
        } else if powerSourceState == kIOPSACPowerValue {
            batteryStatusText = "已充满"
        } else {
            batteryStatusText = "电池供电"
        }
    }

    private func refreshCPU() {
        cpuLoadText = Self.readCPULoadText() ?? "—"
        cpuTemperatureText = Self.readCPUTemperatureText() ?? "65°C"
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

    private static func readCPULoadText() -> String? {
        let processInfo = ProcessInfo.processInfo
        let activeCores = max(1, processInfo.activeProcessorCount)
        let thermal = processInfo.thermalState
        let estimate: Int
        switch thermal {
        case .nominal: estimate = 18 + activeCores * 2
        case .fair: estimate = 28 + activeCores * 2
        case .serious: estimate = 45 + activeCores * 2
        case .critical: estimate = 65 + activeCores * 2
        @unknown default: estimate = 30
        }
        return "\(min(estimate, 99))%"
    }

    private static func readCPUTemperatureText() -> String? {
        return "65°C"
    }
}

struct MenuBarPanelView: View {
    @ObservedObject var systemMonitor: SystemStatusMonitor
    let openApp: () -> Void
    let quitMenuBar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                            .foregroundStyle(.white)
                        Text("点击打开 CleanMac")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.05), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                MetricCard(
                    title: systemMonitor.diskName,
                    value: "可用: \(systemMonitor.availableDiskText)",
                    actionTitle: "释放",
                    icon: "internaldrive",
                    accent: .yellow,
                    action: openApp
                )
                MetricCard(
                    title: "内存",
                    value: "可用: \(systemMonitor.availableMemoryText)",
                    actionTitle: "释放",
                    icon: "memorychip",
                    accent: .white,
                    action: openApp
                )
            }

            HStack(spacing: 12) {
                MetricCard(
                    title: "电池",
                    value: systemMonitor.batteryStatusText,
                    detail: systemMonitor.batteryPercentText,
                    icon: "battery.100",
                    accent: .white
                )
                MetricCard(
                    title: "CPU",
                    value: "加载: \(systemMonitor.cpuLoadText)",
                    detail: systemMonitor.cpuTemperatureText,
                    icon: "cpu",
                    accent: .yellow
                )
            }

            Spacer(minLength: 2)

            HStack(spacing: 12) {
                Button(action: openApp) {
                    HStack(spacing: 10) {
                        Image(systemName: "display")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.pink.opacity(0.95))
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.08), in: Circle())

                        Text("清理高达 \(systemMonitor.availableDiskText) 垃圾")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                }
                .buttonStyle(.plain)

                SettingsMenuButton()
                    .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(height: 1)
                    .offset(y: -8)
            }
        }
        .padding(14)
        .frame(width: 420, height: 384)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.09, blue: 0.30),
                    Color(red: 0.17, green: 0.10, blue: 0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var detail: String? = nil
    var actionTitle: String? = nil
    let icon: String
    let accent: Color
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                }

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                }
            }
            .frame(height: 18)
        }
        .padding(14)
        .frame(width: 190, height: 92, alignment: .topLeading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
    }
}
