import Accelerate
import Foundation

/// Exact (brute-force) cosine search over L2-normalized segment vectors stored at half precision.
// ponytail: brute-force scan, ~150 MB and ~12 ms (release, M-series) at 100k segments; revisit (IVF/HNSW or sharded scan) above 500k.
public final class VectorIndex: @unchecked Sendable {
    public let dimension: Int
    private var storage: [Float16] = []     // row-major, one row of `dimension` per segment
    private var segmentIds: [Int64] = []
    private var itemIds: [Int64] = []
    private let lock = NSLock()

    /// Rows converted to Float32 per step: 1024 × 768 × 4 B = 3 MB of scratch, regardless of index size.
    private static let blockRows = 1024

    public init(dimension: Int = 768) {
        self.dimension = dimension
    }

    public var count: Int { lock.withLock { segmentIds.count } }

    /// Returns false (and stores nothing) when the vector has the wrong dimension, e.g. a corrupt blob.
    @discardableResult
    public func add(segmentId: Int64, itemId: Int64, vector: [Float16]) -> Bool {
        guard vector.count == dimension else { return false }
        lock.withLock {
            storage.append(contentsOf: vector)
            segmentIds.append(segmentId)
            itemIds.append(itemId)
        }
        return true
    }

    @discardableResult
    public func add(segmentId: Int64, itemId: Int64, vector: [Float]) -> Bool {
        add(segmentId: segmentId, itemId: itemId, vector: vector.map { Float16($0) })
    }

    public func removeItem(_ itemId: Int64) { removeItems([itemId]) }

    /// Removes every segment of these items in one pass, compacting in place (no second copy of the buffer).
    public func removeItems(_ ids: Set<Int64>) {
        lock.withLock {
            let d = dimension, n = itemIds.count
            var kept = 0
            storage.withUnsafeMutableBufferPointer { rows in
                for r in 0..<n where !ids.contains(itemIds[r]) {
                    if kept != r {
                        (rows.baseAddress! + kept * d).update(from: rows.baseAddress! + r * d, count: d)
                        segmentIds[kept] = segmentIds[r]
                        itemIds[kept] = itemIds[r]
                    }
                    kept += 1
                }
            }
            storage.removeLast((n - kept) * d)
            segmentIds.removeLast(n - kept)
            itemIds.removeLast(n - kept)
        }
    }

    /// Best-matching segment per item, highest score first. `query` must be L2-normalized like the stored
    /// vectors, so the dot product is the cosine similarity. `allowedItems` nil = all items.
    public func search(_ query: [Float], limit: Int, allowedItems: Set<Int64>? = nil)
        -> [(itemId: Int64, segmentId: Int64, score: Float)] {
        precondition(query.count == dimension, "query has \(query.count) dims, index has \(dimension)")
        return lock.withLock {
            let n = itemIds.count, d = dimension
            guard n > 0, limit > 0 else { return [] }

            var scores = [Float](repeating: 0, count: n)
            var scratch = [Float](repeating: 0, count: Self.blockRows * d)
            storage.withUnsafeBufferPointer { src in
                scratch.withUnsafeMutableBufferPointer { tmp in
                    scores.withUnsafeMutableBufferPointer { out in
                        for start in stride(from: 0, to: n, by: Self.blockRows) {
                            let rows = min(Self.blockRows, n - start)
                            var half = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress! + start * d),
                                                     height: vImagePixelCount(rows), width: vImagePixelCount(d),
                                                     rowBytes: d * MemoryLayout<Float16>.stride)
                            var full = vImage_Buffer(data: tmp.baseAddress!,
                                                     height: vImagePixelCount(rows), width: vImagePixelCount(d),
                                                     rowBytes: d * MemoryLayout<Float>.stride)
                            vImageConvert_Planar16FtoPlanarF(&half, &full, vImage_Flags(kvImageNoFlags))
                            // (rows × d) · (d × 1) -> rows scores
                            vDSP_mmul(tmp.baseAddress!, 1, query, 1, out.baseAddress! + start, 1,
                                      vDSP_Length(rows), 1, vDSP_Length(d))
                        }
                    }
                }
            }

            var best: [Int64: Int] = [:]    // itemId -> row of its best segment
            best.reserveCapacity(n)
            for r in 0..<n {
                let id = itemIds[r]
                if let allowedItems, !allowedItems.contains(id) { continue }
                if let b = best[id], scores[b] >= scores[r] { continue }
                best[id] = r
            }
            return best.values
                .sorted { scores[$0] > scores[$1] }
                .prefix(limit)
                .map { (itemId: itemIds[$0], segmentId: segmentIds[$0], score: scores[$0]) }
        }
    }
}
