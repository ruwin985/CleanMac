import Foundation

/// Read-only audit of system-level security posture and installed configuration
/// profiles. Every check here only *reads* state (via built-in macOS tools or
/// preference files) and never modifies the system; remediation is delegated to
/// System Settings through a deep link on each finding.
struct SecurityAuditScanner {
    private let fileManager = FileManager.default

    func scan() -> [ThreatScanRecord] {
        var records: [ThreatScanRecord] = []
        records.append(contentsOf: systemHardeningRecords())
        records.append(contentsOf: configProfileRecords())
        return records
    }

    // MARK: - System hardening

    private func systemHardeningRecords() -> [ThreatScanRecord] {
        var records: [ThreatScanRecord] = []

        if let record = gatekeeperRecord() { records.append(record) }
        if let record = sipRecord() { records.append(record) }
        if let record = fileVaultRecord() { records.append(record) }
        if let record = firewallRecord() { records.append(record) }
        if let record = autoLoginRecord() { records.append(record) }
        if let record = remoteLoginRecord() { records.append(record) }

        return records
    }

    private func gatekeeperRecord() -> ThreatScanRecord? {
        // `spctl --status` prints "assessments enabled" / "assessments disabled".
        guard let output = runCommand("/usr/sbin/spctl", ["--status"]) else { return nil }
        guard output.lowercased().contains("disabled") else { return nil }
        return hardeningRecord(
            name: "Gatekeeper 已关闭",
            evidence: ThreatEvidence(title: "应用来源校验", detail: "Gatekeeper 已关闭，系统不再拦截未签名或未公证的应用。建议重新开启。"),
            severity: .high,
            settingsURLString: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )
    }

    private func sipRecord() -> ThreatScanRecord? {
        // `csrutil status` -> "System Integrity Protection status: enabled/disabled."
        guard let output = runCommand("/usr/bin/csrutil", ["status"]) else { return nil }
        guard output.lowercased().contains("disabled") else { return nil }
        return hardeningRecord(
            name: "系统完整性保护(SIP) 已关闭",
            evidence: ThreatEvidence(title: "系统完整性保护", detail: "SIP 已关闭，恶意软件可修改受保护的系统文件与目录。建议在恢复模式重新开启。"),
            severity: .high,
            settingsURLString: nil
        )
    }

    private func fileVaultRecord() -> ThreatScanRecord? {
        // `fdesetup status` -> "FileVault is On." / "FileVault is Off."
        guard let output = runCommand("/usr/bin/fdesetup", ["status"]) else { return nil }
        guard output.lowercased().contains("off") else { return nil }
        return hardeningRecord(
            name: "FileVault 全盘加密未开启",
            evidence: ThreatEvidence(title: "磁盘加密", detail: "FileVault 未开启，设备丢失或被物理访问时数据可被直接读取。建议开启全盘加密。"),
            severity: .medium,
            settingsURLString: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )
    }

    private func firewallRecord() -> ThreatScanRecord? {
        // Global firewall state lives in this preference (0 = off).
        let plistPath = "/Library/Preferences/com.apple.alf.plist"
        guard let data = fileManager.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let state = plist["globalstate"] as? Int else {
            return nil
        }
        guard state == 0 else { return nil }
        return hardeningRecord(
            name: "应用防火墙未开启",
            evidence: ThreatEvidence(title: "应用防火墙", detail: "系统应用防火墙未启用，入站网络连接不受限制。建议开启。"),
            severity: .medium,
            settingsURLString: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )
    }

    private func autoLoginRecord() -> ThreatScanRecord? {
        // autoLoginUser present in loginwindow prefs means password-less boot.
        let plistPath = "/Library/Preferences/com.apple.loginwindow.plist"
        guard let data = fileManager.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let user = plist["autoLoginUser"] as? String, !user.isEmpty else {
            return nil
        }
        return hardeningRecord(
            name: "已开启自动登录",
            evidence: ThreatEvidence(title: "登录安全", detail: "系统配置为自动登录账户“\(user)”，开机无需密码即可进入桌面。建议关闭自动登录。"),
            severity: .medium,
            settingsURLString: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        )
    }

    private func remoteLoginRecord() -> ThreatScanRecord? {
        // `systemsetup -getremotelogin` -> "Remote Login: On/Off" (may need privileges;
        // if it fails we simply skip, treating unknown as no finding).
        guard let output = runCommand("/usr/sbin/systemsetup", ["-getremotelogin"]) else { return nil }
        guard output.lowercased().contains("on") else { return nil }
        return hardeningRecord(
            name: "远程登录(SSH) 已开启",
            evidence: ThreatEvidence(title: "远程访问", detail: "远程登录(SSH) 已开启，允许通过网络登录本机。若非必要建议关闭以减少攻击面。"),
            severity: .medium,
            settingsURLString: "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
        )
    }

    private func hardeningRecord(name: String, evidence: ThreatEvidence, severity: ThreatSeverity, settingsURLString: String?) -> ThreatScanRecord {
        ThreatScanRecord(
            path: "系统设置 › 隐私与安全性",
            displayName: name,
            symbolName: ProtectionThreatKind.systemHardening.symbolName,
            kind: .systemHardening,
            severity: severity,
            evidences: [evidence],
            relatedItem: nil,
            settingsURLString: settingsURLString
        )
    }

    // MARK: - Configuration profiles

    private func configProfileRecords() -> [ThreatScanRecord] {
        // User-scoped profiles are readable without root. Device profiles usually
        // require privileges to enumerate, so we focus on what we can read and
        // treat failures as "no finding" rather than surfacing errors.
        let settingsURLString = "x-apple.systempreferences:com.apple.settings.ConfigurationProfiles"
        var records: [ThreatScanRecord] = []

        for profileName in installedProfileNames() {
            let lowered = profileName.lowercased()
            let hijackKeywords = ["search", "homepage", "home page", "browser", "chrome", "safari", "dns", "proxy", "certificate", "root"]
            let looksHijacky = hijackKeywords.contains { lowered.contains($0) }

            let evidence: ThreatEvidence
            let severity: ThreatSeverity
            if looksHijacky {
                evidence = ThreatEvidence(title: "高风险描述文件", detail: "该配置描述文件可能强制修改浏览器、搜索、DNS 或证书设置，是常见劫持手段。请核对来源后移除。")
                severity = .high
            } else {
                evidence = ThreatEvidence(title: "已安装描述文件", detail: "检测到已安装的配置描述文件。个人 Mac 一般不需要，若来源不明建议移除。")
                severity = .medium
            }

            records.append(
                ThreatScanRecord(
                    path: "系统设置 › 通用 › 设备管理",
                    displayName: profileName,
                    symbolName: ProtectionThreatKind.configProfile.symbolName,
                    kind: .configProfile,
                    severity: severity,
                    evidences: [evidence],
                    relatedItem: nil,
                    settingsURLString: settingsURLString
                )
            )
        }

        return records
    }

    private func installedProfileNames() -> [String] {
        // `profiles show -output stdout-xml` emits an XML plist describing installed
        // profiles. Parse profile display names / identifiers out of it.
        guard let output = runCommand("/usr/bin/profiles", ["show", "-output", "stdout-xml"]),
              let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return []
        }

        var names: [String] = []
        collectProfileNames(from: plist, into: &names)
        // Deduplicate while preserving order.
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private func collectProfileNames(from object: Any, into names: inout [String]) {
        if let dict = object as? [String: Any] {
            for key in ["ProfileDisplayName", "ProfileIdentifier"] {
                if let value = dict[key] as? String, !value.isEmpty {
                    names.append(value)
                }
            }
            for value in dict.values {
                collectProfileNames(from: value, into: &names)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectProfileNames(from: value, into: &names)
            }
        }
    }

    // MARK: - Command helper

    /// Runs a read-only system command and returns trimmed stdout, or nil on
    /// failure / non-zero exit. Never throws; a failed probe simply yields no finding.
    private func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        guard fileManager.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}
