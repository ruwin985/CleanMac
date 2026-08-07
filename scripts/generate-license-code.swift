#!/usr/bin/env swift

import CryptoKit
import Foundation
import Security

private enum ScriptError: Error, CustomStringConvertible {
    case missingSigningKey
    case invalidSigningKey
    case missingTransactionID
    case invalidCount
    case randomBytesFailed

    var description: String {
        switch self {
        case .missingSigningKey:
            return "Missing CLEANMAC_LICENSE_SIGNING_KEY. Run with --new-key first, then export the signing key or save it to .cleanmac-license.env."
        case .invalidSigningKey:
            return "CLEANMAC_LICENSE_SIGNING_KEY must be a base64/base64url encoded key of at least 16 bytes."
        case .missingTransactionID:
            return "Missing --transaction <transaction_or_internal_batch_id>."
        case .invalidCount:
            return "--count must be a positive number."
        case .randomBytesFailed:
            return "Failed to generate secure random bytes."
        }
    }
}

private let licenseAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
private let shortLicenseVersion: UInt8 = 3
private let nonceByteCount = 5
private let tagByteCount = 5
private let secondsPerDay: TimeInterval = 86_400
private let hmacContext = "CleanMac.short-license.v3"

private extension Data {
    init?(base64URLOrStandardEncoded string: String) {
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

    var licenseBase32EncodedString: String {
        var bits = 0
        var buffer = 0
        var output = ""

        for byte in self {
            buffer = (buffer << 8) | Int(byte)
            bits += 8

            while bits >= 5 {
                bits -= 5
                let index = (buffer >> bits) & 0x1F
                output.append(licenseAlphabet[index])
                buffer &= (1 << bits) - 1
            }
        }

        if bits > 0 {
            let index = (buffer << (5 - bits)) & 0x1F
            output.append(licenseAlphabet[index])
        }

        return output
    }
}

private func usage() -> String {
    """
    Usage:
      swift scripts/generate-license-code.swift --new-key
      swift scripts/generate-license-code.swift --transaction txn_123 [--count 10]

    Output format:
      CM-XXXXXXX-XXXXXXX-XXXXXXX
    """
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func intValue(after flag: String, in arguments: [String]) -> Int? {
    guard let rawValue = value(after: flag, in: arguments) else { return nil }
    return Int(rawValue)
}

private func unquotedEnvironmentValue(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 2,
       let first = trimmed.first,
       let last = trimmed.last,
       (first == "'" || first == "\""),
       first == last {
        return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
}

private func localEnvironmentValue(for key: String) -> String? {
    let fileManager = FileManager.default
    let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: currentDirectoryURL)
    let candidateURLs = [
        currentDirectoryURL.appendingPathComponent(".cleanmac-license.env"),
        scriptURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".cleanmac-license.env")
    ]

    for url in candidateURLs {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == key else { continue }
            return unquotedEnvironmentValue(String(trimmed[trimmed.index(after: equalsIndex)...]))
        }
    }

    return nil
}

private func randomData(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw ScriptError.randomBytesFailed }
    return Data(bytes)
}

private func shortLicenseTag(for signedPayload: Data, key: SymmetricKey) -> Data {
    var signedData = Data(hmacContext.utf8)
    signedData.append(signedPayload)
    let authenticationCode = HMAC<SHA256>.authenticationCode(for: signedData, using: key)
    return Data(Data(authenticationCode).prefix(tagByteCount))
}

private func groupedLicenseCode(from payload: Data) -> String {
    let encodedPayload = payload.licenseBase32EncodedString
    let groups = stride(from: 0, to: encodedPayload.count, by: 7).map { offset -> String in
        let start = encodedPayload.index(encodedPayload.startIndex, offsetBy: offset)
        let end = encodedPayload.index(start, offsetBy: min(7, encodedPayload.distance(from: start, to: encodedPayload.endIndex)))
        return String(encodedPayload[start..<end])
    }
    return "CM-\(groups.joined(separator: "-"))"
}

private func licenseCode(signingKey: SymmetricKey, issuedAt: Date = Date()) throws -> String {
    var payload = Data([shortLicenseVersion])
    var issuedAtDay = UInt16(issuedAt.timeIntervalSince1970 / secondsPerDay).bigEndian
    withUnsafeBytes(of: &issuedAtDay) { payload.append(contentsOf: $0) }
    payload.append(try randomData(count: nonceByteCount))
    payload.append(shortLicenseTag(for: payload, key: signingKey))
    return groupedLicenseCode(from: payload)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
        print(usage())
        return
    }

    if arguments.contains("--new-key") {
        let keyData = try randomData(count: 32)
        let key = keyData.base64EncodedString()
        print("CLEANMAC_LICENSE_SIGNING_KEY=\(key)")
        print("CLEANMAC_LICENSE_VALIDATION_KEY=\(key)")
        print("CleanMacLicenseValidationKey=\(key)")
        return
    }

    guard let transactionID = value(after: "--transaction", in: arguments) else {
        throw ScriptError.missingTransactionID
    }

    let countArgument = value(after: "--count", in: arguments)
    let count = countArgument.flatMap(Int.init) ?? 1
    guard count > 0 else {
        throw ScriptError.invalidCount
    }

    let environment = ProcessInfo.processInfo.environment
    guard let signingKeyString = environment["CLEANMAC_LICENSE_SIGNING_KEY"]
        ?? environment["CLEANMAC_LICENSE_VALIDATION_KEY"]
        ?? localEnvironmentValue(for: "CLEANMAC_LICENSE_SIGNING_KEY")
        ?? localEnvironmentValue(for: "CLEANMAC_LICENSE_VALIDATION_KEY") else {
        throw ScriptError.missingSigningKey
    }
    guard let signingKeyData = Data(base64URLOrStandardEncoded: signingKeyString), signingKeyData.count >= 16 else {
        throw ScriptError.invalidSigningKey
    }

    let signingKey = SymmetricKey(data: signingKeyData)
    if countArgument == nil {
        print(try licenseCode(signingKey: signingKey))
        return
    }

    for index in 1...count {
        let suffix = String(format: "%02d", index)
        let indexedTransactionID = "\(transactionID)-\(suffix)"
        print("\(suffix)\t\(indexedTransactionID)\t\(try licenseCode(signingKey: signingKey))")
    }
}

do {
    try run()
} catch {
    fputs("\(error)\n", stderr)
    fputs("\n\(usage())\n", stderr)
    exit(1)
}
