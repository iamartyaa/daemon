import Foundation

// Shared types between modules. Owned by integration: agents read these, they don't edit them.
// Shapes follow the PRD "Data model" section (items, segments, vectors, search_text).

// MARK: - Items and segments

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case text, image, screenshot, voice, audio, video, pdf, file, link
}

public enum ItemStatus: String, Codable, Sendable {
    case pending, ready, failed
}

public enum Modality: String, Codable, Sendable {
    case text, image, audio, video
}

/// What the user kept. `text` holds the saved text for text items and links (page title),
/// and is the first-line source for result titles.
public struct Item: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var kind: ItemKind
    public var createdAt: Date
    public var sourceApp: String?        // display name, e.g. "Safari"
    public var sourceBundleID: String?   // e.g. "com.apple.Safari"; used by from: filters
    public var windowTitle: String?
    public var url: String?
    public var note: String?
    public var text: String?
    public var fileHash: String?         // SHA-256 hex of stored content; nil for pure text
    public var fileExtension: String?
    public var originalPath: String?
    public var isReference: Bool         // true when > 500 MB: original path kept, no copy
    public var mime: String?
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var status: ItemStatus

    public init(id: Int64? = nil, kind: ItemKind, createdAt: Date = Date(), sourceApp: String? = nil,
                sourceBundleID: String? = nil, windowTitle: String? = nil, url: String? = nil, note: String? = nil,
                text: String? = nil, fileHash: String? = nil, fileExtension: String? = nil, originalPath: String? = nil,
                isReference: Bool = false, mime: String? = nil, bytes: Int64? = nil, width: Int? = nil,
                height: Int? = nil, durationMs: Int? = nil, status: ItemStatus = .pending) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID; self.windowTitle = windowTitle; self.url = url; self.note = note
        self.text = text; self.fileHash = fileHash; self.fileExtension = fileExtension; self.originalPath = originalPath
        self.isReference = isReference; self.mime = mime; self.bytes = bytes; self.width = width
        self.height = height; self.durationMs = durationMs; self.status = status
    }
}

/// A searchable piece of an item: a text chunk, a PDF page, an image, an audio/video window.
public struct Segment: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var itemId: Int64
    public var modality: Modality
    public var page: Int?
    public var startMs: Int?
    public var endMs: Int?
    public var text: String?             // chunk text, or OCR text for images/scanned pages

    public init(id: Int64? = nil, itemId: Int64, modality: Modality, page: Int? = nil,
                startMs: Int? = nil, endMs: Int? = nil, text: String? = nil) {
        self.id = id; self.itemId = itemId; self.modality = modality; self.page = page
        self.startMs = startMs; self.endMs = endMs; self.text = text
    }
}

// MARK: - Capture -> Library

/// Context captured automatically with every keep (PRD "Save experience").
public struct CaptureContext: Codable, Hashable, Sendable {
    public var createdAt: Date
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var windowTitle: String?
    public var url: String?

    public init(createdAt: Date = Date(), sourceApp: String? = nil, sourceBundleID: String? = nil,
                windowTitle: String? = nil, url: String? = nil) {
        self.createdAt = createdAt; self.sourceApp = sourceApp; self.sourceBundleID = sourceBundleID
        self.windowTitle = windowTitle; self.url = url
    }
}

/// One thing handed to Daemon. File payloads point at a file Capture owns (temp) or the user's original.
public enum CapturePayload: Sendable, Hashable {
    case text(String)
    case files([URL])                                  // Finder selection or drop; one item per file
    case screenshot(URL)                               // PNG written by Capture
    case voiceNote(URL)                                // audio file written by Capture
    case link(url: URL, title: String?, screenshot: URL?)
}

public struct Capture: Sendable, Hashable {
    public var payload: CapturePayload
    public var context: CaptureContext
    public init(payload: CapturePayload, context: CaptureContext) {
        self.payload = payload; self.context = context
    }
}

/// Where Capture sends things. Integration implements it (Library + pipeline).
public protocol CaptureSink: AnyObject, Sendable {
    /// Returns the kept items (several for a multi-file Finder selection) for the toast.
    func keep(_ capture: Capture) async throws -> [Item]
}

// MARK: - Extract -> Embed

/// One unit the model embeds. Text gets the model-card prefixes inside the embedder, not here.
public enum EmbedInput: Sendable, Hashable {
    case query(String)                  // "task: search result | query: "
    case document(String)               // "title: none | text: "
    case image(URL)                     // PNG/JPEG on disk, no prefix
    case audio(URL)                     // 16 kHz mono WAV on disk, <= 60 s, no prefix
}

public struct SegmentDraft: Sendable, Hashable {
    public var segment: Segment         // id nil until stored
    public var input: EmbedInput?       // nil = keyword-only segment (e.g. OCR text kept for FTS)
    public init(segment: Segment, input: EmbedInput?) { self.segment = segment; self.input = input }
}

public protocol Embedder: Sendable {
    /// Model identifier stored in vectors.model_version, e.g. "embeddinggemma-2-q8_0".
    var modelVersion: String { get }
    /// 768 floats, L2-normalized.
    func embed(_ input: EmbedInput) async throws -> [Float]
}

// MARK: - Search

/// Parsed from the Recall query before searching (PRD "Filters inside the query").
public struct SearchFilters: Sendable, Hashable {
    public var kinds: Set<ItemKind>            // "image", "audio", ... ; empty = all
    public var sources: [String]               // from:figma -> ["figma"], matched against app name / bundle id, case-insensitive
    public var dateRange: Range<Date>?         // "last week", "in march"
    public init(kinds: Set<ItemKind> = [], sources: [String] = [], dateRange: Range<Date>? = nil) {
        self.kinds = kinds; self.sources = sources; self.dateRange = dateRange
    }
}

public struct ParsedQuery: Sendable, Hashable {
    public var text: String                    // query with filter tokens removed
    public var filters: SearchFilters
    public init(text: String, filters: SearchFilters) { self.text = text; self.filters = filters }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var item: Item
    public var score: Double
    public var matchedSegment: Segment?        // audio/video: start time for "at 2:14"; PDF: page
    public var id: Int64 { item.id ?? -1 }
    public init(item: Item, score: Double, matchedSegment: Segment? = nil) {
        self.item = item; self.score = score; self.matchedSegment = matchedSegment
    }
}

// MARK: - UI <-> app

/// What the Recall panel reads. Integration implements it; DaemonUI ships a mock for previews/tests.
@MainActor
public protocol RecallDataSource: AnyObject {
    var totalCount: Int { get }
    func recent(limit: Int) async throws -> [SearchHit]
    func search(_ query: String) async throws -> [SearchHit]
    func searchSimilar(to file: URL) async throws -> [SearchHit]
    func thumbnailURL(for item: Item) -> URL?
    func fileURL(for item: Item) -> URL?      // stored copy, or original when isReference
    func delete(_ item: Item) async throws
    func undoDelete(_ item: Item) async throws // within 5 s
    func setNote(_ note: String, for item: Item) async throws
    func keepClipboard() async throws          // ⌘V inside the panel
}

/// Actions the panel triggers that need system access. Implemented in DaemonCapture.
@MainActor
public protocol RecallActions: AnyObject {
    /// Clipboard -> ⌘V into the app that was in front -> restore clipboard. Returns false when it fell back to copy.
    func paste(_ hit: SearchHit, fileURL: URL?) async -> Bool
    func copy(_ hit: SearchHit, fileURL: URL?)
    func open(_ hit: SearchHit, fileURL: URL?)
}
