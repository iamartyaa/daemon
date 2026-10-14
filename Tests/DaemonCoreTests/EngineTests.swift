import XCTest
@testable import DaemonCore

@MainActor
final class EngineTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineTests-\(UUID())")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine() async throws -> Engine {
        let defaults = UserDefaults(suiteName: "EngineTests-\(UUID())")!
        let engine = Engine(library: try Library(root: root), embedder: FakeEmbedder(), stats: UsageStats(defaults: defaults))
        await engine.start()
        return engine
    }

    private func keepText(_ engine: Engine, _ text: String, app: String = "Safari") async throws -> Item {
        try await engine.keep(Capture(payload: .text(text), context: CaptureContext(sourceApp: app, sourceBundleID: "com.test.\(app)")))[0]
    }

    func testKeepThenRecallFindsByMeaningAndKeyword() async throws {
        let engine = try await makeEngine()
        _ = try await keepText(engine, "Use host docker internal to reach the host from a container")
        let pricing = try await keepText(engine, "Default to yearly billing, show the monthly price small", app: "Figma")
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.totalCount, 2)
        let hits = try await engine.search("yearly monthly billing")
        XCTAssertEqual(hits.first?.item.id, pricing.id)
        XCTAssertNotNil(hits.first?.matchedSegment)

        let filtered = try await engine.search("from:figma")
        XCTAssertEqual(filtered.map(\.item.id), [pricing.id])
    }

    func testDeleteHidesImmediatelyAndUndoRestores() async throws {
        let engine = try await makeEngine()
        let item = try await keepText(engine, "warranty for the laptop")
        await engine.waitUntilIdle()

        try await engine.delete(item)
        let afterDelete = try await engine.search("laptop warranty")
        XCTAssertTrue(afterDelete.isEmpty)

        try await engine.undoDelete(item)
        let afterUndo = try await engine.search("laptop warranty")
        XCTAssertEqual(afterUndo.first?.item.id, item.id)
    }

    func testVectorsReloadAfterRestart() async throws {
        do {
            let engine = try await makeEngine()
            _ = try await keepText(engine, "the caching idea for the catalog API")
            await engine.waitUntilIdle()
        }
        let restarted = try await makeEngine()
        let hits = try await restarted.search("caching idea")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(restarted.totalCount, 1)
    }
}

final class RelevanceCutoffTests: XCTestCase {
    private func rows(_ scores: [Float]) -> [(itemId: Int64, segmentId: Int64, score: Float)] {
        scores.enumerated().map { (Int64($0.offset), Int64($0.offset), $0.element) }
    }

    func testKeepsClearMatchesAndDropsTheUnrelatedCluster() {
        // Real cosine scores for "pricing yearly" and "car" in a 10-item library.
        let pricing = Engine.relevant(rows([0.842, 0.693, 0.654, 0.607, 0.602, 0.563, 0.553, 0.552, 0.551, 0.550]))
        XCTAssertEqual(pricing.map(\.itemId), [0])
        let car = Engine.relevant(rows([0.715, 0.702, 0.691, 0.636, 0.625, 0.599, 0.596, 0.588, 0.581, 0.525]))
        XCTAssertEqual(car.first?.itemId, 0)
        XCTAssertLessThanOrEqual(car.count, 3)
    }

    func testSmallSetsAreKeptWhole() {
        XCTAssertEqual(Engine.relevant(rows([0.8, 0.5, 0.4])).count, 3)
    }
}

/// Counts query embeddings; each takes `delay`, like the model.
final class CountingEmbedder: Embedder, @unchecked Sendable {
    let modelVersion = "fake-1"
    var delay: Duration = .zero
    private let lock = NSLock()
    private var calls: [String] = []
    var queries: [String] { lock.withLock { calls } }

    func embed(_ input: EmbedInput) async throws -> [Float] {
        if case .query(let text) = input {
            lock.withLock { calls.append(text) }
            try? await Task.sleep(for: delay)
        }
        return try await FakeEmbedder().embed(input)
    }
}

@MainActor
final class EngineQueryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineQueryTests-\(UUID())")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine(_ embedder: CountingEmbedder) async throws -> Engine {
        let engine = Engine(library: try Library(root: root), embedder: embedder,
                            stats: UsageStats(defaults: UserDefaults(suiteName: "EngineQueryTests-\(UUID())")!))
        await engine.start()
        _ = try await engine.keep(Capture(payload: .text("Default to yearly billing, show the monthly price small"),
                                          context: CaptureContext(sourceApp: "Figma")))
        await engine.waitUntilIdle()
        return engine
    }

    func testRepeatedQueriesUseTheCachedVector() async throws {
        let embedder = CountingEmbedder()
        let engine = try await makeEngine(embedder)
        let before = embedder.queries.count
        let first = try await engine.search("yearly billing")
        let again = try await engine.search("yearly billing")
        XCTAssertEqual(embedder.queries.count - before, 1)
        XCTAssertEqual(first.map(\.id), again.map(\.id))
        XCTAssertFalse(first.isEmpty)
    }

    func testShortAndQuickSearchesNeverWaitForTheModel() async throws {
        let embedder = CountingEmbedder()
        let engine = try await makeEngine(embedder)
        let before = embedder.queries.count
        let short = try await engine.search("ye")
        let quick = try await engine.quickSearch("yearly billing")
        XCTAssertEqual(embedder.queries.count, before, "1–2 Latin letters and keyword-only searches skip the model")
        XCTAssertEqual(short.first?.item.sourceApp, "Figma", "prefix keyword match")
        XCTAssertEqual(quick.first?.item.sourceApp, "Figma")
        XCTAssertTrue(Engine.wantsMeaning("京都"), "other scripts carry meaning in fewer characters")
        XCTAssertFalse(Engine.wantsMeaning("ye"))
    }

    func testFastTypingSendsOnlyTheLatestQueryToABusyModel() async throws {
        let embedder = CountingEmbedder()
        let engine = try await makeEngine(embedder)
        embedder.delay = .milliseconds(80)
        let before = embedder.queries.count
        // "yea" is in flight; "year" and "yearl" wait and are superseded (cancelled) before the model is free.
        var tasks: [Task<[SearchHit]?, Never>] = []
        for prefix in ["yea", "year", "yearl", "yearly"] {
            tasks.last?.cancel()
            tasks.append(Task { try? await engine.search(prefix) })
            try await Task.sleep(for: .milliseconds(10))
        }
        let latest = await tasks.last!.value
        XCTAssertEqual(Array(embedder.queries.dropFirst(before)), ["yea", "yearly"])
        XCTAssertEqual(latest?.first?.item.sourceApp, "Figma")
    }
}
