import CryptoKit
import XCTest
@testable import DaemonCore

final class ModelDownloaderTests: XCTestCase {
    private var dir: URL!
    private let textData = fakeBytes(300_000, seed: 1)
    private let projData = fakeBytes(500_000, seed: 2)
    private lazy var textFile = ModelFile(name: "text.gguf", size: Int64(textData.count), sha256: sha(textData))
    private lazy var projFile = ModelFile(name: "proj.gguf", size: Int64(projData.count), sha256: sha(projData))
    private lazy var manifest = ModelManifest(baseURL: URL(string: "https://stub.test/models/")!, files: [textFile, projFile])

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)")
        StubServer.reset(files: ["text.gguf": textData, "proj.gguf": projData])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDownloader(manifest: ModelManifest? = nil, freeSpace: Int64 = .max) -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return ModelDownloader(manifest: manifest ?? self.manifest, directory: dir,
                               session: URLSession(configuration: config), retryDelay: 0,
                               freeSpace: { _ in freeSpace })
    }

    private func contents(_ name: String) -> Data? { FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }

    func testFullDownloadVerifiesAndRenames() async throws {
        let downloader = makeDownloader()
        let reports = Reports()
        try await downloader.download { reports.append($0) }

        XCTAssertEqual(contents("text.gguf"), textData)
        XCTAssertEqual(contents("proj.gguf"), projData)
        XCTAssertFalse(exists("text.gguf.part"))
        XCTAssertFalse(exists("proj.gguf.part"))
        let status = await downloader.status()
        XCTAssertTrue(status.isComplete)
        XCTAssertEqual(status.downloadedBytes, 800_000)

        let last = try XCTUnwrap(reports.all.last)
        XCTAssertEqual(last.bytesDone, 800_000)
        XCTAssertEqual(last.bytesTotal, 800_000)
        XCTAssertEqual(last.fileName, "proj.gguf")
        XCTAssertEqual(last.fileBytesDone, 500_000)
        XCTAssertTrue(reports.all.contains { $0.fileName == "text.gguf" && $0.fileBytesDone == 300_000 })
        XCTAssertEqual(StubServer.ranges, [nil, nil])
    }

    func testDropMidFileRetriesWithRangeForRemainderOnly() async throws {
        StubServer.set { $0.failOnceAfter = 100_000 }
        try await makeDownloader().download()

        XCTAssertEqual(contents("text.gguf"), textData)
        XCTAssertEqual(StubServer.ranges, [nil, "bytes=100000-", nil])
    }

    func testCancelLeavesResumablePartThenResumes() async throws {
        StubServer.set { $0.stallAfter = 120_000 }
        let downloader = makeDownloader()
        let task = Task { try await downloader.download() }

        let part = dir.appendingPathComponent("text.gguf.part")
        for _ in 0..<500 where (contents("text.gguf.part")?.count ?? 0) < 120_000 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(FileManager.default.contents(atPath: part.path), textData.prefix(120_000))
        let paused = await downloader.status()
        XCTAssertEqual(paused.downloadedBytes, 120_000)

        StubServer.set { $0.stallAfter = nil }
        try await downloader.download()
        XCTAssertEqual(contents("text.gguf"), textData)
        XCTAssertEqual(StubServer.ranges, [nil, "bytes=120000-", nil])
    }

    func testServerIgnoringRangeRestartsFileCleanly() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 50_000).write(to: dir.appendingPathComponent("text.gguf.part"))
        StubServer.set { $0.ignoreRange = true }

        try await makeDownloader().download()
        XCTAssertEqual(contents("text.gguf"), textData)
        XCTAssertEqual(StubServer.ranges.first, "bytes=50000-")
    }

    func testHashMismatchRemovesFileAndReports() async throws {
        var bad = manifest
        bad.files[0].sha256 = String(repeating: "0", count: 64)
        do {
            try await makeDownloader(manifest: bad).download()
            XCTFail("expected corrupt")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .corrupt(file: "text.gguf"))
        }
        XCTAssertFalse(exists("text.gguf"))
        XCTAssertFalse(exists("text.gguf.part"))
        XCTAssertFalse(exists("proj.gguf"))
    }

    func testPresentFilesAreSkipped() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try textData.write(to: dir.appendingPathComponent("text.gguf"))
        let downloader = makeDownloader()
        let before = await downloader.status()
        XCTAssertEqual(before.present, [textFile])
        XCTAssertEqual(before.missing, [projFile])

        try await downloader.download()
        XCTAssertEqual(StubServer.paths, ["/models/proj.gguf"])

        try await downloader.download()
        XCTAssertEqual(StubServer.paths, ["/models/proj.gguf"], "nothing fetched once complete")
    }

    func testInsufficientDiskSpaceFailsBeforeAnyRequest() async throws {
        do {
            try await makeDownloader(freeSpace: 10_000).download()
            XCTFail("expected disk space error")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .insufficientDiskSpace(needed: 800_000, available: 10_000))
            XCTAssertNotNil(error.recoverySuggestion)
        }
        XCTAssertTrue(StubServer.paths.isEmpty)
    }

    func testNonTransientHTTPErrorIsReported() async throws {
        StubServer.set { $0.files = [:] }
        do {
            try await makeDownloader().download()
            XCTFail("expected http error")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .http(status: 404))
        }
        XCTAssertEqual(StubServer.paths.count, 1, "404 is not retried")
    }

    func testRealManifestMatchesHuggingFace() {
        let m = ModelManifest.embeddingGemma2
        XCTAssertEqual(m.totalBytes, 864_676_480)
        XCTAssertEqual(m.remoteURL(for: .embeddingGemma2).absoluteString,
                       "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/embeddinggemma-2-Q8_0.gguf")
    }
}

// MARK: - Helpers

private func fakeBytes(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed })
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ModelDownloadProgress] = []
    func append(_ p: ModelDownloadProgress) { lock.withLock { items.append(p) } }
    var all: [ModelDownloadProgress] { lock.withLock { items } }
}

/// In-process stand-in for Hugging Face: serves `files` by last path component, honors `Range: bytes=N-`.
final class StubServer: URLProtocol {
    struct Config {
        var files: [String: Data] = [:]
        var ignoreRange = false
        var failOnceAfter: Int?   // send this many bytes, then drop the connection (once)
        var stallAfter: Int?      // send this many bytes, then hang until cancelled
    }

    private static let lock = NSLock()
    private static var config = Config()
    private static var requests: [URLRequest] = []

    static func reset(files: [String: Data]) { lock.withLock { config = Config(files: files); requests = [] } }
    static func set(_ change: (inout Config) -> Void) { lock.withLock { change(&config) } }
    static var ranges: [String?] { lock.withLock { requests.map { $0.value(forHTTPHeaderField: "Range") } } }
    static var paths: [String] { lock.withLock { requests.map { $0.url!.path } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let config = Self.lock.withLock {
            Self.requests.append(request)
            let current = Self.config
            Self.config.failOnceAfter = nil
            return current
        }
        let url = request.url!
        guard let data = config.files[url.lastPathComponent] else {
            respond(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var start = 0
        if !config.ignoreRange, let range = request.value(forHTTPHeaderField: "Range") {
            start = Int(range.dropFirst("bytes=".count).dropLast())!
        }
        let body = Data(data[start...])
        respond(HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Length": "\(body.count)"])!)

        if let cut = config.failOnceAfter {
            client?.urlProtocol(self, didLoad: body.prefix(cut))
            // Fail a moment later so the bytes reach the delegate first, like a real mid-stream drop.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            return
        }
        if let cut = config.stallAfter {
            client?.urlProtocol(self, didLoad: body.prefix(cut))
            return
        }
        for chunkStart in stride(from: 0, to: body.count, by: 64 * 1024) {
            client?.urlProtocol(self, didLoad: body[chunkStart..<min(chunkStart + 64 * 1024, body.count)])
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(_ response: HTTPURLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}
