import XCTest
@testable import DaemonCore

final class UsageStatsTests: XCTestCase {
    func testMetricsAndPersistence() {
        let defaults = UserDefaults(suiteName: "UsageStatsTests-\(UUID())")!
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let stats = UsageStats(defaults: defaults, now: t0)

        for d in 0..<5 { stats.record(.keep, at: t0.addingTimeInterval(Double(d) * 86_400)) } // days 0-4
        stats.record(.recall, at: t0.addingTimeInterval(9 * 86_400))
        stats.record(.recall, at: t0.addingTimeInterval(9 * 86_400))
        stats.record(.recallSuccess, at: t0.addingTimeInterval(9 * 86_400))
        stats.record(.recall, at: t0.addingTimeInterval(1 * 86_400)) // older than 7 days at "now"

        let now = t0.addingTimeInterval(10 * 86_400)
        XCTAssertEqual(stats.keepsInFirst3Days(), 3)
        XCTAssertEqual(stats.recallsLast7Days(now: now), 2)
        XCTAssertEqual(stats.recallSuccessRate()!, 1.0 / 3.0, accuracy: 0.001)

        let reloaded = UsageStats(defaults: defaults, now: now) // first launch must survive relaunch
        XCTAssertEqual(reloaded.keepsInFirst3Days(), 3)
        XCTAssertTrue(reloaded.summary(now: now).contains("Recall success: 33%"))
    }

    func testFileVaultStatusReadable() {
        XCTAssertNotNil(FileVault.isOn())
    }
}
