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

    /// A toast that arrives while the last one is leaving turns it around instead of waiting for it to go.
    func testToastArrivingMidExitStays() async throws {
        let toasts = ToastPresenter()
        toasts.origin = NSPoint(x: -10_000, y: -10_000)   // off screen
        toasts.showMessage("Copied, press ⌘V")
        try await Task.sleep(for: .seconds(ToastModel.readingTime("Copied, press ⌘V") + Theme.Motion.toastExit / 3))
        XCTAssertFalse(toasts.model.visible, "leaving")
        toasts.showMessage("Exported everything to Daemon Export.")
        try await Task.sleep(for: .seconds(Theme.Motion.toastExit * 2))
        XCTAssertTrue(toasts.model.visible, "the exit's completion didn't take the new toast with it")
        guard case .message("Exported everything to Daemon Export.") = toasts.model.state else { return XCTFail("new toast") }
    }

    /// Voice -> notice replaces in place (the card never leaves), then hides on its own. Off screen; no hotkeys.
    func testPresenterReplacesInPlaceThenHides() async throws {
        let toasts = ToastPresenter()
        toasts.origin = NSPoint(x: -10_000, y: -10_000)   // off screen
        let model = toasts.model
        toasts.showListening()
        XCTAssertTrue(model.visible)
        toasts.updateLevel(0.9)
        XCTAssertEqual(model.levels.last, 0.9)
        toasts.finishListening()
        guard case .listening(_, ended: .some) = model.state else { return XCTFail("should hold as Keeping") }
        toasts.updateLevel(0.5)
        XCTAssertEqual(model.levels.last, 0.9, "the waveform freezes where it was once the key is up")

        let serial = model.serial
        toasts.showMessage("Copied, press ⌘V")
        XCTAssertTrue(model.visible, "replacing never hides the card")
        XCTAssertEqual(model.serial, serial + 1)

        try await Task.sleep(for: .seconds(ToastModel.readingTime("Copied, press ⌘V") + 0.5))
        XCTAssertFalse(model.visible)
    }

    /// Keeping -> Kept stays on the same card (no new serial), after Keeping has been seen for a moment.
    func testKeepingMorphsIntoKept() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAEMON_UI_LIVE"] != nil, "Kept listens for Tab system-wide; set DAEMON_UI_LIVE=1")
        let toasts = ToastPresenter()
        toasts.origin = NSPoint(x: -10_000, y: -10_000)   // off screen
        let model = toasts.model
        toasts.showKeeping(kind: .text, sourceApp: "Notes")
        guard case .keeping(.text, KeepingSummary(header: "Notes")) = model.state else { return XCTFail("should show Keeping") }
        let serial = model.serial
        toasts.showKept(item: Item(kind: .text, sourceApp: "Notes", text: "hi"), thumbnailURL: nil) { _ in }
        guard case .keeping = model.state else { return XCTFail("Keeping holds at least keepingMin") }
        try await Task.sleep(for: .seconds(Theme.Motion.keepingMin + 0.1))
        guard case .kept = model.state else { return XCTFail("should be Kept") }
        XCTAssertEqual(model.serial, serial, "morphs in place")
    }

    func testKeepingSaysWhatItCanAlready() {
        func say(_ kind: KeepKindHint, app: String? = nil, title: String? = nil, url: String? = nil) -> KeepingSummary {
            KeepingSummary(kind: kind, sourceApp: app, windowTitle: title, url: url)
        }
        XCTAssertEqual(say(.text, app: "Notes", title: "Pricing"), KeepingSummary(header: "Notes"))
        XCTAssertEqual(say(.text), KeepingSummary(header: "Text"))
        XCTAssertEqual(say(.image, app: "Figma", title: "Pricing"), KeepingSummary(header: "Screenshot", detail: "Figma · Pricing"),
                       "same words Kept will use, so only the lead word changes")
        XCTAssertEqual(say(.link, app: "Safari", title: "Stripe Docs", url: "https://www.stripe.com/docs"),
                       KeepingSummary(header: "stripe.com", detail: "Stripe Docs"))
        XCTAssertEqual(say(.files, app: "Finder"), KeepingSummary(header: "Files from Finder"))
        XCTAssertEqual(say(.unknown), KeepingSummary(header: ""))
        XCTAssertTrue(ToastModel.State.keeping(.text, say(.text)).isKeeping)
        XCTAssertTrue(ToastModel.State.listening(Date(), ended: Date()).isKeeping)
        XCTAssertFalse(ToastModel.State.listening(Date(), ended: nil).isKeeping)
    }

    /// The progress line starts after the morph; the hide timer waits for it.
    func testCountdownCanStartLater() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let c = Countdown(total: 1.5, start: t0.addingTimeInterval(0.2))
        XCTAssertEqual(c.progress(at: t0.addingTimeInterval(0.1)), 0)
        XCTAssertEqual(c.remaining(at: t0), 1.7, accuracy: 1e-9)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(0.95)), 0.75, accuracy: 1e-9)
    }

    func testFlightLiftsArcsAndMeltsIntoTheMark() {
        let path = FlightPath(from: CGPoint(x: 500, y: 90), to: CGPoint(x: 100, y: 20))
        let start = path.frame(at: 0), end = path.frame(at: 1)
        XCTAssertEqual(start, FlightPath.Frame(center: CGPoint(x: 500, y: 90), scale: 1, opacity: 1, shadow: 0))
        XCTAssertEqual(end.center.x, 100, accuracy: 1e-6)
        XCTAssertEqual(end.center.y, 20, accuracy: 1e-6)
        XCTAssertEqual(end.scale, FlightPath.endScale, accuracy: 1e-6)
        XCTAssertEqual(end.opacity, 0)

        let lifted = path.frame(at: FlightPath.lift)
        XCTAssertGreaterThan(lifted.scale, 1, "lifts a touch larger first")
        XCTAssertGreaterThan(lifted.shadow, 0.5)
        XCTAssertLessThan(lifted.center.y, 90, "and up off the card")

        let mid = path.frame(at: 0.55)
        let straightY = 90 + (20 - 90) * (500 - mid.center.x) / 400
        XCTAssertLessThan(mid.center.y, straightY, "bows upward rather than sliding in a straight line")
        XCTAssertEqual(path.frame(at: 0.7).opacity, 1, "readable until it reaches the mark")
        XCTAssertEqual(path.frame(at: 2), end, "clamped")
    }

    func testShimmerSweepsThenRests() {
        XCTAssertEqual(Shimmer.sweep(0), 0)
        XCTAssertEqual(Shimmer.sweep(0.425), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Shimmer.sweep(0.9), 1, "rests off the edge before the next pass")
        XCTAssertEqual(Shimmer.breath(0), 1, accuracy: 1e-9)
        XCTAssertEqual(Shimmer.breath(0.5), 0.55, accuracy: 1e-9)
    }

    func testNoticesStayLongEnoughToRead() {
        XCTAssertEqual(ToastModel.readingTime("Copied, press ⌘V"), 2)
        XCTAssertEqual(ToastModel.readingTime(String(repeating: "a", count: 72)), 4, accuracy: 1e-9)
        XCTAssertEqual(ToastModel.readingTime(String(repeating: "a", count: 400)), 5)
    }
}
