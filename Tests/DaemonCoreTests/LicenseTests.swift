import CryptoKit
import XCTest
@testable import DaemonCore

final class MemoryStore: LicenseStore {
    var values: [String: String] = [:]
    func read(_ account: String) -> String? { values[account] }
    func write(_ value: String?, _ account: String) { values[account] = value }
}

final class LicenseKeyTests: XCTestCase {
    let signer = Curve25519.Signing.PrivateKey()
    var key: String { try! LicenseKey.issue(License(email: "ana@example.com", order: "A-42"), privateKey: signer) }

    func verify(_ text: String, appMajor: Int = 1) throws -> License {
        try LicenseKey.verify(text, publicKey: signer.publicKey, appMajor: appMajor)
    }

    func testRoundTrip() throws {
        let license = try verify(key)
        XCTAssertEqual(license.email, "ana@example.com")
        XCTAssertEqual(license.order, "A-42")
        XCTAssertEqual(license.major, 1)
        XCTAssertTrue(key.hasPrefix("DAEMON-"))
    }

    func testWhitespaceWrappedKey() throws {
        let k = key
        let mid = k.index(k.startIndex, offsetBy: 40)
        let wrapped = "\n  " + k[..<mid] + "\r\n\t" + k[mid...] + "  \n"
        XCTAssertEqual(try verify(wrapped).email, "ana@example.com")
    }

    func testTamperedPayloadFailsSignature() {
        let forged = try! LicenseKey.issue(License(email: "mallory@example.com"), privateKey: signer)
        let realSignature = key.split(separator: ".")[1]
        let tampered = forged.split(separator: ".")[0] + "." + realSignature
        XCTAssertThrowsError(try verify(String(tampered))) { XCTAssertEqual($0 as? LicenseError, .invalidSignature) }
    }

    func testWrongKeyFailsSignature() {
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try LicenseKey.verify(key, publicKey: other.publicKey)) {
            XCTAssertEqual($0 as? LicenseError, .invalidSignature)
        }
    }

    func testTruncatedKeyIsMalformed() {
        for cut in [5, 30, key.count - 10] {
            XCTAssertThrowsError(try verify(String(key.prefix(cut)))) { XCTAssertEqual($0 as? LicenseError, .malformed) }
        }
        XCTAssertThrowsError(try verify("")) { XCTAssertEqual($0 as? LicenseError, .malformed) }
        XCTAssertThrowsError(try verify("hello world")) { XCTAssertEqual($0 as? LicenseError, .malformed) }
    }

    func testOlderMajorDoesNotUnlockNewerApp() throws {
        XCTAssertThrowsError(try verify(key, appMajor: 2)) { XCTAssertEqual($0 as? LicenseError, .wrongVersion) }
        XCTAssertEqual(LicenseError.wrongVersion.localizedDescription, "That key doesn't match this version of Daemon.")
    }

    func testEmbeddedPublicKeyLoads() {
        XCTAssertEqual(LicenseKey.publicKey.rawRepresentation.count, 32)
    }
}

final class LicenseManagerTests: XCTestCase {
    let signer = Curve25519.Signing.PrivateKey()
    let store = MemoryStore()
    var now = Date()
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func manager() -> LicenseManager {
        LicenseManager(store: store, publicKey: signer.publicKey, now: { [unowned self] in now }, calendar: calendar)
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testTrialDaysAcrossDSTFallBack() {
        now = date(2026, 10, 25, 23)          // DST ends Nov 1 in New York; that day is 25 h
        let m = manager()
        XCTAssertEqual(m.state, .trial(daysLeft: 14))
        now = date(2026, 10, 26, 0)
        XCTAssertEqual(m.state, .trial(daysLeft: 13))
        now = date(2026, 11, 1, 23)
        XCTAssertEqual(m.state, .trial(daysLeft: 7))
        now = date(2026, 11, 7, 23)
        XCTAssertEqual(m.state, .trial(daysLeft: 1))
        now = date(2026, 11, 8, 0)
        XCTAssertEqual(m.state, .trialExpired)
        XCTAssertFalse(m.state.canKeep)
    }

    func testTrialDaysAcrossDSTSpringForward() {
        now = date(2026, 3, 1, 9)             // DST starts Mar 8; that day is 23 h
        let m = manager()
        now = date(2026, 3, 8, 23)
        XCTAssertEqual(m.state, .trial(daysLeft: 7))
        now = date(2026, 3, 14, 23)
        XCTAssertEqual(m.state, .trial(daysLeft: 1))
        now = date(2026, 3, 15, 0)
        XCTAssertEqual(m.state, .trialExpired)
    }

    func testTrialStartPersistsAcrossLaunches() {
        now = date(2026, 1, 1, 12)
        _ = manager()
        now = date(2026, 1, 11, 12)
        XCTAssertEqual(manager().state, .trial(daysLeft: 4))
    }

    func testClockSetBackNeverExtendsTrial() {
        now = date(2026, 1, 10, 12)
        let m = manager()
        now = date(2025, 6, 1, 12)
        XCTAssertEqual(m.state, .trial(daysLeft: 14))
    }

    func testActivateDeactivate() throws {
        now = date(2026, 1, 1, 12)
        let m = manager()
        now = date(2026, 2, 1, 12)
        XCTAssertEqual(m.state, .trialExpired)

        XCTAssertThrowsError(try m.activate("DAEMON-nope")) { XCTAssertEqual($0 as? LicenseError, .malformed) }
        XCTAssertEqual(m.state, .trialExpired)

        try m.activate("  " + LicenseKey.issue(License(email: "ana@example.com"), privateKey: signer) + "\n")
        XCTAssertEqual(m.state, .licensed(email: "ana@example.com"))
        XCTAssertTrue(m.state.canKeep)
        XCTAssertEqual(manager().state, .licensed(email: "ana@example.com"), "license survives relaunch")

        m.deactivate()
        XCTAssertEqual(m.state, .trialExpired, "trial does not restart after removing a license")
        XCTAssertEqual(manager().state, .trialExpired)
    }

    func testStoredKeyFromAnotherSignerIsIgnored() throws {
        store.values["license"] = try LicenseKey.issue(License(email: "x@y.z"), privateKey: .init())
        XCTAssertEqual(manager().state, .trial(daysLeft: 14))
    }
}

final class FileLicenseStoreTests: XCTestCase {
    func testRoundTripAndRemoval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("license-\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileLicenseStore(url: url)
        XCTAssertNil(store.read("trialStart"))
        store.write("1800000000", "trialStart")
        store.write("DAEMON-abc.def", "license")
        XCTAssertEqual(FileLicenseStore(url: url).read("trialStart"), "1800000000")
        store.write(nil, "license")
        XCTAssertNil(store.read("license"))
        XCTAssertEqual(store.read("trialStart"), "1800000000")
    }
}
