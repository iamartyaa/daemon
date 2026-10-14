import AppKit
import Combine
@testable import DaemonCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import DaemonUI

/// Recall latency benchmark on a generated 2,000-item library (text, screenshots with thumbnails, voice, PDFs, links).
/// Off by default: `DAEMON_PERF=1 swift test --filter RecallPerfTests` (add `DAEMON_PERF_LABEL=after` to name the
/// output). Prints a table and writes `.build/perf-<label>.md`. The library is generated once into
/// `.build/perf-library-v1` and reused. The real model is used for the `real` rows when DaemonEmbedder is built
/// and its model files are on disk. Windows stay offscreen and never take key focus.
@MainActor
final class RecallPerfTests: XCTestCase {
    private let report = PerfReport()

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAEMON_PERF"] != nil, "benchmark; set DAEMON_PERF=1")
        Perf.samples.isRecording = true
        _ = Perf.samples.drain()
    }

    override func tearDown() async throws {
        Perf.samples.isRecording = false
    }

    static let queries = ["pricing yearly toggle", "flight seat confirmation", "docker container cache error",
                          "receipt for the laptop", "meeting notes roadmap", "garlic pasta recipe"]

    func testRecallBenchmark() async throws {
        let root = try await PerfLibrary.prepare()
        let library = try Library(root: root)
        let engine = Engine(library: library, embedder: StableFakeEmbedder(),
                            stats: UsageStats(defaults: UserDefaults(suiteName: "perf-\(UUID())")!))
        await report.time("engine start (load vectors)") { await engine.start() }
        report.note("library: \(engine.totalCount) items, \(engine.index.count) vectors")

        try await engineSearch(engine, label: "fake embedder")
        try await typing(engine)
        try await panelShow(engine)
        try await render(engine)
        try await thumbnails(engine)
        try await realEmbedder(library)

        let text = report.markdown()
        print(text)
        let label = ProcessInfo.processInfo.environment["DAEMON_PERF_LABEL"] ?? "run"
        try text.write(to: PerfLibrary.buildDir.appending(path: "perf-\(label).md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Engine: every prefix of every query, as typed

    private func engineSearch(_ engine: Engine, label: String) async throws {
        _ = try await engine.search("warm up")
        _ = Perf.samples.drain()
        var short: [Double] = [], long: [Double] = []
        for query in Self.queries {
            for n in 1...query.count {
                let prefix = String(query.prefix(n))
                let start = ContinuousClock.now
                _ = try await engine.search(prefix)
                if n < 3 { short.append(ms(since: start)) } else { long.append(ms(since: start)) }
            }
        }
        report.add("engine.search, 1–2 chars (\(label))", short)
        report.add("engine.search, 3+ chars (\(label))", long)
        for (name, values) in Perf.samples.drain().sorted(by: { $0.key < $1.key }) where name != "engine search" {
            report.add("  \(name)", values)
        }
    }

    // MARK: - View model: typing at 10 keys/s with the real debounce

    private func typing(_ engine: Engine) async throws {
        let model = RecallViewModel(dataSource: engine, actions: PerfActions())
        let host = OffscreenHost(RecallView(model: model))
        defer { host.close() }
        var published: [ContinuousClock.Instant] = []
        let sink = model.$hits.dropFirst().sink { _ in published.append(.now) }
        defer { sink.cancel() }

        var firstFeedback: [Double] = [], afterLast: [Double] = [], updates: [Double] = []
        var perKey: [Double] = [], unanswered = 0, keys = 0
        for query in Self.queries {
            model.reset()
            try await Task.sleep(for: .milliseconds(300))
            published = []
            var first: ContinuousClock.Instant?, last = ContinuousClock.now
            var strokes: [ContinuousClock.Instant] = []
            for n in 1...query.count {
                last = .now
                strokes.append(last)
                if first == nil { first = last }
                model.query = String(query.prefix(n))
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(600))
            for (i, stroke) in strokes.enumerated() {
                let next = i + 1 < strokes.count ? strokes[i + 1] : .now
                keys += 1
                if let answer = published.first(where: { $0 >= stroke && $0 < next }) {
                    perKey.append(ms(answer, since: stroke))
                } else {
                    unanswered += 1
                }
            }
            if ProcessInfo.processInfo.environment["DAEMON_PERF_DEBUG"] != nil {
                print("typing '\(query)': per keystroke", perKey.suffix(query.count).map { String(format: "%.0f", $0) })
            }
            guard let first, let firstPublish = published.first, let lastPublish = published.last else { continue }
            firstFeedback.append(ms(firstPublish, since: first))
            afterLast.append(max(0, ms(lastPublish, since: last)))
            updates.append(Double(published.count))
        }
        report.add("typing: first keystroke → first results", firstFeedback)
        report.add("typing: last keystroke → final results", afterLast)
        report.add("typing: result updates per query (count)", updates, unit: "")
        report.add("typing: keystroke → its own results (\(unanswered) of \(keys) keystrokes got none)", perKey)
        for (name, values) in Perf.samples.drain().sorted(by: { $0.key < $1.key }) where name.hasPrefix("keystroke") || name.hasPrefix("thumbnail") || name.hasPrefix("engine") {
            report.add("  \(name) (signpost)", values)
        }
    }

    // MARK: - Panel: hotkey → visible, first and warm

    private func panelShow(_ engine: Engine) async throws {
        let controller = RecallPanelController(dataSource: engine, actions: PerfActions())
        controller.testOrigin = NSPoint(x: -10_000, y: -10_000)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(300))   // the app creates the panel at launch, long before the hotkey
        var firstFrame: [Double] = [], content: [Double] = [], warmFrame: [Double] = [], warmContent: [Double] = []
        var quickFrame: [Double] = [], quickContent: [Double] = []
        for i in 0..<16 {
            let start = ContinuousClock.now
            controller.show()
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            controller.panel.displayIfNeeded()
            let frame = ms(since: start)
            // Correct content = the recent grid with items in it, drawn.
            while !(controller.model.gridShown && controller.model.hits.count == RecallViewModel.recentLimit) {
                try await Task.sleep(for: .milliseconds(1))
                if ms(since: start) > 2000 { break }
            }
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            controller.panel.displayIfNeeded()
            let ready = ms(since: start)
            switch i {
            case 0: firstFrame.append(frame); content.append(ready)
            case 1...10: warmFrame.append(frame); warmContent.append(ready)
            default: quickFrame.append(frame); quickContent.append(ready)
            }
            // Leave it on a search, as people do, before closing; reopen a while later (the last five: right away).
            controller.model.query = "pricing"
            try await Task.sleep(for: .milliseconds(400))
            controller.hide()
            try await Task.sleep(for: .milliseconds(i < 10 ? 700 : 50))
        }
        report.add("panel show → first frame (first)", firstFrame)
        report.add("panel show → recent grid drawn (first)", content)
        report.add("panel show → first frame (warm)", warmFrame)
        report.add("panel show → recent grid drawn (warm)", warmContent)
        report.add("panel show → first frame (reopened within 50 ms)", quickFrame)
        report.add("panel show → recent grid drawn (reopened within 50 ms)", quickContent)
        _ = Perf.samples.drain()
    }

    // MARK: - Render: results update, selection, scrolling, recent grid, Show all

    private func render(_ engine: Engine) async throws {
        let model = RecallViewModel(dataSource: engine, actions: PerfActions(), debounce: .zero)
        let host = OffscreenHost(RecallView(model: model))
        defer { host.close() }
        var sets: [[SearchHit]] = []
        for q in Self.queries + ["pricing", "the", "notes"] { sets.append(try await engine.search(q)) }
        report.note("result set sizes: \(sets.map(\.count))")

        model.query = "pricing"
        try await Task.sleep(for: .milliseconds(400))
        host.draw()

        _ = Perf.samples.drain()
        var update: [Double] = []
        var phase = Perf.begin("bench: results update")   // phases mark the Time Profiler timeline
        defer { phase.end() }
        for round in 0..<3 {
            for hits in sets {
                let start = ContinuousClock.now
                model.apply(hits)
                host.draw()
                if round > 0 { update.append(ms(since: start)) }
            }
        }
        report.add("render: results update (layout + draw)", update)
        report.add("  thumbnail load (in render)", Perf.samples.drain()["thumbnail load"] ?? [])

        let biggest = sets.max { $0.count < $1.count } ?? []
        model.apply(biggest)
        host.draw()
        var select: [Double] = []
        phase.end()
        phase = Perf.begin("bench: selection")
        for _ in 0..<min(20, biggest.count - 1) {
            let start = ContinuousClock.now
            _ = model.handle(.down)
            host.draw()
            select.append(ms(since: start))
        }
        report.add("render: ↓ selection change (\(biggest.count) results)", select)

        model.apply(biggest)
        host.draw()
        if let scroll = host.scrollView() {
            var frames: [Double] = []
            phase.end()
            phase = Perf.begin("bench: scroll")
            let maxY = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
            var y: CGFloat = 0
            while y < maxY {
                y = min(maxY, y + 23)   // half a row per frame
                let start = ContinuousClock.now
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.draw()
                frames.append(ms(since: start))
            }
            report.add("render: scroll results, per frame", frames)
        }

        model.query = ""
        try await Task.sleep(for: .milliseconds(300))
        var grid: [Double] = []
        phase.end()
        phase = Perf.begin("bench: recent grid")
        let recent = try await engine.recent(limit: RecallViewModel.recentLimit)
        let older = Array(try await engine.recent(limit: 60).suffix(RecallViewModel.recentLimit))
        // In the app, results wait (≤ 12 ms) for their thumbnails to decode before they're applied; do the same here.
        ThumbnailCache.prefetch((recent + older).compactMap { engine.thumbnailURL(for: $0.item) }, maxPixels: ThumbnailCache.largePixels)
        try await Task.sleep(for: .milliseconds(100))
        for i in 0..<10 {
            let start = ContinuousClock.now
            model.apply(i % 2 == 0 ? older : recent)
            host.draw()
            grid.append(ms(since: start))
        }
        report.add("render: recent grid update (20 cards)", grid)

        // Switching layouts: the first keystroke (grid → results) and clearing the query (results → grid).
        var toResults: [Double] = [], toGrid: [Double] = []
        for _ in 0..<5 {
            var start = ContinuousClock.now
            model.query = "pricing"
            model.apply(sets[0])
            host.draw()
            toResults.append(ms(since: start))
            try await Task.sleep(for: .milliseconds(200))
            host.draw()
            start = .now
            model.query = ""
            host.draw()
            toGrid.append(ms(since: start))
            try await Task.sleep(for: .milliseconds(200))
            host.draw()
        }
        report.add("render: grid → results (first keystroke)", toResults)
        report.add("render: results → grid (query cleared)", toGrid)

        phase.end()
        phase = Perf.begin("bench: show all")
        var showAll: [Double] = [], showAllDraw: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            _ = model.handle(.cmdR)
            let firstPage = min(engine.totalCount, RecallViewModel.allPageSize)
            while model.hits.count < firstPage, ms(since: start) < 5000 { try await Task.sleep(for: .milliseconds(1)) }
            let loaded = ms(since: start)
            host.draw()
            showAll.append(loaded)
            showAllDraw.append(ms(since: start) - loaded)
            _ = model.handle(.cmdR)
            try await Task.sleep(for: .milliseconds(200))
            host.draw()
        }
        report.add("⌘R Show all → first \(RecallViewModel.allPageSize) of \(engine.totalCount) loaded", showAll)
        report.add("⌘R Show all: draw", showAllDraw)
        _ = Perf.samples.drain()
    }

    // MARK: - Thumbnails: lazy NSImage drawn on the main thread vs. ImageIO decode at display size

    private func thumbnails(_ engine: Engine) async throws {
        let urls = try await engine.recent(limit: 400).compactMap { engine.thumbnailURL(for: $0.item) }.prefix(40)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 104, pixelsHigh: 68, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        func draw(_ image: NSImage) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 104, height: 68))
            NSGraphicsContext.restoreGraphicsState()
        }
        var lazy: [Double] = [], mainDecoded: [Double] = [], offMain: [Double] = []
        for url in urls {
            let start = ContinuousClock.now
            if let image = NSImage(contentsOf: url) { draw(image) }
            lazy.append(ms(since: start))
        }
        for url in urls {
            let decodeStart = ContinuousClock.now
            let cg = await Task.detached { ThumbnailCache.decode(url, maxPixels: ThumbnailCache.rowPixels) }.value
            offMain.append(ms(since: decodeStart))
            let start = ContinuousClock.now
            if let cg { draw(NSImage(cgImage: cg, size: .zero)) }
            mainDecoded.append(ms(since: start))
        }
        report.add("thumbnail: NSImage(contentsOf:) + first draw, main thread", lazy)
        report.add("thumbnail: ImageIO decode at row size, background", offMain)
        report.add("thumbnail: draw decoded image, main thread", mainDecoded)
        _ = Perf.samples.drain()
    }

    // MARK: - Real model: query embedding cold/warm, and while the pipeline embeds a long document

    private func realEmbedder(_ library: Library) async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "DaemonEmbedder")
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Daemon/models/embeddinggemma-2-Q8_0.gguf")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.fileExists(atPath: models.path) else {
            return report.note("real model: skipped (DaemonEmbedder or model files missing)")
        }
        let client = EmbedderClient(executableURL: binary)
        defer { Task { await client.shutdown() } }
        try await report.time("real: first query embed (cold process)") { _ = try await client.embed(.query("pricing")) }
        var warm: [Double] = []
        for q in Self.queries + Self.queries.map({ String($0.prefix(5)) }) {
            let start = ContinuousClock.now
            _ = try await client.embed(.query(q))
            warm.append(ms(since: start))
        }
        report.add("real: query embed (warm)", warm)

        let engine = Engine(library: library, embedder: client,
                            stats: UsageStats(defaults: UserDefaults(suiteName: "perf-\(UUID())")!))
        await engine.start()
        try await engineSearch(engine, label: "real model")

        // A long document being indexed holds the model; how long does a query wait behind it?
        let document = String(repeating: "The quarterly roadmap covers pricing, billing and the docker migration. ", count: 110)
        var blocked: [Double] = [], firstShown: [Double] = [], fullShown: [Double] = []
        let model = RecallViewModel(dataSource: engine, actions: PerfActions())
        var published: [ContinuousClock.Instant] = []
        let sink = model.$hits.dropFirst().sink { _ in published.append(.now) }
        defer { sink.cancel() }
        for i in 0..<3 {
            let words = ["warranty", "invoice", "passport"][i]   // not typed before: no cached vector
            var indexing = Task.detached { _ = try? await client.embed(.document(document)) }
            try await Task.sleep(for: .milliseconds(5))
            var start = ContinuousClock.now
            _ = try await engine.search("\(words) receipt")
            blocked.append(ms(since: start))
            await indexing.value

            indexing = Task.detached { _ = try? await client.embed(.document(document)) }
            try await Task.sleep(for: .milliseconds(5))
            published = []
            start = .now
            model.query = "\(words) order"
            await indexing.value
            try await Task.sleep(for: .milliseconds(100))
            if let first = published.first { firstShown.append(ms(first, since: start)) }
            if let last = published.last { fullShown.append(ms(last, since: start)) }
            model.query = ""
            try await Task.sleep(for: .milliseconds(100))
        }
        report.add("real: engine.search while a long document is embedding", blocked)
        report.add("real: panel, keystroke → first results, model busy", firstShown)
        report.add("real: panel, keystroke → full results, model busy", fullShown)
        _ = Perf.samples.drain()
    }
}

// MARK: - Helpers

private func ms(since start: ContinuousClock.Instant) -> Double { ms(.now, since: start) }

private func ms(_ end: ContinuousClock.Instant, since start: ContinuousClock.Instant) -> Double {
    let c = (end - start).components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

@MainActor
private final class PerfActions: RecallActions {
    func paste(_ hit: SearchHit, fileURL: URL?) async -> Bool { true }
    func copy(_ hit: SearchHit, fileURL: URL?) {}
    func open(_ hit: SearchHit, fileURL: URL?) {}
}

/// A view in a borderless window far offscreen, drawn synchronously on demand.
@MainActor
private final class OffscreenHost {
    let window: NSWindow
    init<V: View>(_ view: V) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.Size.recallPanel), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        draw()
    }

    /// SwiftUI applies pending changes during layout; then draw everything that changed.
    func draw() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func scrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let s = view as? NSScrollView, (s.documentView?.frame.height ?? 0) > s.contentView.bounds.height + 1 { return s }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    func close() { window.orderOut(nil) }
}

final class PerfReport {
    private var lines: [String] = []

    func add(_ name: String, _ values: [Double], unit: String = " ms") {
        guard !values.isEmpty else { return lines.append("| \(name) | – | – | – | 0 |") }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        func f(_ v: Double) -> String { String(format: "%.2f", v) + unit }
        lines.append("| \(name) | \(f(pct(0.5))) | \(f(pct(0.95))) | \(f(sorted.last!)) | \(sorted.count) |")
    }

    func time(_ name: String, _ work: () async throws -> Void) async rethrows {
        let start = ContinuousClock.now
        try await work()
        add(name, [ms(since: start)])
    }

    func note(_ text: String) { lines.append("| _\(text)_ | | | | |") }

    func markdown() -> String {
        (["| Interval | median | p95 | max | n |", "|---|---|---|---|---|"] + lines).joined(separator: "\n")
    }
}

/// Bag-of-words vectors with a stable hash (String.hashValue changes per process), so stored vectors match later runs.
struct StableFakeEmbedder: Embedder {
    var modelVersion: String { "embeddinggemma-2-q8_0" }
    func embed(_ input: EmbedInput) async throws -> [Float] {
        switch input {
        case .query(let s), .document(let s): return PerfLibrary.vector(s)
        case .image(let u), .audio(let u): return PerfLibrary.vector(u.lastPathComponent)
        }
    }
}

// MARK: - Generated library

enum PerfLibrary {
    static let buildDir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".build")
    static let root = buildDir.appending(path: "perf-library-v1")

    static func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 768)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            var h: UInt64 = 0xcbf29ce484222325
            for b in word.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            v[Int(h % 768)] += 1
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm == 0 ? v : v.map { $0 / norm }
    }

    static let topics: [[String]] = [
        "pricing yearly monthly toggle discount annual plan billing invoice subscription badge".split(separator: " ").map(String.init),
        "flight hotel booking seat airport passport itinerary confirmation gate terminal".split(separator: " ").map(String.init),
        "docker container kubernetes deploy build swift compile error stack trace cache".split(separator: " ").map(String.init),
        "recipe pasta garlic oven bake dinner grocery basil tomato olive".split(separator: " ").map(String.init),
        "meeting agenda notes standup review deadline roadmap quarter launch hiring".split(separator: " ").map(String.init),
        "design figma mockup color typography layout spacing icon dark mode".split(separator: " ").map(String.init),
        "receipt tax expense budget payment refund laptop warranty order shipping".split(separator: " ").map(String.init),
        "doctor appointment prescription workout sleep running knee physio".split(separator: " ").map(String.init),
    ]
    static let filler = "the a for with and to of on in about from next this that we should before after it is".split(separator: " ").map(String.init)

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func sentence(_ words: Int, _ rng: inout RNG) -> String {
        let topic = topics.randomElement(using: &rng)!, other = topics.randomElement(using: &rng)!
        return (0..<words).map { _ in
            let r = Int.random(in: 0..<10, using: &rng)
            return r < 5 ? topic.randomElement(using: &rng)! : r < 6 ? other.randomElement(using: &rng)! : filler.randomElement(using: &rng)!
        }.joined(separator: " ")
    }

    /// Builds the library once (≈ 1 min); later runs reuse it.
    static func prepare() async throws -> URL {
        let done = root.appending(path: "complete")
        if FileManager.default.fileExists(atPath: done.path) { return root }
        try? FileManager.default.removeItem(at: root)
        let library = try Library(root: root)
        let scratch = buildDir.appending(path: "perf-scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var rng = RNG(state: 42)
        let images = try (0..<25).map { try makePNG(scratch.appending(path: "src-\($0).png"), &rng) }
        let pdfs = try (0..<10).map { try makePDF(scratch.appending(path: "Report \($0).pdf"), &rng) }
        let apps = ["Safari", "Figma", "Mail", "Slack", "Notes", "Xcode", "Arc", "Preview", "Messages"]
        let now = Date()

        for i in 0..<2000 {
            let context = CaptureContext(createdAt: now.addingTimeInterval(-Double(i) * 3_900 - .random(in: 0..<600, using: &rng)),
                                         sourceApp: apps.randomElement(using: &rng),
                                         windowTitle: sentence(.random(in: 3...7, using: &rng), &rng).capitalized)
            let payload: CapturePayload
            var segments: [(Modality, String, Int?, Int?)] = []   // modality, text for the vector, page, startMs
            switch i % 20 {
            case 0..<11:
                let text = sentence(.random(in: 12...160, using: &rng), &rng)
                payload = .text(text)
                let words = text.split(separator: " ")
                for start in stride(from: 0, to: words.count, by: 60) {
                    segments.append((.text, words[start..<min(words.count, start + 60)].joined(separator: " "), nil, nil))
                }
            case 11..<16:
                let copy = scratch.appending(path: "shot-\(i).png")
                try FileManager.default.copyItem(at: images[i % images.count], to: copy)
                payload = .screenshot(copy)
                segments.append((.image, sentence(30, &rng), nil, nil))
            case 16, 17:
                let audio = scratch.appending(path: "voice-\(i).m4a")
                try Data((0..<2048).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: audio)
                payload = .voiceNote(audio)
                for w in 0..<3 { segments.append((.audio, sentence(20, &rng), nil, w * 27_000)) }
            case 18:
                payload = .files([pdfs[i % pdfs.count]])
                for p in 1...4 { segments.append((.text, sentence(80, &rng), p, nil)) }
            default:
                let title = sentence(6, &rng).capitalized
                payload = .link(url: URL(string: "https://example.com/\(i)/\(title.split(separator: " ").first ?? "page")")!,
                                title: title, screenshot: nil)
                segments.append((.text, title, nil, nil))
            }
            guard let item = try await library.add(Capture(payload: payload, context: context)).first, let id = item.id else { continue }
            let saved = try await library.saveSegments(segments.map {
                Segment(itemId: id, modality: $0.0, page: $0.2, startMs: $0.3, endMs: $0.3.map { $0 + 30_000 },
                        text: $0.0 == .audio ? nil : $0.1)
            })
            for (segment, source) in zip(saved, segments) {
                try await library.saveVector(vector(source.1), segmentId: segment.id!, modelVersion: "embeddinggemma-2-q8_0")
            }
            try await library.setStatus(.ready, itemId: id)
        }
        try Data().write(to: done)
        return root
    }

    private static func makePNG(_ url: URL, _ rng: inout RNG) throws -> URL {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for _ in 0..<400 {
            ctx.setFillColor(CGColor(srgbRed: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0..<Double(w), using: &rng), y: .random(in: 0..<Double(h), using: &rng),
                            width: .random(in: 4..<300, using: &rng), height: .random(in: 2..<60, using: &rng)))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func makePDF(_ url: URL, _ rng: inout RNG) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for _ in 0..<4 {
            ctx.beginPDFPage(nil)
            for line in 0..<40 {
                ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
                ctx.fill(CGRect(x: 60, y: 720 - Double(line) * 16, width: .random(in: 200..<490, using: &rng), height: 6))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
