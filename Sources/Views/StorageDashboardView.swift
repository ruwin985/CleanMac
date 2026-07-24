import AppKit
import SwiftUI

struct StorageDashboardView: View {
    private static let welcomeAppIcon = NSImage(named: "AppIcon")

    @ObservedObject var viewModel: StorageDashboardViewModel

    var body: some View {
        ZStack {
            backgroundView
            switch viewModel.dashboardStage {
            case .welcome:
                welcomeView
            case .ready, .scannedSummary:
                launchView
            case .details:
                resultsView
            }
        }
        .overlay(alignment: .topLeading) {
            if viewModel.dashboardStage != .welcome,
               viewModel.dashboardStage != .details,
               viewModel.canRescanToWelcome {
                Button {
                    viewModel.resetToHome()
                } label: {
                    Label("重新扫描", systemImage: "chevron.left")
                }
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }
                .buttonStyle(.plain)
                .offset(x: 26, y: 55)
            }
        }
        .overlay(alignment: .top) {
            if let toastMessage = viewModel.toastMessage {
                ToastView(message: toastMessage)
                    .padding(.top, 22)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if viewModel.showsFullDiskAccessPrompt {
                FullDiskAccessPrompt(
                    openSettings: { viewModel.openFullDiskAccessSettings() },
                    dismiss: { viewModel.dismissFullDiskAccessPrompt() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: viewModel.toastMessage)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: viewModel.activePopover?.card.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: viewModel.showsFullDiskAccessPrompt)
        .alert("操作失败", isPresented: Binding(get: { viewModel.lastErrorMessage != nil }, set: { if !$0 { viewModel.lastErrorMessage = nil } })) {
            Button("好") { viewModel.lastErrorMessage = nil }
        } message: {
            Text(viewModel.lastErrorMessage ?? "未知错误")
        }
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color(red: 0.60, green: 0.44, blue: 0.74),
                Color(red: 0.38, green: 0.35, blue: 0.60),
                Color(red: 0.27, green: 0.31, blue: 0.52)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(.white.opacity(0.03))
        .ignoresSafeArea()
    }

    private var launchView: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Text("好了，我发现的内容都在这里。")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(viewModel.dashboardStage == .scannedSummary ? "扫描已经完成，您可以先查看结果摘要，再决定是否进入详情处理。" : "保持您的 Mac 干净、安全、性能优化的所有任务正在等候。立即运行！")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            HStack(alignment: .top, spacing: 56) {
                HomeFeatureCard(
                    kind: .cleaning,
                    icon: "internaldrive.fill",
                    tintA: Color(red: 0.15, green: 0.72, blue: 0.96),
                    tintB: Color(red: 0.32, green: 0.44, blue: 0.86),
                    title: "清理",
                    subtitle: "移除不需要的垃圾",
                    value: viewModel.snapshot?.cleanableSizeInBytes.byteString ?? "--",
                    footnote: "可清理空间",
                    buttonTitle: viewModel.dashboardStage == .scannedSummary ? "查看详情…" : nil,
                    isHovered: viewModel.hoveredCard == .cleaning,
                    iconTap: { viewModel.showCleaningPopover() },
                    buttonTap: { viewModel.openDetails(for: .cleaning) },
                    hoverChanged: { hovering in
                        viewModel.setHoveredCard(hovering ? .cleaning : nil)
                    }
                )
                HomeFeatureCard(
                    kind: .protection,
                    icon: "lock.shield.fill",
                    tintA: Color(red: 0.16, green: 0.84, blue: 0.58),
                    tintB: Color(red: 0.19, green: 0.58, blue: 0.82),
                    title: "保护",
                    subtitle: "消除潜在威胁",
                    value: "\(viewModel.protectionCount)",
                    footnote: "项需要关注",
                    buttonTitle: viewModel.dashboardStage == .scannedSummary ? "查看详情…" : nil,
                    badgeText: viewModel.selectedThreatGroup?.title,
                    isHovered: viewModel.hoveredCard == .protection,
                    iconTap: { viewModel.showProtectionPopover() },
                    buttonTap: { viewModel.openDetails(for: .protection) },
                    hoverChanged: { hovering in
                        viewModel.setHoveredCard(hovering ? .protection : nil)
                    }
                )
                HomeFeatureCard(
                    kind: .speed,
                    icon: "speedometer",
                    tintA: Color(red: 0.98, green: 0.40, blue: 0.67),
                    tintB: Color(red: 0.78, green: 0.21, blue: 0.48),
                    title: "速度",
                    subtitle: "提升系统性能",
                    value: "\(viewModel.speedTaskCount)",
                    footnote: viewModel.lastSpeedExecutionResult == nil ? "个任务可运行" : "提升了 \(viewModel.lastSpeedExecutionResult?.performanceGainPercent ?? 0)% 速度",
                    buttonTitle: viewModel.dashboardStage == .scannedSummary ? (viewModel.hasOptimizedSpeedTasks ? "已优化" : "优化") : nil,
                    isButtonDisabled: viewModel.hasOptimizedSpeedTasks,
                    isHovered: viewModel.hoveredCard == .speed,
                    iconTap: { viewModel.showSpeedPopover() },
                    buttonTap: { Task { await viewModel.executeSpeedTasks() } },
                    hoverChanged: { hovering in
                        viewModel.setHoveredCard(hovering ? .speed : nil)
                    }
                )
            }
            .padding(.top, 32)
            .overlay(alignment: .top) {
                if viewModel.dashboardStage != .details, let popover = viewModel.activePopover {
                    if popover.card == .cleaning {
                        CleaningInfoBubble(content: popover)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(x: 12, y: -106)
                    } else if popover.card == .protection {
                        ProtectionInfoBubble(content: popover)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .offset(y: -106)
                    } else {
                        SpeedInfoBubble(content: popover)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .offset(x: -12, y: -106)
                    }
                }
            }

            HStack(spacing: 26) {
                if viewModel.isScanning {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.scanCurrentPath.isEmpty ? "正在等待…" : viewModel.scanCurrentPath)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                            .frame(width: 420, alignment: .leading)
                        Text(viewModel.scanDiscoveredCleanableBytes.byteString)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Button {
                    Task { await viewModel.performPrimaryAction() }
                } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 160, height: 160)
                        .overlay(Circle().stroke(Color.cyan.opacity(0.85), lineWidth: 6))
                        .shadow(color: .cyan.opacity(0.18), radius: 20)
                    Circle()
                        .trim(from: 0.08, to: 0.32)
                        .stroke(Color.white.opacity(viewModel.isPrimaryActionInProgress ? 0.95 : 0), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 148, height: 148)
                        .rotationEffect(.degrees(viewModel.scanRotation))
                    VStack(spacing: 8) {
                        Image(systemName: viewModel.primaryActionSymbolName)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                        Text(viewModel.primaryActionTitle)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                }
                .buttonStyle(.plain)

                if viewModel.isPrimaryActionInProgress {
                    Text(viewModel.scanDiscoveredCleanableBytes.byteString)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 160, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 46)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.hidePopover()
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 54)

            appIconArtwork
                .frame(width: 360, height: 280)

            VStack(spacing: 20) {
                Text("欢迎使用 CleanMac")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("开始全面、仔细扫描您的 Mac。")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.top, 24)

            Spacer()

            Button {
                Task { await viewModel.performPrimaryAction() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: 140, height: 140)
                        .overlay(Circle().stroke(Color.cyan.opacity(0.9), lineWidth: 4))
                        .shadow(color: .cyan.opacity(0.22), radius: 28)
                    Text("扫描")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 42)
        }
        .padding(.horizontal, 48)
    }


    private var resultsView: some View {
        HStack(spacing: 24) {
            leftSidebar
            rightDetailsPane
        }
        .padding(26)
    }

    private var leftSidebar: some View { VStack(alignment: .leading, spacing: 24) {
        Button {
            viewModel.backToSummary()
        } label: {
            Label("返回摘要", systemImage: "chevron.left")
        }
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }
        .buttonStyle(.plain)

        if viewModel.detailKind == .protection {
            protectionSidebar
        } else {
            detailSummaryCard
        }

        cleanAuthorizationCard
        Spacer()
    }
    .frame(width: 440, alignment: .topLeading) }

    @ViewBuilder
    private var detailSummaryCard: some View {
        switch viewModel.detailKind {
        case .cleaning:
            VStack(alignment: .leading, spacing: 18) {
                Button(viewModel.areAllCategoriesSelected ? "取消全选" : "全选") {
                    viewModel.toggleCategorySelection()
                }
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .buttonStyle(.plain)

                VStack(spacing: 12) {
                    ForEach(viewModel.visibleCleaningCategories) { category in
                        CleaningSidebarCategoryCard(
                            category: category,
                            selected: viewModel.selectedCategoryIDs.contains(category.id),
                            focused: viewModel.selectedCategory?.id == category.id,
                            isBulkCleaning: viewModel.isBulkCleaning
                        ) {
                            viewModel.selectCategory(category)
                        }
                    }
                }
            }
        case .protection, .speed:
            EmptyView()
        }
    }

    private var protectionSidebar: some View { VStack(alignment: .leading, spacing: 18) {
        Button(viewModel.areAllThreatsSelected ? "取消全选" : "全选") {
            viewModel.toggleThreatSelection()
        }
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .buttonStyle(.plain)

        VStack(spacing: 12) {
            ForEach(viewModel.protectionThreatGroups) { group in
                ProtectionThreatSidebarCard(group: group, selected: viewModel.selectedThreatKinds.contains(group.kind)) {
                    viewModel.selectThreat(kind: group.kind)
                }
            }
        }
    } }

    private var cleanAuthorizationCard: some View { VStack(alignment: .leading, spacing: 20) {
        Divider().overlay(.white.opacity(0.16))
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 10) {
                Text("通过全部磁盘访问清理更多内容")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(viewModel.hasPromptedForFullDiskAccess ? "完全磁盘访问只需开启一次；开启后，后续扫描会直接复用，无需重复授权。" : "首次开启完全磁盘访问后，CleanMac 后续扫描会直接复用权限，无需每次重复授权。")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Button(viewModel.hasPromptedForFullDiskAccess ? "再次打开设置" : "开启一次授权") {
            viewModel.openFullDiskAccessSettings()
        }
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .foregroundStyle(.black.opacity(0.84))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(LinearGradient(colors: [Color(red: 1.0, green: 0.91, blue: 0.55), Color(red: 0.97, green: 0.82, blue: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .buttonStyle(.plain)
    }
    .padding(.top, 26) }

    private var rightDetailsPane: some View { VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(detailHeaderTitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                Text(detailMainTitle)
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detailSubtitle)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
            }
            Spacer()
            if viewModel.detailKind == .cleaning {
                Button {
                    Task { await viewModel.cleanSelectedCategory() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isBulkCleaning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(viewModel.isBulkCleaning ? "清理中…" : "一键清理")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .disabled(viewModel.selectedCleanableSizeInBytes == 0 || viewModel.isCleaning || viewModel.isScanning)
            } else if viewModel.detailKind == .protection {
                Button {
                    Task { await viewModel.cleanSelectedThreatGroup() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isBulkCleaning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(viewModel.isBulkCleaning ? "清理中…" : "一键清理")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
                .disabled(viewModel.isCleaning || viewModel.isScanning || viewModel.selectedThreatKinds.isEmpty)
            }
        }

        topStatsStrip

        if viewModel.detailKind == .cleaning {
            HStack {
                Spacer()
                Picker("排序方式", selection: $viewModel.sortOption) {
                    ForEach(CategorySortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.88))
                .font(.system(size: 18, weight: .bold, design: .rounded))
            }
        }

        ScrollView {
            switch viewModel.detailKind {
            case .cleaning:
                VStack(spacing: 14) {
                    ForEach(viewModel.visibleCleaningCategories) { category in
                        CleanableCategoryGroup(
                            category: category,
                            items: viewModel.visibleItems(for: category),
                            selected: viewModel.selectedCategoryIDs.contains(category.id),
                            focused: category.id == viewModel.selectedCategory?.id
                            ,activeCleaningItemIDs: viewModel.activeCleaningItemIDs
                            ,isBulkCleaning: viewModel.isBulkCleaning
                        ) {
                            viewModel.selectCategory(category)
                        } cleanAction: { item in
                            Task { await viewModel.clean(item) }
                        }
                    }
                }
                .padding(.vertical, 4)
            case .protection:
                allProtectionDetailsContent
            case .speed:
                EmptyView()
            }
        }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.ultraThinMaterial.opacity(0.34), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .stroke(.white.opacity(0.10), lineWidth: 1)
    } }

    private var detailHeaderTitle: String {
        switch viewModel.detailKind {
        case .cleaning: return "清理详情"
        case .protection: return "保护详情"
        case .speed: return "速度详情"
        }
    }

    private var detailMainTitle: String {
        switch viewModel.detailKind {
        case .cleaning: return viewModel.selectedCategory?.title ?? "系统垃圾"
        case .protection: return viewModel.selectedThreatGroup?.title ?? "潜在威胁"
        case .speed: return "建议执行的优化"
        }
    }

    private var detailSubtitle: String {
        switch viewModel.detailKind {
        case .cleaning:
            return "仅展示可安全清理的缓存、日志、开发残留与废纸篓内容。"
        case .protection:
            return viewModel.selectedThreatGroup?.description ?? "这里展示需要进一步处理的潜在威胁。"
        case .speed:
            return "这里展示建议执行的性能优化项，首页仅保留数量摘要。"
        }
    }

    private var allProtectionDetailsContent: some View { VStack(alignment: .leading, spacing: 28) {
        ForEach(viewModel.protectionThreatGroups) { group in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 68, height: 68)
                        Image(systemName: group.symbolName)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(group.description)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.80))
                    }
                    Spacer()
                    Text("\(group.threatCount) 个威胁")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 14) {
                    ForEach(group.items) { item in
                        ProtectionThreatItemRow(item: item, isLoading: viewModel.activeCleaningThreatItemIDs.contains(item.id)) {
                            if item.item != nil && item.item?.isCleanable == true {
                                Task {
                                    await viewModel.cleanThreatItem(item)
                                }
                            } else {
                                viewModel.revealThreatItem(item)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
    .padding(.vertical, 4) }

    private var topStatsStrip: some View {
        Group {
            if let snapshot = viewModel.snapshot {
                HStack(spacing: 18) {
                    StatsCapsule(title: "已扫描", value: snapshot.usedSpace.byteString, tint: .cyan)
                    StatsCapsule(title: "可清理", value: snapshot.cleanableSizeInBytes.byteString, tint: .mint)
                    StatsCapsule(title: viewModel.detailKind == .protection ? "风险项" : "可用空间", value: viewModel.detailKind == .protection ? "\(viewModel.protectionCount)" : snapshot.freeSpace.byteString, tint: viewModel.detailKind == .protection ? .orange : .pink)
                }
            }
        }
    }

    private var appIconArtwork: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.98, green: 0.40, blue: 0.70).opacity(0.34),
                            Color(red: 0.36, green: 0.80, blue: 0.96).opacity(0.14),
                            .clear
                        ],
                        center: .center,
                        startRadius: 18,
                        endRadius: 170
                    )
                )
                .frame(width: 320, height: 320)
                .blur(radius: 10)

            ZStack {
                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.97, green: 0.42, blue: 0.73),
                                Color(red: 0.89, green: 0.21, blue: 0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 280, height: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 42, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.24), .white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 280, height: 200)
                    .mask(
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 42, style: .continuous)
                                .frame(height: 66)
                            Spacer()
                        }
                    )

                iconWiperShape
                    .stroke(Color(red: 0.22, green: 0.13, blue: 0.31), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    .frame(width: 170, height: 150)
                    .offset(x: 54, y: -6)

                iconWiperShape
                    .stroke(.black.opacity(0.16), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                    .frame(width: 170, height: 150)
                    .offset(x: 57, y: -2)
                    .blur(radius: 0.8)

                Circle()
                    .trim(from: 0.18, to: 0.92)
                    .stroke(Color(red: 0.67, green: 0.12, blue: 0.43), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(-38))
                    .offset(y: 62)
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.94), Color(red: 0.86, green: 0.88, blue: 0.95)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 82, height: 18)
                .offset(y: 118)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 7)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.98), Color(red: 0.80, green: 0.82, blue: 0.90)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 128, height: 18)
                .offset(y: 144)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
        }
        .frame(width: 360, height: 300)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 20)
    }

    private var iconWiperShape: Path {
        Path { path in
            path.move(to: CGPoint(x: 14, y: 10))
            path.addLine(to: CGPoint(x: 138, y: 102))
            path.addLine(to: CGPoint(x: 124, y: 108))
            path.addLine(to: CGPoint(x: 152, y: 16))
            path.move(to: CGPoint(x: 136, y: 102))
            path.addLine(to: CGPoint(x: 164, y: 146))
        }
    }
}

private struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.48), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }
}

private struct FullDiskAccessPrompt: View {
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.36))
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(alignment: .center, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .center, spacing: 12) {
                        Text("授权 CleanMac 访问全部磁盘")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        (
                            Text("打开您的“")
                                .foregroundStyle(.white.opacity(0.88))
                            + Text("系统偏好设置")
                                .foregroundStyle(Color.blue)
                            + Text("”，进行身份验证并在“完全磁盘访问权限”列表中选择 CleanMac。")
                                .foregroundStyle(.white.opacity(0.88))
                        )
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .onTapGesture(perform: openSettings)
                    }

                    Spacer(minLength: 16)

                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Image("FullDiskAccessGuide")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.26), radius: 24, y: 18)
                    .frame(maxWidth: .infinity)

            }
            .padding(28)
            .frame(width: 540)
            .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
        }
    }
}

private struct CleaningInfoBubble: View {
    let content: DashboardPopoverContent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                        Text(row.title)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 12)
                        if let value = row.value {
                            Text(value)
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }
            }
            if let action = content.action {
                Button(action.title, action: action.handler)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.28), in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 250, maxWidth: 300, alignment: .leading)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .bottom) {
            Triangle().fill(Color.black.opacity(0.85)).frame(width: 18, height: 12).offset(y: 11)
        }
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

private struct ProtectionInfoBubble: View {
    let content: DashboardPopoverContent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                        Text(row.title)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 12)
                        if let value = row.value {
                            Text(value)
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }
            }
            if let action = content.action {
                Button(action.title, action: action.handler)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.28), in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 250, maxWidth: 300, alignment: .leading)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .bottom) {
            Triangle().fill(Color.black.opacity(0.85)).frame(width: 18, height: 12).offset(y: 11)
        }
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

private struct SpeedInfoBubble: View {
    let content: DashboardPopoverContent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                        Text(row.title)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 12)
                        if let value = row.value {
                            Text(value)
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 250, maxWidth: 300, alignment: .leading)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .bottom) {
            Triangle().fill(Color.black.opacity(0.85)).frame(width: 18, height: 12).offset(y: 11)
        }
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

private struct HomeFeatureCard: View {
    let kind: DashboardCardKind
    let icon: String
    let tintA: Color
    let tintB: Color
    let title: String
    let subtitle: String
    let value: String
    let footnote: String
    let buttonTitle: String?
    var isButtonDisabled: Bool = false
    var badgeText: String? = nil
    let isHovered: Bool
    let iconTap: () -> Void
    let buttonTap: () -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Button(action: iconTap) {
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(LinearGradient(colors: [tintA, tintB], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 210, height: 170)
                        .shadow(color: tintA.opacity(isHovered ? 0.40 : 0.25), radius: isHovered ? 24 : 18)
                    Image(systemName: icon)
                        .font(.system(size: 74, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .scaleEffect(isHovered ? 1.05 : 1)
                .offset(y: isHovered ? -6 : 0)
            }
            .buttonStyle(.plain)
            .onHover(perform: hoverChanged)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.cyan)
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if let badgeText {
                        Text(badgeText)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))

                VStack(spacing: 12) {
                    Button(action: iconTap) {
                        VStack(spacing: 2) {
                            Text(value)
                                .font(.system(size: 62, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                            Text(footnote)
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .buttonStyle(.plain)

                    if let buttonTitle {
                        Button(buttonTitle, action: buttonTap)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(isButtonDisabled ? .white.opacity(0.45) : .cyan)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(isButtonDisabled ? .white.opacity(0.10) : .black.opacity(0.18), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(isButtonDisabled ? .white.opacity(0.12) : .clear, lineWidth: 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(isButtonDisabled)
                    }
                }
            }
        }
        .frame(width: 320, alignment: .top)
    }
}

private struct StatsCapsule: View {
    let title: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.62))
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ProtectionThreatSidebarCard: View {
    let group: ProtectionThreatGroup
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 28, weight: .bold)).foregroundStyle(selected ? .cyan : .white.opacity(0.58))
                ZStack {
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 72, height: 72)
                    Image(systemName: group.symbolName).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                }
                Text(group.title).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                Text("\(group.threatCount) 个威胁").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(22)
            .background(selected ? .white.opacity(0.12) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(selected ? .white.opacity(0.14) : .clear, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct ProtectionThreatItemRow: View {
    let item: ProtectionThreatItem
    let isLoading: Bool
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.12)).frame(width: 54, height: 54)
                Image(systemName: item.symbolName).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(item.name).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(item.severity.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(severityColor.opacity(0.9), in: Capsule())
                }
                Text(item.path).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.52)).lineLimit(1)
                if let evidence = item.evidences.first {
                    Text("\(evidence.title)：\(evidence.detail)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                if item.evidences.count > 1, let secondaryEvidence = item.evidences.dropFirst().first {
                    Text("\(secondaryEvidence.title)：\(secondaryEvidence.detail)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                deleteAction()
            } label: {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isLoading ? "清理中…" : (item.item != nil && item.item?.isCleanable == true ? "删除" : "查看"))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(item.item != nil && item.item?.isCleanable == true ? .red.opacity(0.82) : .white.opacity(0.18))
            .disabled(isLoading)
        }
        .padding(18)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var severityColor: Color {
        switch item.severity {
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct CleanableCategoryGroup: View {
    let category: StorageCategory
    let items: [StorageItem]
    let selected: Bool
    let focused: Bool
    let activeCleaningItemIDs: Set<StorageItem.ID>
    let isBulkCleaning: Bool
    let selectAction: () -> Void
    let cleanAction: (StorageItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button(action: selectAction) {
                    HStack(spacing: 14) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(selected ? .cyan : .white.opacity(0.55))
                        ZStack {
                            Circle().fill(category.section.tint.gradient).frame(width: 56, height: 56)
                            Image(systemName: category.section.icon).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        }
                        Text(category.title).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 8) {
                    if isBulkCleaning && selected {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isBulkCleaning && selected ? "清理中…" : category.cleanableSizeInBytes.byteString)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }

            ForEach(items) { item in
                HStack(spacing: 14) {
                    Image(systemName: item.symbolName).frame(width: 28).foregroundStyle(.white.opacity(0.86))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text(item.path).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.50)).lineLimit(1)
                    }
                    Spacer()
                    Text(item.sizeInBytes.byteString).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Button {
                        cleanAction(item)
                    } label: {
                        HStack(spacing: 8) {
                            if activeCleaningItemIDs.contains(item.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(activeCleaningItemIDs.contains(item.id) ? "清理中…" : "清理")
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(.red.opacity(0.82))
                        .disabled(activeCleaningItemIDs.contains(item.id))
                }
                .padding(16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(22)
        .background((selected ? .white.opacity(0.12) : .white.opacity(0.06)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke((focused || selected) ? .white.opacity(0.16) : .clear, lineWidth: 1)
        }
    }
}

private struct CleaningSidebarCategoryCard: View {
    let category: StorageCategory
    let selected: Bool
    let focused: Bool
    let isBulkCleaning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(selected ? .cyan : .white.opacity(0.55))

                ZStack {
                    Circle()
                        .fill(category.section.tint.gradient)
                        .frame(width: 54, height: 54)
                    Image(systemName: category.section.icon)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(viewModelText(for: category))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 8) {
                    if isBulkCleaning && selected {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Text(isBulkCleaning && selected ? "清理中…" : category.cleanableSizeInBytes.byteString)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .padding(20)
            .background(.black.opacity(focused ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke((focused || selected) ? .white.opacity(0.16) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBulkCleaning)
    }

    private func viewModelText(for category: StorageCategory) -> String {
        category.subtitle
    }
}
