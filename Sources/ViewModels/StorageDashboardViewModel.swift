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
    @Published var selectedCleaningItemIDs: Set<StorageItem.ID> = []
    @Published var selectedProtectionItemKeys: Set<String> = []
    @Published var activePopover: DashboardPopoverContent?
    @Published var hoveredCard: DashboardCardKind?
    @Published var lastSpeedExecutionResult: SpeedExecutionResult?
    @Published var scanCurrentPath: String = ""
    @Published var scanDiscoveredCleanableBytes: Int64 = 0
    @Published var primaryActionPhase: PrimaryActionPhase = .idle {
        didSet {
            if primaryActionPhase == .idle {
                stopScanAnimation()
            } else {
                startScanAnimation()
            }
        }
    }
    @Published var pendingManualActionCount: Int = 0

    private var scanLifecycle: ScanLifecycle = .idle
    private var scanSessionID = UUID()

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
        orderedCategories.filter {
            if $0.section == .trash { return true }
            return !visibleItems(for: $0).isEmpty
        }
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
            result + visibleItems(for: category)
                .filter { selectedCleaningItemIDs.contains($0.id) && $0.isCleanable }
                .reduce(0) { $0 + $1.sizeInBytes }
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
        return protectionThreatGroups.compactMap { group in
            guard selectedThreatKinds.contains(group.kind) else { return nil }
            let items = group.items.filter { selectedProtectionItemKeys.contains(protectionItemKey(for: $0)) }
            guard !items.isEmpty else { return nil }
            return ProtectionThreatGroup(kind: group.kind, items: items)
        }
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
            if isScanning { return "暂停" }
            if isScanPaused { return "暂停中" }
            if dashboardStage == .scannedSummary && primaryActionPhase == .cleaning { return "清理中" }
            return "运行"
        }
        return primaryActionPhase.title
    }

    var primaryActionSymbolName: String {
        if dashboardStage == .ready || dashboardStage == .scannedSummary {
            if isScanning { return "pause.fill" }
            if isScanPaused { return "pause.fill" }
            if dashboardStage == .scannedSummary && primaryActionPhase == .cleaning { return PrimaryActionPhase.cleaning.symbolName }
            return "play.fill"
        }
        return primaryActionPhase.symbolName
    }

    var isScanPaused: Bool {
        scanLifecycle == .paused
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
        if category.section == .trash { return cleanable }
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
        let currentScanSessionID = UUID()
        scanSessionID = currentScanSessionID
        scanLifecycle = .scanning
        isScanning = true
        primaryActionPhase = .scanning
        startScanAnimation()
        defer {
            if scanSessionID == currentScanSessionID {
                isScanning = false
                primaryActionPhase = .idle
                stopScanAnimation()
            }
        }

        scanCurrentPath = ""
        scanDiscoveredCleanableBytes = 0

        let snapshot = await Task.detached(priority: .userInitiated) { [weak self] in
            StorageScanner(progress: { progress in
                Task { @MainActor in
                    guard let self,
                          self.scanLifecycle == .scanning,
                          self.scanSessionID == currentScanSessionID else { return }
                    self.scanCurrentPath = progress.currentPath
                    self.scanDiscoveredCleanableBytes = progress.discoveredCleanableBytes
                }
            }).scan()
        }.value

        guard scanLifecycle == .scanning,
              scanSessionID == currentScanSessionID else { return }

        self.snapshot = snapshot
        self.selectedCategory = orderedCategories.first(where: { !$0.items.filter(\.isCleanable).isEmpty }) ?? orderedCategories.first
        self.selectedCategoryIDs = Set(visibleCleaningCategories.map(\.id))
        self.selectedThreatKind = snapshot.protectionThreatGroups.first?.kind
        self.selectedThreatKinds = Set(snapshot.protectionThreatGroups.map(\.kind))
        self.selectedCleaningItemIDs = Set(visibleCleaningCategories.flatMap { visibleItems(for: $0).map(\.id) })
        self.selectedProtectionItemKeys = Set(snapshot.protectionThreatGroups.flatMap { group in
            group.items.map { protectionItemKey(for: $0) }
        })

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
        selectedCategory = defaultCategory(for: kind)
        if kind == .cleaning, selectedCategoryIDs.isEmpty {
            selectedCategoryIDs = Set(visibleCleaningCategories.map(\.id))
        }
        if kind == .protection {
            selectedThreatKind = defaultThreatKind()
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
        scanSessionID = UUID()
        scanLifecycle = .paused
        isScanning = false
        primaryActionPhase = .idle
        stopScanAnimation()
        scanCurrentPath = ""
        showToast("已暂停扫描")
    }

    func resetToHome() {
        scanSessionID = UUID()
        snapshot = nil
        scanCurrentPath = ""
        scanDiscoveredCleanableBytes = 0
        selectedCategory = nil
        selectedThreatKind = nil
        selectedThreatKinds = []
        selectedCategoryIDs = []
        selectedCleaningItemIDs = []
        selectedProtectionItemKeys = []
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
        guard item.isCleanable else {
            revealItem(item)
            return
        }

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
            applyLocalCleanup(for: item, message: "已清理 \(item.name)")
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func revealItem(_ item: StorageItem) {
        revealPath(item.path)
    }

    private func revealPath(_ path: String) {
        let rawPath = NSString(string: path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: rawPath)

        if FileManager.default.fileExists(atPath: rawPath) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let parentURL = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parentURL.path) {
            NSWorkspace.shared.open(parentURL)
            return
        }

        lastErrorMessage = "无法打开路径：\(path)"
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
            selectedCleaningItemIDs = []
        } else {
            selectedCategoryIDs = Set(visibleCleaningCategories.map(\.id))
            selectedCleaningItemIDs = Set(visibleCleaningCategories.flatMap { visibleItems(for: $0).map(\.id) })
        }
    }

    func focusCategory(_ category: StorageCategory) {
        selectedCategory = category
    }

    func toggleCategorySelection(for category: StorageCategory) {
        let itemIDs = Set(visibleItems(for: category).map(\.id))
        if selectedCategoryIDs.contains(category.id) {
            selectedCategoryIDs.remove(category.id)
            selectedCleaningItemIDs.subtract(itemIDs)
        } else {
            selectedCategoryIDs.insert(category.id)
            selectedCleaningItemIDs.formUnion(itemIDs)
        }
    }

    func toggleCleaningItemSelection(_ item: StorageItem, in category: StorageCategory) {
        if selectedCleaningItemIDs.contains(item.id) {
            selectedCleaningItemIDs.remove(item.id)
        } else {
            selectedCleaningItemIDs.insert(item.id)
        }
        syncCategorySelection(for: category)
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
            applyLocalCleanup(for: item, message: "已删除 \(threatItem.name)")
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
        var cleanedCategoryTitle: String?
        var cleanedCategoryCount = 0
        var cleanedThreatCount = 0
        var optimizedTaskCount = 0
        var manualCategories: [String] = []

        if let category = preferredCategory(for: .cleaning) {
            let allVisibleItems = visibleItems(for: category)
            let items = allVisibleItems.filter(\.isSafeForOneClickCleanup)
            let manualItems = allVisibleItems.filter { $0.isCleanable && !$0.isSafeForOneClickCleanup }
            skippedManualItemCount += manualItems.count
            manualCategories.append(contentsOf: manualItems.map(\.manualCleanupHint))
            if !items.isEmpty {
                do {
                    let summary = try await Task.detached(priority: .userInitiated) {
                        try StorageScanner().clean(items: items, categoryName: category.title)
                    }.value
                    if summary.succeededCount > 0 {
                        didPerformAnyAction = true
                        cleanedCategoryTitle = category.title
                        cleanedCategoryCount = summary.succeededCount
                        summaries.append("已清理\(category.title)中的 \(summary.succeededCount) 项内容")
                    }
                    skippedManualItemCount += summary.skippedCount
                manualCategories.append(contentsOf: summary.skippedItems.map(\.manualCleanupHint))
                manualCategories.append(contentsOf: summary.skippedItems.map(\.manualCleanupHint))
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
                    cleanedThreatCount = summary.succeededCount
                    summaries.append("已处理 \(summary.succeededCount) 项风险内容")
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
                optimizedTaskCount = completedTasks.count
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
            summaries.append("另有 \(skippedManualItemCount) 项需要点击“查看详情”后手动确认删除")
        } else {
            pendingManualActionCount = 0
        }

        let cleanupSummary = buildRunSummary(
            cleanedCategoryTitle: cleanedCategoryTitle,
            cleanedCategoryCount: cleanedCategoryCount,
            cleanedThreatCount: cleanedThreatCount,
            optimizedTaskCount: optimizedTaskCount,
            skippedManualItemCount: skippedManualItemCount,
            manualCategories: manualCategories,
            fallbackSummaries: summaries
        )

        await refreshAfterCleaning(message: cleanupSummary)
    }

    func toggleThreatSelection() {
        if areAllThreatsSelected {
            selectedThreatKinds = []
            selectedThreatKind = nil
            selectedProtectionItemKeys = []
        } else {
            let allKinds = Set(protectionThreatGroups.map(\.kind))
            selectedThreatKinds = allKinds
            selectedThreatKind = protectionThreatGroups.first?.kind
            selectedProtectionItemKeys = Set(protectionThreatGroups.flatMap { group in
                group.items.map { protectionItemKey(for: $0) }
            })
        }
    }

    func focusThreat(kind: ProtectionThreatKind) {
        selectedThreatKind = kind
    }

    func toggleThreatSelection(for kind: ProtectionThreatKind) {
        let itemIDs = Set(protectionThreatGroups.first(where: { $0.kind == kind })?.items.map { protectionItemKey(for: $0) } ?? [])
        if selectedThreatKinds.contains(kind) {
            selectedThreatKinds.remove(kind)
            selectedProtectionItemKeys.subtract(itemIDs)
            if selectedThreatKind == kind {
                selectedThreatKind = defaultThreatKind(from: selectedThreatKinds)
            }
        } else {
            selectedThreatKinds.insert(kind)
            selectedProtectionItemKeys.formUnion(itemIDs)
        }
    }

    func toggleProtectionItemSelection(_ item: ProtectionThreatItem, in kind: ProtectionThreatKind) {
        let itemKey = protectionItemKey(for: item)
        if selectedProtectionItemKeys.contains(itemKey) {
            selectedProtectionItemKeys.remove(itemKey)
        } else {
            selectedProtectionItemKeys.insert(itemKey)
        }
        syncThreatSelection(for: kind)
    }

    func clearThreatSelection() {
        selectedThreatKinds = []
        selectedThreatKind = nil
        selectedProtectionItemKeys = []
    }

    private func refreshAfterCleaning(message: String) async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            StorageScanner().scan()
        }.value
        self.snapshot = snapshot
        self.selectedCategory = defaultCategory(for: detailKind)
        self.selectedCleaningItemIDs = Set(visibleCleaningCategories.flatMap { visibleItems(for: $0).map(\.id) })
        let allKinds = Set(snapshot.protectionThreatGroups.map(\.kind))
        self.selectedThreatKinds = selectedThreatKinds.intersection(allKinds)
        self.selectedThreatKind = defaultThreatKind(from: self.selectedThreatKinds)
        self.selectedProtectionItemKeys = Set(snapshot.protectionThreatGroups.flatMap { group in
            self.selectedThreatKinds.contains(group.kind) ? group.items.map { protectionItemKey(for: $0) } : []
        })
        self.pendingManualActionCount = snapshot.categories
            .flatMap(\.items)
            .filter { $0.isCleanable && !$0.isSafeForOneClickCleanup }
            .count
        showToast(message)
    }

    private func applyLocalCleanup(for item: StorageItem, message: String) {
        guard let snapshot else {
            showToast(message)
            return
        }

        let updatedCategories = snapshot.categories.compactMap { category -> StorageCategory? in
            let remainingItems = category.items.filter { $0.path != item.path }
            guard remainingItems.count != category.items.count else {
                return category
            }

            if category.section != .trash && remainingItems.filter(\.isCleanable).isEmpty {
                return nil
            }

            return StorageCategory(section: category.section, items: remainingItems)
        }

        let updatedThreatRecords = snapshot.threatRecords.filter { record in
            if let storageItem = record.relatedItem {
                return storageItem.path != item.path
            }
            return record.path != item.path
        }

        self.snapshot = StorageSnapshot(
            scannedAt: Date(),
            totalCapacity: snapshot.totalCapacity,
            freeSpace: snapshot.freeSpace + item.sizeInBytes,
            categories: updatedCategories,
            threatRecords: updatedThreatRecords
        )

        let validCategoryIDs = Set(visibleCleaningCategories.map(\.id))
        selectedCategoryIDs = selectedCategoryIDs.intersection(validCategoryIDs)
        if selectedCategoryIDs.isEmpty, !validCategoryIDs.isEmpty {
            selectedCategoryIDs = validCategoryIDs
        }
        let validCleaningItemIDs = Set(visibleCleaningCategories.flatMap { visibleItems(for: $0).map(\.id) })
        selectedCleaningItemIDs = selectedCleaningItemIDs.intersection(validCleaningItemIDs)
        if selectedCleaningItemIDs.isEmpty, !validCleaningItemIDs.isEmpty {
            selectedCleaningItemIDs = validCleaningItemIDs
        }

        selectedCategory = defaultCategory(for: detailKind)

        let allKinds = Set(protectionThreatGroups.map(\.kind))
        selectedThreatKinds = selectedThreatKinds.intersection(allKinds)
        if selectedThreatKinds.isEmpty, !allKinds.isEmpty {
            selectedThreatKinds = allKinds
        }
        let validProtectionItemIDs = Set(protectionThreatGroups.flatMap { group in
            selectedThreatKinds.contains(group.kind) ? group.items.map { protectionItemKey(for: $0) } : []
        })
        selectedProtectionItemKeys = selectedProtectionItemKeys.intersection(validProtectionItemIDs)
        if selectedProtectionItemKeys.isEmpty, !validProtectionItemIDs.isEmpty {
            selectedProtectionItemKeys = validProtectionItemIDs
        }
        selectedThreatKind = defaultThreatKind(from: selectedThreatKinds)

        pendingManualActionCount = self.snapshot?.categories
            .flatMap(\.items)
            .filter { $0.isCleanable && !$0.isSafeForOneClickCleanup }
            .count ?? 0

        showToast(message)
    }

    private func preferredCategory(for kind: DashboardDetailKind) -> StorageCategory? {
        switch kind {
        case .cleaning:
            return orderedCategories.first(where: { $0.section == .trash && !$0.items.filter(\.isCleanable).isEmpty })
                ?? orderedCategories.first(where: { !$0.items.filter(\.isCleanable).isEmpty })
                ?? orderedCategories.first
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

    private func defaultCategory(for kind: DashboardDetailKind) -> StorageCategory? {
        switch kind {
        case .cleaning:
            return visibleCleaningCategories.first ?? preferredCategory(for: kind)
        case .protection, .speed:
            return preferredCategory(for: kind)
        }
    }

    private func defaultThreatKind(from selectedKinds: Set<ProtectionThreatKind>? = nil) -> ProtectionThreatKind? {
        let activeKinds = selectedKinds ?? selectedThreatKinds
        return protectionThreatGroups.first(where: { activeKinds.contains($0.kind) })?.kind
            ?? protectionThreatGroups.first?.kind
    }

    private func syncCategorySelection(for category: StorageCategory) {
        let itemIDs = Set(visibleItems(for: category).map(\.id))
        guard !itemIDs.isEmpty else {
            selectedCategoryIDs.remove(category.id)
            return
        }

        if itemIDs.isSubset(of: selectedCleaningItemIDs) {
            selectedCategoryIDs.insert(category.id)
        } else {
            selectedCategoryIDs.remove(category.id)
        }
    }

    private func syncThreatSelection(for kind: ProtectionThreatKind) {
        let itemIDs = Set(protectionThreatGroups.first(where: { $0.kind == kind })?.items.map { protectionItemKey(for: $0) } ?? [])
        guard !itemIDs.isEmpty else {
            selectedThreatKinds.remove(kind)
            return
        }

        if itemIDs.isSubset(of: selectedProtectionItemKeys) {
            selectedThreatKinds.insert(kind)
        } else {
            selectedThreatKinds.remove(kind)
        }

        if selectedThreatKind == kind, !selectedThreatKinds.contains(kind) {
            selectedThreatKind = defaultThreatKind(from: selectedThreatKinds)
        }
    }

    private func protectionItemKey(for item: ProtectionThreatItem) -> String {
        let marker = item.item?.path ?? item.path
        return "\(item.name)|\(marker)|\(item.symbolName)"
    }

    private func startScanAnimation() {
        scanRotation = 0
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            scanRotation = 360
        }
    }

    private func stopScanAnimation() {
        withAnimation(.easeOut(duration: 0.2)) {
            scanRotation = 0
        }
    }

    private func buildRunSummary(
        cleanedCategoryTitle: String?,
        cleanedCategoryCount: Int,
        cleanedThreatCount: Int,
        optimizedTaskCount: Int,
        skippedManualItemCount: Int,
        manualCategories: [String],
        fallbackSummaries: [String]
    ) -> String {
        var parts: [String] = []

        if cleanedCategoryCount > 0, let cleanedCategoryTitle {
            parts.append("已清理\(cleanedCategoryTitle)中的 \(cleanedCategoryCount) 项内容")
        }

        if cleanedThreatCount > 0 {
            parts.append("已处理 \(cleanedThreatCount) 项风险内容")
        }

        if optimizedTaskCount > 0 {
            parts.append("已完成 \(optimizedTaskCount) 项性能优化")
        }

        if skippedManualItemCount > 0 {
            let categoryHint = manualCleanupCategoryHint(from: manualCategories)
            if categoryHint.isEmpty {
                parts.append("另有 \(skippedManualItemCount) 项需要点击“查看详情”后手动确认删除")
            } else {
                parts.append("另有 \(skippedManualItemCount) 项需要点击“查看详情”后手动确认删除，例如：\(categoryHint)")
            }
        }

        return parts.isEmpty ? fallbackSummaries.joined(separator: "，") : parts.joined(separator: "；")
    }

    private func manualCleanupCategoryHint(from categories: [String]) -> String {
        let unique = Array(NSOrderedSet(array: categories)) as? [String] ?? []
        return unique.prefix(3).joined(separator: "、")
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.toastMessage == message {
                self.toastMessage = nil
            }
        }
    }
}
