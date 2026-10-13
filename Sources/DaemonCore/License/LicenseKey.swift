import CryptoKit
import Foundation

// Key text: "DAEMON-" + base64url(JSON payload) + "." + base64url(Ed25519 signature over the payload bytes).
// This file is also compiled into Tools/license-tool (symlinked), so it must only need Foundation + CryptoKit.

public struct License: Codable, Equatable, Sendable {
    public var email: String
    public var major: Int          // a 1.x key unlocks every 1.x release
    public var issued: Date
    public var order: String?

    public init(email: String, major: Int = 1, issued: Date = Date(), order: String? = nil) {
        self.email = email; self.major = major; self.order = order
        self.issued = Date(timeIntervalSince1970: issued.timeIntervalSince1970.rounded(.down)) // shorter key
    }

    enum CodingKeys: String, CodingKey { case email = "e", major = "v", issued = "d", order = "o" }
}

public enum LicenseError: Error, Equatable, LocalizedError {
    case malformed
    case invalidSignature
    case wrongVersion

    public var errorDescription: String? {
        switch self {
        case .malformed: "That doesn't look like a Daemon key — check for missing characters."
        case .invalidSignature: "That key couldn't be verified — copy it again from your receipt email."
        case .wrongVersion: "That key doesn't match this version of Daemon."
        }
    }
}

public enum LicenseKey {
    static let prefix = "DAEMON-"

    /// Placeholder generated during development; its private key was thrown away.
    /// Before launch: `swift run --package-path Tools/license-tool license-tool keygen`, keep the private
    /// key in the password manager / merchant webhook secret store, and paste the public key here.
    public static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "eAFkhtA+3x/VVxKn/veHXEzClw63R0xtptqutpIMGR0=")!)

    public static func issue(_ license: License, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(license)
        let signature = try privateKey.signature(for: payload)
        return prefix + payload.base64URL + "." + signature.base64URL
    }

    /// Accepts keys with whitespace or line breaks anywhere (email clients wrap long lines).
    /// A key for the app's major version or newer unlocks it.
    public static func verify(_ text: String, publicKey: Curve25519.Signing.PublicKey = publicKey,
                              appMajor: Int = 1) throws -> License {
        let key = normalize(text)
        guard key.hasPrefix(prefix) else { throw LicenseError.malformed }
        let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = Data(base64URL: String(parts[0])),
              let signature = Data(base64URL: String(parts[1])), signature.count == 64
        else { throw LicenseError.malformed }
        guard publicKey.isValidSignature(signature, for: payload) else { throw LicenseError.invalidSignature }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let license = try? decoder.decode(License.self, from: payload) else { throw LicenseError.malformed }
        guard license.major >= appMajor else { throw LicenseError.wrongVersion }
        return license
    }

    public static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
}
