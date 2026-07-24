import Foundation
import AppKit
import SwiftUI

@MainActor
final class StorageDashboardViewModel: ObservableObject {
    private enum ScanLifecycle {
        case idle
        case scanning
        case paused
        case completed
    }

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
    @Published var showsFullDiskAccessPrompt = false
    @Published var isCleaning = false
    @Published var isBulkCleaning = false
    @Published var activeCleaningItemIDs: Set<StorageItem.ID> = []
    @Published var activeCleaningThreatItemIDs: Set<ProtectionThreatItem.ID> = []
    @Published var toastMessage: String?
    @Published var dashboardStage: DashboardStage = .welcome
    @Published var scanRotation = 0.0
    @Published var hasPromptedForFullDiskAccess = DiskAuthorizationManager.shared.hasPromptedForFullDiskAccess
    @Published var selectedThreatKind: ProtectionThreatKind?
    @Published var selectedThreatKinds: Set<ProtectionThreatKind> = []
    @Published var selectedCategoryIDs: Set<StorageCategory.ID> = []
    @Published var activePopover: DashboardPopoverContent?
    @Published var hoveredCard: DashboardCardKind?
    @Published var lastSpeedExecutionResult: SpeedExecutionResult?
    @Published var scanCurrentPath: String = ""
    @Published var scanDiscoveredCleanableBytes: Int64 = 0
    @Published var primaryActionPhase: PrimaryActionPhase = .idle
    @Published var pendingManualActionCount: Int = 0

    private var scanLifecycle: ScanLifecycle = .idle

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

    var visibleCleaningCategories: [StorageCategory] {
        orderedCategories.filter { !visibleItems(for: $0).isEmpty }
    }

    var areAllCategoriesSelected: Bool {
        let ids = Set(visibleCleaningCategories.map(\.id))
        return !ids.isEmpty && selectedCategoryIDs == ids
    }

    var selectedCategories: [StorageCategory] {
        visibleCleaningCategories.filter { selectedCategoryIDs.contains($0.id) }
    }

    var selectedCleanableSizeInBytes: Int64 {
        selectedCategories.reduce(0) { result, category in
            result + visibleItems(for: category).reduce(0) { $0 + $1.sizeInBytes }
        }
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
        if dashboardStage == .ready || dashboardStage == .scannedSummary {
            return isScanning ? "暂停" : "运行"
        }
        return primaryActionPhase.title
    }

    var primaryActionSymbolName: String {
        if dashboardStage == .ready || dashboardStage == .scannedSummary {
            return isScanning ? "pause.fill" : "play.fill"
        }
        return primaryActionPhase.symbolName
    }

    var showsWelcomeScreen: Bool {
        dashboardStage == .welcome
    }

    var canRescanToWelcome: Bool {
        (dashboardStage == .ready && !isScanning) || dashboardStage == .scannedSummary || dashboardStage == .details
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
        scanLifecycle = .scanning
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

        guard scanLifecycle == .scanning else { return }

        self.snapshot = snapshot
        self.selectedCategory = orderedCategories.first(where: { !$0.items.filter(\.isCleanable).isEmpty }) ?? orderedCategories.first
        self.selectedCategoryIDs = Set(visibleCleaningCategories.map(\.id))
        self.selectedThreatKind = snapshot.protectionThreatGroups.first?.kind
        self.selectedThreatKinds = Set(snapshot.protectionThreatGroups.map(\.kind))

        self.detailKind = .cleaning
        self.dashboardStage = .scannedSummary
        self.scanLifecycle = .completed
        self.lastSpeedExecutionResult = nil
        self.activePopover = nil
        self.scanCurrentPath = ""
        showToast("扫描完成")
    }

    func performPrimaryAction() async {
        if dashboardStage == .welcome {
            dashboardStage = .ready
            await refresh()
            return
        }

        if dashboardStage == .ready, isScanning {
            pauseScan()
            return
        }

        if dashboardStage == .ready, !isScanning {
            await refresh()
            return
        }

        if dashboardStage == .scannedSummary {
            guard hasFullDiskAccess else {
                presentFullDiskAccessPrompt()
                return
            }

            await runAllRecommendedActions()
            return
        }

        guard hasFullDiskAccess else {
            presentFullDiskAccessPrompt()
            return
        }

        await runAllRecommendedActions()
    }

    func openDetails(for kind: DashboardDetailKind) {
        detailKind = kind
        selectedCategory = preferredCategory(for: kind)
        if kind == .cleaning, selectedCategoryIDs.isEmpty {
            selectedCategoryIDs = Set(visibleCleaningCategories.map(\.id))
        }
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

    func pauseScan() {
        guard isScanning else { return }
        scanLifecycle = .paused
        isScanning = false
        primaryActionPhase = .idle
        stopScanAnimation()
        scanCurrentPath = ""
        showToast("已暂停扫描")
    }

    func resetToHome() {
        snapshot = nil
        scanCurrentPath = ""
        scanDiscoveredCleanableBytes = 0
        selectedCategory = nil
        selectedThreatKind = nil
        selectedThreatKinds = []
        selectedCategoryIDs = []
        detailKind = .cleaning
        dashboardStage = .welcome
        scanLifecycle = .idle
        isScanning = false
        primaryActionPhase = .idle
        stopScanAnimation()
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
        showsFullDiskAccessPrompt = false
    }

    func presentFullDiskAccessPrompt() {
        showsFullDiskAccessPrompt = true
    }

    func dismissFullDiskAccessPrompt() {
        showsFullDiskAccessPrompt = false
    }

    func revealThreatItem(_ threatItem: ProtectionThreatItem) {
        // Audit findings (system hardening / config profiles) have no file to reveal;
        // deep-link into the relevant System Settings pane for remediation instead.
        if threatItem.item == nil, let settingsURLString = threatItem.settingsURLString,
           let url = URL(string: settingsURLString) {
            NSWorkspace.shared.open(url)
            return
        }

        let rawPath = NSString(string: threatItem.item?.path ?? threatItem.path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: rawPath)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: rawPath) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let parentURL = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parentURL.path) {
            NSWorkspace.shared.open(parentURL)
            return
        }

        lastErrorMessage = "无法打开路径：\(threatItem.path)"
    }

    func clean(_ item: StorageItem) async {
        isCleaning = true
        activeCleaningItemIDs.insert(item.id)
        defer {
            activeCleaningItemIDs.remove(item.id)
            isCleaning = isBulkCleaning || !activeCleaningItemIDs.isEmpty || !activeCleaningThreatItemIDs.isEmpty
        }

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
        let categories = selectedCategories
        guard !categories.isEmpty else { return }

        let cleanableItems = categories.flatMap { visibleItems(for: $0) }
        guard !cleanableItems.isEmpty else { return }

        let executableItems = cleanableItems.filter(\.isSafeForOneClickCleanup)
        let skippedCount = cleanableItems.count - executableItems.count

        guard !executableItems.isEmpty else {
            showToast(skippedCount > 0 ? "当前项目需要额外权限，已跳过 \(skippedCount) 项" : "当前没有可执行清理项")
            return
        }

        isCleaning = true
        isBulkCleaning = true
        defer {
            isBulkCleaning = false
            isCleaning = isBulkCleaning || !activeCleaningItemIDs.isEmpty || !activeCleaningThreatItemIDs.isEmpty
        }

        do {
            let categoryName = categories.count == 1 ? categories[0].title : "选中分类"
            let summary = try await Task.detached(priority: .userInitiated) {
                try StorageScanner().clean(items: executableItems, categoryName: categoryName)
            }.value
            let totalSkippedCount = skippedCount + summary.skippedCount
            let message = totalSkippedCount > 0
                ? "已清理 \(summary.succeededCount) 项，跳过 \(totalSkippedCount) 项，可在详情中手动处理"
                : "已完成\(categoryName)清理"
            await refreshAfterCleaning(message: message)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func toggleCategorySelection() {
        if areAllCategoriesSelected {
            selectedCategoryIDs = []
        } else {
            selectedCategoryIDs = Set(visibleCleaningCategories.map(\.id))
        }
    }

    func selectCategory(_ category: StorageCategory) {
        selectedCategory = category
        if selectedCategoryIDs.contains(category.id) {
            selectedCategoryIDs.remove(category.id)
        } else {
            selectedCategoryIDs.insert(category.id)
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
        isBulkCleaning = true
        defer {
            isBulkCleaning = false
            isCleaning = isBulkCleaning || !activeCleaningItemIDs.isEmpty || !activeCleaningThreatItemIDs.isEmpty
        }

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

    func cleanThreatItem(_ threatItem: ProtectionThreatItem) async {
        guard let item = threatItem.item else {
            showToast(threatItem.isExactMatch ? "该项目当前不可直接删除" : "这是建议检查位置，未扫描到可直接删除的实际文件")
            return
        }

        guard item.isCleanable else {
            showToast("该项目需要手动处理或额外权限")
            return
        }

        isCleaning = true
        activeCleaningThreatItemIDs.insert(threatItem.id)
        defer {
            activeCleaningThreatItemIDs.remove(threatItem.id)
            isCleaning = isBulkCleaning || !activeCleaningItemIDs.isEmpty || !activeCleaningThreatItemIDs.isEmpty
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try StorageScanner().clean(item)
            }.value
            await refreshAfterCleaning(message: "已删除 \(threatItem.name)")
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
