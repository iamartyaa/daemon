import Foundation
import UniformTypeIdentifiers

/// The app's core: Capture keeps into it, the Recall panel reads from it.
@MainActor
public final class Engine: CaptureSink, RecallDataSource {
    public let library: Library
    public let stats: UsageStats
    private let embedder: any Embedder
    private let pipeline: Pipeline
    private let index = VectorIndex()
    private var hidden: Set<Int64> = []            // deleted, waiting out the 5 s undo window
    private var pendingDeletes: [Int64: Task<Void, Never>] = [:]
    public private(set) var totalCount = 0
    public private(set) var todayCount = 0

    /// ⌘V inside the panel; set by the app (Capture reads the clipboard).
    public var onKeepClipboard: (() -> Void)?
    /// Fires after anything changes the counts (menu bar header).
    public var onCountsChanged: ((_ total: Int, _ today: Int) -> Void)?

    static let resultLimit = 50
    static let undoWindow: Duration = .seconds(5)

    public init(library: Library, embedder: any Embedder, stats: UsageStats = UsageStats()) {
        self.library = library
        self.embedder = embedder
        self.stats = stats
        self.pipeline = Pipeline(library: library, embedder: embedder)
    }

    /// Loads stored vectors into memory and resumes items left pending.
    public func start() async {
        for row in await library.allVectors(modelVersion: embedder.modelVersion) {
            index.add(segmentId: row.segmentId, itemId: row.itemId, vector: row.vector)
        }
        let index = self.index
        await pipeline.setOnIndexed { segmentId, itemId, vector in
            index.add(segmentId: segmentId, itemId: itemId, vector: vector)
        }
        await pipeline.resumePending()
        await refreshCounts()
    }

    public func waitUntilIdle() async { await pipeline.idle() }

    // MARK: CaptureSink

    public func keep(_ capture: Capture) async throws -> [Item] {
        let items = try await library.add(capture)
        await pipeline.enqueue(items)
        items.forEach { _ in stats.record(.keep) }
        await refreshCounts()
        return items
    }

    // MARK: RecallDataSource

    public func recent(limit: Int) async throws -> [SearchHit] {
        await library.recent(limit: limit + hidden.count)
            .filter { !hidden.contains($0.id ?? -1) }
            .prefix(limit)
            .map { SearchHit(item: $0, score: 0) }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let parsed = QueryParser.parse(query)
        let filters = parsed.filters
        let hasFilters = !filters.kinds.isEmpty || !filters.sources.isEmpty || filters.dateRange != nil
        let allowed = hasFilters ? await library.itemIds(matching: filters) : nil

        guard !parsed.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Filters only ("images last week"): newest first.
            guard let allowed else { return try await recent(limit: Self.resultLimit) }
            let items = await library.items(ids: Array(allowed)).sorted { $0.createdAt > $1.createdAt }
            return items.filter { !hidden.contains($0.id ?? -1) }.prefix(Self.resultLimit).map { SearchHit(item: $0, score: 0) }
        }

        let keyword = await library.keywordSearch(parsed.text, filters: filters, limit: Self.resultLimit)
        var semantic: [(itemId: Int64, segmentId: Int64, score: Float)] = []
        if let vector = try? await embedder.embed(.query(parsed.text)) {   // no model yet: keyword only
            semantic = index.search(vector, limit: Self.resultLimit, allowedItems: allowed)
        }
        return await hits(semantic: semantic, keyword: keyword)
    }

    public func searchSimilar(to file: URL) async throws -> [SearchHit] {
        let type = UTType(filenameExtension: file.pathExtension)
        let input: EmbedInput
        if type?.conforms(to: .image) == true {
            input = .image(file)
        } else if type?.conforms(to: .audio) == true {
            input = .audio(file)
        } else if let text = try? String(contentsOf: file, encoding: .utf8) {
            input = .document(String(text.prefix(6_000)))
        } else {
            input = .query(file.deletingPathExtension().lastPathComponent)
        }
        let vector = try await embedder.embed(input)
        return await hits(semantic: index.search(vector, limit: Self.resultLimit, allowedItems: nil), keyword: [])
    }

    public nonisolated func thumbnailURL(for item: Item) -> URL? { library.thumbnailURL(for: item) }
    public nonisolated func fileURL(for item: Item) -> URL? { library.fileURL(for: item) }

    public func delete(_ item: Item) async throws {
        guard let id = item.id else { return }
        hidden.insert(id)
        pendingDeletes[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled, let self else { return }
            self.index.removeItem(id)
            try? await self.library.delete(itemId: id)
            self.hidden.remove(id)
            self.pendingDeletes[id] = nil
            await self.refreshCounts()
        }
    }

    public func undoDelete(_ item: Item) async throws {
        guard let id = item.id else { return }
        pendingDeletes.removeValue(forKey: id)?.cancel()
        hidden.remove(id)
    }

    public func setNote(_ note: String, for item: Item) async throws {
        guard let id = item.id else { return }
        try await library.setNote(note, itemId: id)
    }

    public func keepClipboard() async throws { onKeepClipboard?() }

    // MARK: Helpers

    private func hits(semantic: [(itemId: Int64, segmentId: Int64, score: Float)],
                      keyword: [(itemId: Int64, score: Double)]) async -> [SearchHit] {
        let ids = Array(Set(semantic.map(\.itemId) + keyword.map(\.itemId)).subtracting(hidden))
        let items = Dictionary(uniqueKeysWithValues: await library.items(ids: ids).compactMap { i in i.id.map { ($0, i) } })
        let merged = HybridRanker.merge(semantic: semantic.filter { items[$0.itemId] != nil },
                                        keyword: keyword.filter { items[$0.itemId] != nil },
                                        createdAt: items.mapValues(\.createdAt), now: Date(), limit: Self.resultLimit)
        var result: [SearchHit] = []
        for m in merged {
            guard let item = items[m.itemId] else { continue }
            let segment: Segment? = if let s = m.segmentId { await library.segment(id: s) } else { nil }
            result.append(SearchHit(item: item, score: m.score, matchedSegment: segment))
        }
        return result
    }

    private func refreshCounts() async {
        totalCount = await library.count() - hidden.count
        todayCount = await library.countToday()
        onCountsChanged?(totalCount, todayCount)
    }
}
