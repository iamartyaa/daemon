import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaemonCore

final class EmbeddingProtocolTests: XCTestCase {
    func testRequestRoundTripsEveryInput() throws {
        let inputs: [EmbedInput] = [
            .query("docker can't reach host"),
            .document("line one\nline \"two\" ✓"),
            .image(URL(fileURLWithPath: "/tmp/a b/shot.png")),
            .audio(URL(fileURLWithPath: "/tmp/note.wav")),
        ]
        for (i, input) in inputs.enumerated() {
            let request = EmbedderRequest(id: i, op: .embed, input: input)
            let json = try JSONEncoder().encode(request)
            XCTAssertFalse(json.contains(0x0A), "a request must stay on one line")
            let decoded = try JSONDecoder().decode(EmbedderRequest.self, from: json)
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.input?.embedInput, input)
        }
    }

    func testWireShape() throws {
        let json = String(decoding: try JSONEncoder().encode(EmbedderRequest(id: 7, op: .embed, input: .query("hi"))), as: UTF8.self)
        XCTAssertTrue(json.contains(#""input":{"query":"hi"}"#), json)
        let stats = try JSONDecoder().decode(EmbedderRequest.self, from: Data(#"{"id":3,"op":"stats"}"#.utf8))
        XCTAssertEqual(stats, EmbedderRequest(id: 3, op: .stats))
        let twoKeys = try JSONDecoder().decode(EmbedderRequest.self, from: Data(#"{"id":1,"op":"embed","input":{"query":"a","image":"/b"}}"#.utf8))
        XCTAssertNil(twoKeys.input?.embedInput)
    }

    func testResponseRoundTrips() throws {
        let responses = [
            EmbedderResponse(id: 1, vector: [0.1, -0.25, 1e-7]),
            EmbedderResponse(id: 2, error: "cannot decode /x.png"),
            EmbedderResponse(id: 3, footprintMB: 412.5, mediaLoaded: true, pid: 42),
        ]
        for response in responses {
            let decoded = try JSONDecoder().decode(EmbedderResponse.self, from: try JSONEncoder().encode(response))
            XCTAssertEqual(decoded, response)
        }
    }
}

/// Runs the real DaemonEmbedder binary; skipped when the model files aren't on disk.
final class EmbeddingIntegrationTests: XCTestCase {
    var binary: URL!
    var scratch: URL!

    override func setUpWithError() throws {
        binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "DaemonEmbedder not built at \(binary.path)")
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Daemon/models")
        for file in ["embeddinggemma-2-Q8_0.gguf", "mmproj-embeddinggemma-2-Q8_0.gguf"] {
            try XCTSkipUnless(FileManager.default.fileExists(atPath: models.appendingPathComponent(file).path), "missing \(file)")
        }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testQueryRanksMatchingDocumentFirst() async throws {
        let client = EmbedderClient(executableURL: binary)
        let docs = [
            "Use host.docker.internal to reach services on the host machine from inside a Docker container.",
            "Default to yearly billing and show the monthly price small on the pricing page.",
            "The master theorem gives asymptotic bounds for divide and conquer recurrences.",
        ]
        let queries = ["docker container can't reach host", "pricing toggle monthly yearly", "proof of the master theorem"]
        var docVectors: [[Float]] = []
        for d in docs { docVectors.append(try await client.embed(.document(d))) }
        for (i, q) in queries.enumerated() {
            let start = ContinuousClock.now
            let qv = try await client.embed(.query(q))
            print("query embed round trip: \(ContinuousClock.now - start)")
            assertUnitVector(qv)
            let scores = docVectors.map { cosine(qv, $0) }
            XCTAssertEqual(scores.indices.max { scores[$0] < scores[$1] }, i, "\(q): \(scores)")
        }

        // Longer than the 2,048-token context: truncated, not an error.
        let long = try await client.embed(.document(String(repeating: docs.joined(separator: " ") + " ", count: 80)))
        assertUnitVector(long)
        print(String(format: "text-only footprint: %.0f MB", try await client.stats().footprintMB))
        await client.shutdown()
    }

    func testImageAndAudioEmbed() async throws {
        let client = EmbedderClient(executableURL: binary)
        let start = ContinuousClock.now
        assertUnitVector(try await client.embed(.image(try writePNG())))
        print("first image embed (incl. projector load): \(ContinuousClock.now - start)")
        assertUnitVector(try await client.embed(.audio(try writeWAV())))

        do {
            _ = try await client.embed(.image(scratch.appendingPathComponent("missing.png")))
            XCTFail("expected an error for a missing file")
        } catch EmbedderError.remote(let message) {
            XCTAssertTrue(message.contains("missing.png"), message)
        }
        await client.shutdown()
    }

    func testRestartsAfterCrash() async throws {
        let client = EmbedderClient(executableURL: binary)
        let before = try await client.stats().pid
        XCTAssertEqual(kill(before, SIGKILL), 0)
        assertUnitVector(try await client.embed(.query("still alive?")))
        let after = try await client.stats().pid
        XCTAssertNotEqual(after, before)
        await client.shutdown()
    }

    func testIdleUnloadReleasesMedia() async throws {
        let client = EmbedderClient(executableURL: binary, mediaIdleTimeout: .seconds(2))
        _ = try await client.embed(.image(try writePNG()))
        let loaded = try await client.stats()
        XCTAssertTrue(loaded.mediaLoaded)

        try await Task.sleep(for: .seconds(3))
        let unloaded = try await client.stats()
        print(String(format: "media-loaded footprint: %.0f MB, after idle unload: %.0f MB", loaded.footprintMB, unloaded.footprintMB))
        XCTAssertFalse(unloaded.mediaLoaded)
        XCTAssertNotEqual(unloaded.pid, loaded.pid)
        XCTAssertLessThan(unloaded.footprintMB, loaded.footprintMB - 300)
        await client.shutdown()
    }

    // MARK: - helpers

    private func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    private func assertUnitVector(_ v: [Float], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(v.count, 768, file: file, line: line)
        XCTAssertEqual(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-3, file: file, line: line)
    }

    /// 256x256 PNG: a red disc on a blue background.
    private func writePNG() throws -> URL {
        let url = scratch.appendingPathComponent("disc.png")
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 48, y: 48, width: 160, height: 160))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// 2 s of a 440 Hz tone, 16 kHz mono 16-bit PCM.
    private func writeWAV() throws -> URL {
        let url = scratch.appendingPathComponent("tone.wav")
        let rate = 16_000
        let samples = (0..<(rate * 2)).map { Int16(12_000 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let pcmBytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcmBytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(pcmBytes))
        samples.forEach { put($0) }
        try data.write(to: url)
        return url
    }
}
