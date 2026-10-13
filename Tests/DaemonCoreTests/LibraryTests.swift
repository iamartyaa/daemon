import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaemonCore

final class LibraryTests: XCTestCase {
    var dir: URL!
    var library: Library!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        library = try Library(root: dir.appendingPathComponent("Library"), referenceThreshold: 100_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    func textFile(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func png(_ name: String, width: Int = 800, height: Int = 600) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func keep(_ payload: CapturePayload, _ context: CaptureContext = CaptureContext()) async throws -> [Item] {
        try await library.add(Capture(payload: payload, context: context))
    }

    func ids(_ query: String, _ filters: SearchFilters = SearchFilters()) async -> [Int64] {
        await library.keywordSearch(query, filters: filters, limit: 10).map(\.itemId)
    }

    // MARK: Add

    func testAddText() async throws {
        let context = CaptureContext(sourceApp: "Safari", sourceBundleID: "com.apple.Safari",
                                     windowTitle: "Pasta recipes", url: "https://example.com/pasta")
        let item = try await keep(.text("Cacio e pepe needs pecorino"), context)[0]
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.status, .pending)
        let stored = await library.item(id: item.id!)
        XCTAssertEqual(stored, item)
        XCTAssertEqual(stored?.sourceBundleID, "com.apple.Safari")
        XCTAssertNil(library.fileURL(for: item))
        let count = await library.count()
        XCTAssertEqual(count, 1)
        let today = await library.countToday()
        XCTAssertEqual(today, 1)
        let found = await ids("pecorino")
        XCTAssertEqual(found, [item.id!])
    }

    func testAddImageFileCopiesWithMetadataAndThumbnail() async throws {
        let original = try png("Moodboard.png")
        let item = try await keep(.files([original]))[0]
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.mime, "image/png")
        XCTAssertEqual(item.fileExtension, "png")
        XCTAssertEqual(item.width, 800)
        XCTAssertEqual(item.height, 600)
        XCTAssertEqual(item.originalPath, original.path)
        XCTAssertFalse(item.isReference)
        let stored = try XCTUnwrap(library.fileURL(for: item))
        XCTAssertEqual(stored.lastPathComponent, "\(item.fileHash!).png")
        XCTAssertEqual(try Data(contentsOf: stored), try Data(contentsOf: original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "files are copied, not moved")
        let thumb = try XCTUnwrap(library.thumbnailURL(for: item))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(thumb as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertLessThanOrEqual(props[kCGImagePropertyPixelWidth] as! Int, 400)
    }

    func testPDFAndAudioMetadata() async throws {
        let pdf = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
        ctx.endPDFPage()
        ctx.closePDF()

        let wav = dir.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000  // 0.5 s of silence
        try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)

        let items = try await keep(.files([pdf, wav]))
        XCTAssertEqual(items.map(\.kind), [.pdf, .audio])
        XCTAssertEqual(items[0].mime, "application/pdf")
        XCTAssertNotNil(library.thumbnailURL(for: items[0]))
        XCTAssertEqual(items[1].durationMs, 500)
        XCTAssertNil(library.thumbnailURL(for: items[1]))
    }

    func testDuplicateFileStoredOnce() async throws {
        let a = try textFile("a.txt", "same content")
        let b = try textFile("b.txt", "same content")
        let items = try await keep(.files([a, b]))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].fileHash, items[1].fileHash)
        XCTAssertEqual(items[0].kind, .file)
        let stored = try FileManager.default.contentsOfDirectory(atPath: library.filesDir.path)
        XCTAssertEqual(stored, ["\(items[0].fileHash!).txt"])
    }

    func testLargeFileKeptAsReference() async throws {
        let big = try textFile("big.txt", String(repeating: "x", count: 200_000))
        let item = try await keep(.files([big]))[0]
        XCTAssertTrue(item.isReference)
        XCTAssertNil(item.fileHash)
        XCTAssertEqual(item.bytes, 200_000)
        XCTAssertEqual(library.fileURL(for: item), big)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.filesDir.path).isEmpty)
    }

    func testScreenshotIsMovedIn() async throws {
        let temp = try png("shot.png", width: 300, height: 200)
        let item = try await keep(.screenshot(temp), CaptureContext(sourceApp: "Figma", windowTitle: "Onboarding v3"))[0]
        XCTAssertEqual(item.kind, .screenshot)
        XCTAssertEqual(item.width, 300)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "temp screenshot is moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: item)!.path))
        XCTAssertNotNil(library.thumbnailURL(for: item))
        let found = await ids("onboarding")
        XCTAssertEqual(found, [item.id!])
    }

    func testLink() async throws {
        let shot = try png("page.png")
        let url = URL(string: "https://swift.org/documentation/concurrency")!
        let item = try await keep(.link(url: url, title: "Swift Concurrency Guide", screenshot: shot))[0]
        XCTAssertEqual(item.kind, .link)
        XCTAssertEqual(item.url, url.absoluteString)
        XCTAssertEqual(item.text, "Swift Concurrency Guide")
        XCTAssertNotNil(library.fileURL(for: item))
        XCTAssertNotNil(library.thumbnailURL(for: item))
        let byTitle = await ids("concurrency guide")
        XCTAssertEqual(byTitle, [item.id!])
        let byURL = await ids("swift.org")
        XCTAssertEqual(byURL, [item.id!])
    }

    // MARK: Search

    func testKeywordSearchFieldsAndPrefix() async throws {
        let file = try await keep(.files([try textFile("quarterly-invoice.txt", "numbers")]))[0]
        let noted = try await keep(.text("something"))[0]
        try await library.setNote("ask Dana about the budget", itemId: noted.id!)
        let byName = await ids("invoice")
        XCTAssertEqual(byName, [file.id!])
        let byNote = await ids("dana")
        XCTAssertEqual(byNote, [noted.id!])
        let prefix = await ids("budg")
        XCTAssertEqual(prefix, [noted.id!])
        let hostile = await ids("\"budget OR* (NEAR")
        XCTAssertEqual(hostile, [noted.id!])
        let empty = await ids("  ")
        XCTAssertEqual(empty, [])
    }

    func testSegmentsIndexedForSearch() async throws {
        let item = try await keep(.screenshot(try png("s.png")))[0]
        let saved = try await library.saveSegments([Segment(itemId: item.id!, modality: .image, text: "Quarterly roadmap")])
        XCTAssertNotNil(saved[0].id)
        let fetched = await library.segment(id: saved[0].id!)
        XCTAssertEqual(fetched, saved[0])
        let all = await library.segments(itemId: item.id!)
        XCTAssertEqual(all, saved)
        let found = await ids("roadmap")
        XCTAssertEqual(found, [item.id!])
    }

    func testFilters() async throws {
        let old = Date(timeIntervalSinceNow: -30 * 86400)
        let figma = try await keep(.text("design tokens"), CaptureContext(createdAt: old, sourceApp: "Figma", sourceBundleID: "com.figma.Desktop"))[0]
        let safari = try await keep(.text("design blog"), CaptureContext(sourceApp: "Safari", sourceBundleID: "com.apple.Safari"))[0]
        let image = try await keep(.files([try png("design.png")]))[0]

        let byKind = await library.itemIds(matching: SearchFilters(kinds: [.image]))
        XCTAssertEqual(byKind, [image.id!])
        let bySource = await library.itemIds(matching: SearchFilters(sources: ["FIGMA"]))
        XCTAssertEqual(bySource, [figma.id!])
        let byBundle = await library.itemIds(matching: SearchFilters(sources: ["apple.safari", "nope"]))
        XCTAssertEqual(byBundle, [safari.id!])
        let lastWeek = Date(timeIntervalSinceNow: -7 * 86400)..<Date(timeIntervalSinceNow: 60)
        let byDate = await library.itemIds(matching: SearchFilters(dateRange: lastWeek))
        XCTAssertEqual(byDate, [safari.id!, image.id!])
        let all = await library.itemIds(matching: SearchFilters())
        XCTAssertEqual(all.count, 3)

        let searched = await ids("design", SearchFilters(kinds: [.text], dateRange: lastWeek))
        XCTAssertEqual(searched, [safari.id!])
        let today = await library.countToday()
        XCTAssertEqual(today, 2)
        let recent = await library.recent(limit: 10).map(\.id!)
        XCTAssertEqual(recent, [image.id!, safari.id!, figma.id!])
        let ordered = await library.items(ids: [figma.id!, 999, image.id!]).map(\.id!)
        XCTAssertEqual(ordered, [figma.id!, image.id!])
    }

    // MARK: Delete, status, vectors, export

    func testDeleteKeepsSharedFileUntilLastItem() async throws {
        let a = try await keep(.files([try png("a.png")]))[0]
        let b = try await keep(.files([try png("b.png")]))[0]
        let stored = try XCTUnwrap(library.fileURL(for: a))
        let thumbA = try XCTUnwrap(library.thumbnailURL(for: a))
        let seg = try await library.saveSegments([Segment(itemId: a.id!, modality: .image, text: "unique words")])
        try await library.saveVector([0.5], segmentId: seg[0].id!, modelVersion: "m")

        try await library.delete(itemId: a.id!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path), "b still uses the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbA.path))
        let gone = await library.item(id: a.id!)
        XCTAssertNil(gone)
        let segments = await library.segments(itemId: a.id!)
        XCTAssertEqual(segments, [])
        let vectors = await library.allVectors(modelVersion: "m")
        XCTAssertTrue(vectors.isEmpty)
        let found = await ids("unique")
        XCTAssertEqual(found, [])

        try await library.delete(itemId: b.id!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        let count = await library.count()
        XCTAssertEqual(count, 0)
    }

    func testStatusAndPending() async throws {
        let a = try await keep(.text("a"))[0]
        let b = try await keep(.text("b"))[0]
        try await library.setStatus(.ready, itemId: a.id!)
        let pending = await library.pendingItems().map(\.id!)
        XCTAssertEqual(pending, [b.id!])
        let ready = await library.item(id: a.id!)?.status
        XCTAssertEqual(ready, .ready)
    }

    func testVectorFloat16RoundTrip() async throws {
        let item = try await keep(.text("vector"))[0]
        let seg = try await library.saveSegments([Segment(itemId: item.id!, modality: .text, text: "vector")])[0]
        let vector = (0..<768).map { Float(sin(Double($0))) }
        try await library.saveVector(vector, segmentId: seg.id!, modelVersion: "embeddinggemma-2-q8_0")
        try await library.saveVector(vector, segmentId: seg.id!, modelVersion: "embeddinggemma-2-q8_0")  // replace, not duplicate
        let loaded = await library.allVectors(modelVersion: "embeddinggemma-2-q8_0")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].segmentId, seg.id!)
        XCTAssertEqual(loaded[0].itemId, item.id!)
        XCTAssertEqual(loaded[0].vector.count, 768)
        for (a, b) in zip(vector, loaded[0].vector) { XCTAssertEqual(a, Float(b), accuracy: 1e-3) }
        let other = await library.allVectors(modelVersion: "other")
        XCTAssertTrue(other.isEmpty)
    }

    func testExport() async throws {
        let image = try await keep(.files([try png("photo.png")]))[0]
        let text = try await keep(.text("plain words"))[0]
        _ = try await library.saveSegments([Segment(itemId: image.id!, modality: .image, text: "ocr text")])
        let out = dir.appendingPathComponent("Export")
        try await library.export(to: out)

        let stored = library.fileURL(for: image)!.lastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("files/\(stored)").path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("items.json"))) as! [[String: Any]]
        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["file"] as? String, "files/\(stored)")
        XCTAssertEqual((json[0]["segments"] as? [[String: Any]])?.first?["text"] as? String, "ocr text")
        XCTAssertEqual((json[1]["item"] as? [String: Any])?["text"] as? String, "plain words")
        XCTAssertEqual((json[1]["item"] as? [String: Any])?["id"] as? Int64, text.id)
    }

    func testReopenAndSize() async throws {
        _ = try await keep(.files([try png("p.png")]))
        let size = await library.librarySize()
        XCTAssertGreaterThan(size, 0)
        library = nil
        let reopened = try Library(root: dir.appendingPathComponent("Library"))
        let count = await reopened.count()
        XCTAssertEqual(count, 1)
    }
}
