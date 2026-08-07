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
    private static let purchasePriceTextInfoKey = "CleanMacPurchasePriceText"
    private static let purchasePriceTextEnvironmentKey = "CLEANMAC_PURCHASE_PRICE_TEXT"
    private static let validationKeyInfoKey = "CleanMacLicenseValidationKey"
    private static let validationKeyEnvironmentKey = "CLEANMAC_LICENSE_VALIDATION_KEY"
    private static let shortLicenseVersion: UInt8 = 3
    private static let shortLicensePayloadByteCount = 13
    private static let shortLicenseSignedByteCount = 8
    private static let shortLicenseTagByteCount = 5
    private static let shortLicenseSecondsPerDay: TimeInterval = 86_400
    private static let shortLicenseHMACContext = "CleanMac.short-license.v3"

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

    var purchasePriceText: String {
        configuredValue(
            infoKey: Self.purchasePriceTextInfoKey,
            environmentKey: Self.purchasePriceTextEnvironmentKey
        )?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "¥0.01"
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
            activationErrorMessage = "购买入口尚未配置：请在 Paddle 创建 \(purchasePriceText) 一次性买断 Checkout，并填入 CleanMacPaddleCheckoutURL。"
            return
        }
        NSWorkspace.shared.open(purchaseURL)
    }

    func activate(with rawCode: String) {
        do {
            let licenseInfo = try validateLicenseCode(rawCode)
            store(rawCode.filter { !$0.isWhitespace }, for: Self.licenseCodeAccount)
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
        let normalized = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { !$0.isWhitespace }
        guard normalized.hasPrefix("CM-") else {
            throw LicenseValidationError.invalidFormat
        }

        let encodedPayload = normalized.dropFirst(3).filter { $0 != "-" }
        guard encodedPayload.count == 21,
              let payloadData = Data(licenseBase32Encoded: String(encodedPayload)),
              payloadData.count == Self.shortLicensePayloadByteCount,
              payloadData.first == Self.shortLicenseVersion else {
            throw LicenseValidationError.invalidFormat
        }

        let signedPayload = payloadData.prefix(Self.shortLicenseSignedByteCount)
        let signatureTag = payloadData.suffix(Self.shortLicenseTagByteCount)
        let expectedTag = try shortLicenseTag(for: signedPayload)
        guard Data(signatureTag).constantTimeEquals(expectedTag) else {
            throw LicenseValidationError.invalidSignature
        }

        let issuedAtDay = payloadData[1..<3].reduce(UInt16(0)) { result, byte in
            (result << 8) | UInt16(byte)
        }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(issuedAtDay) * Self.shortLicenseSecondsPerDay)
        let futureGracePeriod: TimeInterval = 24 * 60 * 60
        guard issuedAt <= Date().addingTimeInterval(futureGracePeriod) else {
            throw LicenseValidationError.invalidPayload
        }

        let licenseID = payloadData[3..<8]
            .map { String(format: "%02x", $0) }
            .joined()

        return LicenseInfo(
            version: Int(Self.shortLicenseVersion),
            product: Self.productIdentifier,
            transactionID: "cm-\(licenseID)",
            email: nil,
            issuedAt: issuedAt
        )
    }

    private func shortLicenseTag(for payloadData: Data.SubSequence) throws -> Data {
        guard let validationKeyString = configuredValue(
            infoKey: Self.validationKeyInfoKey,
            environmentKey: Self.validationKeyEnvironmentKey
        ),
              let validationKeyData = Data(base64URLEncoded: validationKeyString),
              validationKeyData.count >= 16 else {
            throw LicenseValidationError.missingValidationKey
        }

        let key = SymmetricKey(data: validationKeyData)
        var signedData = Data(Self.shortLicenseHMACContext.utf8)
        signedData.append(contentsOf: payloadData)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: signedData, using: key)
        return Data(Data(authenticationCode).prefix(Self.shortLicenseTagByteCount))
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

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum LicenseValidationError: LocalizedError {
    case invalidFormat
    case missingValidationKey
    case invalidSignature
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "授权码格式不正确，请粘贴完整的 CM 授权码。"
        case .missingValidationKey:
            return "授权校验密钥尚未配置，无法验证授权码。"
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

    init?(licenseBase32Encoded string: String) {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, UInt8($0.offset)) })
        var bits = 0
        var buffer = 0
        var output = Data()

        for character in string {
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | Int(value)
            bits += 5

            while bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }

        if bits > 0 {
            guard buffer == 0 else { return nil }
        }

        self = output
    }

    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for index in indices {
            difference |= self[index] ^ other[index]
        }
        return difference == 0
    }
}
