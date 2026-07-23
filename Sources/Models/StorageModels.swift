import Foundation
import SwiftUI

enum StorageSection: String, CaseIterable, Identifiable {
    case userFiles
    case applications
    case developer
    case system
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userFiles: return "文件"
        case .applications: return "应用"
        case .developer: return "开发环境"
        case .system: return "系统"
        case .hidden: return "隐形空间"
        }
    }

    var subtitle: String {
        switch self {
        case .userFiles: return "文稿、下载、桌面与媒体文件"
        case .applications: return "应用程序与 App 容器"
        case .developer: return "Xcode、模拟器、Homebrew 与开发缓存"
        case .system: return "系统数据、日志与系统缓存"
        case .hidden: return "Library、容器、索引与其他不易察觉的数据"
        }
    }

    var tint: Color {
        switch self {
        case .userFiles: return Color(red: 0.23, green: 0.73, blue: 0.98)
        case .applications: return Color(red: 0.41, green: 0.56, blue: 0.98)
        case .developer: return Color(red: 0.64, green: 0.45, blue: 0.98)
        case .system: return Color(red: 0.40, green: 0.84, blue: 0.67)
        case .hidden: return Color(red: 0.99, green: 0.67, blue: 0.39)
        }
    }

    var icon: String {
        switch self {
        case .userFiles: return "folder.fill"
        case .applications: return "app.dashed"
        case .developer: return "hammer.fill"
        case .system: return "gearshape.2.fill"
        case .hidden: return "eye.slash.fill"
        }
    }
}

enum CategorySortOption: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending: return "按大小"
        case .sizeAscending: return "按大小（升序）"
        case .title: return "按名称"
        }
    }
}

enum DashboardStage {
    case welcome
    case ready
    case scannedSummary
    case details
}

enum DashboardDetailKind {
    case cleaning
    case protection
    case speed
}

enum ProtectionThreatKind: String, CaseIterable, Identifiable {
    case trojan
    case adware
    case trackers
    case systemHardening
    case configProfile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trojan: return "木马病毒"
        case .adware: return "广告软件"
        case .trackers: return "隐私追踪项"
        case .systemHardening: return "系统安全配置"
        case .configProfile: return "配置描述文件"
        }
    }

    var summary: String {
        switch self {
        case .trojan: return "发现伪装程序与下载残留，建议立即处理。"
        case .adware: return "发现可能影响浏览与启动行为的可疑项目。"
        case .trackers: return "发现可采集使用行为的追踪文件与缓存。"
        case .systemHardening: return "发现被关闭或削弱的系统安全防护，建议尽快恢复。"
        case .configProfile: return "发现已安装的配置描述文件，可能被用于篡改系统或浏览器设置。"
        }
    }

    var description: String {
        switch self {
        case .trojan:
            return "“木马病毒”是一类伪装成正常文件或安装包的潜在威胁，可能在未经授权的情况下访问设备文件、网络连接或敏感信息。建议清理可疑安装包、启动残留和相关缓存。"
        case .adware:
            return "“广告软件”通常会通过启动项、浏览器扩展或缓存残留影响系统体验，造成弹窗、重定向或后台资源占用。建议移除来源不明的残留与相关缓存。"
        case .trackers:
            return "“隐私追踪项”会记录使用行为、浏览信息或应用活动，虽然不一定直接破坏系统，但会增加隐私暴露风险。建议清理相关日志、容器与追踪缓存。"
        case .systemHardening:
            return "“系统安全配置”检查 Gatekeeper、系统完整性保护(SIP)、FileVault 全盘加密、应用防火墙与自动登录等系统级防护状态。这些防护被关闭会显著扩大攻击面。请前往系统设置逐项恢复。"
        case .configProfile:
            return "“配置描述文件”(Configuration Profile) 可强制修改浏览器主页、搜索引擎、DNS 或安装根证书，是广告软件与劫持程序常见的持久化手段。请在系统设置中核对来源并移除可疑描述文件。"
        }
    }

    var symbolName: String {
        switch self {
        case .trojan: return "exclamationmark.shield.fill"
        case .adware: return "sparkles.rectangle.stack.fill"
        case .trackers: return "eye.trianglebadge.exclamationmark"
        case .systemHardening: return "lock.shield.fill"
        case .configProfile: return "doc.badge.gearshape.fill"
        }
    }
}

struct ProtectionThreatItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let symbolName: String
    let item: StorageItem?
    let isExactMatch: Bool
    let severity: ThreatSeverity
    let evidences: [ThreatEvidence]
    var settingsURLString: String? = nil
}

struct ProtectionThreatGroup: Identifiable, Hashable {
    let kind: ProtectionThreatKind
    let items: [ProtectionThreatItem]

    var id: ProtectionThreatKind { kind }
    var title: String { kind.title }
    var summary: String { kind.summary }
    var description: String { kind.description }
    var symbolName: String { kind.symbolName }
    var threatCount: Int { items.count }
}

struct SpeedExecutionResult {
    let executedTasks: [OptimizationTask]
    let performanceGainPercent: Int

    var message: String {
        if performanceGainPercent > 0 {
            return "性能已提升约 \(performanceGainPercent)%"
        }
        guard let first = executedTasks.first else { return "已完成优化" }
        if executedTasks.count == 1 { return "已优化：\(first.title)" }
        return "已完成 \(executedTasks.count) 项优化"
    }
}

enum DashboardCardKind: String, Identifiable {
    case cleaning
    case protection
    case speed

    var id: String { rawValue }
}

struct DashboardPopoverAction {
    let title: String
    let handler: () -> Void
}

struct DashboardPopoverContent {
    let card: DashboardCardKind
    let title: String
    let rows: [DashboardPopoverRow]
    let action: DashboardPopoverAction?
}

struct DashboardPopoverRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String?
}


struct StorageItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let sizeInBytes: Int64
    let symbolName: String
    let isCleanable: Bool

    var isSafeForOneClickCleanup: Bool {
        guard isCleanable else { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var safePrefixes = [
            home + "/Library/Caches",
            home + "/Library/Logs",
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/Xcode/Archives",
            home + "/Library/Developer/CoreSimulator/Caches",
            home + "/Library/Developer/CoreSimulator/Devices",
            "/opt/homebrew/var/homebrew",
            "/private/tmp",
            "/tmp"
        ]
        // 家目录顶层可再生缓存类隐藏目录（白名单）。
        safePrefixes.append(contentsOf: HiddenDotWhitelist.cleanableNames.map { home + "/" + $0 })

        return safePrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    var shouldSuggestManualCleanup: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let manualPrefixes = [
            home + "/Library/Logs",
            home + "/Library/Application Support",
            home + "/Library/Group Containers",
            home + "/Library/Mail",
            "/Library/Caches",
            "/private/var/log"
        ]

        return manualPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

struct StorageCategory: Identifiable, Hashable {
    let id = UUID()
    let section: StorageSection
    let items: [StorageItem]

    var title: String { section.title }
    var subtitle: String { section.subtitle }
    var sizeInBytes: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }
    var cleanableSizeInBytes: Int64 { items.filter(\.isCleanable).reduce(0) { $0 + $1.sizeInBytes } }
}

struct OptimizationTask: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String
}

enum SpeedOptimizationError: LocalizedError {
    case commandFailed(task: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(task, reason):
            return "无法完成“\(task)”：\(reason)"
        }
    }
}

struct StorageSnapshot {
    let scannedAt: Date
    let totalCapacity: Int64
    let freeSpace: Int64
    let categories: [StorageCategory]
    let threatRecords: [ThreatScanRecord]

    var usedSpace: Int64 { max(totalCapacity - freeSpace, 0) }
    var cleanableSizeInBytes: Int64 { categories.reduce(0) { $0 + $1.cleanableSizeInBytes } }
    var protectionIssueCount: Int { threatRecords.count }

    var speedTasks: [OptimizationTask] {
        var tasks: [OptimizationTask] = [
            OptimizationTask(title: "运行维护脚本", detail: "建议定期执行系统维护任务"),
            OptimizationTask(title: "刷新 DNS 缓存", detail: "解决网络解析迟缓与缓存异常"),
            OptimizationTask(title: "释放 RAM", detail: "关闭高占用后台任务并释放内存压力")
        ]

        if categories.contains(where: { $0.section == .developer && $0.cleanableSizeInBytes > 5_000_000_000 }) {
            tasks.append(OptimizationTask(title: "清理开发缓存", detail: "DerivedData、Archives 与包缓存占用较高"))
        }
        if freeSpace < 40_000_000_000 {
            tasks.append(OptimizationTask(title: "释放启动盘空间", detail: "保持更多可用空间可提升系统流畅度"))
        }
        if categories.contains(where: { $0.section == .system && $0.cleanableSizeInBytes > 1_000_000_000 }) {
            tasks.append(OptimizationTask(title: "清理日志与系统缓存", detail: "过多日志会增加系统索引与扫描负担"))
        }
        if categories.contains(where: { $0.section == .hidden && $0.cleanableSizeInBytes > 500_000_000 }) {
            tasks.append(OptimizationTask(title: "整理废纸篓与隐形残留", detail: "减少无用残留文件对磁盘与搜索的影响"))
        }
        return tasks
    }

    var protectionThreatGroups: [ProtectionThreatGroup] {
        let grouped = Dictionary(grouping: threatRecords, by: \.kind)

        return ProtectionThreatKind.allCases.compactMap { kind in
            guard let records = grouped[kind], !records.isEmpty else { return nil }
            let items = records.map { record in
                ProtectionThreatItem(
                    name: record.displayName,
                    path: record.path,
                    symbolName: record.symbolName,
                    item: record.relatedItem,
                    isExactMatch: true,
                    severity: record.severity,
                    evidences: record.evidences,
                    settingsURLString: record.settingsURLString
                )
            }
            return ProtectionThreatGroup(kind: kind, items: items)
        }
    }
}

extension Int64 {
    var byteString: String {
        let value = ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
        return value.replacingOccurrences(of: "Zero KB", with: "0 KB")
            .replacingOccurrences(of: "Zero bytes", with: "0 bytes")
    }
}
