import AppKit
import CryptoKit
import Foundation
import Security

@MainActor
final class LicenseManager: ObservableObject {
    enum AccessState: Equatable {
        case trial(expiresAt: Date)
        case licensed(LicenseInfo)
        case locked
    }

    struct LicenseInfo: Codable, Equatable {
        let version: Int
        let product: String
        let transactionID: String
        let email: String?
        let issuedAt: Date
    }

    @Published private(set) var state: AccessState = .locked
    @Published var activationErrorMessage: String?

    private let defaults = UserDefaults.standard
    private let trialDuration: TimeInterval = 24 * 60 * 60

    private static let productIdentifier = "CleanMac"
    private static let trialStartedAtAccount = "trialStartedAt"
    private static let licenseCodeAccount = "licenseCode"
    private static let defaultsPrefix = "cleanmac.license."
    private static let checkoutURLInfoKey = "CleanMacPaddleCheckoutURL"
    private static let checkoutURLEnvironmentKey = "CLEANMAC_PADDLE_CHECKOUT_URL"
    private static let publicKeyInfoKey = "CleanMacLicensePublicKey"
    private static let publicKeyEnvironmentKey = "CLEANMAC_LICENSE_PUBLIC_KEY"

    init() {
        _ = ensureTrialStartedAt()
        refresh()
    }

    var hasAccess: Bool {
        switch state {
        case .trial, .licensed:
            return true
        case .locked:
            return false
        }
    }

    var requiresLicenseOverlay: Bool {
        !hasAccess
    }

    var statusText: String {
        switch state {
        case .trial:
            return "试用剩余 \(trialRemainingDescription)"
        case .licensed:
            return "已授权"
        case .locked:
            return "试用已结束"
        }
    }

    var trialRemainingDescription: String {
        guard case let .trial(expiresAt) = state else { return "0 分钟" }
        let remainingSeconds = max(0, expiresAt.timeIntervalSince(Date()))
        if remainingSeconds >= 60 * 60 {
            return "\(Int(ceil(remainingSeconds / 3600))) 小时"
        }
        if remainingSeconds >= 60 {
            return "\(Int(ceil(remainingSeconds / 60))) 分钟"
        }
        return "不到 1 分钟"
    }

    var purchaseURL: URL? {
        guard let rawValue = configuredValue(
            infoKey: Self.checkoutURLInfoKey,
            environmentKey: Self.checkoutURLEnvironmentKey
        ) else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("replace"),
              let url = URL(string: trimmed) else {
            return nil
        }
        return url
    }

    func refresh() {
        if let storedCode = storedString(for: Self.licenseCodeAccount),
           let licenseInfo = try? validateLicenseCode(storedCode) {
            state = .licensed(licenseInfo)
            return
        }

        let trialStartedAt = ensureTrialStartedAt()
        let expiresAt = trialStartedAt.addingTimeInterval(trialDuration)
        if Date() < expiresAt {
            state = .trial(expiresAt: expiresAt)
        } else {
            state = .locked
        }
    }

    func openPurchasePage() {
        guard let purchaseURL else {
            activationErrorMessage = "购买入口尚未配置：请在 Paddle 创建 ¥10 一次性买断 Checkout，并填入 CleanMacPaddleCheckoutURL。"
            return
        }
        NSWorkspace.shared.open(purchaseURL)
    }

    func activate(with rawCode: String) {
        do {
            let licenseInfo = try validateLicenseCode(rawCode)
            store(rawCode.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.licenseCodeAccount)
            activationErrorMessage = nil
            state = .licensed(licenseInfo)
        } catch {
            activationErrorMessage = error.localizedDescription
        }
    }

    private func ensureTrialStartedAt() -> Date {
        if let storedValue = storedString(for: Self.trialStartedAtAccount),
           let timestamp = TimeInterval(storedValue) {
            return Date(timeIntervalSince1970: timestamp)
        }

        let now = Date()
        store(String(now.timeIntervalSince1970), for: Self.trialStartedAtAccount)
        return now
    }

    private func validateLicenseCode(_ rawCode: String) throws -> LicenseInfo {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = trimmed.hasPrefix("CM1-") ? String(trimmed.dropFirst(4)) : trimmed
        let parts = code.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw LicenseValidationError.invalidFormat
        }

        guard let payloadData = Data(base64URLEncoded: String(parts[0])),
              let signatureData = Data(base64URLEncoded: String(parts[1])) else {
            throw LicenseValidationError.invalidFormat
        }

        guard let publicKeyString = configuredValue(
            infoKey: Self.publicKeyInfoKey,
            environmentKey: Self.publicKeyEnvironmentKey
        ),
              let publicKeyData = Data(base64URLEncoded: publicKeyString),
              publicKeyData.count == 32 else {
            throw LicenseValidationError.missingPublicKey
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw LicenseValidationError.invalidSignature
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let licenseInfo = try decoder.decode(LicenseInfo.self, from: payloadData)
        guard licenseInfo.version == 1,
              licenseInfo.product == Self.productIdentifier,
              !licenseInfo.transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LicenseValidationError.invalidPayload
        }

        let futureGracePeriod: TimeInterval = 24 * 60 * 60
        guard licenseInfo.issuedAt <= Date().addingTimeInterval(futureGracePeriod) else {
            throw LicenseValidationError.invalidPayload
        }

        return licenseInfo
    }

    private func storedString(for account: String) -> String? {
        LicenseKeychainStore.string(for: account) ?? defaults.string(forKey: Self.defaultsPrefix + account)
    }

    private func store(_ value: String, for account: String) {
        LicenseKeychainStore.set(value, for: account)
        defaults.set(value, forKey: Self.defaultsPrefix + account)
    }

    private func configuredValue(infoKey: String, environmentKey: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[environmentKey],
           !environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentValue
        }
        if let bundleValue = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
           !bundleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundleValue
        }
        return nil
    }
}

private enum LicenseValidationError: LocalizedError {
    case invalidFormat
    case missingPublicKey
    case invalidSignature
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "授权码格式不正确，请粘贴完整的 CM1 授权码。"
        case .missingPublicKey:
            return "授权公钥尚未配置，无法验证授权码。"
        case .invalidSignature:
            return "授权码验证失败，请确认没有复制错字符。"
        case .invalidPayload:
            return "授权码内容无效，请联系支持重新获取。"
        }
    }
}

private enum LicenseKeychainStore {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.zyb.CleanMac"
    }

    static func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - base64.count % 4) % 4
        if paddingLength > 0 {
            base64 += String(repeating: "=", count: paddingLength)
        }
        self.init(base64Encoded: base64)
    }
}
