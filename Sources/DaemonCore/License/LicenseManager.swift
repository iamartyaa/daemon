import Combine
import CryptoKit
import Foundation
import Security

public enum LicenseState: Equatable, Sendable {
    case trial(daysLeft: Int)
    case trialExpired
    case licensed(email: String)

    /// After the trial, Keep pauses; Recall, browsing, paste and export keep working,
    /// so nobody loses access to what they already kept.
    public var canKeep: Bool { self != .trialExpired }
}

/// Small string storage. Keychain in the app (survives deleting preferences), in-memory in tests.
public protocol LicenseStore {
    func read(_ account: String) -> String?
    func write(_ value: String?, _ account: String)
}

public final class LicenseManager: ObservableObject {
    public static let trialDays = 14
    public static let appMajor = 1

    private let store: LicenseStore
    private let publicKey: Curve25519.Signing.PublicKey
    private let now: () -> Date
    private let calendar: Calendar
    private let trialStart: Date
    private var license: License?

    public init(store: LicenseStore = KeychainStore(),
                publicKey: Curve25519.Signing.PublicKey = LicenseKey.publicKey,
                now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.store = store; self.publicKey = publicKey; self.now = now; self.calendar = calendar

        if let stored = store.read("trialStart").flatMap(TimeInterval.init) {
            trialStart = Date(timeIntervalSince1970: stored)
        } else {
            trialStart = now()
            store.write(String(trialStart.timeIntervalSince1970), "trialStart")
        }
        license = store.read("license").flatMap {
            try? LicenseKey.verify($0, publicKey: publicKey, appMajor: Self.appMajor)
        }
    }

    public var state: LicenseState {
        if let license { return .licensed(email: license.email) }
        // Calendar days, so the trial ends at local midnight and DST days count as one day each.
        let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: trialStart),
                                              to: calendar.startOfDay(for: now())).day ?? 0
        let left = min(Self.trialDays, Self.trialDays - elapsed)  // clock set back: never more than 14
        return left > 0 ? .trial(daysLeft: left) : .trialExpired
    }

    public func activate(_ key: String) throws {
        let verified = try LicenseKey.verify(key, publicKey: publicKey, appMajor: Self.appMajor)
        objectWillChange.send()
        license = verified
        store.write(LicenseKey.normalize(key), "license")
    }

    public func deactivate() {
        objectWillChange.send()
        license = nil
        store.write(nil, "license")
    }
}

public struct KeychainStore: LicenseStore {
    let service: String

    public init(service: String = "app.mydaemon.Daemon.license") { self.service = service }

    public func read(_ account: String) -> String? {
        var result: AnyObject?
        let query = base(account).merging([kSecReturnData as String: true]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, _ account: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard let value else { return }
        let item = base(account).merging([kSecValueData as String: Data(value.utf8)]) { $1 }
        SecItemAdd(item as CFDictionary, nil)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
