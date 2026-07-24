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
            makeDeveloperCategory(home: home),
            makeSystemCategory(home: home),
            makeHiddenCategory(home: home),
            makeTrashCategory(home: home)
        ]

        let threatRecords = ThreatScanner().scan(categories: categories) + SecurityAuditScanner().scan()

        return StorageSnapshot(scannedAt: Date(), totalCapacity: total, freeSpace: free, categories: categories, threatRecords: threatRecords)
    }

    func clean(_ item: StorageItem) throws {
        guard item.isCleanable, fileManager.fileExists(atPath: item.path) else { return }
        let url = URL(fileURLWithPath: item.path)
        do {
            if url.lastPathComponent == ".Trash" {
                try emptyDirectoryContents(at: url)
            } else {
                try trashItem(at: url)
            }
        } catch {
            throw mapCleanError(error, item: item)
        }
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
            options: [.skipsHiddenFiles]
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

    private func makeDeveloperCategory(home: URL) -> StorageCategory {
        let defs: [(String, String, String, Bool)] = [
            ("Xcode DerivedData", home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path, "hammer.circle.fill", true),
            ("Xcode Archives", home.appendingPathComponent("Library/Developer/Xcode/Archives").path, "archivebox.fill", true),
            ("iOS Simulators", home.appendingPathComponent("Library/Developer/CoreSimulator").path, "iphone.gen3", false),
            ("Homebrew", "/opt/homebrew", "terminal.fill", false),
            ("CocoaPods Cache", home.appendingPathComponent("Library/Caches/CocoaPods").path, "tray.full.fill", true),
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
            ("Playwright Cache", home.appendingPathComponent("Library/Caches/ms-playwright").path, "globe", true),
            ("Cypress Cache", home.appendingPathComponent("Library/Caches/Cypress").path, "checkmark.seal.fill", true),
            ("Puppeteer Cache", home.appendingPathComponent("Library/Caches/puppeteer").path, "network", true),
            ("Vite Cache", home.appendingPathComponent("Library/Caches/vite").path, "bolt.fill", true),
            ("Turborepo Cache", home.appendingPathComponent("Library/Caches/turbo").path, "speedometer", true),
            ("Next.js Cache", home.appendingPathComponent("Library/Caches/next-swc").path, "shippingbox.circle.fill", true),
            ("Unity Cache", home.appendingPathComponent("Library/Unity").path, "cube.transparent.fill", true),
            ("Unity Hub Cache", home.appendingPathComponent("Library/Application Support/UnityHub/Cache").path, "cube.transparent.fill", true),
            ("Android Studio Cache", home.appendingPathComponent("Library/Caches/Google/AndroidStudio").path, "ladybug.fill", true),
            ("IntelliJ Cache", home.appendingPathComponent("Library/Caches/JetBrains").path, "brain.head.profile", true),
            ("VS Code Cache", home.appendingPathComponent("Library/Application Support/Code/Cache").path, "chevron.left.forwardslash.chevron.right", true),
            ("Cursor Cache", home.appendingPathComponent("Library/Application Support/Cursor/Cache").path, "cursorarrow.rays", true),
            ("Figma Cache", home.appendingPathComponent("Library/Application Support/Figma/Cache").path, "paintpalette.fill", true),
            ("Sketch Cache", home.appendingPathComponent("Library/Caches/com.bohemiancoding.sketch3").path, "pencil.and.ruler.fill", true),
            ("Adobe Common Cache", home.appendingPathComponent("Library/Caches/Adobe").path, "camera.filters", true),
            ("Blender Cache", home.appendingPathComponent("Library/Caches/Blender").path, "fanblades.fill", true),
            ("Postman Cache", home.appendingPathComponent("Library/Application Support/Postman/Cache").path, "paperplane.fill", true),
            ("Charles Cache", home.appendingPathComponent("Library/Application Support/Charles/Cache").path, "wave.3.right.circle.fill", true),
            ("Chrome Profile Cache", home.appendingPathComponent("Library/Caches/Google/Chrome").path, "globe", true),
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
            ("用户缓存", home.appendingPathComponent("Library/Caches").path, "externaldrive.fill", true),
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
        let size = directorySize(at: trashURL, countAsCleanable: true)

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
