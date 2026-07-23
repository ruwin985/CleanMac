import Foundation

struct ThreatEvidence: Hashable {
    let title: String
    let detail: String
}

enum ThreatSeverity: Int, Comparable, Hashable {
    case low = 1
    case medium = 2
    case high = 3

    static func < (lhs: ThreatSeverity, rhs: ThreatSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "可疑"
        case .high: return "高风险"
        }
    }
}

struct ThreatScanRecord: Hashable {
    let path: String
    let displayName: String
    let symbolName: String
    let kind: ProtectionThreatKind
    let severity: ThreatSeverity
    let evidences: [ThreatEvidence]
    let relatedItem: StorageItem?
    var settingsURLString: String? = nil
}

private struct SignatureCheckResult {
    let isTrusted: Bool
    let authority: String?
    let teamIdentifier: String?
}

struct ThreatScanner {
    private let fileManager = FileManager.default
    private let maxStartupItems = 120
    private let maxCommandChecks = 24

    func scan(categories: [StorageCategory]) -> [ThreatScanRecord] {
        let allItems = categories.flatMap(\.items)
        let startupItems = scanStartupItems()
        let candidateItems = Array(deduplicate(items: allItems + startupItems).prefix(maxStartupItems))
        var commandBudget = maxCommandChecks

        return candidateItems.compactMap { item in
            evaluate(item: item, commandBudget: &commandBudget)
        }
        .sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func deduplicate(items: [StorageItem]) -> [StorageItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.path).inserted }
    }

    private func scanStartupItems() -> [StorageItem] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let startupPaths: [(String, String)] = [
            (home + "/Library/LaunchAgents", "bolt.fill"),
            ("/Library/LaunchAgents", "bolt.fill"),
            ("/Library/LaunchDaemons", "bolt.fill"),
            (home + "/Library/Application Support", "folder.fill"),
            (home + "/Library/Safari/Extensions", "safari.fill"),
            (home + "/Library/Containers", "shippingbox.fill")
        ]

        var results: [StorageItem] = []
        var scannedCount = 0
        for (basePath, symbolName) in startupPaths {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                if scannedCount >= maxStartupItems { return results }
                let path = url.path
                let name = url.lastPathComponent
                guard isThreatRelevant(path: path, name: name) else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                results.append(StorageItem(name: name, path: path, sizeInBytes: size, symbolName: symbolName, isCleanable: false))
                scannedCount += 1
            }
        }

        return results
    }

    private func isThreatRelevant(path: String, name: String) -> Bool {
        let loweredPath = path.lowercased()
        let loweredName = name.lowercased()
        let interestingExtensions = ["plist", "app", "appex", "pkg", "dmg", "sh", "command"]
        let interestingKeywords = [
            "install", "update", "helper", "daemon", "agent", "launch", "search", "toolbar",
            "redirect", "ad", "track", "telemetry", "analytics", "monitor", "plugin", "extension"
        ]

        return interestingExtensions.contains(where: { loweredName.hasSuffix("." + $0) })
            || interestingKeywords.contains(where: { loweredName.contains($0) || loweredPath.contains($0) })
    }

    private func evaluate(item: StorageItem, commandBudget: inout Int) -> ThreatScanRecord? {
        let path = item.path
        let name = item.name
        let loweredPath = path.lowercased()
        let loweredName = name.lowercased()

        var evidences: [ThreatEvidence] = []
        var kind: ProtectionThreatKind = .trojan
        var severity: ThreatSeverity = .low

        if let knownThreat = knownFamilyEvidence(path: loweredPath, name: loweredName) {
            evidences.append(knownThreat.evidence)
            severity = max(severity, .high)
            kind = knownThreat.kind
        }

        if let quarantine = quarantineEvidence(for: path, commandBudget: &commandBudget) {
            evidences.append(quarantine)
            severity = max(severity, .medium)
        }

        if unsignedAppEvidence(path: path, name: name, commandBudget: &commandBudget) {
            evidences.append(ThreatEvidence(title: "签名异常", detail: "应用签名校验未通过或来源无法验证"))
            severity = max(severity, .high)
            kind = .trojan
        }

        if let signatureEvidence = signatureEvidence(path: path, name: name, commandBudget: &commandBudget) {
            evidences.append(signatureEvidence)
        }

        if let startupEvidence = startupPersistenceEvidence(path: path) {
            evidences.append(startupEvidence)
            severity = max(severity, .medium)
            kind = .adware
        }

        if let launchItem = inspectLaunchItem(path: path) {
            evidences.append(launchItem.evidence)
            if launchItem.isDropper {
                severity = max(severity, .high)
                kind = .trojan
            } else {
                severity = max(severity, .medium)
                if kind != .trojan { kind = .adware }
            }
        }

        if let trackerEvidence = trackerEvidence(path: loweredPath, name: loweredName) {
            evidences.append(trackerEvidence)
            severity = max(severity, .medium)
            if kind != .trojan { kind = .trackers }
        }

        let hasStartupPersistence = evidences.contains { $0.title == "启动持久化" }
        if let keywordEvidence = suspiciousKeywordEvidence(path: loweredPath, name: loweredName, hasStartupPersistence: hasStartupPersistence) {
            evidences.append(keywordEvidence.evidence)
            severity = max(severity, .medium)
            if kind == .trojan { /* keep */ } else { kind = keywordEvidence.kind }
        }

        guard !evidences.isEmpty else { return nil }

        // 木马与广告软件分类不再筛查 .plist：启动项/描述 plist 在正常 Mac 上大量存在，
        // 误报高。归类为这两类的 .plist 直接排除，追踪判定不受影响。
        if (kind == .trojan || kind == .adware), loweredName.hasSuffix(".plist") { return nil }

        return ThreatScanRecord(
            path: path,
            displayName: name,
            symbolName: item.symbolName,
            kind: kind,
            severity: severity,
            evidences: evidences,
            relatedItem: item
        )
    }

    private func quarantineEvidence(for path: String, commandBudget: inout Int) -> ThreatEvidence? {
        guard consumeCommandBudget(&commandBudget) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-p", "com.apple.quarantine", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            return ThreatEvidence(title: "来自网络下载", detail: "文件带有隔离属性，建议核对来源与签名")
        } catch {
            return nil
        }
    }

    private func unsignedAppEvidence(path: String, name: String, commandBudget: inout Int) -> Bool {
        let loweredName = name.lowercased()
        guard loweredName.hasSuffix(".app") || loweredName.hasSuffix(".pkg") || loweredName.hasSuffix(".dmg") else {
            return false
        }
        guard consumeCommandBudget(&commandBudget) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", loweredName.hasSuffix(".app") ? "execute" : "open", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus != 0
        } catch {
            return false
        }
    }

    private func signatureEvidence(path: String, name: String, commandBudget: inout Int) -> ThreatEvidence? {
        let loweredName = name.lowercased()
        guard loweredName.hasSuffix(".app") || loweredName.hasSuffix(".pkg") else { return nil }
        guard consumeCommandBudget(&commandBudget) else { return nil }
        guard let result = signatureCheck(path: path) else { return nil }

        if result.isTrusted {
            if let authority = result.authority, let teamIdentifier = result.teamIdentifier {
                return ThreatEvidence(title: "签名来源", detail: "已签名：\(authority)（Team ID: \(teamIdentifier)）")
            }
            if let authority = result.authority {
                return ThreatEvidence(title: "签名来源", detail: "已签名：\(authority)")
            }
            return ThreatEvidence(title: "签名来源", detail: "已通过签名校验")
        }

        return ThreatEvidence(title: "签名来源", detail: "未识别到可信开发者签名")
    }

    private func signatureCheck(path: String) -> SignatureCheckResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", path]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""

            let authority = text
                .split(separator: "\n")
                .map(String.init)
                .first(where: { $0.hasPrefix("Authority=") })
                .map { String($0.dropFirst("Authority=".count)) }
            let teamIdentifier = text
                .split(separator: "\n")
                .map(String.init)
                .first(where: { $0.hasPrefix("TeamIdentifier=") })
                .map { String($0.dropFirst("TeamIdentifier=".count)) }

            return SignatureCheckResult(
                isTrusted: process.terminationStatus == 0,
                authority: authority,
                teamIdentifier: teamIdentifier
            )
        } catch {
            return nil
        }
    }

    private func startupPersistenceEvidence(path: String) -> ThreatEvidence? {
        let loweredPath = path.lowercased()
        let startupLocations = ["/library/launchagents/", "/library/launchdaemons/", "/loginitems", "/library/safari/extensions/"]
        guard startupLocations.contains(where: loweredPath.contains) else { return nil }
        return ThreatEvidence(title: "启动持久化", detail: "位于启动项或扩展目录，可能随系统自动运行")
    }

    private struct LaunchItemInspection {
        let evidence: ThreatEvidence
        let isDropper: Bool
    }

    private func launchItemPayloadEvidence(path: String) -> ThreatEvidence? {
        inspectLaunchItem(path: path)?.evidence
    }

    private func inspectLaunchItem(path: String) -> LaunchItemInspection? {
        guard path.lowercased().hasSuffix(".plist") else { return nil }
        guard let data = fileManager.contents(atPath: path) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        // Gather every command string the launch item would execute.
        var invocation: [String] = []
        if let program = plist["Program"] as? String, !program.isEmpty {
            invocation.append(program)
        }
        if let arguments = plist["ProgramArguments"] as? [String] {
            invocation.append(contentsOf: arguments)
        }

        let joined = invocation.joined(separator: " ")
        let lowered = joined.lowercased()

        // Dropper / stager behavior: fetch-and-execute, decode-and-run, or launching
        // from a world-writable / temporary location. These are strong malware signals.
        if !lowered.isEmpty {
            let pipeToShell = (lowered.contains("curl") || lowered.contains("wget"))
                && (lowered.contains("| sh") || lowered.contains("|sh") || lowered.contains("| bash") || lowered.contains("|bash"))
            let inlineDecode = lowered.contains("base64 -d") || lowered.contains("base64 --decode") || lowered.contains("| osascript")
            let volatileLaunch = ["/tmp/", "/private/tmp/", "/var/tmp/", "/users/shared/", "/private/var/folders/"]
                .contains { lowered.contains($0) }
            let evalPattern = lowered.contains("eval(") || lowered.contains("python -c") || lowered.contains("perl -e")

            if pipeToShell || inlineDecode || evalPattern {
                return LaunchItemInspection(
                    evidence: ThreatEvidence(title: "投放器行为", detail: "启动项会下载或解码后直接执行代码：\(truncate(joined))"),
                    isDropper: true
                )
            }
            if volatileLaunch {
                return LaunchItemInspection(
                    evidence: ThreatEvidence(title: "可疑启动位置", detail: "启动项从临时或公共可写目录运行：\(truncate(joined))"),
                    isDropper: true
                )
            }
        }

        if let program = invocation.first, !program.isEmpty {
            return LaunchItemInspection(
                evidence: ThreatEvidence(title: "启动目标", detail: "plist 会启动：\(truncate(program))"),
                isDropper: false
            )
        }

        if let label = plist["Label"] as? String, !label.isEmpty {
            return LaunchItemInspection(
                evidence: ThreatEvidence(title: "启动标签", detail: "启动项标签：\(label)"),
                isDropper: false
            )
        }

        return nil
    }

    private func truncate(_ text: String, limit: Int = 160) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private struct KnownFamilyMatch {
        let evidence: ThreatEvidence
        let kind: ProtectionThreatKind
    }

    // IOC sources: Apple XProtect, Objective-See, Malwarebytes public threat reports.
    private func knownFamilyEvidence(path: String, name: String) -> KnownFamilyMatch? {
        // Known trojan / backdoor family path/name fragments (case-insensitive, lowered input).
        let trojanIOCs: [(fragment: String, family: String)] = [
            ("macstealer", "MacStealer"),
            ("atomicstealer", "Atomic Stealer (AMOS)"),
            ("amos", "Atomic Stealer (AMOS)"),
            ("realst", "RealSt Infostealer"),
            ("geacon", "Geacon (Cobalt Strike)"),
            ("macma", "MacMa Backdoor"),
            ("coldroot", "ColdRoot RAT"),
            ("fruitfly", "FruitFly"),
            ("proton", "Proton RAT"),
            ("mokes", "Mokes Backdoor"),
            ("netwire", "NetWire RAT"),
            ("bundlore", "Bundlore Dropper"),
            ("shlayer", "Shlayer Trojan"),
            ("zshlayer", "ZShlayer"),
            ("cimpli", "Cimpli Adware Dropper"),
            ("pirrit", "Pirrit"),
            ("genieo", "Genieo"),
            ("vsearch", "VSearch"),
            ("crossrider", "CrossRider"),
            ("dolittle", "Dolittle Backdoor"),
            ("xcsset", "XCSSET Malware"),
            ("lazarus", "Lazarus Group"),
            ("nukesped", "NukeSped"),
            ("jokerspy", "JokerSpy"),
            ("swiftspy", "SwiftSpy"),
            ("activator", "Activator Trojan"),
        ]

        // Known adware family fragments.
        let adwareIOCs: [(fragment: String, family: String)] = [
            ("installcore", "InstallCore"),
            ("installmac", "InstallMac"),
            ("mackeeper", "MacKeeper"),
            ("pckeeper", "PCKeeper"),
            ("advancedmaccleaner", "Advanced Mac Cleaner"),
            ("maccleaner", "Mac Cleaner PUA"),
            ("cleanmymac", "CleanMyMac (verify legitimacy)"),
            ("searchbaron", "SearchBaron Hijacker"),
            ("searchmarquis", "Search Marquis Hijacker"),
            ("searchdiversion", "Search Diversion"),
            ("weknow", "WeKnow Browser Hijacker"),
            ("trovi", "Trovi Search Hijacker"),
            ("conduit", "Conduit Toolbar"),
            ("spigot", "Spigot Adware"),
            ("yontoo", "Yontoo"),
            ("vidx", "VidX Adware"),
            ("bnodlero", "Bnodlero Adware"),
            ("adload", "AdLoad"),
            ("adware.mac", "AdwareMac"),
            ("operatorsmac", "OperatorsMac"),
            ("defaultsearch", "DefaultSearch Hijacker"),
            ("standardboost", "StandardBoost Adware"),
            ("adventurefeeds", "AdventureFeed Adware"),
        ]

        for ioc in trojanIOCs {
            if name.contains(ioc.fragment) || path.contains(ioc.fragment) {
                return KnownFamilyMatch(
                    evidence: ThreatEvidence(title: "已知威胁家族", detail: "匹配到已知木马/后门特征：\(ioc.family)"),
                    kind: .trojan
                )
            }
        }

        for ioc in adwareIOCs {
            if name.contains(ioc.fragment) || path.contains(ioc.fragment) {
                return KnownFamilyMatch(
                    evidence: ThreatEvidence(title: "已知广告软件家族", detail: "匹配到已知广告/劫持软件特征：\(ioc.family)"),
                    kind: .adware
                )
            }
        }

        return nil
    }

    private func trackerEvidence(path: String, name: String) -> ThreatEvidence? {
        let trackerKeywords = ["track", "tracking", "telemetry", "analytics", "metrics", "pixel"]
        let trackerLocations = ["/library/logs/", "/library/application support/", "/library/group containers/", "/library/caches/"]
        guard trackerLocations.contains(where: path.contains) else { return nil }
        guard trackerKeywords.contains(where: { name.contains($0) || path.contains($0) }) else { return nil }
        return ThreatEvidence(title: "追踪特征", detail: "名称或路径包含遥测、追踪或分析关键词")
    }

    private struct KeywordMatch {
        let evidence: ThreatEvidence
        let kind: ProtectionThreatKind
    }

    private func suspiciousKeywordEvidence(path: String, name: String, hasStartupPersistence: Bool) -> KeywordMatch? {
        // High-confidence: rarely appear in legitimate software, safe to flag on their own.
        let strongTrojanKeywords = ["crack", "keygen", "inject", "backdoor", "rootkit", "stealer"]
        // Weak: common in legit apps (helper/install/update), only meaningful when combined
        // with startup persistence to avoid flagging every updater/helper on the system.
        let weakTrojanKeywords = ["patch", "loader", "helper", "installer", "dropper"]
        let strongAdwareKeywords = ["toolbar", "coupon", "popup", "hijack", "browserhijack"]
        let weakAdwareKeywords = ["redirect", "searchassist", "adhelper"]

        if strongTrojanKeywords.contains(where: { name.contains($0) || path.contains($0) }) {
            return KeywordMatch(
                evidence: ThreatEvidence(title: "可疑命名", detail: "名称包含常见破解/木马投递关键词"),
                kind: .trojan
            )
        }
        if strongAdwareKeywords.contains(where: { name.contains($0) || path.contains($0) }) {
            return KeywordMatch(
                evidence: ThreatEvidence(title: "广告残留关键词", detail: "名称包含常见广告劫持或浏览器干扰关键词"),
                kind: .adware
            )
        }

        // Weak keywords only escalate when the item also persists at startup.
        guard hasStartupPersistence else { return nil }

        if weakTrojanKeywords.contains(where: { name.contains($0) || path.contains($0) }) {
            return KeywordMatch(
                evidence: ThreatEvidence(title: "可疑启动项命名", detail: "启动项名称包含常见伪装安装器/投递器关键词"),
                kind: .trojan
            )
        }
        if weakAdwareKeywords.contains(where: { name.contains($0) || path.contains($0) }) {
            return KeywordMatch(
                evidence: ThreatEvidence(title: "可疑启动项命名", detail: "启动项名称包含常见广告劫持关键词"),
                kind: .adware
            )
        }
        return nil
    }

    private func consumeCommandBudget(_ commandBudget: inout Int) -> Bool {
        guard commandBudget > 0 else { return false }
        commandBudget -= 1
        return true
    }
}
