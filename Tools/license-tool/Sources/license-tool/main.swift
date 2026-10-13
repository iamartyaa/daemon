import CryptoKit
import Foundation

// swift run --package-path Tools/license-tool license-tool keygen
// DAEMON_PRIVATE_KEY=<base64> swift run --package-path Tools/license-tool license-tool sign --email a@b.com [--order 123]
// The private key comes from the environment, not argv, so it stays out of shell history and `ps`.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
    usage: license-tool keygen
           DAEMON_PRIVATE_KEY=<base64> license-tool sign --email <email> [--order <id>] [--major <n>]
    """

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private (keep secret, never commit): \(key.rawRepresentation.base64EncodedString())")
    print("public  (paste into LicenseKey.publicKey): \(key.publicKey.rawRepresentation.base64EncodedString())")

case "sign":
    guard let email = option("email"), email.contains("@") else { fail(usage) }
    guard let secret = ProcessInfo.processInfo.environment["DAEMON_PRIVATE_KEY"],
          let raw = Data(base64Encoded: secret),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("Set DAEMON_PRIVATE_KEY to the base64 private key from keygen.") }
    let license = License(email: email, major: Int(option("major") ?? "1") ?? 1, order: option("order"))
    print(try LicenseKey.issue(license, privateKey: key))

default:
    fail(usage)
}
