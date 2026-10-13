import XCTest
@testable import DaemonCore

final class SearchVectorIndexTests: XCTestCase {
    private func randomUnit(_ d: Int, _ rng: inout some RandomNumberGenerator) -> [Float] {
        let v = (0..<d).map { _ in Float.random(in: -1...1, using: &rng) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    func testMatchesNaiveDotProducts() {
        var rng = SystemRandomNumberGenerator()
        let index = VectorIndex()
        // 2500 rows spans several 1024-row blocks, including a partial last one.
        let vectors = (0..<2500).map { _ in randomUnit(768, &rng) }
        for (i, v) in vectors.enumerated() { index.add(segmentId: Int64(i), itemId: Int64(i), vector: v) }
        XCTAssertEqual(index.count, 2500)

        let query = randomUnit(768, &rng)
        // Expected scores use the same Float16-rounded vectors the index stores.
        let naive = vectors.map { v in dot(query, v.map { Float(Float16($0)) }) }
        let expected = naive.sorted(by: >)
        let hits = index.search(query, limit: 10)
        XCTAssertEqual(hits.count, 10)
        // Compare scores rather than ids so summation-order rounding can't flip near-equal neighbours.
        for (hit, want) in zip(hits, expected) {
            XCTAssertEqual(hit.score, naive[Int(hit.itemId)], accuracy: 1e-4)
            XCTAssertEqual(hit.score, want, accuracy: 1e-4)
            XCTAssertEqual(hit.segmentId, hit.itemId)
        }
    }

    func testBestSegmentPerItemAndAllowedItems() {
        var rng = SystemRandomNumberGenerator()
        let index = VectorIndex()
        let query = randomUnit(768, &rng)
        let opposite = query.map { -$0 }
        // Item 1: weak page then exact page. Item 2: decent. Item 3: opposite.
        index.add(segmentId: 10, itemId: 1, vector: randomUnit(768, &rng))
        index.add(segmentId: 11, itemId: 1, vector: query)
        index.add(segmentId: 20, itemId: 2, vector: zip(query, randomUnit(768, &rng)).map { 0.7 * $0 + 0.3 * $1 })
        index.add(segmentId: 30, itemId: 3, vector: opposite.map { Float16($0) })

        let hits = index.search(query, limit: 10)
        XCTAssertEqual(hits.map(\.itemId), [1, 2, 3])
        XCTAssertEqual(hits[0].segmentId, 11)
        XCTAssertEqual(hits[0].score, 1, accuracy: 1e-3)

        XCTAssertEqual(index.search(query, limit: 1).map(\.itemId), [1])
        XCTAssertEqual(index.search(query, limit: 10, allowedItems: [2, 3]).map(\.itemId), [2, 3])
        XCTAssertEqual(index.search(query, limit: 10, allowedItems: []).count, 0)
    }

    func testRemoveItemAndBadDimension() {
        var rng = SystemRandomNumberGenerator()
        let index = VectorIndex()
        let a = randomUnit(768, &rng), b = randomUnit(768, &rng)
        index.add(segmentId: 1, itemId: 1, vector: a)
        index.add(segmentId: 2, itemId: 2, vector: b)
        index.add(segmentId: 3, itemId: 1, vector: randomUnit(768, &rng))
        XCTAssertFalse(index.add(segmentId: 4, itemId: 4, vector: [Float](repeating: 0, count: 10)))

        index.removeItem(1)
        XCTAssertEqual(index.count, 1)
        let hits = index.search(a, limit: 10)
        XCTAssertEqual(hits.map(\.itemId), [2])
        XCTAssertEqual(hits[0].segmentId, 2)
        // The surviving row moved down; its vector must have moved with it.
        XCTAssertEqual(index.search(b, limit: 1)[0].score, 1, accuracy: 1e-3)

        index.removeItem(2)
        XCTAssertEqual(index.count, 0)
        XCTAssertTrue(index.search(a, limit: 10).isEmpty)
    }

    func testPerformance100kSegments() {
        let n = 100_000, d = 768
        var rng = SystemRandomNumberGenerator()
        let index = VectorIndex()
        // Shifted windows over one random pool: distinct vectors without generating 77M randoms.
        // 4 segments per item -> 25k items, exercising the best-per-item reduction.
        let pool = (0..<(d + 4096)).map { _ in Float16(Float.random(in: -0.05...0.05, using: &rng)) }
        for i in 0..<n {
            let offset = (i * 7919) % 4096
            index.add(segmentId: Int64(i), itemId: Int64(i / 4), vector: Array(pool[offset..<offset + d]))
        }
        let query = randomUnit(d, &rng)
        _ = index.search(query, limit: 50)   // warm up

        let runs = 5
        let start = Date()
        for _ in 0..<runs { XCTAssertEqual(index.search(query, limit: 50).count, 50) }
        let ms = Date().timeIntervalSince(start) / Double(runs) * 1000
        print("VectorIndex.search over \(n) x \(d) Float16: \(String(format: "%.2f", ms)) ms per query")
        XCTAssertLessThan(ms, 1000)
    }
}
