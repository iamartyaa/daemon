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
