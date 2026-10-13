import Foundation

/// Kept item -> segments -> vectors -> ready (PRD "Processing pipeline").
/// Items are processed one at a time in arrival order; the model process is single-threaded anyway.
public actor Pipeline {
    private let library: Library
    private let embedder: any Embedder
    private let extractor = Extractor()
    private let workRoot: URL
    private var onIndexed: (@Sendable (_ segmentId: Int64, _ itemId: Int64, _ vector: [Float]) -> Void)?
    private var queue: [Item] = []
    private var running = false

    public init(library: Library, embedder: any Embedder,
                workRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DaemonWork")) {
        self.library = library
        self.embedder = embedder
        self.workRoot = workRoot
    }

    /// Called for each stored vector so the in-memory index can add it.
    public func setOnIndexed(_ handler: @escaping @Sendable (Int64, Int64, [Float]) -> Void) {
        onIndexed = handler
    }

    public func enqueue(_ items: [Item]) {
        queue.append(contentsOf: items)
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    /// Picks up items left pending by a quit or crash.
    public func resumePending() async {
        enqueue(await library.pendingItems())
    }

    /// Waits until everything enqueued so far is processed (tests, quit).
    public func idle() async {
        while running || !queue.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func drain() async {
        while !queue.isEmpty {
            await process(queue.removeFirst())
        }
        running = false
    }

    private func process(_ item: Item) async {
        guard let itemId = item.id else { return }
        let work = workRoot.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let drafts = try await extractor.segments(for: item, fileURL: library.fileURL(for: item), workDir: work)
            // Embed everything before writing, so a failure leaves no half-indexed item behind.
            var vectors: [[Float]?] = []
            for draft in drafts {
                if let input = draft.input {
                    vectors.append(try await embedder.embed(input))
                } else {
                    vectors.append(nil)
                }
            }
            let saved = try await library.saveSegments(drafts.map(\.segment))
            for (segment, vector) in zip(saved, vectors) {
                guard let vector, let segmentId = segment.id else { continue }
                try await library.saveVector(vector, segmentId: segmentId, modelVersion: embedder.modelVersion)
                onIndexed?(segmentId, itemId, vector)
            }
            try await library.setStatus(.ready, itemId: itemId)
        } catch {
            try? await library.setStatus(.failed, itemId: itemId)
        }
    }
}
