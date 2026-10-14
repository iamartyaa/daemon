import AppKit
import DaemonCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaemonUI

/// A source whose answers arrive after a delay chosen per query, to exercise ordering and the two-phase results.
@MainActor
final class TimedSource: QuickRecallSource {
    var totalCount = 0
    var quickDelay: Duration = .zero
    var fullDelay: (String) -> Duration = { _ in .zero }
    var recentItems: [SearchHit] = []
    var files: [Int64: URL] = [:]
    private(set) var fullCalls: [String] = []

    static func hit(_ id: Int64, _ text: String, kind: ItemKind = .text, url: String? = nil) -> SearchHit {
        SearchHit(item: Item(id: id, kind: kind, url: url, text: text, status: .ready), score: 1)
    }

    /// Keyword answers lead with id 1xx, full answers with 300 (ranked up by meaning) then 2xx.
    func quickSearch(_ query: String) async throws -> [SearchHit] {
        try await Task.sleep(for: quickDelay)
        return [Self.hit(100 + Int64(query.count), "keyword \(query)"), Self.hit(300, "both")]
    }

    func search(_ query: String) async throws -> [SearchHit] {
        fullCalls.append(query)
        // Ignores cancellation, like a model call already in flight: a stale answer still comes back, late.
        let delay = fullDelay(query)
        await withCheckedContinuation { done in
            let c = delay.components
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(c.seconds) + Double(c.attoseconds) / 1e18) { done.resume() }
        }
        return [Self.hit(300, "both"), Self.hit(200 + Int64(query.count), "full \(query)")]
    }

    func recent(limit: Int) async throws -> [SearchHit] { Array(recentItems.prefix(limit)) }
    func searchSimilar(to file: URL) async throws -> [SearchHit] { [] }
    func thumbnailURL(for item: Item) -> URL? { nil }
    func fileURL(for item: Item) -> URL? { item.id.flatMap { files[$0] } }
    func delete(_ item: Item) async throws {}
    func undoDelete(_ item: Item) async throws {}
    func setNote(_ note: String, for item: Item) async throws {}
    func keepClipboard() async throws {}
}

@MainActor
final class RecallSpeedTests: XCTestCase {
    private var source: TimedSource!
    private var model: RecallViewModel!
    private var updates: [[Int64]] = []

    override func setUp() async throws {
        source = TimedSource()
        model = RecallViewModel(dataSource: source, actions: FakeActions(), refineBudget: .milliseconds(50))
        updates = []
    }

    private func record() -> Any {
        model.$hits.dropFirst().sink { [unowned self] in self.updates.append($0.map(\.id)) }
    }

    private func wait(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    func testFastFullResultsReplaceKeywordResultsWithoutAFlash() async throws {
        let sink = record()
        model.query = "pricing"
        try await wait(120)
        XCTAssertEqual(updates, [[300, 207]], "full results inside the budget: one update, keyword results never shown")
        _ = sink
    }

    func testSlowModelShowsKeywordResultsThenRefines() async throws {
        source.fullDelay = { _ in .milliseconds(200) }
        let sink = record()
        model.query = "pricing"
        try await wait(100)
        XCTAssertEqual(model.hits.map(\.id), [107, 300], "keyword results at the budget while the model is busy")
        XCTAssertFalse(model.gridShown)
        try await wait(200)
        XCTAssertEqual(updates, [[107, 300], [300, 207]])
        _ = sink
    }

    func testStaleAnswersAreDropped() async throws {
        source.quickDelay = .milliseconds(500)                       // keyword answers never win here
        source.fullDelay = { $0 == "pr" ? .milliseconds(150) : .milliseconds(10) }
        let sink = record()
        model.query = "pr"
        try await wait(20)
        model.query = "pri"
        try await wait(300)
        XCTAssertEqual(source.fullCalls, ["pr", "pri"])
        XCTAssertEqual(updates, [[300, 203]], "the slow answer for “pr” arrived last and was dropped")
        _ = sink
    }

    func testGridStaysUntilTheQuerysResultsLand() async throws {
        source.recentItems = [TimedSource.hit(1, "recent one"), TimedSource.hit(2, "recent two")]
        source.fullDelay = { _ in .milliseconds(30) }
        model.reset()
        try await wait(20)
        XCTAssertTrue(model.gridShown)
        model.query = "p"
        XCTAssertTrue(model.gridShown, "no frame of recent items laid out as results")
        XCTAssertEqual(model.hits.map(\.id), [1, 2])
        try await wait(100)
        XCTAssertFalse(model.gridShown)
        XCTAssertEqual(model.hits.map(\.id), [300, 201])
        model.query = ""
        XCTAssertTrue(model.gridShown, "cached recent items come back at once")
        XCTAssertEqual(model.hits.map(\.id), [1, 2])
    }

    func testRefinementKeepsTheSelectedItem() async throws {
        source.fullDelay = { _ in .milliseconds(150) }
        model.query = "pricing"
        try await wait(80)
        XCTAssertEqual(model.hits.map(\.id), [107, 300])
        _ = model.handle(.down)                                       // arrowing through the keyword results
        XCTAssertEqual(model.selectedHit?.id, 300)
        try await wait(150)
        XCTAssertEqual(model.hits.map(\.id), [300, 207])
        XCTAssertEqual(model.selectedHit?.id, 300, "refinement moved it; the selection followed")
        model.query = "pricing t"
        try await wait(250)
        XCTAssertEqual(model.selection, 0, "a new query starts at the top")
    }

    func testShowAllLoadsPagesAsTheGridScrolls() async throws {
        source.recentItems = (1...300).map { TimedSource.hit(Int64($0), "item \($0)") }
        model.reset()
        try await wait(20)
        XCTAssertEqual(model.hits.count, RecallViewModel.recentLimit)
        XCTAssertTrue(model.handle(.cmdR))
        try await wait(20)
        XCTAssertEqual(model.hits.count, RecallViewModel.allPageSize)
        model.loadMoreIfNeeded(after: model.hits[10])
        try await wait(20)
        XCTAssertEqual(model.hits.count, RecallViewModel.allPageSize, "only near the end")
        model.loadMoreIfNeeded(after: model.hits.last!)
        try await wait(20)
        XCTAssertEqual(model.hits.count, 2 * RecallViewModel.allPageSize)
        XCTAssertTrue(model.handle(.cmdR))
        try await wait(20)
        XCTAssertEqual(model.hits.count, RecallViewModel.recentLimit)
    }

    func testClearingTheQueryOnAnEmptyLibraryShowsTheGridAgain() async throws {
        let data = MockRecallDataSource()
        data.recentHits = []
        data.results = []
        model = RecallViewModel(dataSource: data, actions: FakeActions())
        model.reset()
        try await wait(20)
        model.query = "x"
        try await wait(20)
        XCTAssertFalse(model.gridShown)
        model.query = ""
        try await wait(20)
        XCTAssertTrue(model.gridShown)
        XCTAssertEqual(model.emptyMessage, "Nothing kept yet. Press ⌃⌥S on anything.")
    }

    // MARK: Hints say what the keys do

    func testCountLineAndPreviewHint() async throws {
        source.totalCount = 1284
        XCTAssertEqual(model.countLine, "1,284 kept")
        source.recentItems = [TimedSource.hit(1, "note"), TimedSource.hit(2, "shot", kind: .screenshot)]
        source.files[2] = URL(filePath: "/tmp/shot.png")
        model.reset()
        try await wait(20)
        XCTAssertFalse(model.canPreview, "text has no file for Quick Look")
        _ = model.handle(.right)
        XCTAssertTrue(model.canPreview)
        model.query = "shot"
        try await wait(80)
        XCTAssertFalse(model.canPreview, "Space types a space until the arrows are used")
    }

    func testOpenSendsLinksToTheBrowserNotTheirScreenshot() async throws {
        let actions = OpenRecorder()
        model = RecallViewModel(dataSource: source, actions: actions)
        source.recentItems = [TimedSource.hit(1, "Stripe Docs", kind: .link, url: "https://stripe.com/docs")]
        source.files[1] = URL(filePath: "/tmp/page.png")
        model.reset()
        try await wait(20)
        XCTAssertNotNil(model.openAppName(for: model.hits[0]))
        model.open()
        XCTAssertEqual(actions.openedFiles, [nil])
    }

    func testTextOpensInTheTextEditorNotTheAppItCameFrom() {
        var item = TimedSource.hit(1, "Flight confirmation")
        item.item.sourceApp = "Mail"
        let app = model.openAppName(for: item)
        XCTAssertNotNil(app)
        XCTAssertNotEqual(app, "Mail")
    }

    // MARK: Panel

    func testPanelOpensOnTheRecentGridInItsFirstFrame() async throws {
        source.recentItems = [TimedSource.hit(1, "recent")]
        let controller = RecallPanelController(dataSource: source, actions: FakeActions())
        controller.testOrigin = NSPoint(x: -10_000, y: -10_000)
        defer { controller.hide() }
        try await wait(50)
        controller.show()
        controller.model.query = "pricing"
        try await wait(100)
        XCTAssertFalse(controller.model.gridShown)
        controller.hide()
        controller.show()                       // reopened right away, before the deferred reset
        XCTAssertTrue(controller.model.gridShown)
        XCTAssertEqual(controller.model.query, "")
        XCTAssertEqual(controller.model.hits.map(\.id), [1])
        controller.model.query = "pricing"
        try await wait(100)
        controller.hide()
        try await wait(600)
        XCTAssertTrue(controller.model.gridShown, "reset while hidden, so opening only puts it on screen")
        XCTAssertEqual(controller.model.query, "")
    }
}

@MainActor
private final class OpenRecorder: RecallActions {
    var openedFiles: [URL?] = []
    func paste(_ hit: SearchHit, fileURL: URL?) async -> Bool { true }
    func copy(_ hit: SearchHit, fileURL: URL?) {}
    func open(_ hit: SearchHit, fileURL: URL?) { openedFiles.append(fileURL) }
}

@MainActor
final class ThumbnailCacheTests: XCTestCase {
    private func jpeg(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "thumb-\(UUID()).jpg")
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDecodesAtTheDrawnSizeAndCaches() async throws {
        let url = try jpeg(width: 400, height: 260)
        XCTAssertNil(ThumbnailCache.cached(url, maxPixels: ThumbnailCache.rowPixels))
        let row = await ThumbnailCache.load(url, maxPixels: ThumbnailCache.rowPixels)
        XCTAssertEqual(row?.size.width, 120, "rows decode a 120 px copy, not the full thumbnail")
        XCTAssertEqual(row?.size.height, 78)
        XCTAssertTrue(ThumbnailCache.cached(url, maxPixels: ThumbnailCache.rowPixels) === row)
        XCTAssertNil(ThumbnailCache.cached(url, maxPixels: ThumbnailCache.largePixels), "sizes are cached apart")
        XCTAssertEqual(ThumbnailCache.image(url)?.size.width, 400, "never scaled up")
    }

    func testConcurrentLoadsShareOneDecode() async throws {
        let url = try jpeg(width: 400, height: 260)
        async let a = ThumbnailCache.load(url, maxPixels: ThumbnailCache.largePixels)
        async let b = ThumbnailCache.load(url, maxPixels: ThumbnailCache.largePixels)
        let (first, second) = await (a, b)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testMissingFileIsNil() async {
        let url = URL(filePath: "/nonexistent/\(UUID()).jpg")
        let image = await ThumbnailCache.load(url, maxPixels: ThumbnailCache.rowPixels)
        XCTAssertNil(image)
        XCTAssertNil(ThumbnailCache.image(url))
    }
}
