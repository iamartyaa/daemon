import Foundation
import UniformTypeIdentifiers

/// The app's core: Capture keeps into it, the Recall panel reads from it.
@MainActor
public final class Engine: CaptureSink, RecallDataSource {
    public let library: Library
    public let stats: UsageStats
    private let embedder: any Embedder
    private let pipeline: Pipeline
    let index = VectorIndex()
    private var hidden: Set<Int64> = []            // deleted, waiting out the 5 s undo window
    private var pendingDeletes: [Int64: Task<Void, Never>] = [:]
    public private(set) var totalCount = 0
    public private(set) var todayCount = 0

    /// ⌘V inside the panel; set by the app (Capture reads the clipboard).
    public var onKeepClipboard: (() -> Void)?
    /// Fires after anything changes the counts (menu bar header).
    public var onCountsChanged: ((_ total: Int, _ today: Int) -> Void)?

    nonisolated static let resultLimit = 50
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

    /// Keyword and meaning, merged. The query vector comes from a small cache or the model; the rest runs off the
    /// main thread, so typing and drawing never wait on it.
    public func search(_ query: String) async throws -> [SearchHit] {
        try await search(query, semantic: true)
    }

    /// Keyword results only, no model call: a few milliseconds, cheap enough for every keystroke. The Recall panel
    /// shows these when `search` hasn't answered within its budget (model busy indexing, or still cold).
    public func quickSearch(_ query: String) async throws -> [SearchHit] {
        try await search(query, semantic: false)
    }

    private func search(_ query: String, semantic: Bool) async throws -> [SearchHit] {
        let total = semantic ? Perf.begin("engine search") : Perf.begin("engine quick search")
        defer { total.end() }
        let parsed = QueryParser.parse(query)
        let filters = parsed.filters
        let text = parsed.text.trimmingCharacters(in: .whitespaces)
        let hasFilters = !filters.kinds.isEmpty || !filters.sources.isEmpty || filters.dateRange != nil
        let library = self.library, index = self.index, hidden = self.hidden

        guard !text.isEmpty else {
            // Filters only ("images last week"): newest first.
            guard hasFilters else { return try await recent(limit: Self.resultLimit) }
            let allowed = await library.itemIds(matching: filters).subtracting(hidden)
            let items = await library.items(ids: Array(allowed)).sorted { $0.createdAt > $1.createdAt }
            return items.prefix(Self.resultLimit).map { SearchHit(item: $0, score: 0) }
        }

        // The keyword search and the query vector don't depend on each other: run them together.
        async let keywordHits = Perf.measure("keyword search") {
            await library.keywordSearch(text, filters: filters, limit: Self.resultLimit)
        }
        var vector: [Float]?
        if semantic, Self.wantsMeaning(text) { vector = await queryVector(text) }   // nil: no model yet, keyword only
        var semanticHits: [(itemId: Int64, segmentId: Int64, score: Float)] = []
        if let vector {
            let allowed = hasFilters ? await library.itemIds(matching: filters) : nil
            semanticHits = await Self.vectorSearch(index, vector, allowed: allowed)
        }
        let keyword = await keywordHits
        try Task.checkCancellation()   // superseded by the next keystroke: skip the merge
        let semanticResult = semanticHits
        return await Perf.measure("merge") {
            await Self.hits(library: library, hidden: hidden, semantic: semanticResult, keyword: keyword)
        }
    }

    /// One or two Latin letters ("p", "pr") carry no meaning to embed; keyword prefix matching covers them.
    /// Other scripts pack meaning into fewer characters ("京都"), so they always get a vector.
    nonisolated static func wantsMeaning(_ text: String) -> Bool {
        text.count >= 3 || !text.allSatisfy(\.isASCII)
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
        let semantic = await Self.vectorSearch(index, vector, allowed: nil)
        return await Self.hits(library: library, hidden: hidden, semantic: semantic, keyword: [])
    }

    // MARK: Query vectors

    static let queryCacheLimit = 128
    private var queryCache: [String: [Float]] = [:]
    private var queryCacheOrder: [String] = []
    private var embedding: Task<[Float]?, Never>?

    /// Recent queries come from the cache (backspacing, reopening the panel). Otherwise one request is in flight at a
    /// time: a query typed while the model is busy waits for that one, and if a newer keystroke cancels it meanwhile,
    /// it never reaches the model. So fast typing can't pile requests up behind each other.
    func queryVector(_ text: String) async -> [Float]? {
        if let cached = queryCache[text] { return cached }
        while let running = embedding {
            _ = await running.value
            if Task.isCancelled { return nil }
            if let cached = queryCache[text] { return cached }
        }
        let embedder = self.embedder
        let task = Task { [weak self] () -> [Float]? in
            let vector = try? await Perf.measure("embed query") { try await embedder.embed(.query(text)) }
            self?.embedding = nil
            if let vector { self?.remember(text, vector) }
            return vector
        }
        embedding = task
        return await task.value
    }

    private func remember(_ text: String, _ vector: [Float]) {
        if queryCache.updateValue(vector, forKey: text) == nil { queryCacheOrder.append(text) }
        if queryCacheOrder.count > Self.queryCacheLimit { queryCache[queryCacheOrder.removeFirst()] = nil }
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

    // MARK: Retention

    /// Removes everything older than the policy's window (any status), then leftover temp files.
    /// VACUUMs after a large purge so the database file shrinks too.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date = Date(),
                               leftoverDirs: [URL] = Leftovers.defaultDirs) async -> PurgeResult {
        var result = PurgeResult()
        do {
            let removed = try await library.purge(before: policy.cutoff(now: now))
            index.removeItems(Set(removed.ids))
            for id in removed.ids {
                pendingDeletes.removeValue(forKey: id)?.cancel()
                hidden.remove(id)
            }
            result = PurgeResult(items: removed.ids.count, bytes: removed.bytes)
            if result.items > Self.vacuumThreshold { try await library.vacuum() }
        } catch {
            retentionLog.error("Purge failed: \(error.localizedDescription, privacy: .public)")
        }
        result.bytes += Leftovers.sweep(leftoverDirs, now: now)
        if result.items > 0 { await refreshCounts() }
        retentionLog.info("Kept \(policy.days) days: removed \(result.items) items, \(result.bytes) bytes")
        return result
    }

    static let vacuumThreshold = 50

    // MARK: Helpers

    /// Brute-force search always returns the nearest items, related or not. Unrelated items cluster around
    /// 0.52–0.66 cosine for this model; real matches sit clearly above that cluster. Keep hits within 0.10 of the
    /// best and above one standard deviation over the mean. Small result sets have no cluster to measure.
    nonisolated static func relevant(_ semantic: [(itemId: Int64, segmentId: Int64, score: Float)])
        -> [(itemId: Int64, segmentId: Int64, score: Float)] {
        guard semantic.count >= 5, let best = semantic.map(\.score).max() else { return semantic }
        let n = Float(semantic.count)
        let mean = semantic.reduce(0) { $0 + $1.score } / n
        let sd = (semantic.reduce(0) { $0 + ($1.score - mean) * ($1.score - mean) } / n).squareRoot()
        let cutoff = max(best - 0.10, mean + sd)
        return semantic.filter { $0.score >= cutoff }
    }

    /// Brute-force scan of every stored vector; off the main thread, since it grows with the library.
    private nonisolated static func vectorSearch(_ index: VectorIndex, _ vector: [Float], allowed: Set<Int64>?) async
        -> [(itemId: Int64, segmentId: Int64, score: Float)] {
        Perf.measure("vector search") { relevant(index.search(vector, limit: resultLimit, allowedItems: allowed)) }
    }

    /// Off the main thread: one items read, and the matched segments read together rather than a round trip each.
    private nonisolated static func hits(library: Library, hidden: Set<Int64>,
                                         semantic: [(itemId: Int64, segmentId: Int64, score: Float)],
                                         keyword: [(itemId: Int64, score: Double)]) async -> [SearchHit] {
        let ids = Array(Set(semantic.map(\.itemId) + keyword.map(\.itemId)).subtracting(hidden))
        let items = Dictionary(uniqueKeysWithValues: await library.items(ids: ids).compactMap { i in i.id.map { ($0, i) } })
        let merged = HybridRanker.merge(semantic: semantic.filter { items[$0.itemId] != nil },
                                        keyword: keyword.filter { items[$0.itemId] != nil },
                                        createdAt: items.mapValues(\.createdAt), now: Date(), limit: resultLimit)
        let segments = await withTaskGroup(of: (Int64, Segment?).self) { group in
            for id in Set(merged.compactMap(\.segmentId)) { group.addTask { (id, await library.segment(id: id)) } }
            var found: [Int64: Segment] = [:]
            for await (id, segment) in group { found[id] = segment }
            return found
        }
        return merged.compactMap { m in
            items[m.itemId].map { SearchHit(item: $0, score: m.score, matchedSegment: m.segmentId.flatMap { segments[$0] }) }
        }
    }

    private func refreshCounts() async {
        totalCount = await library.count() - hidden.count
        todayCount = await library.countToday()
        onCountsChanged?(totalCount, todayCount)
    }
}
