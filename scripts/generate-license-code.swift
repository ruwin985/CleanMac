#!/usr/bin/env swift

import CryptoKit
import Foundation

private struct LicensePayload: Encodable {
    let version: Int
    let product: String
    let transactionID: String
    let email: String?
    let issuedAt: Date
}

private enum ScriptError: Error, CustomStringConvertible {
    case missingPrivateKey
    case missingTransactionID
    case invalidPrivateKey
    case invalidArguments

    var description: String {
        switch self {
        case .missingPrivateKey:
            return "Missing CLEANMAC_LICENSE_PRIVATE_KEY. Run with --new-key first, then export the private key."
        case .missingTransactionID:
            return "Missing --transaction <paddle_transaction_id>."
        case .invalidPrivateKey:
            return "CLEANMAC_LICENSE_PRIVATE_KEY must be a base64/base64url encoded Curve25519 private key."
        case .invalidArguments:
            return "Usage: swift scripts/generate-license-code.swift --transaction txn_... [--email buyer@example.com]"
        }
    }
}

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

    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
        throw ScriptError.invalidArguments
    }

    if arguments.contains("--new-key") {
        let privateKey = Curve25519.Signing.PrivateKey()
        print("CLEANMAC_LICENSE_PRIVATE_KEY=\(privateKey.rawRepresentation.base64EncodedString())")
        print("CleanMacLicensePublicKey=\(privateKey.publicKey.rawRepresentation.base64EncodedString())")
        return
    }

    guard let transactionID = value(after: "--transaction", in: arguments) else {
        throw ScriptError.missingTransactionID
    }
    guard let privateKeyString = ProcessInfo.processInfo.environment["CLEANMAC_LICENSE_PRIVATE_KEY"] else {
        throw ScriptError.missingPrivateKey
    }
    guard let privateKeyData = Data(base64URLOrStandardEncoded: privateKeyString) else {
        throw ScriptError.invalidPrivateKey
    }

    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    let payload = LicensePayload(
        version: 1,
        product: "CleanMac",
        transactionID: transactionID,
        email: value(after: "--email", in: arguments),
        issuedAt: Date()
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = try encoder.encode(payload)
    let signature = try privateKey.signature(for: payloadData)
    print("CM1-\(payloadData.base64URLEncodedString).\(signature.base64URLEncodedString)")
}

do {
    try run()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
