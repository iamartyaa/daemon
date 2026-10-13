import DaemonCore
import Foundation

/// Sample library matching the design screenshots, for previews, tests and visual checks.
/// Any non-empty query returns the same seven results.
@MainActor
public final class MockRecallDataSource: RecallDataSource {
    public var totalCount = 1284
    public private(set) var searches: [String] = []
    public private(set) var deleted: [Item] = []
    public private(set) var keptClipboardCount = 0
    public var results: [SearchHit]
    public var recentHits: [SearchHit]

    public init(now: Date = Date()) {
        results = MockRecallDataSource.sampleHits(now: now)
        recentHits = MockRecallDataSource.sampleRecent(now: now)
    }

    public func recent(limit: Int) async throws -> [SearchHit] { Array(recentHits.prefix(limit)) }

    public func search(_ query: String) async throws -> [SearchHit] {
        searches.append(query)
        return results
    }

    public func searchSimilar(to file: URL) async throws -> [SearchHit] {
        results.filter { [.image, .screenshot].contains($0.item.kind) }
    }

    public func thumbnailURL(for item: Item) -> URL? { nil }
    public func fileURL(for item: Item) -> URL? { nil }

    public func delete(_ item: Item) async throws {
        deleted.append(item)
        results.removeAll { $0.item.id == item.id }
    }

    public func undoDelete(_ item: Item) async throws {
        deleted.removeAll { $0.id == item.id }
    }

    public func setNote(_ note: String, for item: Item) async throws {}
    public func keepClipboard() async throws { keptClipboardCount += 1 }

    // MARK: - Sample data

    static let sampleHits = sampleHits(now: Date())

    static func sampleHits(now: Date) -> [SearchHit] {
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        let items: [(Item, Segment?)] = [
            (Item(id: 1, kind: .screenshot, createdAt: ago(3), sourceApp: "Figma", sourceBundleID: "com.figma.Desktop",
                  windowTitle: "Pricing — Monthly / Yearly toggle, dark",
                  note: "Compare with Linear’s annual badge before Thursday.", status: .ready), nil),
            (Item(id: 2, kind: .screenshot, createdAt: ago(3.01), sourceApp: "Safari", sourceBundleID: "com.apple.Safari",
                  windowTitle: "Billing settings, dark mode", status: .ready), nil),
            (Item(id: 3, kind: .screenshot, createdAt: ago(7), sourceApp: "Arc", sourceBundleID: "company.thebrowser.Browser",
                  windowTitle: "Plan picker with annual discount badge", status: .ready), nil),
            (Item(id: 4, kind: .link, createdAt: ago(3.02), sourceApp: "Safari", sourceBundleID: "com.apple.Safari",
                  url: "https://docs.stripe.com/payments/checkout/pricing-table",
                  text: "Pricing table component — Stripe Docs", status: .ready), nil),
            (Item(id: 5, kind: .pdf, createdAt: ago(14), sourceApp: "Preview", sourceBundleID: "com.apple.Preview",
                  windowTitle: "SaaS Pricing Playbook", fileExtension: "pdf",
                  originalPath: "/Users/me/Documents/SaaS Pricing Playbook.pdf", status: .ready),
             Segment(itemId: 5, modality: .text, page: 12)),
            (Item(id: 6, kind: .voice, createdAt: ago(1), text: "Default to yearly, show the monthly price small under it",
                  durationMs: 58_000, status: .ready),
             Segment(itemId: 6, modality: .audio, startMs: 42_000, endMs: 52_000)),
            (Item(id: 7, kind: .video, createdAt: ago(21), sourceApp: "QuickTime", sourceBundleID: "com.apple.QuickTimePlayerX",
                  windowTitle: "Lecture 9 — Pricing & Positioning", fileExtension: "mp4",
                  originalPath: "/Users/me/Movies/Lecture 9 — Pricing & Positioning.mp4", durationMs: 4_380_000,
                  status: .ready),
             Segment(itemId: 7, modality: .video, startMs: 2_840_000, endMs: 2_850_000)),
        ]
        return items.enumerated().map { i, pair in
            SearchHit(item: pair.0, score: 1 - Double(i) * 0.05, matchedSegment: pair.1)
        }
    }

    static func sampleRecent(now: Date) -> [SearchHit] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let items = [
            Item(id: 11, kind: .screenshot, createdAt: ago(2), sourceApp: "Figma",
                 windowTitle: "Pricing — Monthly / Yearly toggle, dark", status: .ready),
            Item(id: 12, kind: .text, createdAt: ago(62), sourceApp: "Mail", sourceBundleID: "com.apple.mail",
                 text: "Flight confirmation, LHR → SFO\nBA 287, 14 Oct, seat 32A", status: .ready),
            Item(id: 13, kind: .link, createdAt: ago(200), sourceApp: "Safari",
                 url: "https://linear.app/daemon/issue/DMN-214", text: "DMN-214 Recall loses focus on paste", status: .ready),
            Item(id: 14, kind: .voice, createdAt: ago(240), text: "Call Hana about the Tuesday review",
                 durationMs: 12_000, status: .ready),
            Item(id: 15, kind: .pdf, createdAt: ago(60 * 26), sourceApp: "Preview",
                 fileExtension: "pdf", originalPath: "/Users/me/Documents/Q3 roadmap.pdf", status: .ready),
            Item(id: 16, kind: .image, createdAt: ago(60 * 27), sourceApp: "Freeform",
                 windowTitle: "Onboarding flow sketch", status: .ready),
        ]
        return items.map { SearchHit(item: $0, score: 0) }
    }
}
