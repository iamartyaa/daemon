import CryptoKit
import Foundation

public struct ModelStatus: Sendable, Equatable {
    public var present: [ModelFile]       // full size on disk (sha256 is checked when a download completes)
    public var missing: [ModelFile]
    public var downloadedBytes: Int64     // present files plus resumable partial downloads
    public var totalBytes: Int64
    public var isComplete: Bool { missing.isEmpty }
}

public struct ModelDownloadProgress: Sendable, Equatable {
    public var fileName: String
    public var fileBytesDone: Int64
    public var fileBytesTotal: Int64
    public var bytesDone: Int64           // overall, across all files
    public var bytesTotal: Int64
    public var bytesPerSecond: Double?    // nil until there is enough to measure

    public init(fileName: String, fileBytesDone: Int64, fileBytesTotal: Int64,
                bytesDone: Int64, bytesTotal: Int64, bytesPerSecond: Double? = nil) {
        self.fileName = fileName; self.fileBytesDone = fileBytesDone; self.fileBytesTotal = fileBytesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }

    public var secondsRemaining: Double? {
        guard let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(max(bytesTotal - bytesDone, 0)) / rate
    }
}

public enum ModelDownloadError: Error, Equatable, LocalizedError {
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case corrupt(file: String)
    case http(status: Int)
    case network(URLError.Code)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace: "Not enough free space."
        case .corrupt: "The download didn't come through intact."
        case .http(let status): "Hugging Face didn't answer as expected (\(status))."
        case .network: "The connection dropped."
        case .alreadyRunning: "Already downloading."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .insufficientDiskSpace(let needed, _):
            "Daemon needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free. Make some room, then try again."
        case .corrupt: "The damaged file was removed. Try again to fetch a fresh copy."
        case .http: "Try again in a few minutes."
        case .network: "Check your internet connection, then try again. Daemon picks up where it left off."
        case .alreadyRunning: nil
        }
    }
}

/// Fetches the model files into `directory` on first launch. Resumable: bytes land in `<name>.part`
/// and continue with an HTTP Range request; cancel the calling task to pause.
public actor ModelDownloader {
    public nonisolated let manifest: ModelManifest
    public nonisolated let directory: URL
    private let session: URLSession
    private let retryDelay: TimeInterval
    private let freeSpace: @Sendable (URL) throws -> Int64
    private let maxAttempts = 4
    private var isRunning = false

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Daemon/models", isDirectory: true)
    }

    /// - Parameters:
    ///   - retryDelay: first backoff after a transient network error; doubles on each retry.
    ///   - freeSpace: bytes available on the volume holding the given directory.
    public init(manifest: ModelManifest = .embeddingGemma2,
                directory: URL = ModelDownloader.defaultDirectory,
                session: URLSession? = nil,
                retryDelay: TimeInterval = 1,
                freeSpace: @escaping @Sendable (URL) throws -> Int64 = ModelDownloader.availableCapacity) {
        self.manifest = manifest
        self.directory = directory
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.urlCache = nil
            return URLSession(configuration: config)
        }()
        self.retryDelay = retryDelay
        self.freeSpace = freeSpace
    }

    public nonisolated func localURL(for file: ModelFile) -> URL { directory.appendingPathComponent(file.name) }
    nonisolated func partURL(for file: ModelFile) -> URL { directory.appendingPathComponent(file.name + ".part") }

    /// Cheap launch-time check: a file counts as present when its size matches the manifest.
    public func status() -> ModelStatus {
        var present: [ModelFile] = [], missing: [ModelFile] = [], downloaded: Int64 = 0
        for file in manifest.files {
            if Self.size(of: localURL(for: file)) == file.size {
                present.append(file)
                downloaded += file.size
            } else {
                missing.append(file)
                downloaded += min(Self.size(of: partURL(for: file)) ?? 0, file.size)
            }
        }
        return ModelStatus(present: present, missing: missing, downloadedBytes: downloaded, totalBytes: manifest.totalBytes)
    }

    /// Downloads whatever is missing, in manifest order. Throws `CancellationError` when the task is
    /// cancelled (the `.part` file stays for the next call) or a `ModelDownloadError`.
    public func download(progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }) async throws {
        guard !isRunning else { throw ModelDownloadError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = status()
            let needed = current.totalBytes - current.downloadedBytes
            if needed > 0 {
                let available = try freeSpace(directory)
                guard available >= needed else {
                    throw ModelDownloadError.insufficientDiskSpace(needed: needed, available: available)
                }
            }

            var meter = ProgressMeter(total: current.totalBytes, startDone: current.downloadedBytes, report: progress)
            var finished: Int64 = 0
            for file in manifest.files {
                if !current.present.contains(file) {
                    try await fetch(file, finished: finished, meter: &meter)
                }
                finished += file.size
            }
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw ModelDownloadError.network(error.code)
        }
    }

    // MARK: - Private

    private func fetch(_ file: ModelFile, finished: Int64, meter: inout ProgressMeter) async throws {
        try? FileManager.default.removeItem(at: localURL(for: file)) // wrong-size leftover
        var attempt = 0
        while true {
            do {
                try await transfer(file, finished: finished, meter: &meter)
                break
            } catch let error where Self.isTransient(error) && attempt < maxAttempts - 1 {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * pow(2, Double(attempt)) * 1e9))
                attempt += 1
            }
        }
        try FileManager.default.moveItem(at: partURL(for: file), to: localURL(for: file))
    }

    /// One attempt: resume `<name>.part` from its current length, then verify sha256.
    private func transfer(_ file: ModelFile, finished: Int64, meter: inout ProgressMeter) async throws {
        let part = partURL(for: file)
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: part)
        defer { try? handle.close() }

        var offset = Int64(try handle.seekToEnd())
        if offset > file.size {
            try handle.truncate(atOffset: 0)
            offset = 0
        }
        var hasher = SHA256()
        if offset > 0 { try Self.hashExisting(handle, into: &hasher) }

        if offset < file.size {
            var request = URLRequest(url: manifest.remoteURL(for: file))
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            for try await chunk in Self.chunks(session, request) {
                switch chunk {
                case .response(let response):
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 200 && offset > 0 { // server ignored Range: start this file over
                        try handle.truncate(atOffset: 0)
                        offset = 0
                        hasher = SHA256()
                    } else if status != 200 && status != 206 {
                        throw ModelDownloadError.http(status: status)
                    }
                case .data(let data):
                    guard offset + Int64(data.count) <= file.size else { throw corrupt(file) }
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    offset += Int64(data.count)
                    meter.update(file, fileDone: offset, done: finished + offset)
                }
            }
            try Task.checkCancellation()
            if offset < file.size { throw URLError(.networkConnectionLost) } // body ended early; retry resumes
        }

        meter.update(file, fileDone: offset, done: finished + offset, force: true)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else { throw corrupt(file) }
    }

    private func corrupt(_ file: ModelFile) -> ModelDownloadError {
        try? FileManager.default.removeItem(at: partURL(for: file))
        return .corrupt(file: file.name)
    }

    private static func hashExisting(_ handle: FileHandle, into hasher: inout SHA256) throws {
        try handle.seek(toOffset: 0)
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case ModelDownloadError.http(let status) = error { return status == 429 || status >= 500 }
        guard let error = error as? URLError else { return false }
        let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        return transient.contains(error.code)
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    public static let availableCapacity: @Sendable (URL) throws -> Int64 = { url in
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Streaming

    private enum Chunk: Sendable {
        case response(URLResponse)
        case data(Data)
    }

    /// Response and body as delivered by URLSession (tens of KB per chunk), so nothing is buffered whole.
    private static func chunks(_ session: URLSession, _ request: URLRequest) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            task.delegate = ChunkForwarder(continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    private final class ChunkForwarder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let continuation: AsyncThrowingStream<Chunk, Error>.Continuation
        init(_ continuation: AsyncThrowingStream<Chunk, Error>.Continuation) { self.continuation = continuation }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            continuation.yield(.response(response))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            continuation.finish(throwing: error)
        }
    }
}

/// Throttled progress reports with a throughput estimate.
private struct ProgressMeter {
    let total: Int64
    let startDone: Int64
    let report: @Sendable (ModelDownloadProgress) -> Void
    let start = Date()
    var lastReport = Date.distantPast

    mutating func update(_ file: ModelFile, fileDone: Int64, done: Int64, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return }
        lastReport = now
        // ponytail: average since this download() began; a sliding window if estimates feel jumpy.
        let elapsed = now.timeIntervalSince(start)
        let rate = elapsed >= 1 && done > startDone ? Double(done - startDone) / elapsed : nil
        report(ModelDownloadProgress(fileName: file.name, fileBytesDone: fileDone, fileBytesTotal: file.size,
                                     bytesDone: done, bytesTotal: total, bytesPerSecond: rate))
    }
}
