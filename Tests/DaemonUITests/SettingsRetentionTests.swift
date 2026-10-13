import DaemonCore
import XCTest
@testable import DaemonUI

@MainActor
final class SettingsRetentionTests: XCTestCase {
    private func model(removing count: Int) -> SettingsModel {
        let model = SettingsModel(storageLocation: URL(filePath: "/tmp"), version: "1")
        model.countRemoved = { _ in count }
        return model
    }

    func testShorteningAsksFirstWithTheCount() async {
        let model = model(removing: 12)
        XCTAssertEqual(model.retention, .days30)
        await model.requestRetention(.days7)
        XCTAssertEqual(model.retention, .days30)
        XCTAssertEqual(model.pendingRetention?.message, "12 items older than 7 days will be removed now.")
        model.confirmRetention()
        XCTAssertEqual(model.retention, .days7)
        XCTAssertNil(model.pendingRetention)
    }

    func testCancelKeepsTheWindow() async {
        let model = model(removing: 1)
        await model.requestRetention(.days7)
        XCTAssertEqual(model.pendingRetention?.message, "1 item older than 7 days will be removed now.")
        model.pendingRetention = nil   // what Cancel does
        XCTAssertEqual(model.retention, .days30)
    }

    func testLengtheningOrNothingToRemoveAppliesAtOnce() async {
        let model = model(removing: 0)
        await model.requestRetention(.days7)
        XCTAssertEqual(model.retention, .days7)
        let longer = self.model(removing: 50)
        await longer.requestRetention(.days90)
        XCTAssertEqual(longer.retention, .days90)
        XCTAssertNil(longer.pendingRetention)
    }

    func testOldestItemText() {
        let now = Date()
        XCTAssertNil(SettingsModel.oldestText(nil, now: now))
        XCTAssertEqual(SettingsModel.oldestText(now, now: now), "Oldest item: today")
        let days23 = Calendar.current.date(byAdding: .day, value: -23, to: now)!
        XCTAssertEqual(SettingsModel.oldestText(days23, now: now), "Oldest item: 23 days ago")
    }
}
