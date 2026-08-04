import Foundation

struct ScanProgress {
    let currentPath: String
    let discoveredCleanableBytes: Int64
}

struct CleanupSummary {
    let succeededCount: Int
    let skippedItems: [StorageItem]

    var skippedCount: Int { skippedItems.count }
}

enum ScanAccessMode {
    case lightweight
    case privileged
}

/// 家目录顶层隐藏项的清理白名单。只有这些目录里的内容由对应工具在需要时自动重建，
/// 整目录清理仅影响缓存/临时数据；名单外的 dotfile/dotfolder 一律只列出、不代删，
/// 以免误删 .ssh、.gitconfig、.aws、.zshrc 等配置。
enum HiddenDotWhitelist {
    static let cleanableNames: Set<String> = [
        ".cache",
        ".npm",
        ".yarn",
        ".pnpm-store",
        ".gradle",
        ".m2",
        ".sbt",
        ".ivy2",
        ".expo",
        ".dartServer",
        ".pub-cache",
        ".electron",
        ".node-gyp",
        ".android",
        ".keras",
        ".ollama",
        ".cursor-tutor",
        ".vscode-test"
    ]

    static func isCleanable(name: String) -> Bool {
        cleanableNames.contains(name)
    }
}

enum StorageCleanError: LocalizedError {
    case permissionDenied(itemName: String, path: String)
    case itemBusy(itemName: String, path: String)
    case manualCleanupRecommended(itemName: String, path: String)
    case partialFailure(itemName: String, succeeded: Int, failed: Int)
    case cleanupFailed(itemName: String, path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(itemName, path):
            return "无法清理“\(itemName)”。CleanMac 当前没有访问该目录的权限。请前往系统设置 > 隐私与安全性 > 完全磁盘访问，并为 CleanMac 开启权限后重试。\n\n路径：\(path)"
        case let .itemBusy(itemName, path):
            return "无法清理“\(itemName)”，因为它正被系统或其他 App 占用。请先退出相关应用后重试。\n\n路径：\(path)"
        case let .manualCleanupRecommended(itemName, path):
            return "“\(itemName)”建议手动清理。这个目录里的内容可能仍被系统或其他 App 使用，为避免误删，CleanMac 不会直接代删。\n\n建议：打开 Finder 前往该路径，自行检查后删除不需要的内容。\n\n路径：\(path)"
        case let .partialFailure(itemName, succeeded, failed):
            return "“\(itemName)”已部分清理完成，成功清理 \(succeeded) 项，仍有 \(failed) 项因权限或占用未能处理。"
        case let .cleanupFailed(itemName, path, reason):
            return "无法清理“\(itemName)”。\(reason)\n\n路径：\(path)"
        }
    }
}

struct StorageScanner {
    private struct InstalledAppInfo {
        let bundleIdentifier: String
        let displayName: String
        let appPath: String

        var cacheDisplayName: String {
            let baseName = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            return "\(baseName).app 缓存"
        }
    }

    private struct AppMetadataIndex {
        let appsByBundleIdentifier: [String: InstalledAppInfo]
        let appsByName: [String: InstalledAppInfo]
        let bundleIdentifiersByLength: [String]

        func owner(forCacheName name: String) -> InstalledAppInfo? {
            let loweredName = name.lowercased()
            if let app = appsByBundleIdentifier[loweredName] {
                return app
            }

            if let bundleIdentifier = bundleIdentifiersByLength.first(where: { identifier in
                loweredName.hasPrefix(identifier + ".")
                    || loweredName.hasPrefix(identifier + "-")
                    || loweredName.hasPrefix(identifier + "_")
            }) {
                return appsByBundleIdentifier[bundleIdentifier]
            }

            let normalized = Self.normalizedName(name)
            if let app = appsByName[normalized] {
                return app
            }

            return appsByName[Self.normalizedNameByRemovingCacheSuffix(from: name)]
        }

        func owner(forApplicationSupportName name: String) -> InstalledAppInfo? {
            owner(forCacheName: name)
        }

        func owner(forGroupContainerName name: String) -> InstalledAppInfo? {
            let loweredName = name.lowercased()
            if let bundleIdentifier = bundleIdentifiersByLength.first(where: { loweredName.contains($0) }) {
                return appsByBundleIdentifier[bundleIdentifier]
            }
            return owner(forCacheName: name)
        }

        static func normalizedName(_ value: String) -> String {
            value
                .lowercased()
                .replacingOccurrences(of: ".app", with: "")
                .filter { $0.isLetter || $0.isNumber }
        }

        private static func normalizedNameByRemovingCacheSuffix(from value: String) -> String {
            let lowercased = value.lowercased()
            let suffixes = [" cache", " caches", "缓存"]
            let stripped = suffixes.reduce(lowercased) { partial, suffix in
                partial.hasSuffix(suffix) ? String(partial.dropLast(suffix.count)) : partial
            }
            return normalizedName(stripped)
        }
    }

    private struct AppCacheAccumulator {
        let name: String
        let symbolName: String
        let appIconPath: String?
        var paths: [String]
        var sizeInBytes: Int64

        mutating func add(path: String, sizeInBytes: Int64) {
            guard !paths.contains(path) else { return }
            paths.append(path)
            self.sizeInBytes += sizeInBytes
        }

        var storageItem: StorageItem? {
            guard let path = paths.first else { return nil }
            return StorageItem(
                name: name,
                path: path,
                relatedPaths: Array(paths.dropFirst()),
                sizeInBytes: sizeInBytes,
                symbolName: symbolName,
                isCleanable: true,
                appIconPath: appIconPath
            )
        }
    }

    private let fileManager = FileManager.default
    private let progress: ((ScanProgress) -> Void)?
    private let progressState = ProgressState()
    private let accessMode: ScanAccessMode

    init(accessMode: ScanAccessMode = .lightweight, progress: ((ScanProgress) -> Void)? = nil) {
        self.accessMode = accessMode
        self.progress = progress
    }

    func scan() -> StorageSnapshot {
        progressState.cleanableAccumulator = 0
        let home = fileManager.homeDirectoryForCurrentUser
        let volume = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(volume?.volumeTotalCapacity ?? 0)
        let free = Int64(volume?.volumeAvailableCapacityForImportantUsage ?? 0)

        let categories = [
            makeUserFilesCategory(home: home),
            makeApplicationsCategory(home: home),
            makeAppCachesCategory(home: home),
            makeDeveloperCategory(home: home),
            makeSystemCategory(home: home),
            makeHiddenCategory(home: home),
            makeTrashCategory(home: home)
        ]

        let threatRecords = ThreatScanner().scan(categories: categories) + SecurityAuditScanner().scan()

        return StorageSnapshot(scannedAt: Date(), totalCapacity: total, freeSpace: free, categories: categories, threatRecords: threatRecords)
    }

    func clean(_ item: StorageItem) throws {
        guard item.isCleanable else { return }
        let existingPaths = item.cleanupPaths.filter { fileManager.fileExists(atPath: $0) }
        guard !existingPaths.isEmpty else { return }

        do {
            for path in existingPaths {
                try cleanPath(path)
            }
            CleanupHistoryStore.addCleanedBytes(item.sizeInBytes)
        } catch {
            throw mapCleanError(error, item: item)
        }
    }

    private func cleanPath(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == ".Trash" || shouldEmptyDirectoryContents(at: url) {
            try emptyDirectoryContents(at: url)
        } else {
            try trashItem(at: url)
        }
    }

    private func shouldEmptyDirectoryContents(at url: URL) -> Bool {
        let path = url.path
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(homePath + "/Library/Containers/")
                || path.hasPrefix(homePath + "/Library/Group Containers/") else {
            return false
        }

        return path.hasSuffix("/Cache") || path.hasSuffix("/Caches")
    }

    func clean(items: [StorageItem], categoryName: String) throws -> CleanupSummary {
        var succeeded = 0
        var skippedItems: [StorageItem] = []
        var firstFatalError: Error?

        for item in items where item.isCleanable {
            do {
                try clean(item)
                succeeded += 1
            } catch {
                if let cleanError = error as? StorageCleanError {
                    switch cleanError {
                    case .permissionDenied, .manualCleanupRecommended, .itemBusy:
                        skippedItems.append(item)
                    case .partialFailure, .cleanupFailed:
                        if firstFatalError == nil {
                            firstFatalError = cleanError
                        }
                    }
                } else if firstFatalError == nil {
                    firstFatalError = error
                }
            }
        }

        if let firstFatalError, succeeded == 0, skippedItems.isEmpty {
            throw firstFatalError
        }

        if succeeded == 0, skippedItems.isEmpty, !items.isEmpty {
            throw StorageCleanError.cleanupFailed(itemName: categoryName, path: "", reason: "未知错误")
        }

        return CleanupSummary(succeededCount: succeeded, skippedItems: skippedItems)
    }

    private func trashItem(at url: URL) throws {
        var trashedURL: NSURL?
        do {
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFeatureUnsupportedError, NSFileWriteUnsupportedSchemeError].contains(nsError.code) {
                try fileManager.removeItem(at: url)
                return
            }
            throw error
        }
    }

    private func emptyDirectoryContents(at url: URL) throws {
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )

        for childURL in children {
            do {
                try fileManager.removeItem(at: childURL)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError].contains(nsError.code) {
                    continue
                }
                throw error
            }
        }
    }

    private func mapCleanError(_ error: Error, item: StorageItem) -> StorageCleanError {
        if item.shouldSuggestManualCleanup {
            return .manualCleanupRecommended(itemName: item.name, path: item.path)
        }

        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain {
            if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
                return .permissionDenied(itemName: item.name, path: item.path)
            }
            if [NSFileLockingError, NSExecutableRuntimeMismatchError].contains(nsError.code) {
                return .itemBusy(itemName: item.name, path: item.path)
            }
        }

        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) {
            return .permissionDenied(itemName: item.name, path: item.path)
        }

        return .cleanupFailed(itemName: item.name, path: item.path, reason: nsError.localizedDescription)
    }

    private func makeUserFilesCategory(home: URL) -> StorageCategory {
        let downloadsURL = home.appendingPathComponent("Downloads")
        let picturesURL = home.appendingPathComponent("Pictures")

        let baseItems: [StorageItem] = [
            StorageItem(name: "桌面", path: home.appendingPathComponent("Desktop").path, sizeInBytes: categoryDirectorySize(at: home.appendingPathComponent("Desktop")), symbolName: "desktopcomputer", isCleanable: false),
            StorageItem(name: "文稿", path: home.appendingPathComponent("Documents").path, sizeInBytes: categoryDirectorySize(at: home.appendingPathComponent("Documents")), symbolName: "doc.text.fill", isCleanable: false),
            StorageItem(name: "下载", path: downloadsURL.path, sizeInBytes: categoryDirectorySize(at: downloadsURL), symbolName: "arrow.down.circle.fill", isCleanable: false),
            StorageItem(name: "图片", path: picturesURL.path, sizeInBytes: categoryDirectorySize(at: picturesURL), symbolName: "photo.fill", isCleanable: false),
            StorageItem(name: "影片", path: home.appendingPathComponent("Movies").path, sizeInBytes: categoryDirectorySize(at: home.appendingPathComponent("Movies")), symbolName: "film.fill", isCleanable: false),
            StorageItem(name: "音乐", path: home.appendingPathComponent("Music").path, sizeInBytes: categoryDirectorySize(at: home.appendingPathComponent("Music")), symbolName: "music.note", isCleanable: false)
        ].filter { $0.sizeInBytes > 0 }

        let downloadCleanableItems = makeDownloadCleanableItems(at: downloadsURL)

        return StorageCategory(section: .userFiles, items: baseItems + downloadCleanableItems)
    }

    private func makeDownloadCleanableItems(at url: URL) -> [StorageItem] {
        guard fileManager.fileExists(atPath: url.path),
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
              ) else {
            return []
        }

        let oldEnough = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        var items: [StorageItem] = []

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            let cleanableExtensions = Set(["dmg", "zip", "pkg", "xip", "iso", "rar", "7z", "tar", "gz"])
            guard cleanableExtensions.contains(ext) else { continue }

            let modifiedAt = values.contentModificationDate ?? .distantPast
            guard modifiedAt < oldEnough else { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard size > 0 else { continue }

            progress?(ScanProgress(currentPath: fileURL.path, discoveredCleanableBytes: progressState.cleanableAccumulator + size))
            progressState.cleanableAccumulator += size

            items.append(
                StorageItem(
                    name: fileURL.lastPathComponent,
                    path: fileURL.path,
                    sizeInBytes: size,
                    symbolName: symbolName(forExtension: ext),
                    isCleanable: true
                )
            )
        }

        return items.sorted { $0.sizeInBytes > $1.sizeInBytes }
    }

    private func symbolName(forExtension ext: String) -> String {
        switch ext {
        case "dmg", "pkg", "xip", "iso":
            return "shippingbox.fill"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox.fill"
        default:
            return "doc.fill"
        }
    }

    private func makeApplicationsCategory(home: URL) -> StorageCategory {
        let defs: [(String, String, String, Bool)] = [
            ("系统应用", "/Applications", "app.fill", false),
            ("用户应用", home.appendingPathComponent("Applications").path, "person.crop.square", false),
            ("App 容器", home.appendingPathComponent("Library/Containers").path, "shippingbox.fill", false)
        ]
        return StorageCategory(section: .applications, items: defs.map { name, path, icon, cleanable in
            StorageItem(name: name, path: path, sizeInBytes: directorySize(atPath: path, countAsCleanable: cleanable), symbolName: icon, isCleanable: cleanable)
        }.filter { $0.sizeInBytes > 0 })
    }

    private func makeAppCachesCategory(home: URL) -> StorageCategory {
        let appIndex = makeAppMetadataIndex(home: home)
        var accumulators: [String: AppCacheAccumulator] = [:]

        scanUserCacheDirectory(home: home, appIndex: appIndex, accumulators: &accumulators)
        scanContainerCacheDirectories(home: home, appIndex: appIndex, accumulators: &accumulators)
        scanGroupContainerCacheDirectories(home: home, appIndex: appIndex, accumulators: &accumulators)
        scanApplicationSupportCacheDirectories(home: home, appIndex: appIndex, accumulators: &accumulators)

        let items = accumulators.values.compactMap(\.storageItem)
        return StorageCategory(section: .appCaches, items: items.sorted { $0.sizeInBytes > $1.sizeInBytes })
    }

    private func scanUserCacheDirectory(home: URL, appIndex: AppMetadataIndex, accumulators: inout [String: AppCacheAccumulator]) {
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
        guard fileManager.fileExists(atPath: cachesURL.path),
              let childURLs = try? fileManager.contentsOfDirectory(
                at: cachesURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: []
              ) else {
            return
        }

        for childURL in childURLs {
            guard !isIgnoredAppCacheEntry(childURL) else { continue }
            let owner = appIndex.owner(forCacheName: childURL.lastPathComponent)
            addAppCacheRoot(childURL, owner: owner, fallbackName: childURL.lastPathComponent, accumulators: &accumulators)
        }
    }

    private func scanContainerCacheDirectories(home: URL, appIndex: AppMetadataIndex, accumulators: inout [String: AppCacheAccumulator]) {
        let containersURL = home.appendingPathComponent("Library/Containers", isDirectory: true)
        guard let containerURLs = try? fileManager.contentsOfDirectory(
            at: containersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for containerURL in containerURLs where !isIgnoredAppCacheEntry(containerURL) {
            let cacheURL = containerURL.appendingPathComponent("Data/Library/Caches", isDirectory: true)
            guard fileManager.fileExists(atPath: cacheURL.path) else { continue }

            let owner = appIndex.owner(forCacheName: containerURL.lastPathComponent)
            addAppCacheRoot(cacheURL, owner: owner, fallbackName: containerURL.lastPathComponent, accumulators: &accumulators)
        }
    }

    private func scanGroupContainerCacheDirectories(home: URL, appIndex: AppMetadataIndex, accumulators: inout [String: AppCacheAccumulator]) {
        let groupContainersURL = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        guard let groupContainerURLs = try? fileManager.contentsOfDirectory(
            at: groupContainersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for groupContainerURL in groupContainerURLs where !isIgnoredAppCacheEntry(groupContainerURL) {
            let owner = appIndex.owner(forGroupContainerName: groupContainerURL.lastPathComponent)
            let candidates = [
                groupContainerURL.appendingPathComponent("Library/Caches", isDirectory: true),
                groupContainerURL.appendingPathComponent("Caches", isDirectory: true),
                groupContainerURL.appendingPathComponent("Cache", isDirectory: true)
            ]

            for cacheURL in candidates where fileManager.fileExists(atPath: cacheURL.path) {
                addAppCacheRoot(cacheURL, owner: owner, fallbackName: groupContainerURL.lastPathComponent, accumulators: &accumulators)
            }
        }
    }

    private func scanApplicationSupportCacheDirectories(home: URL, appIndex: AppMetadataIndex, accumulators: inout [String: AppCacheAccumulator]) {
        let applicationSupportURL = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let appSupportURLs = try? fileManager.contentsOfDirectory(
            at: applicationSupportURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for appSupportURL in appSupportURLs where !isIgnoredAppCacheEntry(appSupportURL) {
            let owner = appIndex.owner(forApplicationSupportName: appSupportURL.lastPathComponent)
            let candidates = [
                appSupportURL.appendingPathComponent("Cache", isDirectory: true),
                appSupportURL.appendingPathComponent("Caches", isDirectory: true)
            ]

            for cacheURL in candidates where fileManager.fileExists(atPath: cacheURL.path) {
                addAppCacheRoot(cacheURL, owner: owner, fallbackName: appSupportURL.lastPathComponent, accumulators: &accumulators)
            }
        }
    }

    private func addAppCacheRoot(_ url: URL, owner: InstalledAppInfo?, fallbackName: String, accumulators: inout [String: AppCacheAccumulator]) {
        let size = cacheItemSize(at: url)
        guard size > 0 else { return }

        let key = owner?.bundleIdentifier.lowercased() ?? "fallback:\(AppMetadataIndex.normalizedName(fallbackName))"
        let name = owner?.cacheDisplayName ?? fallbackCacheDisplayName(for: fallbackName)
        let symbolName = fallbackName.contains(".") ? "folder.fill" : "app.fill"

        var accumulator = accumulators[key] ?? AppCacheAccumulator(
            name: name,
            symbolName: symbolName,
            appIconPath: owner?.appPath,
            paths: [],
            sizeInBytes: 0
        )
        accumulator.add(path: url.path, sizeInBytes: size)
        accumulators[key] = accumulator
    }

    private func cacheItemSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return 0
        }

        if values.isDirectory == true {
            return cacheDirectorySize(at: url)
        }

        guard values.isRegularFile == true else { return 0 }
        let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        if size > 0 {
            progressState.cleanableAccumulator += size
            progress?(ScanProgress(currentPath: url.path, discoveredCleanableBytes: progressState.cleanableAccumulator))
        }
        return size
    }

    private func cacheDirectorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            total += size
            progressState.cleanableAccumulator += size
            progress?(ScanProgress(currentPath: url.path, discoveredCleanableBytes: progressState.cleanableAccumulator))
        }
        return total
    }

    private func fallbackCacheDisplayName(for rawName: String) -> String {
        if rawName.localizedCaseInsensitiveContains("cache") || rawName.contains("缓存") {
            return rawName
        }
        if rawName.contains(".") {
            return rawName
        }
        return "\(rawName) 缓存"
    }

    private func isIgnoredAppCacheEntry(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "." || name == ".." || name == ".DS_Store" || name == ".localized"
    }

    private func makeAppMetadataIndex(home: URL) -> AppMetadataIndex {
        let appSearchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]

        var appsByBundleIdentifier: [String: InstalledAppInfo] = [:]
        var appsByName: [String: InstalledAppInfo] = [:]
        var visitedPaths: Set<String> = []

        for rootURL in appSearchRoots where fileManager.fileExists(atPath: rootURL.path) {
            for appURL in appBundleURLs(in: rootURL) where !visitedPaths.contains(appURL.path) {
                visitedPaths.insert(appURL.path)
                guard let appInfo = installedAppInfo(at: appURL) else { continue }

                let bundleKey = appInfo.bundleIdentifier.lowercased()
                if appsByBundleIdentifier[bundleKey] == nil {
                    appsByBundleIdentifier[bundleKey] = appInfo
                }

                let displayNameKey = AppMetadataIndex.normalizedName(appInfo.displayName)
                if !displayNameKey.isEmpty, appsByName[displayNameKey] == nil {
                    appsByName[displayNameKey] = appInfo
                }

                let fileNameKey = AppMetadataIndex.normalizedName(appURL.deletingPathExtension().lastPathComponent)
                if !fileNameKey.isEmpty, appsByName[fileNameKey] == nil {
                    appsByName[fileNameKey] = appInfo
                }
            }
        }

        return AppMetadataIndex(
            appsByBundleIdentifier: appsByBundleIdentifier,
            appsByName: appsByName,
            bundleIdentifiersByLength: appsByBundleIdentifier.keys.sorted { $0.count > $1.count }
        )
    }

    private func appBundleURLs(in rootURL: URL) -> [URL] {
        if rootURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
            return [rootURL]
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var appURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
            appURLs.append(fileURL)
        }
        return appURLs
    }

    private func installedAppInfo(at appURL: URL) -> InstalledAppInfo? {
        guard let bundle = Bundle(url: appURL),
              let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? appURL.deletingPathExtension().lastPathComponent

        return InstalledAppInfo(bundleIdentifier: bundleIdentifier, displayName: displayName, appPath: appURL.path)
    }

    private func makeDeveloperCategory(home: URL) -> StorageCategory {
        let defs: [(String, String, String, Bool)] = [
            ("Xcode DerivedData", home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path, "hammer.circle.fill", true),
            ("Xcode Archives", home.appendingPathComponent("Library/Developer/Xcode/Archives").path, "archivebox.fill", true),
            ("iOS Simulators", home.appendingPathComponent("Library/Developer/CoreSimulator").path, "iphone.gen3", false),
            ("Homebrew", "/opt/homebrew", "terminal.fill", false),
            ("SwiftPM Cache", home.appendingPathComponent(".swiftpm").path, "shippingbox.circle.fill", true),
            ("Gradle Cache", home.appendingPathComponent(".gradle/caches").path, "bolt.circle.fill", true),
            ("Maven Repository Cache", home.appendingPathComponent(".m2/repository").path, "shippingbox.circle.fill", true),
            ("SBT Cache", home.appendingPathComponent(".sbt").path, "archivebox.circle.fill", true),
            ("Ivy Cache", home.appendingPathComponent(".ivy2/cache").path, "shippingbox.circle.fill", true),
            ("Android Build Cache", home.appendingPathComponent(".android/build-cache").path, "cpu.fill", true),
            ("Android AVD Cache", home.appendingPathComponent(".android/avd").path, "smartphone.fill", false),
            ("Flutter Pub Cache", home.appendingPathComponent(".pub-cache").path, "shippingbox.circle.fill", true),
            ("Dart Server Cache", home.appendingPathComponent(".dartServer").path, "server.rack", true),
            ("Node Cache", home.appendingPathComponent(".npm").path, "shippingbox.circle.fill", true),
            ("Yarn Cache", home.appendingPathComponent(".yarn").path, "shippingbox.circle.fill", true),
            ("pnpm Store", home.appendingPathComponent(".pnpm-store").path, "shippingbox.circle.fill", true),
            ("node-gyp Cache", home.appendingPathComponent(".node-gyp").path, "wrench.and.screwdriver.fill", true),
            ("Expo Cache", home.appendingPathComponent(".expo").path, "shippingbox.circle.fill", true),
            ("Electron Cache", home.appendingPathComponent(".electron").path, "bolt.horizontal.circle.fill", true),
            ("Unity Cache", home.appendingPathComponent("Library/Unity").path, "cube.transparent.fill", true),
            ("Unity Hub Cache", home.appendingPathComponent("Library/Application Support/UnityHub/Cache").path, "cube.transparent.fill", true),
            ("VS Code Cache", home.appendingPathComponent("Library/Application Support/Code/Cache").path, "chevron.left.forwardslash.chevron.right", true),
            ("Cursor Cache", home.appendingPathComponent("Library/Application Support/Cursor/Cache").path, "cursorarrow.rays", true),
            ("Figma Cache", home.appendingPathComponent("Library/Application Support/Figma/Cache").path, "paintpalette.fill", true),
            ("Postman Cache", home.appendingPathComponent("Library/Application Support/Postman/Cache").path, "paperplane.fill", true),
            ("Charles Cache", home.appendingPathComponent("Library/Application Support/Charles/Cache").path, "wave.3.right.circle.fill", true),
            ("Slack Cache", home.appendingPathComponent("Library/Application Support/Slack/Cache").path, "message.fill", true),
            ("Notion Cache", home.appendingPathComponent("Library/Application Support/Notion/Cache").path, "doc.text.fill", true),
            ("Claude Cache", home.appendingPathComponent("Library/Application Support/Claude/Cache").path, "sparkles", true),
            ("Ollama Blobs", home.appendingPathComponent(".ollama/models/blobs").path, "internaldrive.fill", true),
            ("Hugging Face Hub", home.appendingPathComponent(".cache/huggingface/hub").path, "brain", true),
            ("Torch Hub Cache", home.appendingPathComponent(".cache/torch/hub").path, "brain.head.profile", true),
            ("Keras Cache", home.appendingPathComponent(".keras").path, "brain", true)
        ]
        return StorageCategory(section: .developer, items: defs.map { name, path, icon, cleanable in
            StorageItem(name: name, path: path, sizeInBytes: directorySize(atPath: path, countAsCleanable: cleanable), symbolName: icon, isCleanable: cleanable)
        }.filter { $0.sizeInBytes > 0 })
    }

    private func makeSystemCategory(home: URL) -> StorageCategory {
        let defs: [(String, String, String, Bool)] = [
            ("系统缓存", "/Library/Caches", "internaldrive.fill", false),
            ("系统日志", "/private/var/log", "doc.text.magnifyingglass", false),
            ("用户日志", home.appendingPathComponent("Library/Logs").path, "note.text", true)
        ]
        return StorageCategory(section: .system, items: defs.map { name, path, icon, cleanable in
            StorageItem(name: name, path: path, sizeInBytes: directorySize(atPath: path, countAsCleanable: cleanable), symbolName: icon, isCleanable: cleanable)
        }.filter { $0.sizeInBytes > 0 })
    }

    private func makeHiddenCategory(home: URL) -> StorageCategory {
        let defs: [(String, String, String, Bool)] = [
            ("Application Support", home.appendingPathComponent("Library/Application Support").path, "square.stack.3d.up.fill", false),
            ("Group Containers", home.appendingPathComponent("Library/Group Containers").path, "square.3.layers.3d.down.right", false),
            ("Mail", home.appendingPathComponent("Library/Mail").path, "envelope.fill", false),
            ("Spotlight", "/System/Volumes/Data/.Spotlight-V100", "magnifyingglass.circle.fill", false)
        ]
        var items = defs.map { name, path, icon, cleanable in
            StorageItem(name: name, path: path, sizeInBytes: directorySize(atPath: path, countAsCleanable: cleanable), symbolName: icon, isCleanable: cleanable)
        }
        items.append(contentsOf: makeHiddenDotItems(home: home))
        return StorageCategory(section: .hidden, items: items.filter { $0.sizeInBytes > 0 })
    }

    private func makeTrashCategory(home: URL) -> StorageCategory {
        let trashURL = home.appendingPathComponent(".Trash", isDirectory: true)
        let size = trashDirectorySize(at: trashURL)

        let trashItem = StorageItem(
            name: "废纸篓",
            path: trashURL.path,
            sizeInBytes: size,
            symbolName: "trash.fill",
            isCleanable: true
        )

        return StorageCategory(section: .trash, items: [trashItem])
    }

    /// 家目录下的隐藏 dotfile / dotfolder（如 ~/.cache、~/.android、~/.npm）。
    /// 出于安全考虑，只有位于可再生缓存白名单中的目录才标记为可清理；
    /// 其余（.ssh、.gitconfig、.zshrc、.aws 等配置类）仅列出供用户查看，绝不代删。
    private func makeHiddenDotItems(home: URL) -> [StorageItem] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return entries.compactMap { url -> StorageItem? in
            let name = url.lastPathComponent
            // 仅处理点开头，且排除系统/元数据项。
            guard name.hasPrefix("."),
                  name != ".",
                  name != "..",
                  name != ".Trash",
                  name != ".DS_Store",
                  name != ".localized",
                  name != ".CFUserTextEncoding" else {
                return nil
            }

            let size = boundedDirectorySize(at: url)
            guard size > 0 else { return nil }

            let cleanable = HiddenDotWhitelist.isCleanable(name: name)
            return StorageItem(
                name: name,
                path: url.path,
                sizeInBytes: size,
                symbolName: cleanable ? "shippingbox.fill" : "eye.slash.circle.fill",
                isCleanable: cleanable
            )
        }
    }

    private func directorySize(at url: URL, countAsCleanable: Bool) -> Int64 {
        directorySize(atPath: url.path, countAsCleanable: countAsCleanable)
    }

    private func trashDirectorySize(at url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        var visitedFileCount = 0
        var lastReportedPath = url.path

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            total += size
            progressState.cleanableAccumulator += size
            visitedFileCount += 1
            lastReportedPath = fileURL.path

            if visitedFileCount.isMultiple(of: 200) {
                progress?(ScanProgress(currentPath: fileURL.path, discoveredCleanableBytes: progressState.cleanableAccumulator))
            }
        }

        progress?(ScanProgress(currentPath: lastReportedPath, discoveredCleanableBytes: progressState.cleanableAccumulator))
        return total
    }

    /// 递归计算目录体积，但**不触发进度回调**，并对遍历文件数设上限。
    /// 用于家目录隐藏项：像 ~/.cocoapods/repos 这类含几十万小文件的 git 镜像，
    /// 若逐文件派发进度到主线程会直接冻结 UI，这里以近似值换取有界耗时。
    private func boundedDirectorySize(at url: URL, fileLimit: Int = 20_000) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > fileLimit { break }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func categoryDirectorySize(at url: URL) -> Int64 {
        switch accessMode {
        case .lightweight:
            return lightweightDirectorySize(at: url)
        case .privileged:
            return directorySize(at: url, countAsCleanable: false)
        }
    }

    private func lightweightDirectorySize(at url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        guard let childURLs = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for childURL in childURLs {
            guard let values = try? childURL.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func directorySize(atPath path: String, countAsCleanable: Bool) -> Int64 {
        guard fileManager.fileExists(atPath: path) else { return 0 }
        let url = URL(fileURLWithPath: path)
        let useLightweight = shouldUseLightweightEnumeration(for: path)
        if useLightweight {
            return lightweightDirectorySize(at: url)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            total += size
            if countAsCleanable {
                progressState.cleanableAccumulator += size
            }
            progress?(ScanProgress(currentPath: fileURL.path, discoveredCleanableBytes: progressState.cleanableAccumulator))
        }
        return total
    }

    private func shouldUseLightweightEnumeration(for path: String) -> Bool {
        let loweredPath = path.lowercased()
        let homePath = fileManager.homeDirectoryForCurrentUser.path.lowercased()
        let heavyPrefixes = [
            "/applications",
            "/opt/homebrew",
            "/system/volumes/data/.spotlight-v100",
            "/private/var/log",
            homePath + "/library/group containers",
            homePath + "/library/application support",
            homePath + "/library/containers",
            homePath + "/library/mail",
            homePath + "/library/messages",
            homePath + "/library/safari",
            homePath + "/.trash"
        ]

        return heavyPrefixes.contains(where: loweredPath.hasPrefix)
    }
}

private final class ProgressState: @unchecked Sendable {
    var cleanableAccumulator: Int64 = 0
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum CleanupHistoryStore {
    private static let totalCleanedBytesKey = "totalCleanedBytes"

    static func addCleanedBytes(_ bytes: Int64) {
        guard bytes > 0, let storeURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let updatedTotal = totalCleanedBytes() + bytes
            let payload: [String: Int64] = [totalCleanedBytesKey: updatedTotal]
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Failed to save cleanup history: %@", error.localizedDescription)
        }
    }

    private static func totalCleanedBytes() -> Int64 {
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
