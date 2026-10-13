import AppKit
import DaemonCore
import XCTest
@testable import DaemonUI

@MainActor
final class FakeActions: RecallActions {
    var pasted: [SearchHit] = []
    var copied: [SearchHit] = []
    var opened: [SearchHit] = []
    var pasteSucceeds = true

    func paste(_ hit: SearchHit, fileURL: URL?) async -> Bool { pasted.append(hit); return pasteSucceeds }
    func copy(_ hit: SearchHit, fileURL: URL?) { copied.append(hit) }
    func open(_ hit: SearchHit, fileURL: URL?) { opened.append(hit) }
}

@MainActor
final class RecallBehaviorTests: XCTestCase {
    private var data: MockRecallDataSource!
    private var actions: FakeActions!
    private var model: RecallViewModel!
    private var closed = 0

    override func setUp() async throws {
        data = MockRecallDataSource()
        actions = FakeActions()
        model = RecallViewModel(dataSource: data, actions: actions, debounce: .milliseconds(150))
        model.close = { [unowned self] in self.closed += 1 }
    }

    private func settle(_ ms: Int = 60) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    private func search(_ query: String) async throws {
        model.query = query
        try await settle(250)
    }

    func testDebounceSearchesOnlyAfterTypingStops() async throws {
        model.query = "p"
        try await settle(50)
        model.query = "pr"
        try await settle(50)
        model.query = "pri"
        try await settle(100)
        XCTAssertEqual(data.searches, [], "nothing runs until 150 ms after the last keystroke")
        try await settle(120)
        XCTAssertEqual(data.searches, ["pri"])
        XCTAssertEqual(model.visibleHits.count, 7)
    }

    func testEmptyQueryShowsRecentWithoutSearching() async throws {
        model.reset()
        try await settle()
        XCTAssertTrue(model.isRecent)
        XCTAssertEqual(model.hits.count, 6)
        XCTAssertEqual(data.searches, [])
    }

    func testFilterChipCounts() async throws {
        try await search("pricing")
        let counts = Dictionary(uniqueKeysWithValues: model.chips.map { ($0.filter, $0.count) })
        XCTAssertEqual(counts, [.all: 7, .images: 3, .audio: 1, .video: 1, .pdfs: 1, .links: 1])
        XCTAssertEqual(model.chips.map(\.filter), RecallFilter.allCases)
    }

    func testZeroCountChipsAreHidden() async throws {
        data.results = Array(data.results.prefix(2))
        try await search("billing")
        XCTAssertEqual(model.chips.map(\.filter), [.all, .images])
    }

    func testTabCyclesFilters() async throws {
        try await search("pricing")
        XCTAssertTrue(model.handle(.tab))
        XCTAssertEqual(model.filter, .images)
        XCTAssertEqual(model.visibleHits.count, 3)
        XCTAssertTrue(model.handle(.shiftTab))
        XCTAssertTrue(model.handle(.shiftTab))
        XCTAssertEqual(model.filter, .links)
    }

    func testArrowsMoveSelectionWithinBounds() async throws {
        try await search("pricing")
        XCTAssertTrue(model.handle(.up))
        XCTAssertEqual(model.selection, 0)
        for _ in 0..<10 { _ = model.handle(.down) }
        XCTAssertEqual(model.selection, 6)
        XCTAssertFalse(model.handle(.left), "left/right move the text cursor while a query is typed")
    }

    func testRecentGridMovesByRows() async throws {
        model.reset()
        try await settle()
        _ = model.handle(.down)
        XCTAssertEqual(model.selection, 3)
        _ = model.handle(.right)
        XCTAssertEqual(model.selection, 4)
    }

    func testEnterPastesThenCloses() async throws {
        try await search("pricing")
        _ = model.handle(.down)
        XCTAssertTrue(model.handle(.enter))
        XCTAssertEqual(closed, 1)
        try await settle()
        XCTAssertEqual(actions.pasted.map(\.id), [2])
    }

    func testFailedPasteShowsCopiedToast() async throws {
        var toast: String?
        model.showToast = { toast = $0 }
        actions.pasteSucceeds = false
        try await search("pricing")
        _ = model.handle(.enter)
        try await settle()
        XCTAssertEqual(toast, "Copied, press ⌘V")
    }

    func testCopyAndOpen() async throws {
        try await search("pricing")
        _ = model.handle(.cmdC)
        _ = model.handle(.cmdEnter)
        XCTAssertEqual(actions.copied.map(\.id), [1])
        XCTAssertEqual(actions.opened.map(\.id), [1])
        XCTAssertEqual(closed, 2)
    }

    func testSpaceTypesWhileTypingAndPreviewsWhileBrowsing() async throws {
        var previewed: [URL] = []
        model.quickLook = { previewed.append($0) }
        try await search("pricing")
        XCTAssertFalse(model.handle(.space), "a space in the middle of a query is just a space")
        _ = model.handle(.down)
        XCTAssertTrue(model.handle(.space))
        XCTAssertNotNil(model.notice, "mock items have no file, so it says why nothing opened")
        model.query = "pricing "
        XCTAssertFalse(model.handle(.space))
    }

    func testDeleteAndUndo() async throws {
        try await search("pricing")
        XCTAssertTrue(model.handle(.cmdDelete))
        XCTAssertEqual(model.visibleHits.count, 6)
        XCTAssertEqual(model.pendingDelete?.id, 1)
        try await settle()
        XCTAssertEqual(data.deleted.map(\.id), [1])
        XCTAssertTrue(model.handle(.cmdZ))
        XCTAssertNil(model.pendingDelete)
        XCTAssertEqual(model.visibleHits.first?.id, 1)
        try await settle()
        XCTAssertEqual(data.deleted, [])
        XCTAssertFalse(model.handle(.cmdZ), "⌘Z does nothing without a pending delete")
    }

    func testCmdVKeepsClipboard() async throws {
        XCTAssertTrue(model.handle(.cmdV))
        try await settle()
        XCTAssertEqual(data.keptClipboardCount, 1)
    }

    func testDroppedFileSearchesSimilar() async throws {
        model.searchSimilar(to: URL(filePath: "/tmp/shot.png"))
        try await settle()
        XCTAssertFalse(model.isRecent)
        XCTAssertEqual(model.similarTo, "shot.png")
        XCTAssertEqual(model.visibleHits.count, 3)
    }

    func testEmptyMessages() async throws {
        data.recentHits = []
        model.reset()
        try await settle()
        XCTAssertEqual(model.emptyMessage, "Nothing kept yet. Press ⌃⌥S on anything.")
        XCTAssertFalse(model.emptyMessage.localizedCaseInsensitiveContains("oops"))
    }

    func testKeyMapping() {
        func event(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        XCTAssertEqual(RecallPanelController.key(for: event(36, "\r")), .enter)
        XCTAssertEqual(RecallPanelController.key(for: event(36, "\r", .command)), .cmdEnter)
        XCTAssertEqual(RecallPanelController.key(for: event(8, "c", .command)), .cmdC)
        XCTAssertEqual(RecallPanelController.key(for: event(9, "v", .command)), .cmdV)
        XCTAssertEqual(RecallPanelController.key(for: event(51, "\u{8}", .command)), .cmdDelete)
        XCTAssertEqual(RecallPanelController.key(for: event(125, "", .numericPad)), .down)
        XCTAssertNil(RecallPanelController.key(for: event(0, "a")))
    }
}

@MainActor
final class ControllerSmokeTests: XCTestCase {
    func testRecallPanelShowsAndHides() {
        let toasts = ToastPresenter()
        let panel = RecallPanelController(dataSource: MockRecallDataSource(), actions: FakeActions(), toasts: toasts)
        panel.show()
        XCTAssertTrue(panel.isVisible)
        panel.toggle()
        XCTAssertFalse(panel.isVisible)
        toasts.showMessage("Copied, press ⌘V")
        toasts.showListening()
        toasts.updateLevel(0.6)
        toasts.finishListening()
    }
}

final class FormattingTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T16:41:00Z")!

    private func ago(_ seconds: Double) -> String {
        relativeDate(now.addingTimeInterval(-seconds), now: now, calendar: calendar)
    }

    func testRelativeDates() {
        XCTAssertEqual(ago(20), "Just now")
        XCTAssertEqual(ago(120), "2 min ago")
        XCTAssertEqual(ago(3600), "1 hr ago")
        XCTAssertEqual(ago(5 * 3600), "Today")
        XCTAssertEqual(ago(20 * 3600), "Yesterday")
        XCTAssertEqual(ago(3 * 86400), "3 days ago")
        XCTAssertEqual(ago(7 * 86400), "1 week ago")
        XCTAssertEqual(ago(21 * 86400), "3 weeks ago")
        XCTAssertEqual(ago(65 * 86400), "2 months ago")
        XCTAssertEqual(ago(800 * 86400), "2 years ago")
    }

    func testTimecodes() {
        XCTAssertEqual(timecode(ms: 42_000), "0:42")
        XCTAssertEqual(timecode(ms: 2_840_000), "47:20")
        XCTAssertEqual(timecode(ms: 3_723_000), "1:02:03")
    }

    @MainActor func testTitlesAndBadges() {
        let hits = MockRecallDataSource.sampleHits(now: now)
        XCTAssertEqual(hits[4].displayTitle, "SaaS Pricing Playbook, page 12")
        XCTAssertEqual(hits[5].displayTitle, "“Default to yearly, show the monthly price small under it”")
        XCTAssertEqual(hits[5].timeBadge, "at 0:42")
        XCTAssertEqual(hits[6].timeBadge, "at 47:20")
        XCTAssertNil(hits[0].timeBadge)
        XCTAssertEqual(hits[5].item.sourceLabel, "Voice")
    }
}
