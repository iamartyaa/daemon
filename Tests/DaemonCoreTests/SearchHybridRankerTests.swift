import XCTest
@testable import DaemonCore

final class SearchHybridRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { now.addingTimeInterval(-365 * 86_400) }

    func testItemInBothListsBeatsSingleListHits() {
        let r = HybridRanker.merge(
            semantic: [(1, 10, 0.9), (2, 20, 0.8), (3, 30, 0.7)],
            keyword: [(4, -9), (5, -8), (3, -7)],
            createdAt: [1: old, 2: old, 3: old, 4: now, 5: now], now: now, limit: 10)
        XCTAssertEqual(r.first?.itemId, 3)
        XCTAssertEqual(r.first?.segmentId, 30)
        XCTAssertEqual(r.count, 5)
        // Keyword-only hits carry no segment.
        XCTAssertNil(r.first { $0.itemId == 4 }?.segmentId)
        XCTAssertEqual(r.first { $0.itemId == 1 }?.segmentId, 10)
    }

    func testRecencyBreaksTiesOnly() {
        // Tie: both rank 1 in one list each. The newer one wins.
        let tie = HybridRanker.merge(semantic: [(1, 10, 0.9)], keyword: [(2, 1)],
                                     createdAt: [1: old, 2: now], now: now, limit: 10)
        XCTAssertEqual(tie.map(\.itemId), [2, 1])

        // A fresh rank-10 hit must not pass an old rank-1 hit.
        let semantic = (1...10).map { (itemId: Int64($0), segmentId: Int64($0), score: Float(1) - Float($0) / 100) }
        let r = HybridRanker.merge(semantic: semantic, keyword: [],
                                   createdAt: [1: old, 10: now], now: now, limit: 10)
        XCTAssertEqual(r.first?.itemId, 1)

        // Neighbouring ranks are near-ties: a fresh rank-2 overtakes an old rank-1.
        let near = HybridRanker.merge(semantic: [(1, 1, 0.9), (2, 2, 0.89)], keyword: [],
                                      createdAt: [1: old, 2: now], now: now, limit: 10)
        XCTAssertEqual(near.map(\.itemId), [2, 1])
    }

    func testLimitAndDuplicateKeywordRows() {
        let semantic = (1...20).map { (itemId: Int64($0), segmentId: Int64($0), score: Float(0.5)) }
        XCTAssertEqual(HybridRanker.merge(semantic: semantic, keyword: [], createdAt: [:], now: now, limit: 5).count, 5)
        XCTAssertTrue(HybridRanker.merge(semantic: semantic, keyword: [], createdAt: [:], now: now, limit: 0).isEmpty)

        // FTS can return the same item for several segments; it counts once at its best rank.
        let r = HybridRanker.merge(semantic: [], keyword: [(7, 1), (7, 1), (8, 1)],
                                   createdAt: [:], now: now, limit: 10)
        XCTAssertEqual(r.map(\.itemId), [7, 8])
        XCTAssertEqual(r[1].score, 1 / 62, accuracy: 1e-12)
    }
}
