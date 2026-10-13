import DaemonCore
import XCTest
@testable import DaemonUI

@MainActor
final class ToastTests: XCTestCase {
    private func summary(_ item: Item, count: Int = 1) -> KeptSummary { KeptSummary(item: item, count: count) }

    func testKeptSummarySaysWhatAndWhere() {
        XCTAssertEqual(summary(Item(kind: .text, sourceApp: "Notes", text: "\n  Annual   badge on Pro\nsecond")),
                       KeptSummary(header: "Notes", detail: "Annual badge on Pro"))
        XCTAssertEqual(summary(Item(kind: .text, text: "hi")), KeptSummary(header: "Text", detail: "hi"))
        XCTAssertEqual(summary(Item(kind: .screenshot, sourceApp: "Figma", windowTitle: "Pricing")),
                       KeptSummary(header: "Screenshot", detail: "Figma · Pricing"))
        XCTAssertEqual(summary(Item(kind: .screenshot)), KeptSummary(header: "Screenshot", detail: nil))
        XCTAssertEqual(summary(Item(kind: .voice, text: "Call Hana", durationMs: 7_400)),
                       KeptSummary(header: "Voice note · 0:07", detail: "“Call Hana”"))
        XCTAssertEqual(summary(Item(kind: .voice)), KeptSummary(header: "Voice note", detail: nil))
        XCTAssertEqual(summary(Item(kind: .link, sourceApp: "Safari", url: "https://www.stripe.com/docs", text: "Stripe Docs")),
                       KeptSummary(header: "stripe.com", detail: "Stripe Docs"))
        XCTAssertEqual(summary(Item(kind: .link, url: "news.ycombinator.com/item?id=1")),
                       KeptSummary(header: "news.ycombinator.com", detail: "news.ycombinator.com/item?id=1"))
        XCTAssertEqual(summary(Item(kind: .pdf, sourceApp: "Preview", originalPath: "/tmp/Q3 roadmap.pdf")),
                       KeptSummary(header: "PDF from Preview", detail: "Q3 roadmap.pdf", detailIsFileName: true))
        XCTAssertEqual(summary(Item(kind: .video, originalPath: "/m/Lecture 9.mp4", durationMs: 2_840_000)),
                       KeptSummary(header: "Video · 47:20", detail: "Lecture 9.mp4", detailIsFileName: true))
    }

    func testSeveralKeptAtOnce() {
        XCTAssertEqual(summary(Item(kind: .file, sourceApp: "Finder", originalPath: "/a/b.key"), count: 3),
                       KeptSummary(header: "3 files from Finder", detail: "b.key and 2 more"))
        XCTAssertEqual(summary(Item(kind: .text, text: "one"), count: 2),
                       KeptSummary(header: "2 items", detail: "one and 1 more"))
    }

    func testCountdownPausesAndResumes() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = Countdown(total: 1.5, start: t0)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(0.5)), 1.0, accuracy: 1e-9)
        c.pause(at: t0.addingTimeInterval(0.5))
        XCTAssertTrue(c.isPaused)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(10)), 1.0, accuracy: 1e-9)   // hovering holds it
        c.resume(at: t0.addingTimeInterval(10))
        XCTAssertEqual(c.progress(at: t0.addingTimeInterval(10.25)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(99)), 0)                      // never negative
    }

    /// Voice -> notice replaces in place (the card never leaves), then hides on its own.
    func testPresenterReplacesInPlaceThenHides() async throws {
        let toasts = ToastPresenter()
        let model = toasts.model
        toasts.showListening()
        XCTAssertTrue(model.visible)
        toasts.updateLevel(0.9)
        XCTAssertEqual(model.levels.last, 0.9)
        toasts.finishListening()
        guard case .listening(_, ended: .some) = model.state else { return XCTFail("should hold as Keeping") }
        toasts.updateLevel(0.5)
        XCTAssertEqual(model.levels.last, ToastModel.floor, "levels stop once the key is up")

        let serial = model.serial
        toasts.showMessage("Copied, press ⌘V")
        XCTAssertTrue(model.visible, "replacing never hides the card")
        XCTAssertEqual(model.serial, serial + 1)

        try await Task.sleep(for: .seconds(ToastModel.readingTime("Copied, press ⌘V") + 0.5))
        XCTAssertFalse(model.visible)
    }

    func testNoticesStayLongEnoughToRead() {
        XCTAssertEqual(ToastModel.readingTime("Copied, press ⌘V"), 2)
        XCTAssertEqual(ToastModel.readingTime(String(repeating: "a", count: 72)), 4, accuracy: 1e-9)
        XCTAssertEqual(ToastModel.readingTime(String(repeating: "a", count: 400)), 5)
    }
}
