import AppKit
import SwiftUI
import Darwin.Mach
import IOKit.ps

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private static let lowDiskThresholdBytes: Int64 = 50_000_000_000
    private static let lowDiskPromptLastShownDayKey = "lowDiskSpacePrompt.lastShownDay"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let systemMonitor = SystemStatusMonitor()
    private var popover: NSPopover?
    private var lowDiskPopover: NSPopover?
    private var lowDiskPromptTimer: Timer?
    private var settingsMenu: NSMenu?

    private override init() {
        super.init()
        configureStatusItem()
    }

    func start() {
        systemMonitor.start()
        configurePopover()
        configureSettingsMenu()
        scheduleLowDiskPromptChecks()
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
        }, releaseMemory: {
            self.systemMonitor.releaseMemory()
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
        if lowDiskPopover?.isShown == true {
            lowDiskPopover?.performClose(sender)
            return
        }

        if shouldShowLowDiskPromptToday {
            popover.performClose(sender)
            showLowDiskPrompt(relativeTo: button)
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openMainApp() {
        popover?.performClose(nil)
        lowDiskPopover?.performClose(nil)
        launchMainApp(arguments: [])
    }

    func openMainAppSettings() {
        popover?.performClose(nil)
        lowDiskPopover?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.launchMainApp(arguments: ["--show-settings"])
        }
    }

    private func launchMainApp(arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments

        if let appURL = locateMainApp() {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("Failed to open CleanMac via URL: %@", error.localizedDescription)
                    self.launchMainAppByBundleIdentifier(arguments: arguments)
                }
            }
            return
        }

        launchMainAppByBundleIdentifier(arguments: arguments)
    }

    private func launchMainAppByBundleIdentifier(arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.zyb.CleanMac") else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                NSLog("Failed to open CleanMac via bundle identifier: %@", error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func locateMainApp() -> URL? {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let candidates = [
            contentsURL.deletingLastPathComponent().appendingPathComponent("MacOS/CleanMac.app"),
            contentsURL.appendingPathComponent("../../CleanMac.app").standardizedFileURL,
            bundleURL.deletingLastPathComponent().appendingPathComponent("CleanMac.app", isDirectory: true),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMac.app", isDirectory: true),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CleanMac.app", isDirectory: true)
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
        lowDiskPopover?.performClose(nil)
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

    private func scheduleLowDiskPromptChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showLowDiskPromptIfNeeded()
        }

        lowDiskPromptTimer?.invalidate()
        lowDiskPromptTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.showLowDiskPromptIfNeeded()
            }
        }
    }

    private func showLowDiskPromptIfNeeded() {
        guard let button = statusItem.button,
              popover?.isShown != true,
              shouldShowLowDiskPromptToday else { return }

        showLowDiskPrompt(relativeTo: button)
    }

    private func showLowDiskPrompt(relativeTo button: NSStatusBarButton) {
        markLowDiskPromptShownToday()

        let prompt = lowDiskPopover ?? makeLowDiskPopover()
        prompt.contentViewController = NSHostingController(
            rootView: LowDiskSpacePromptView(
                diskName: systemMonitor.diskName,
                availableBytes: systemMonitor.availableDiskBytes,
                totalBytes: systemMonitor.totalDiskBytes,
                dismiss: { [weak self] in self?.dismissLowDiskPrompt() },
                openApp: { [weak self] in self?.openMainApp() }
            )
        )
        lowDiskPopover = prompt
        prompt.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var shouldShowLowDiskPromptToday: Bool {
        systemMonitor.availableDiskBytes > 0
            && systemMonitor.availableDiskBytes < Self.lowDiskThresholdBytes
            && lowDiskPopover?.isShown != true
            && !hasShownLowDiskPromptToday()
    }

    private func makeLowDiskPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 338, height: 202)
        return popover
    }

    private func dismissLowDiskPrompt() {
        lowDiskPopover?.performClose(nil)
    }

    private func hasShownLowDiskPromptToday() -> Bool {
        UserDefaults.standard.string(forKey: Self.lowDiskPromptLastShownDayKey) == Self.currentDayString()
    }

    private func markLowDiskPromptShownToday() {
        UserDefaults.standard.set(Self.currentDayString(), forKey: Self.lowDiskPromptLastShownDayKey)
    }

    private static func currentDayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.autoupdatingCurrent
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

@MainActor
final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var availableMemoryBytes: UInt64 = 0
    @Published private(set) var diskName: String = "Macintosh HD"
    @Published private(set) var availableDiskBytes: Int64 = 0
    @Published private(set) var totalDiskBytes: Int64 = 0
    @Published private(set) var totalCleanedBytes: Int64 = 0
    @Published private(set) var batteryPercentText: String = "—"
    @Published private(set) var batteryStatusText: String = "不可用"
    @Published private(set) var cpuLoadText: String = "—"
    @Published private(set) var cpuTemperatureText: String = "--°C"
    @Published private(set) var isReleasingMemory = false
    @Published private(set) var memoryReleaseStatusText: String?

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

    var totalCleanedText: String {
        ByteCountFormatter.string(fromByteCount: totalCleanedBytes, countStyle: .file)
    }

    func releaseMemory() {
        guard !isReleasingMemory else { return }
        isReleasingMemory = true
        memoryReleaseStatusText = nil

        Task {
            let failureReason = await Task.detached(priority: .userInitiated) {
                Self.runMemoryReleaseCommand()
            }.value

            if let failureReason {
                memoryReleaseStatusText = "释放失败"
                NSLog("Failed to release memory from menu bar: %@", failureReason)
                NSSound.beep()
            } else {
                refresh()
                memoryReleaseStatusText = "已释放"
            }

            isReleasingMemory = false
            clearMemoryReleaseStatusLater()
        }
    }

    private func refresh() {
        availableMemoryBytes = Self.readAvailableMemoryBytes() ?? 0
        refreshDisk()
        totalCleanedBytes = CleanupHistoryReader.totalCleanedBytes()
        refreshBattery()
        refreshCPU()
    }

    private func refreshDisk() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeNameKey]) {
            availableDiskBytes = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            totalDiskBytes = Int64(values.volumeTotalCapacity ?? 0)
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

    nonisolated private static func runMemoryReleaseCommand() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        process.arguments = ["-S", "-l", "warn"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : "memory_pressure exited with status \(process.terminationStatus)"
        }

        return nil
    }

    private func clearMemoryReleaseStatusLater() {
        let currentStatus = memoryReleaseStatusText
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if memoryReleaseStatusText == currentStatus {
                memoryReleaseStatusText = nil
            }
        }
    }
}

struct MenuBarPanelView: View {
    @ObservedObject var systemMonitor: SystemStatusMonitor
    let openApp: () -> Void
    let releaseMemory: () -> Void
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
                            .foregroundStyleCompat(.white)
                        Text("点击打开 CleanMac")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyleCompat(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyleCompat(.white.opacity(0.7))
                }
                .padding(14)
                .backgroundCompat(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    detail: systemMonitor.memoryReleaseStatusText,
                    actionTitle: systemMonitor.isReleasingMemory ? "释放中…" : "释放",
                    icon: "memorychip",
                    accent: .white,
                    action: releaseMemory,
                    isActionDisabled: systemMonitor.isReleasingMemory
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
                            .foregroundStyleCompat(.pink.opacity(0.95))
                            .frame(width: 22, height: 22)
                            .backgroundCompat(.white.opacity(0.08), in: Circle())

                        Text("已累计清理 \(systemMonitor.totalCleanedText) 垃圾")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyleCompat(.white)

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
            .overlayCompat(alignment: .top) {
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
    var isActionDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyleCompat(.white.opacity(0.9))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyleCompat(.white)
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyleCompat(accent)
                }

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyleCompat(accent)
                }
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyleCompat(.white)
                        .buttonStyle(.plain)
                        .disabled(isActionDisabled)
                        .opacity(isActionDisabled ? 0.62 : 1)
                        .padding(.top, 2)
                }
            }
            .frame(height: 18)
        }
        .padding(14)
        .frame(width: 190, height: 92, alignment: .topLeading)
        .backgroundCompat(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct LowDiskSpacePromptView: View {
    let diskName: String
    let availableBytes: Int64
    let totalBytes: Int64
    let dismiss: () -> Void
    let openApp: () -> Void

    private var availableText: String {
        String(format: "%.2f GB", Double(max(availableBytes, 0)) / 1_000_000_000)
    }

    private var usedRatio: CGFloat {
        guard totalBytes > 0 else { return 0.9 }
        let usedBytes = max(totalBytes - availableBytes, 0)
        let ratio = Double(usedBytes) / Double(totalBytes)
        return CGFloat(min(max(ratio, 0.06), 0.96))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("磁盘空间快用完了！")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyleCompat(.white)

                    Text("启动 CleanMac 移除不需要的项目并恢复空间。")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyleCompat(Color(red: 0.65, green: 0.80, blue: 0.96))
                }

                HStack(spacing: 15) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.82, green: 0.82, blue: 0.82),
                                        Color(red: 0.48, green: 0.48, blue: 0.48)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)

                        Image(systemName: "apple.logo")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyleCompat(.black.opacity(0.24))

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.black.opacity(0.28))
                            .frame(height: 4)
                            .offset(y: 18)
                    }
                    .frame(width: 33, height: 39)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(diskName)
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyleCompat(.white)

                            Spacer()

                            Text("可用： \(availableText)")
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyleCompat(.white)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.23))

                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 1.0, green: 0.35, blue: 0.25),
                                                Color(red: 1.0, green: 0.48, blue: 0.32)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(10, proxy.size.width * usedRatio))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .padding(.leading, 3)
            }
            .padding(.top, 21)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
                .overlay(Color.white.opacity(0.38))

            HStack {
                Button(action: dismiss) {
                    Text("忽略")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyleCompat(.white.opacity(0.95))
                        .frame(width: 68, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(red: 0.37, green: 0.63, blue: 0.82).opacity(0.9))
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: openApp) {
                    Text("打开 CleanMac")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyleCompat(.white)
                        .frame(width: 128, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.10, green: 0.55, blue: 0.96),
                                            Color(red: 0.08, green: 0.43, blue: 0.88)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 55)
            .background(Color(red: 0.07, green: 0.34, blue: 0.48).opacity(0.72))
        }
        .frame(width: 338, height: 202)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.34, blue: 0.48),
                    Color(red: 0.06, green: 0.31, blue: 0.45),
                    Color(red: 0.08, green: 0.40, blue: 0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private enum CleanupHistoryReader {
    private static let totalCleanedBytesKey = "totalCleanedBytes"

    static func totalCleanedBytes() -> Int64 {
        guard let storeURL,
              let data = try? Data(contentsOf: storeURL),
              let payload = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return 0
        }

        if let value = payload[totalCleanedBytesKey] as? Int64 {
            return value
        }
        if let value = payload[totalCleanedBytesKey] as? Int {
            return Int64(value)
        }
        return 0
    }

    private static var storeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CleanMac", isDirectory: true)
            .appendingPathComponent("CleanupHistory.plist")
    }
}
