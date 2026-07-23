import Foundation
import SwiftUI

@MainActor
final class StorageDashboardViewModel: ObservableObject {
    enum PrimaryActionPhase {
        case idle
        case scanning
        case cleaning
        case protecting
        case optimizing

        var title: String {
            switch self {
            case .idle: return "运行"
            case .scanning: return "扫描中"
            case .cleaning: return "正在清理"
            case .protecting: return "正在保护"
            case .optimizing: return "正在优化"
            }
        }

        var symbolName: String {
            switch self {
            case .idle: return "play.fill"
            case .scanning: return "waveform.path.ecg"
            case .cleaning: return "sparkles"
            case .protecting: return "shield.fill"
            case .optimizing: return "speedometer"
            }
        }
    }

    @Published var snapshot: StorageSnapshot?
    @Published var isScanning = false
    @Published var selectedCategory: StorageCategory?
    @Published var detailKind: DashboardDetailKind = .cleaning
    @Published var sortOption: CategorySortOption = .sizeDescending
    @Published var lastErrorMessage: String?
    @Published var isCleaning = false
    @Published var toastMessage: String?
    @Published var dashboardStage: DashboardStage = .ready
    @Published var scanRotation = 0.0
    @Published var hasPromptedForFullDiskAccess = DiskAuthorizationManager.shared.hasPromptedForFullDiskAccess
    @Published var selectedThreatKind: ProtectionThreatKind?
    @Published var selectedThreatKinds: Set<ProtectionThreatKind> = []
    @Published var activePopover: DashboardPopoverContent?
    @Published var hoveredCard: DashboardCardKind?
    @Published var lastSpeedExecutionResult: SpeedExecutionResult?
    @Published var scanCurrentPath: String = ""
    @Published var scanDiscoveredCleanableBytes: Int64 = 0
    @Published var primaryActionPhase: PrimaryActionPhase = .idle
    @Published var pendingManualActionCount: Int = 0

    var orderedCategories: [StorageCategory] {
        guard let snapshot else { return [] }
        return snapshot.categories.sorted { lhs, rhs in
            switch sortOption {
            case .sizeDescending:
                return lhs.sizeInBytes > rhs.sizeInBytes
            case .sizeAscending:
                return lhs.sizeInBytes < rhs.sizeInBytes
            case .title:
                return lhs.title.localizedCompare(rhs.title) == .orderedAscending
            }
        }
    }

    var cleanCategory: StorageCategory? {
        orderedCategories.max(by: { $0.cleanableSizeInBytes < $1.cleanableSizeInBytes })
    }

    var protectionCount: Int {
        snapshot?.protectionThreatGroups.reduce(0) { $0 + $1.threatCount } ?? 0
    }

    var speedTaskCount: Int {
        snapshot?.speedTasks.count ?? 0
    }

    var protectionThreatGroups: [ProtectionThreatGroup] {
        snapshot?.protectionThreatGroups ?? []
    }

    var areAllThreatsSelected: Bool {
        let allKinds = Set(protectionThreatGroups.map(\.kind))
        return !allKinds.isEmpty && selectedThreatKinds == allKinds
    }

    var selectedThreatGroups: [ProtectionThreatGroup] {
        if selectedThreatKinds.isEmpty {
            return []
        }
        return protectionThreatGroups.filter { selectedThreatKinds.contains($0.kind) }
    }

    var selectedThreatGroup: ProtectionThreatGroup? {
        let groups = protectionThreatGroups
        guard !groups.isEmpty else { return nil }
        if let selectedThreatKind,
           let group = groups.first(where: { $0.kind == selectedThreatKind }) {
            return group
        }
        return groups.first
    }

    var hasOptimizedSpeedTasks: Bool {
        lastSpeedExecutionResult != nil
    }

    var hasFullDiskAccess: Bool {
        DiskAuthorizationManager.shared.hasFullDiskAccess
    }

    var primaryActionTitle: String {
        if dashboardStage == .ready {
            return isScanning ? "扫描中" : "扫描"
        }
        return primaryActionPhase.title
    }

    var primaryActionSymbolName: String {
        if dashboardStage == .ready {
            return isScanning ? PrimaryActionPhase.scanning.symbolName : "magnifyingglass"
        }
        return primaryActionPhase.symbolName
    }

    var isPrimaryActionInProgress: Bool {
        isScanning || primaryActionPhase != .idle
    }

    func visibleItems(for category: StorageCategory) -> [StorageItem] {
        let cleanable = category.items.filter(\.isCleanable)
        switch sortOption {
        case .sizeDescending:
            return cleanable.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .sizeAscending:
            return cleanable.sorted { $0.sizeInBytes < $1.sizeInBytes }
        case .title:
            return cleanable.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    func refresh() async {
        isScanning = true
        primaryActionPhase = .scanning
        startScanAnimation()
        defer {
            isScanning = false
            primaryActionPhase = .idle
            stopScanAnimation()
        }

        scanCurrentPath = ""
        scanDiscoveredCleanableBytes = 0

        let snapshot = await Task.detached(priority: .userInitiated) { [weak self] in
            StorageScanner(progress: { progress in
                Task { @MainActor in
                    self?.scanCurrentPath = progress.currentPath
                    self?.scanDiscoveredCleanableBytes = progress.discoveredCleanableBytes
                }
            }).scan()
        }.value

        self.snapshot = snapshot
        self.selectedCategory = orderedCategories.first(where: { !$0.items.filter(\.isCleanable).isEmpty }) ?? orderedCategories.first
        self.selectedThreatKind = snapshot.protectionThreatGroups.first?.kind
        self.selectedThreatKinds = Set(snapshot.protectionThreatGroups.map(\.kind))
        self.detailKind = .cleaning
        self.dashboardStage = .scannedSummary
        self.lastSpeedExecutionResult = nil
        self.activePopover = nil
        self.scanCurrentPath = ""
        showToast("扫描完成")
    }

    func performPrimaryAction() async {
        if dashboardStage == .ready {
            await refresh()
            return
        }

        guard hasFullDiskAccess else {
            lastErrorMessage = "运行前可先开启完全磁盘访问，以便统一处理需要权限的目录。\n\nDiskSense 无法替您一键授权所有文件夹；macOS 仅允许跳转到系统设置，由您手动为 DiskSense 开启“完全磁盘访问”。开启后可返回继续运行。"
            openFullDiskAccessSettings()
            return
        }

        await runAllRecommendedActions()
    }

    func openDetails(for kind: DashboardDetailKind) {
        detailKind = kind
        selectedCategory = preferredCategory(for: kind)
        if kind == .protection {
            selectedThreatKind = protectionThreatGroups.first?.kind
            if selectedThreatKinds.isEmpty {
                selectedThreatKinds = Set(protectionThreatGroups.map(\.kind))
            }
        }
        dashboardStage = .details
    }

    func backToSummary() {
        dashboardStage = .scannedSummary
    }

    func resetToHome() {
        snapshot = nil
        scanCurrentPath = ""
        scanDiscoveredCleanableBytes = 0
        selectedCategory = nil
        selectedThreatKind = nil
        selectedThreatKinds = []
        detailKind = .cleaning
        dashboardStage = .ready
        activePopover = nil
        lastSpeedExecutionResult = nil
    }

    func setHoveredCard(_ card: DashboardCardKind?) {
        hoveredCard = card
    }

    func hidePopover() {
        activePopover = nil
    }

    func showCleaningPopover() {
        guard let cleanCategory else { return }
        activePopover = DashboardPopoverContent(
            card: .cleaning,
            title: "各种可安全清理的文件，释放您的 Mac 的空间：",
            rows: [
                DashboardPopoverRow(title: cleanCategory.title, value: cleanCategory.cleanableSizeInBytes.byteString)
            ],
            action: DashboardPopoverAction(title: "查看详情…", handler: { [weak self] in
                self?.openDetails(for: .cleaning)
            })
        )
    }

    func showProtectionPopover() {
        guard let selectedThreatGroup else { return }
        activePopover = DashboardPopoverContent(
            card: .protection,
            title: "让您的 Mac 易受威胁的恶意文件：",
            rows: [
                DashboardPopoverRow(title: selectedThreatGroup.title, value: "\(selectedThreatGroup.threatCount) 个威胁")
            ],
            action: DashboardPopoverAction(title: "查看详情…", handler: { [weak self] in
                self?.openDetails(for: .protection)
            })
        )
    }

    func showSpeedPopover() {
        let tasks = snapshot?.speedTasks ?? []
        guard !tasks.isEmpty else { return }
        let title: String
        if let lastSpeedExecutionResult {
            title = "已完成优化，性能提升约 \(lastSpeedExecutionResult.performanceGainPercent)%："
        } else {
            title = "基于您的 Mac 情况推荐的优化任务："
        }
        activePopover = DashboardPopoverContent(
            card: .speed,
            title: title,
            rows: tasks.prefix(4).map { DashboardPopoverRow(title: $0.title, value: nil) },
            action: nil
        )
    }

    func openFullDiskAccessSettings() {
        DiskAuthorizationManager.shared.openFullDiskAccessSettings()
        hasPromptedForFullDiskAccess = true
    }

    func clean(_ item: StorageItem) async {
        isCleaning = true
        defer { isCleaning = false }

        do {
            try await Task.detached(priority: .userInitiated) {
                try StorageScanner().clean(item)
            }.value
            await refreshAfterCleaning(message: "已清理 \(item.name)")
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func cleanSelectedCategory() async {
        guard let category = selectedCategory else { return }
        let cleanableItems = visibleItems(for: category)
        guard !cleanableItems.isEmpty else { return }

        let executableItems = cleanableItems.filter(\.isSafeForOneClickCleanup)
        let skippedCount = cleanableItems.count - executableItems.count

        guard !executableItems.isEmpty else {
            showToast(skippedCount > 0 ? "当前项目需要额外权限，已跳过 \(skippedCount) 项" : "当前没有可执行清理项")
            return
        }

        isCleaning = true
        defer { isCleaning = false }

        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try StorageScanner().clean(items: executableItems, categoryName: category.title)
            }.value
            let totalSkippedCount = skippedCount + summary.skippedCount
            let message = totalSkippedCount > 0
                ? "已清理 \(summary.succeededCount) 项，跳过 \(totalSkippedCount) 项，可在详情中手动处理"
                : "已完成 \(category.title) 清理"
            await refreshAfterCleaning(message: message)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func cleanSelectedThreatGroup() async {
        let groups = selectedThreatGroups
        guard !groups.isEmpty else { return }
        let cleanableItems = groups.flatMap { $0.items.compactMap(\.item).filter(\.isCleanable) }

        if cleanableItems.isEmpty {
            showToast("已处理选中推荐项")
            return
        }

        isCleaning = true
        defer { isCleaning = false }

        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try StorageScanner().clean(items: cleanableItems, categoryName: "选中风险项")
            }.value
            let message = summary.skippedCount > 0
                ? "已处理 \(summary.succeededCount) 项风险，跳过 \(summary.skippedCount) 项，可在详情中手动处理"
                : "已清理 \(groups.count) 项选中风险"
            await refreshAfterCleaning(message: message)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func executeSpeedTasks() async {
        if let lastSpeedExecutionResult {
            showToast(lastSpeedExecutionResult.message)
            return
        }

        let tasks = snapshot?.speedTasks ?? []
        guard !tasks.isEmpty else {
            showToast("当前没有可执行优化项")
            return
        }

        isCleaning = true
        defer { isCleaning = false }

        do {
            let currentSnapshot = snapshot
            let completedTasks = try await Task.detached(priority: .userInitiated) {
                try SpeedOptimizer().execute(tasks: tasks, snapshot: currentSnapshot)
            }.value

            let performanceGain = min(8 + completedTasks.count * 3, 32)
            lastSpeedExecutionResult = SpeedExecutionResult(executedTasks: completedTasks, performanceGainPercent: performanceGain)
            await refreshAfterCleaning(message: lastSpeedExecutionResult?.message ?? "已完成优化")
            showSpeedPopover()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func runAllRecommendedActions() async {
        guard !isCleaning, !isScanning else { return }

        isCleaning = true
        primaryActionPhase = .cleaning
        defer { isCleaning = false }
        defer { primaryActionPhase = .idle }

        var didPerformAnyAction = false
        var summaries: [String] = []
        var skippedManualItemCount = 0

        if let category = preferredCategory(for: .cleaning) {
            let items = visibleItems(for: category).filter(\.isSafeForOneClickCleanup)
            if !items.isEmpty {
                do {
                    let summary = try await Task.detached(priority: .userInitiated) {
                        try StorageScanner().clean(items: items, categoryName: category.title)
                    }.value
                    if summary.succeededCount > 0 {
                        didPerformAnyAction = true
                        summaries.append("已清理 \(summary.succeededCount) 项")
                    }
                    skippedManualItemCount += summary.skippedCount
                } catch {
                    lastErrorMessage = error.localizedDescription
                    return
                }
            }
        }

        let threatItems = selectedThreatGroups.flatMap { $0.items.compactMap(\.item).filter(\.isCleanable) }
        if !threatItems.isEmpty {
            primaryActionPhase = .protecting
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try StorageScanner().clean(items: threatItems, categoryName: "选中风险项")
                }.value
                if summary.succeededCount > 0 {
                    didPerformAnyAction = true
                    summaries.append("已处理 \(summary.succeededCount) 项风险")
                }
                skippedManualItemCount += summary.skippedCount
            } catch {
                lastErrorMessage = error.localizedDescription
                return
            }
        }

        let speedTasks = snapshot?.speedTasks ?? []
        if !speedTasks.isEmpty, lastSpeedExecutionResult == nil {
            primaryActionPhase = .optimizing
            do {
                let currentSnapshot = snapshot
                let completedTasks = try await Task.detached(priority: .userInitiated) {
                    try SpeedOptimizer().execute(tasks: speedTasks, snapshot: currentSnapshot)
                }.value
                let performanceGain = min(8 + completedTasks.count * 3, 32)
                lastSpeedExecutionResult = SpeedExecutionResult(executedTasks: completedTasks, performanceGainPercent: performanceGain)
                didPerformAnyAction = true
                summaries.append(lastSpeedExecutionResult?.message ?? "已完成优化")
            } catch {
                lastErrorMessage = error.localizedDescription
                return
            }
        }

        guard didPerformAnyAction else {
            showToast(skippedManualItemCount > 0 ? "当前内容需要在详情中手动处理" : "当前没有可运行的一键处理任务")
            return
        }

        if skippedManualItemCount > 0 {
            pendingManualActionCount = skippedManualItemCount
            summaries.append("另有 \(skippedManualItemCount) 项可在详情中手动处理")
        } else {
            pendingManualActionCount = 0
        }

        await refreshAfterCleaning(message: summaries.joined(separator: "，"))
    }

    func toggleThreatSelection() {
        if areAllThreatsSelected {
            selectedThreatKinds = []
            selectedThreatKind = nil
        } else {
            let allKinds = Set(protectionThreatGroups.map(\.kind))
            selectedThreatKinds = allKinds
            selectedThreatKind = protectionThreatGroups.first?.kind
        }
    }

    func selectThreat(kind: ProtectionThreatKind) {
        if selectedThreatKinds.contains(kind) {
            selectedThreatKinds.remove(kind)
            if selectedThreatKind == kind {
                selectedThreatKind = selectedThreatKinds.first
            }
        } else {
            selectedThreatKinds.insert(kind)
            selectedThreatKind = kind
        }
    }

    func clearThreatSelection() {
        selectedThreatKinds = []
        selectedThreatKind = nil
    }

    private func refreshAfterCleaning(message: String) async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            StorageScanner().scan()
        }.value
        self.snapshot = snapshot
        self.selectedCategory = preferredCategory(for: detailKind)
        let allKinds = Set(snapshot.protectionThreatGroups.map(\.kind))
        self.selectedThreatKinds = selectedThreatKinds.intersection(allKinds)
        self.selectedThreatKind = snapshot.protectionThreatGroups.first(where: { selectedThreatKinds.contains($0.kind) })?.kind
        self.pendingManualActionCount = snapshot.categories
            .flatMap(\.items)
            .filter { $0.isCleanable && !$0.isSafeForOneClickCleanup }
            .count
        showToast(message)
    }

    private func preferredCategory(for kind: DashboardDetailKind) -> StorageCategory? {
        switch kind {
        case .cleaning:
            return orderedCategories.first(where: { !$0.items.filter(\.isCleanable).isEmpty }) ?? orderedCategories.first
        case .protection:
            return orderedCategories.first(where: { $0.section == .hidden })
                ?? orderedCategories.first(where: { $0.section == .system })
                ?? orderedCategories.first
        case .speed:
            return orderedCategories.first(where: { $0.section == .system })
                ?? orderedCategories.first(where: { $0.section == .developer })
                ?? orderedCategories.first
        }
    }

    private func startScanAnimation() {
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            scanRotation = 360
        }
    }

    private func stopScanAnimation() {
        scanRotation = 0
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.toastMessage == message {
                self.toastMessage = nil
            }
        }
    }
}
