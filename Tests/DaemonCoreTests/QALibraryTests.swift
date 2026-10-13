import XCTest
@testable import DaemonCore

/// Runs Recall queries against a copy of a real library. Set DAEMON_QA_LIBRARY to the library folder and
/// DAEMON_QA_QUERIES to queries separated by "|". Skipped otherwise.
@MainActor
final class QALibraryTests: XCTestCase {
    func testQueries() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["DAEMON_QA_LIBRARY"], let queries = env["DAEMON_QA_QUERIES"] else {
            throw XCTSkip("set DAEMON_QA_LIBRARY and DAEMON_QA_QUERIES")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("qa-lib-\(UUID())")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        let embedder = EmbedderClient(executableURL: binary)
        let engine = Engine(library: try Library(root: copy), embedder: embedder,
                            stats: UsageStats(defaults: UserDefaults(suiteName: "qa-\(UUID())")!))
        await engine.start()
        for query in queries.split(separator: "|").map(String.init) {
            let start = ContinuousClock.now
            let hits = try await engine.search(query)
            let elapsed = ContinuousClock.now - start
            let qv = try await embedder.embed(.query(query))
            let cos = engine.index.search(qv, limit: 20, allowedItems: nil).map { "#\($0.itemId)=\(String(format: "%.3f", $0.score))" }
            print("QA '\(query)' (\(elapsed)) cosine: \(cos.prefix(6).joined(separator: " "))")
            for hit in hits.prefix(5) {
                print(String(format: "  #%lld %@ %.4f %@", hit.item.id ?? -1, hit.item.kind.rawValue, hit.score,
                             String((hit.item.text ?? hit.item.originalPath.map { ($0 as NSString).lastPathComponent } ?? hit.matchedSegment?.text ?? "").prefix(50))))
            }
        }
        await embedder.shutdown()
    }
}
