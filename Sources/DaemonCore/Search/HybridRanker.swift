import Foundation

/// Merges the semantic and keyword lists with Reciprocal Rank Fusion plus a small recency boost.
public enum HybridRanker {
    /// RRF constant (Cormack et al. 2009): each list contributes 1 / (k + rank), rank starting at 1.
    static let k = 60.0
    /// Recency bonus for a brand-new item, halving every `recencyHalfLife`.
    /// 0.0004 is ~2.4% of a rank-1 single-list score (1/61): enough to swap neighbours a couple of ranks
    /// apart, far below what appearing in the other list adds (>= 1/(k + rank) ≈ 0.008 for rank <= 60),
    /// and too small to lift e.g. a rank-10 hit (1/70) over a rank-1 hit (1/61).
    static let maxRecencyBoost = 0.0004
    static let recencyHalfLife: TimeInterval = 14 * 86_400

    /// Both lists must be ordered best-first (as `VectorIndex.search` and FTS5 `ORDER BY rank` return them);
    /// only positions are used, so bm25 and cosine scores need no calibration. Repeated items count once,
    /// at their best position. Keyword-only hits have a nil `segmentId`.
    public static func merge(semantic: [(itemId: Int64, segmentId: Int64, score: Float)],
                             keyword: [(itemId: Int64, score: Double)],
                             createdAt: [Int64: Date], now: Date, limit: Int)
        -> [(itemId: Int64, segmentId: Int64?, score: Double)] {
        var fused: [Int64: (segmentId: Int64?, score: Double)] = [:]

        var rank = 0.0
        for hit in semantic where fused[hit.itemId] == nil {
            rank += 1
            fused[hit.itemId] = (hit.segmentId, 1 / (k + rank))
        }
        rank = 0
        var seen = Set<Int64>()
        for hit in keyword where seen.insert(hit.itemId).inserted {
            rank += 1
            fused[hit.itemId, default: (nil, 0)].score += 1 / (k + rank)
        }

        var merged: [(itemId: Int64, segmentId: Int64?, score: Double)] = []
        for (id, hit) in fused {
            var score = hit.score
            if let created = createdAt[id] {
                let age: Double = max(0, now.timeIntervalSince(created))
                score += maxRecencyBoost * pow(0.5, age / recencyHalfLife)
            }
            merged.append((itemId: id, segmentId: hit.segmentId, score: score))
        }
        merged.sort { $0.score != $1.score ? $0.score > $1.score : $0.itemId < $1.itemId }
        return Array(merged.prefix(max(0, limit)))
    }
}
