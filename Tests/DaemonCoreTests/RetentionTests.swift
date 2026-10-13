import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaemonCore

@MainActor
final class RetentionTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)   // injected clock
    private let ages = [1, 6, 8, 29, 31, 89, 91]

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func daysAgo(_ days: Int) -> Date { Calendar.current.date(byAdding: .day, value: -days, to: now)! }

    private func makeEngine() async throws -> Engine {
        let library = try Library(root: dir.appendingPathComponent("Library-\(UUID())"))
        let engine = Engine(library: library, embedder: FakeEmbedder(),
                            stats: UsageStats(defaults: UserDefaults(suiteName: "RetentionTests-\(UUID())")!))
        await engine.start()
        return engine
    }

    @discardableResult
    private func keep(_ engine: Engine, _ payload: CapturePayload, age: Int) async throws -> Item {
        try await engine.keep(Capture(payload: payload, context: CaptureContext(createdAt: daysAgo(age))))[0]
    }

    private func png(_ name: String) throws -> URL {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: Policy

    func testEachPolicyRemovesExactlyTheOlderItems() async throws {
        let expected: [RetentionPolicy: [Int]] = [.days7: [1, 6], .days30: [1, 6, 8, 29], .days90: [1, 6, 8, 29, 31, 89]]
        for policy in RetentionPolicy.allCases {
            let engine = try await makeEngine()
            var ageById: [Int64: Int] = [:]
            for age in ages { ageById[try await keep(engine, .text("note from \(age) days ago"), age: age).id!] = age }
            await engine.waitUntilIdle()

            let wouldRemove = await engine.library.count(before: policy.cutoff(now: now))
            let result = await engine.applyRetention(policy, now: now, leftoverDirs: [])
            XCTAssertEqual(result.items, ages.count - expected[policy]!.count, policy.title)
            XCTAssertEqual(wouldRemove, result.items, policy.title)
            let left = await engine.library.recent(limit: 100).map { ageById[$0.id!]! }.sorted()
            XCTAssertEqual(left, expected[policy], policy.title)
            XCTAssertEqual(engine.totalCount, left.count)
        }
    }

    func testPendingAndFailedItemsOutsideTheWindowGoToo() async throws {
        let library = try Library(root: dir.appendingPathComponent("Library"))
        let pending = try await library.add(Capture(payload: .text("pending"), context: CaptureContext(createdAt: daysAgo(10))))[0]
        let failed = try await library.add(Capture(payload: .text("failed"), context: CaptureContext(createdAt: daysAgo(10))))[0]
        try await library.setStatus(.failed, itemId: failed.id!)
        let removed = try await library.purge(before: RetentionPolicy.days7.cutoff(now: now))
        XCTAssertEqual(Set(removed.ids), [pending.id!, failed.id!])
        let oldest = await library.oldestDate()
        XCTAssertNil(oldest)
    }

    // MARK: Everything an item owns goes with it

    func testPurgeRemovesVectorsSegmentsFTSAndIndexRows() async throws {
        let engine = try await makeEngine()
        let old = try await keep(engine, .text("quarterly tax receipts for the accountant"), age: 40)
        let fresh = try await keep(engine, .text("quarterly roadmap for the design team"), age: 2)
        await engine.waitUntilIdle()
        let query = try await FakeEmbedder().embed(.query("quarterly tax receipts accountant"))
        XCTAssertEqual(engine.index.search(query, limit: 10).first?.itemId, old.id)

        await engine.applyRetention(.days30, now: now, leftoverDirs: [])

        let library = engine.library
        XCTAssertEqual(engine.index.search(query, limit: 10).map(\.itemId), [fresh.id!])
        let segments = await library.segments(itemId: old.id!)
        XCTAssertTrue(segments.isEmpty)
        let vectorItems = await library.allVectors(modelVersion: "fake-1").map(\.itemId)
        XCTAssertEqual(Set(vectorItems), [fresh.id!])
        let keyword = await library.keywordSearch("receipts", filters: SearchFilters(), limit: 10)
        XCTAssertTrue(keyword.isEmpty)
        let hits = try await engine.search("tax receipts")
        XCTAssertFalse(hits.contains { $0.item.id == old.id })
    }

    func testSharedFileSurvivesUntilItsLastItemIsPurged() async throws {
        let engine = try await makeEngine()
        let older = try await keep(engine, .files([try png("a.png")]), age: 40)
        let newer = try await keep(engine, .files([try png("b.png")]), age: 10)   // same pixels, same hash
        XCTAssertEqual(older.fileHash, newer.fileHash)
        let file = try XCTUnwrap(engine.fileURL(for: older))
        let olderThumb = try XCTUnwrap(engine.thumbnailURL(for: older))
        let newerThumb = try XCTUnwrap(engine.thumbnailURL(for: newer))
        await engine.waitUntilIdle()

        let first = await engine.applyRetention(.days30, now: now, leftoverDirs: [])
        XCTAssertEqual(first.items, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderThumb.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerThumb.path))

        let second = await engine.applyRetention(.days7, now: now, leftoverDirs: [])
        XCTAssertEqual(second.items, 1)
        XCTAssertGreaterThan(second.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newerThumb.path))
    }

    func testLargePurgeVacuums() async throws {
        let engine = try await makeEngine()
        for i in 0..<60 { try await keep(engine, .text("old note \(i)"), age: 45) }
        await engine.waitUntilIdle()
        let result = await engine.applyRetention(.days30, now: now, leftoverDirs: [])
        XCTAssertEqual(result.items, 60)
        XCTAssertEqual(engine.totalCount, 0)
    }

    // MARK: Leftovers and the setting

    func testSweepRemovesOnlyTempFilesOlderThanADay() throws {
        let temp = dir.appendingPathComponent("DaemonCapture")
        let work = dir.appendingPathComponent("DaemonWork/stale-job")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let stale = temp.appendingPathComponent("old.png"), recent = temp.appendingPathComponent("new.m4a")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: stale)
        try Data(repeating: 2, count: 10_000).write(to: recent)
        try Data(repeating: 3, count: 10_000).write(to: work.appendingPathComponent("chunk.wav"))
        let old = now.addingTimeInterval(-25 * 3600)
        for url in [stale, work] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: recent.path)

        let freed = Leftovers.sweep([temp, dir.appendingPathComponent("DaemonWork")], now: now)

        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testSettingDefaultsTo30DaysAndPersists() {
        let defaults = UserDefaults(suiteName: "RetentionTests-\(UUID())")!
        XCTAssertEqual(RetentionPolicy.load(from: defaults), .days30)
        RetentionPolicy.days7.save(to: defaults)
        XCTAssertEqual(defaults.integer(forKey: "retentionDays"), 7)
        XCTAssertEqual(RetentionPolicy.load(from: defaults), .days7)
        defaults.set(365, forKey: "retentionDays")   // no "forever", nothing past 90
        XCTAssertEqual(RetentionPolicy.load(from: defaults), .days30)
        XCTAssertEqual(RetentionPolicy.allCases.map(\.title), ["7 days", "30 days", "90 days"])
    }
}
