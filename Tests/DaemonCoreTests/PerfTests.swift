import AppKit
import Vision
import XCTest
@testable import DaemonCore

/// Process CPU time (all threads), for "how many cores for how long".
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

/// Times `body`: wall seconds and CPU seconds.
func clock<T>(_ body: () async throws -> T) async rethrows -> (T, wall: Double, cpu: Double) {
    let c0 = cpuSeconds(), t0 = ContinuousClock.now
    let value = try await body()
    let wall = ContinuousClock.now - t0
    return (value, Double(wall.components.attoseconds) / 1e18 + Double(wall.components.seconds), cpuSeconds() - c0)
}

var benchmarking: Bool { ProcessInfo.processInfo.environment["DAEMON_BENCH"] != nil }

final class OCRTests: XCTestCase {
    static let screenshots = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "design/screenshots")

    private func image(_ name: String) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(Self.screenshots.appending(path: name) as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Vision with language correction over the whole image: what Daemon did before, and the reference.
    private func corrected(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 })
    }

    /// Full-screen screenshots (3056×2056): the same readable words as correcting everything, for well under half the CPU.
    func testScreenshotTextMatchesFullCorrectionForAFractionOfTheCPU() throws {
        for name in ["screens-ivory.png", "screens-smoked.png"] {
            let shot = try image(name)
            _ = try corrected(shot)   // Vision loads its models on first use
            let c0 = cpuSeconds()
            let reference = words(try corrected(shot))
            let c1 = cpuSeconds()
            let text = try XCTUnwrap(try Extractor().recognizeText(shot, orientation: .up))
            let c2 = cpuSeconds()
            let got = words(text)

            let recall = Double(reference.intersection(got).count) / Double(reference.count)
            XCTAssertGreaterThanOrEqual(recall, 0.98, "\(name) missing \(reference.subtracting(got).sorted())")
            for word in ["copy", "turn", "starter", "security", "accessibility", "recall", "pricing"] where reference.contains(word) {
                XCTAssertTrue(got.contains(word), "\(name): \(word)")
            }
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value >= 0x400 && $0.value < 0x530 },
                           "no Cyrillic look-alikes in English text")
            let share = (c2 - c1) / (c1 - c0)
            XCTAssertLessThan(share, 0.5, "\(name): CPU \(c2 - c1) s vs \(c1 - c0) s correcting everything")
            print(String(format: "[bench] OCR %@: %.2f s CPU (was %.2f s), %.1f%% of words", name, c2 - c1, c1 - c0, recall * 100))
        }
    }

    func testLinesThatNeedCorrection() {
        let lines = ["Turn on Daemon, then return here.", "lurn on Daemon, then return here.", "| Сору",
                     "Privacy & SecurityAccessibility", "Pricing table component", "Slarter plan"]
        XCTAssertEqual(Extractor.linesNeedingCorrection(lines), IndexSet([1, 2, 3, 5]))
    }
}

/// Opt-in benchmarks (DAEMON_BENCH=1): extraction per kind, the model's warm-up and the launch path.
/// Numbers print as `[bench] ...` lines.
final class PerfBenchmarks: XCTestCase {
    func testExtractEachKind() async throws {
        try XCTSkipUnless(benchmarking, "benchmark; set DAEMON_BENCH=1")
        let fixtures = ExtractTests()
        fixtures.dir = FileManager.default.temporaryDirectory.appendingPathComponent("PerfBenchmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtures.dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures.dir) }
        let dir = fixtures.dir!

        let words = (0..<10_000).map { ["pricing", "toggle", "monthly", "yearly", "badge", "annual"][$0 % 6] }
        let text = words.joined(separator: " ")
        let shot = OCRTests.screenshots.appending(path: "screens-ivory.png")
        let pdf = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for page in 0..<5 {
            ctx.beginPDFPage(nil)
            fixtures.draw("Quarterly report page \(page) about pricing", in: ctx, at: CGPoint(x: 72, y: 700), fontSize: 18)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let audio = dir.appendingPathComponent("talk.wav")
        try fixtures.writeSine(to: audio, seconds: 62, sampleRate: 44_100, channels: 2)
        let video = dir.appendingPathComponent("clip.mp4")
        try await fixtures.writeMovie(to: video, seconds: 25)

        let cases: [(String, Item, URL?)] = [
            ("text 10k words", Item(id: 1, kind: .text, text: text), nil),
            ("screenshot 3056x2056", Item(id: 2, kind: .screenshot), shot),
            ("pdf 5 pages", Item(id: 3, kind: .pdf), pdf),
            ("audio 62 s", Item(id: 4, kind: .audio), audio),
            ("video 25 s", Item(id: 5, kind: .video), video),
        ]
        for (name, item, url) in cases {
            let work = dir.appendingPathComponent("work-\(item.id!)")
            _ = try await Extractor().segments(for: item, fileURL: url, workDir: work)   // warm
            let (drafts, wall, cpu) = try await clock { try await Extractor().segments(for: item, fileURL: url, workDir: work) }
            print(String(format: "[bench] extract %@: %.0f ms wall, %.0f ms CPU (%.1f cores), %d segments",
                         name, wall * 1000, cpu * 1000, cpu / wall, drafts.count))
        }
    }

    /// Process start -> ready, then the first and a later query: what the first Recall after launch waits on.
    func testModelWarmUp() async throws {
        try XCTSkipUnless(benchmarking, "benchmark; set DAEMON_BENCH=1")
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "DaemonEmbedder not built")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.models.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path))
        for run in 1...3 {
            let client = EmbedderClient(executableURL: binary)
            let (_, start, _) = try await clock { try await client.stats() }
            let (_, first, _) = try await clock { try await client.embed(.query("pricing toggle monthly yearly")) }
            let (_, second, _) = try await clock { try await client.embed(.query("annual badge on the plan picker")) }
            await client.shutdown()
            print(String(format: "[bench] model run %d: start -> ready %.0f ms, first query %.0f ms, next query %.0f ms",
                         run, start * 1000, first * 1000, second * 1000))
        }
    }

    /// The launch path after the menu bar icon: open the library, load its vectors, warm the model.
    /// Runs on a copy of this Mac's library when there is one.
    @MainActor
    func testLaunchPath() async throws {
        try XCTSkipUnless(benchmarking, "benchmark; set DAEMON_BENCH=1")
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "DaemonEmbedder not built")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = Library.defaultRoot.appendingPathComponent("library.sqlite")
        if FileManager.default.fileExists(atPath: real.path) {
            try FileManager.default.copyItem(at: real, to: root.appendingPathComponent("library.sqlite"))
        }

        let (library, open, _) = try await clock { try Library(root: root) }
        let client = EmbedderClient(executableURL: binary)
        let engine = Engine(library: library, embedder: client)
        let (_, start, _) = await clock { await engine.start() }
        let (_, warm, _) = try await clock { try await client.stats() }   // what launch does to start the model
        let (hits, query, _) = try await clock { try await engine.search("pricing toggle") }
        await client.shutdown()
        print(String(format: "[bench] launch: library open %.1f ms, engine start (%d items) %.1f ms, model ready %.0f ms, first Recall %.1f ms (%d hits)",
                     open * 1000, engine.totalCount, start * 1000, warm * 1000, query * 1000, hits.count))
    }

    static let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Daemon/models")
}
