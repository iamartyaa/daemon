import XCTest
@testable import DaemonCore

/// Measures the model process footprint per audio segment length. Set DAEMON_QA_AUDIO_DIR (audio15/30/45/60.wav).
final class QAAudioMemoryTests: XCTestCase {
    func testFootprintPerSegmentLength() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DAEMON_QA_AUDIO_DIR"] else { throw XCTSkip("set DAEMON_QA_AUDIO_DIR") }
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        for secs in [15, 30, 45, 60] {
            let client = EmbedderClient(executableURL: binary)   // fresh process each time
            let before = try await client.stats().footprintMB
            let start = ContinuousClock.now
            _ = try await client.embed(.audio(URL(fileURLWithPath: "\(dir)/audio\(secs).wav")))
            let first = ContinuousClock.now - start
            let warmStart = ContinuousClock.now
            _ = try await client.embed(.audio(URL(fileURLWithPath: "\(dir)/audio\(secs).wav")))
            let warm = ContinuousClock.now - warmStart
            let after = try await client.stats().footprintMB
            print(String(format: "QA audio %2ds: text-only %.0f MB -> %.0f MB; first %@, warm %@", secs, before, after, "\(first)", "\(warm)"))
            await client.shutdown()
        }
    }
}
