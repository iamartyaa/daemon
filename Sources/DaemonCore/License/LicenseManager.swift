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

    public init(store: LicenseStore = FileLicenseStore(),
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

/// Trial start and license key in Application Support. Neither is secret (keys are signature-checked), and a
/// Keychain item prompts whenever the app's signature changes, which used to block launch on a system dialog.
public struct FileLicenseStore: LicenseStore {
    let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Daemon/license.plist")) {
        self.url = url
    }

    public func read(_ account: String) -> String? { values()[account] }

    public func write(_ value: String?, _ account: String) {
        var all = values()
        all[account] = value
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PropertyListEncoder().encode(all).write(to: url, options: .atomic)
    }

    private func values() -> [String: String] {
        (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}
