import Foundation
import GRDB
import UniformTypeIdentifiers

/// Everything Daemon keeps: a SQLite database plus `files/` (content-addressed copies) and `thumbnails/` (`<item id>.jpg`)
/// under one root folder the user can move.
public actor Library {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Daemon/Library", isDirectory: true)
    }

    public nonisolated let root: URL
    nonisolated let filesDir: URL
    nonisolated let thumbnailsDir: URL
    private let referenceThreshold: Int64
    private let db: DatabaseQueue

    public init(root: URL = Library.defaultRoot, referenceThreshold: Int64 = 500 * 1024 * 1024) throws {
        self.root = root
        filesDir = root.appendingPathComponent("files", isDirectory: true)
        thumbnailsDir = root.appendingPathComponent("thumbnails", isDirectory: true)
        self.referenceThreshold = referenceThreshold
        for dir in [filesDir, thumbnailsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        db = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path)
        try Self.migrator.migrate(db)
    }

    // MARK: - Keeping

    public func add(_ capture: Capture) async throws -> [Item] {
        let ctx = capture.context
        var item = Item(kind: .text, createdAt: ctx.createdAt, sourceApp: ctx.sourceApp,
                        sourceBundleID: ctx.sourceBundleID, windowTitle: ctx.windowTitle, url: ctx.url)
        switch capture.payload {
        case .text(let text):
            item.text = text
            return [try insert(item, file: nil)]
        case .files(let urls):
            var items: [Item] = []
            for url in urls {
                item.kind = Self.kind(forExtension: url.pathExtension)
                item.originalPath = url.path
                items.append(try insert(item, file: await inspect(url, kind: item.kind, move: false)))
            }
            return items
        case .screenshot(let url):
            item.kind = .screenshot
            return [try insert(item, file: await inspect(url, kind: .screenshot, move: true))]
        case .voiceNote(let url):
            item.kind = .voice
            return [try insert(item, file: await inspect(url, kind: .voice, move: true))]
        case .link(let url, let title, let screenshot):
            item.kind = .link
            item.url = url.absoluteString
            item.text = title
            var file: IncomingFile?
            if let screenshot { file = await inspect(screenshot, kind: .link, move: true) }
            return [try insert(item, file: file)]
        }
    }

    private func inspect(_ url: URL, kind: ItemKind, move: Bool) async -> IncomingFile {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return await IncomingFile(url: url, kind: kind, bytes: bytes,
                                  isReference: !move && bytes > referenceThreshold, move: move)
    }

    /// Stores the file and the row with no suspension point in between, so a concurrent delete can't
    /// remove a shared file this item is about to point at.
    private func insert(_ item: Item, file: IncomingFile?) throws -> Item {
        var item = item
        if let file {
            item.fileExtension = file.url.pathExtension.lowercased()
            item.mime = UTType(filenameExtension: item.fileExtension ?? "")?.preferredMIMEType
            item.bytes = file.bytes
            item.width = file.width
            item.height = file.height
            item.durationMs = file.durationMs
            if file.isReference {
                item.isReference = true
                item.originalPath = file.url.path
            } else {
                let hash = try sha256(of: file.url)
                item.fileHash = hash
                let dest = storedURL(hash: hash, ext: item.fileExtension)
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) {
                    if file.move { try? fm.removeItem(at: file.url) }
                } else if file.move {
                    try fm.moveItem(at: file.url, to: dest)
                } else {
                    try fm.copyItem(at: file.url, to: dest)
                }
            }
        }
        item = try db.write { db in
            try item.insert(db)
            try Self.reindex(item.id!, db)
            return try Item.fetchOne(db, key: item.id!)!  // as stored (dates keep milliseconds), so it equals later reads
        }
        if let thumbnail = file?.thumbnail {
            writeJPEG(thumbnail, to: thumbnailsDir.appendingPathComponent("\(item.id!).jpg"))
        }
        return item
    }

    // MARK: - Files

    public nonisolated func fileURL(for item: Item) -> URL? {
        if item.isReference { return item.originalPath.map { URL(fileURLWithPath: $0) } }
        return item.fileHash.map { storedURL(hash: $0, ext: item.fileExtension) }
    }

    public nonisolated func thumbnailURL(for item: Item) -> URL? {
        guard let id = item.id else { return nil }
        let url = thumbnailsDir.appendingPathComponent("\(id).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func storedURL(hash: String, ext: String?) -> URL {
        let name = (ext ?? "").isEmpty ? hash : "\(hash).\(ext!)"
        return filesDir.appendingPathComponent(name)
    }

    // MARK: - Processing results

    public func saveSegments(_ segments: [Segment]) throws -> [Segment] {
        try db.write { db in
            var saved: [Segment] = []
            for var segment in segments {
                try segment.insert(db)
                saved.append(segment)
            }
            for itemId in Set(segments.map(\.itemId)) { try Self.reindex(itemId, db) }
            return saved
        }
    }

    public func saveVector(_ vector: [Float], segmentId: Int64, modelVersion: String) throws {
        let data = vector.map(Float16.init).withUnsafeBytes { Data($0) }
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO vectors (segment_id, model_version, dims, vector) VALUES (?, ?, ?, ?)
                """, arguments: [segmentId, modelVersion, vector.count, data])
        }
    }

    public func setStatus(_ status: ItemStatus, itemId: Int64) throws {
        try db.write { try $0.execute(sql: "UPDATE items SET status = ? WHERE id = ?", arguments: [status.rawValue, itemId]) }
    }

    public func setNote(_ note: String, itemId: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE items SET note = ? WHERE id = ?", arguments: [note.isEmpty ? nil : note, itemId])
            try Self.reindex(itemId, db)
        }
    }

    // MARK: - Delete

    public func delete(itemId: Int64) throws {
        let orphanedFile: URL? = try db.write { db in
            guard let item = try Item.fetchOne(db, key: itemId) else { return nil }
            try Item.deleteOne(db, key: itemId)  // segments and vectors cascade
            try db.execute(sql: "DELETE FROM search_text WHERE rowid = ?", arguments: [itemId])
            guard let hash = item.fileHash,
                  try Item.filter(sql: "file_hash = ?", arguments: [hash]).fetchCount(db) == 0 else { return nil }
            return fileURL(for: item)
        }
        if let orphanedFile { try? FileManager.default.removeItem(at: orphanedFile) }
        try? FileManager.default.removeItem(at: thumbnailsDir.appendingPathComponent("\(itemId).jpg"))
    }

    // MARK: - Reads

    public func item(id: Int64) -> Item? {
        try? db.read { try Item.fetchOne($0, key: id) }
    }

    /// Items in the order of `ids`; missing ids are skipped.
    public func items(ids: [Int64]) -> [Item] {
        let found = (try? db.read { try Item.fetchAll($0, keys: ids) }) ?? []
        let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.id!, $0) })
        return ids.compactMap { byId[$0] }
    }

    public func recent(limit: Int) -> [Item] {
        (try? db.read { try Item.order(sql: "created_at DESC, id DESC").limit(limit).fetchAll($0) }) ?? []
    }

    public func count() -> Int {
        (try? db.read { try Item.fetchCount($0) }) ?? 0
    }

    public func countToday() -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        return (try? db.read { try Item.filter(sql: "created_at >= ?", arguments: [start]).fetchCount($0) }) ?? 0
    }

    public func segments(itemId: Int64) -> [Segment] {
        (try? db.read { try Segment.filter(sql: "item_id = ?", arguments: [itemId]).order(sql: "id").fetchAll($0) }) ?? []
    }

    public func segment(id: Int64) -> Segment? {
        try? db.read { try Segment.fetchOne($0, key: id) }
    }

    /// Items still waiting for extraction/embedding, oldest first (resume after restart).
    public func pendingItems() -> [Item] {
        (try? db.read { try Item.filter(sql: "status = ?", arguments: [ItemStatus.pending.rawValue]).order(sql: "id").fetchAll($0) }) ?? []
    }

    public func allVectors(modelVersion: String) -> [(segmentId: Int64, itemId: Int64, vector: [Float16])] {
        let rows = (try? db.read {
            try Row.fetchAll($0, sql: """
                SELECT v.segment_id, s.item_id, v.vector FROM vectors v JOIN segments s ON s.id = v.segment_id
                WHERE v.model_version = ? ORDER BY v.segment_id
                """, arguments: [modelVersion])
        }) ?? []
        return rows.map { row in
            let data: Data = row[2]
            let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return (row[0], row[1], vector)
        }
    }

    // MARK: - Search

    /// FTS5 bm25 over note, text, recognized text, window title, URL and file name. Higher score = better.
    public func keywordSearch(_ text: String, filters: SearchFilters, limit: Int) -> [(itemId: Int64, score: Double)] {
        guard let match = Self.ftsQuery(text) else { return [] }
        let (clauses, args) = Self.filterSQL(filters)
        let sql = """
            SELECT search_text.rowid, bm25(search_text) AS rank FROM search_text
            JOIN items ON items.id = search_text.rowid
            WHERE search_text MATCH ?\(clauses.map { " AND \($0)" }.joined())
            ORDER BY rank LIMIT ?
            """
        let rows = (try? db.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments([match] + args + [limit])) }) ?? []
        return rows.map { (itemId: $0[0], score: -($0[1] as Double)) }
    }

    public func itemIds(matching filters: SearchFilters) -> Set<Int64> {
        let (clauses, args) = Self.filterSQL(filters)
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return Set((try? db.read { try Int64.fetchAll($0, sql: "SELECT id FROM items" + whereSQL, arguments: StatementArguments(args)) }) ?? [])
    }

    /// Words become quoted terms OR'ed together (bm25 rewards matching more of them); the last word matches as a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in "\"\(w)\"" + (i == words.count - 1 ? "*" : "") }.joined(separator: " OR ")
    }

    static func filterSQL(_ filters: SearchFilters) -> (clauses: [String], args: [DatabaseValueConvertible?]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if !filters.kinds.isEmpty {
            clauses.append("items.kind IN (\(Array(repeating: "?", count: filters.kinds.count).joined(separator: ",")))")
            args += filters.kinds.map(\.rawValue)
        }
        if !filters.sources.isEmpty {
            let one = "(instr(lower(ifnull(items.source_app, '')), lower(?)) > 0 OR instr(lower(ifnull(items.source_bundle_id, '')), lower(?)) > 0)"
            clauses.append("(" + Array(repeating: one, count: filters.sources.count).joined(separator: " OR ") + ")")
            for source in filters.sources { args += [source, source] }
        }
        if let range = filters.dateRange {
            clauses.append("items.created_at >= ? AND items.created_at < ?")
            args += [range.lowerBound, range.upperBound]
        }
        return (clauses, args)
    }

    // MARK: - Export and size

    /// Copies stored files to `folder/files/` and writes `folder/items.json` (items, their file path, segment text).
    public func export(to folder: URL) throws {
        struct Entry: Encodable { var item: Item; var file: String?; var segments: [Segment] }
        let fm = FileManager.default
        let exportFiles = folder.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: exportFiles, withIntermediateDirectories: true)
        let (items, segments) = try db.read { db in
            (try Item.order(sql: "id").fetchAll(db), try Segment.order(sql: "id").fetchAll(db))
        }
        let segmentsByItem = Dictionary(grouping: segments, by: \.itemId)
        var entries: [Entry] = []
        for item in items {
            var file: String?
            if let source = fileURL(for: item) {
                if item.isReference {
                    file = source.path
                } else {
                    let dest = exportFiles.appendingPathComponent(source.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: source, to: dest) }
                    file = "files/" + source.lastPathComponent
                }
            }
            entries.append(Entry(item: item, file: file, segments: segmentsByItem[item.id!] ?? []))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: folder.appendingPathComponent("items.json"))
    }

    /// Bytes on disk under the library root (database, files, thumbnails).
    public func librarySize() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")  // never reused: ids name thumbnails and FTS rows
                t.column("kind", .text).notNull()
                t.column("created_at", .datetime).notNull().indexed()
                t.column("source_app", .text)
                t.column("source_bundle_id", .text)
                t.column("window_title", .text)
                t.column("url", .text)
                t.column("note", .text)
                t.column("text", .text)
                t.column("file_hash", .text).indexed()
                t.column("file_extension", .text)
                t.column("original_path", .text)
                t.column("is_reference", .boolean).notNull().defaults(to: false)
                t.column("mime", .text)
                t.column("bytes", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("duration_ms", .integer)
                t.column("status", .text).notNull().indexed()
            }
            try db.create(table: "segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .integer).notNull().indexed().references("items", onDelete: .cascade)
                t.column("modality", .text).notNull()
                t.column("page", .integer)
                t.column("start_ms", .integer)
                t.column("end_ms", .integer)
                t.column("text", .text)
            }
            try db.create(table: "vectors") { t in
                t.column("segment_id", .integer).notNull().references("segments", onDelete: .cascade)
                t.column("model_version", .text).notNull()
                t.column("dims", .integer).notNull()
                t.column("vector", .blob).notNull()  // dims x Float16
                t.primaryKey(["segment_id", "model_version"])
            }
            // GRDB's FTS5 API needs SQLITE_ENABLE_FTS5 at compile time; the system SQLite has FTS5, so plain SQL.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_text USING fts5(
                    note, text, recognized, window_title, url, file_name,
                    tokenize = 'porter unicode61 remove_diacritics 2')
                """)
        }
        return migrator
    }

    /// Rewrites the item's FTS row (rowid = item id) from its fields and all its segment text.
    private static func reindex(_ itemId: Int64, _ db: Database) throws {
        guard let item = try Item.fetchOne(db, key: itemId) else { return }
        let recognized = try String.fetchAll(db, sql: "SELECT text FROM segments WHERE item_id = ? AND text IS NOT NULL ORDER BY id",
                                             arguments: [itemId]).joined(separator: "\n")
        try db.execute(sql: "DELETE FROM search_text WHERE rowid = ?", arguments: [itemId])
        try db.execute(sql: """
            INSERT INTO search_text (rowid, note, text, recognized, window_title, url, file_name) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [itemId, item.note, item.text, recognized, item.windowTitle, item.url,
                             item.originalPath.map { ($0 as NSString).lastPathComponent }])
    }

    static func kind(forExtension ext: String) -> ItemKind {
        guard let type = UTType(filenameExtension: ext) else { return .file }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) { return .video }
        return .file
    }
}

// MARK: - GRDB records

private struct ColumnKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// snake_case column -> camelCase property, with the one acronym in our models (`sourceBundleID`).
private let snakeColumns = DatabaseColumnDecodingStrategy.custom { column in
    if column == "source_bundle_id" { return ColumnKey(stringValue: "sourceBundleID") }
    let parts = column.split(separator: "_")
    return ColumnKey(stringValue: parts.enumerated().map { $0 == 0 ? String($1) : $1.capitalized }.joined())
}

extension Item: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "items"
    public static let databaseColumnDecodingStrategy = snakeColumns
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Segment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "segments"
    public static let databaseColumnDecodingStrategy = snakeColumns
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
