import XCTest
@testable import DaemonCore

/// Deterministic stand-in for the model: hashes words into a 768-d unit vector.
struct FakeEmbedder: Embedder {
    var modelVersion: String { "fake-1" }
    var failOn: String? = nil

    func embed(_ input: EmbedInput) async throws -> [Float] {
        let text: String
        switch input {
        case .query(let s), .document(let s): text = s
        case .image(let u), .audio(let u): text = u.lastPathComponent
        }
        if let failOn, text.contains(failOn) { throw CocoaError(.fileReadCorruptFile) }
        var v = [Float](repeating: 0, count: 768)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            v[abs(word.hashValue) % 768] += 1
        }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm == 0 ? v : v.map { $0 / norm }
    }
}

final class PipelineTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineTests-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testTextItemBecomesReadyWithVectors() async throws {
        let library = try Library(root: root.appendingPathComponent("lib"))
        let pipeline = Pipeline(library: library, embedder: FakeEmbedder(), workRoot: root.appendingPathComponent("work"))
        let indexed = Counter()
        await pipeline.setOnIndexed { _, _, _ in indexed.add() }

        let items = try await library.add(Capture(payload: .text("Use host.docker.internal from a container"),
                                                  context: CaptureContext(sourceApp: "Safari")))
        await pipeline.enqueue(items)
        await pipeline.idle()

        let item = await library.item(id: items[0].id!)
        let vectors = await library.allVectors(modelVersion: "fake-1")
        XCTAssertEqual(item?.status, .ready)
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(indexed.value, 1)
    }

    func testEmbedFailureMarksFailedWithoutPartialSegments() async throws {
        let library = try Library(root: root.appendingPathComponent("lib"))
        let pipeline = Pipeline(library: library, embedder: FakeEmbedder(failOn: "boom"),
                                workRoot: root.appendingPathComponent("work"))
        let items = try await library.add(Capture(payload: .text("this will boom"), context: CaptureContext()))
        await pipeline.enqueue(items)
        await pipeline.idle()

        let item = await library.item(id: items[0].id!)
        let segments = await library.segments(itemId: items[0].id!)
        XCTAssertEqual(item?.status, .failed)
        XCTAssertTrue(segments.isEmpty)
    }

    func testResumePendingProcessesLeftovers() async throws {
        let library = try Library(root: root.appendingPathComponent("lib"))
        _ = try await library.add(Capture(payload: .text("left pending by a quit"), context: CaptureContext()))
        let pipeline = Pipeline(library: library, embedder: FakeEmbedder(), workRoot: root.appendingPathComponent("work"))
        await pipeline.resumePending()
        await pipeline.idle()
        let pending = await library.pendingItems()
        XCTAssertTrue(pending.isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
