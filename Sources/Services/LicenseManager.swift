import AppKit
import CryptoKit
import Foundation
import IOKit
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
    @Published var isActivating = false

    private let defaults = UserDefaults.standard
    private let trialDuration: TimeInterval = 24 * 60 * 60

    private static let productIdentifier = "CleanMac"
    private static let trialStartedAtAccount = "trialStartedAt"
    private static let licenseCodeAccount = "licenseCode"
    private static let serverLicenseCodeAccount = "serverLicenseCode"
    private static let serverLicenseInfoAccount = "serverLicenseInfo"
    private static let serverLicenseTokenAccount = "serverLicenseToken"
    private static let deviceIDAccount = "deviceID"
    private static let defaultsPrefix = "cleanmac.license."
    private static let purchaseURLInfoKey = "CleanMacPurchaseURL"
    private static let purchaseURLEnvironmentKey = "CLEANMAC_PURCHASE_URL"
    private static let refundURLInfoKey = "CleanMacRefundURL"
    private static let refundURLEnvironmentKey = "CLEANMAC_REFUND_URL"
    private static let licenseServerURLInfoKey = "CleanMacLicenseServerURL"
    private static let licenseServerURLEnvironmentKey = "CLEANMAC_LICENSE_SERVER_URL"
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
        configuredURL(infoKey: Self.purchaseURLInfoKey, environmentKey: Self.purchaseURLEnvironmentKey)
    }

    var refundURL: URL? {
        configuredURL(
            infoKey: Self.refundURLInfoKey,
            environmentKey: Self.refundURLEnvironmentKey
        ) ?? URL(string: "https://ruwin.cn/legal/refund/")
    }

    var purchasePriceText: String {
        configuredValue(
            infoKey: Self.purchasePriceTextInfoKey,
            environmentKey: Self.purchasePriceTextEnvironmentKey
        )?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "¥2.00"
    }

    var hasLicenseServer: Bool {
        licenseServerURL != nil
    }

    func refresh() {
        if licenseServerURL != nil {
            if let serverLicenseInfo = storedServerLicenseInfo(),
               storedString(for: Self.serverLicenseTokenAccount) != nil {
                state = .licensed(serverLicenseInfo)
                Task {
                    await verifyStoredServerLicense()
                }
                return
            }

            clearStoredServerAuthorization()
            applyTrialState()
            return
        }

        if let localLicenseInfo = storedLocalLicenseInfo() {
            state = .licensed(localLicenseInfo)
            return
        }

        applyTrialState()
    }

    private func applyTrialState() {
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
            activationErrorMessage = "购买入口尚未配置：请配置 \(purchasePriceText) 一次性买断购买链接。"
            return
        }
        NSWorkspace.shared.open(purchaseURL)
    }

    func openRefundPage() {
        guard let refundURL else {
            activationErrorMessage = "退款入口尚未配置，请填入 CleanMacRefundURL。"
            return
        }
        NSWorkspace.shared.open(refundURL)
    }

    func activate(with rawCode: String) {
        guard !isActivating else { return }
        activationErrorMessage = nil

        if licenseServerURL != nil {
            isActivating = true
            Task {
                await activateWithServer(rawCode: rawCode)
            }
            return
        }

        do {
            let licenseInfo = try validateLicenseCode(rawCode)
            storeLocalLicense(rawCode, licenseInfo: licenseInfo)
        } catch {
            activationErrorMessage = error.localizedDescription
        }
    }

    private func storeLocalLicense(_ rawCode: String, licenseInfo: LicenseInfo) {
        store(canonicalLicenseCode(rawCode), for: Self.licenseCodeAccount)
        clearStoredServerAuthorization()
        activationErrorMessage = nil
        state = .licensed(licenseInfo)
    }

    private func activateWithServer(rawCode: String) async {
        defer { isActivating = false }

        do {
            let response = try await requestServerActivation(rawCode: rawCode)
            guard response.valid, let remoteLicense = response.license else {
                throw LicenseServerError.rejected(response.message ?? "服务端授权校验失败，请确认授权码是否正确。")
            }

            let licenseInfo = remoteLicense.licenseInfo
            let canonicalCode = canonicalLicenseCode(rawCode)
            if (try? validateLicenseCode(rawCode)) != nil {
                store(canonicalCode, for: Self.licenseCodeAccount)
            }
            store(canonicalCode, for: Self.serverLicenseCodeAccount)
            storeServerLicenseInfo(licenseInfo)
            if let token = response.token {
                store(token, for: Self.serverLicenseTokenAccount)
            }
            activationErrorMessage = nil
            state = .licensed(licenseInfo)
        } catch {
            activationErrorMessage = error.localizedDescription
        }
    }

    private func verifyStoredServerLicense() async {
        guard let token = storedString(for: Self.serverLicenseTokenAccount) else { return }

        do {
            let response = try await requestServerVerification(token: token)
            guard response.valid else {
                throw LicenseServerError.rejected(response.message ?? "授权已失效，请重新激活。")
            }
        } catch let error as LicenseServerError {
            if case let .rejected(message) = error {
                let shouldRemoveLocalLicense = storedServerLicenseMatchesLocalLicense()
                clearStoredServerAuthorization()
                if shouldRemoveLocalLicense {
                    removeStoredValue(for: Self.licenseCodeAccount)
                }
                activationErrorMessage = message
                if let localLicenseInfo = storedLocalLicenseInfo() {
                    state = .licensed(localLicenseInfo)
                } else {
                    applyTrialState()
                }
            }
        } catch {
            return
        }
    }

    private func requestServerActivation(rawCode: String) async throws -> LicenseServerActivationResponse {
        let bundle = Bundle.main
        let payload = LicenseServerActivationRequest(
            licenseCode: rawCode,
            deviceId: deviceID(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            platform: "macOS"
        )

        var request = URLRequest(url: try licenseServerEndpoint("/licenses/activate"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseServerError.invalidResponse
        }

        let activationResponse = try JSONDecoder().decode(LicenseServerActivationResponse.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LicenseServerError.rejected(activationResponse.message ?? "服务端授权校验失败，请确认授权码是否正确。")
        }
        return activationResponse
    }

    private func requestServerVerification(token: String) async throws -> LicenseServerVerificationResponse {
        let payload = LicenseServerVerificationRequest(
            token: token,
            deviceId: deviceID()
        )

        var request = URLRequest(url: try licenseServerEndpoint("/licenses/verify"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseServerError.invalidResponse
        }

        let verificationResponse = try JSONDecoder().decode(LicenseServerVerificationResponse.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LicenseServerError.rejected(verificationResponse.message ?? "授权已失效，请重新激活。")
        }
        return verificationResponse
    }

    private func licenseServerEndpoint(_ path: String) throws -> URL {
        guard let licenseServerURL,
              let endpointURL = URL(string: licenseServerURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw LicenseServerError.notConfigured
        }
        return endpointURL
    }

    private var licenseServerURL: URL? {
        guard let rawValue = configuredValue(
            infoKey: Self.licenseServerURLInfoKey,
            environmentKey: Self.licenseServerURLEnvironmentKey
        ) else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("replace"),
              let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return url
    }

    private func deviceID() -> String {
        if let hardwareDeviceID = hardwareBoundDeviceID() {
            return hardwareDeviceID
        }

        if let storedDeviceID = storedString(for: Self.deviceIDAccount), !storedDeviceID.isEmpty {
            return storedDeviceID
        }

        let newDeviceID = UUID().uuidString
        store(newDeviceID, for: Self.deviceIDAccount)
        return newDeviceID
    }

    private func hardwareBoundDeviceID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? Self.productIdentifier
        let digest = SHA256.hash(data: Data("\(bundleIdentifier):\(trimmedValue)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func storedServerLicenseInfo() -> LicenseInfo? {
        guard let storedValue = storedString(for: Self.serverLicenseInfoAccount),
              let data = storedValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LicenseInfo.self, from: data)
    }

    private func storedLocalLicenseInfo() -> LicenseInfo? {
        guard let storedCode = storedString(for: Self.licenseCodeAccount) else { return nil }
        return try? validateLicenseCode(storedCode)
    }

    private func verifyStoredServerLicenseIfNeeded() {
        guard licenseServerURL != nil,
              storedString(for: Self.serverLicenseTokenAccount) != nil,
              storedServerLicenseMatchesLocalLicense() else { return }

        Task {
            await verifyStoredServerLicense()
        }
    }

    private func storedServerLicenseMatchesLocalLicense() -> Bool {
        guard let localCode = storedString(for: Self.licenseCodeAccount),
              let serverCode = storedString(for: Self.serverLicenseCodeAccount) else { return false }
        return canonicalLicenseCode(localCode) == canonicalLicenseCode(serverCode)
    }

    private func storeServerLicenseInfo(_ licenseInfo: LicenseInfo) {
        guard let data = try? JSONEncoder().encode(licenseInfo),
              let encoded = String(data: data, encoding: .utf8) else { return }
        store(encoded, for: Self.serverLicenseInfoAccount)
    }

    private func clearStoredServerAuthorization() {
        [
            Self.serverLicenseCodeAccount,
            Self.serverLicenseInfoAccount,
            Self.serverLicenseTokenAccount
        ].forEach { removeStoredValue(for: $0) }
    }

    private func canonicalLicenseCode(_ rawCode: String) -> String {
        rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { !$0.isWhitespace }
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

    private func removeStoredValue(for account: String) {
        LicenseKeychainStore.delete(for: account)
        defaults.removeObject(forKey: Self.defaultsPrefix + account)
    }

    private func configuredURL(infoKey: String, environmentKey: String) -> URL? {
        guard let rawValue = configuredValue(infoKey: infoKey, environmentKey: environmentKey) else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("replace"),
              let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return url
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

private struct LicenseServerActivationRequest: Encodable {
    let licenseCode: String
    let deviceId: String
    let appVersion: String?
    let buildNumber: String?
    let platform: String
}

private struct LicenseServerVerificationRequest: Encodable {
    let token: String
    let deviceId: String
}

private struct LicenseServerActivationResponse: Decodable {
    struct RemoteLicense: Decodable {
        let licenseId: String
        let product: String
        let transactionId: String
        let email: String?
        let issuedAt: String

        var licenseInfo: LicenseManager.LicenseInfo {
            LicenseManager.LicenseInfo(
                version: 100,
                product: product,
                transactionID: transactionId,
                email: email,
                issuedAt: issuedAtDate
            )
        }

        private var issuedAtDate: Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: issuedAt) {
                return date
            }

            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: issuedAt) ?? Date()
        }
    }

    let valid: Bool
    let token: String?
    let maxDevices: Int?
    let license: RemoteLicense?
    let message: String?
}

private struct LicenseServerVerificationResponse: Decodable {
    let valid: Bool
    let maxDevices: Int?
    let message: String?
}

private enum LicenseServerError: LocalizedError {
    case notConfigured
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "授权服务器尚未配置，无法联网校验授权码。"
        case .invalidResponse:
            return "授权服务器响应异常，请稍后重试。"
        case let .rejected(message):
            return message
        }
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

    static func delete(for account: String) {
        SecItemDelete(baseQuery(for: account) as CFDictionary)
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
