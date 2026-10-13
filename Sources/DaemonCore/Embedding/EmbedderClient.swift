import Foundation

public enum EmbedderError: Error, Equatable, Sendable {
    case processDied            // the model process exited or broke the pipe (after one restart + retry)
    case remote(String)         // the model process answered with an error
    case badResponse(String)
}

/// Talks to the DaemonEmbedder process over stdin/stdout (see EmbedderProtocol.swift).
///
/// The actor runs on its own serial dispatch queue, and its methods do blocking pipe I/O without suspending,
/// so requests are naturally serialized and the cooperative thread pool is never blocked.
public actor EmbedderClient: Embedder {
    public nonisolated let modelVersion = "embeddinggemma-2-q8_0"

    private let executableURL: URL
    private let modelsDirectory: URL?
    private let mediaIdleTimeout: Duration
    private let queue = DispatchSerialQueue(label: "daemon.embedder-client")
    private var child: ChildProcess?
    private var nextID = 1
    private var mediaLoaded = false
    private var idleUnload: DispatchWorkItem?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(executableURL: URL, modelsDirectory: URL? = nil, mediaIdleTimeout: Duration = .seconds(120)) {
        self.executableURL = executableURL
        self.modelsDirectory = modelsDirectory
        self.mediaIdleTimeout = mediaIdleTimeout
    }

    /// `DaemonEmbedder` next to the running app's executable.
    public static func bundledExecutableURL() -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
    }

    public func embed(_ input: EmbedInput) throws -> [Float] {
        let response = try send(.embed, input)
        switch input {
        case .image, .audio:
            mediaLoaded = true
            scheduleIdleUnload()
        case .query, .document: break
        }
        if let error = response.error { throw EmbedderError.remote(error) }
        guard let vector = response.vector else { throw EmbedderError.badResponse("no vector") }
        return vector
    }

    public func stats() throws -> EmbedderStats {
        let r = try send(.stats, nil)
        guard let footprint = r.footprintMB, let media = r.mediaLoaded, let pid = r.pid else {
            throw EmbedderError.badResponse(r.error ?? "incomplete stats")
        }
        return EmbedderStats(footprintMB: footprint, mediaLoaded: media, pid: pid)
    }

    /// Ends the model process (it exits on stdin EOF). A later request starts a fresh one.
    public func shutdown() {
        idleUnload?.cancel()
        idleUnload = nil
        child?.stop()
        child = nil
        mediaLoaded = false
    }

    // MARK: - private

    /// One round trip. If the process is gone, restart it and retry once.
    private func send(_ op: EmbedderRequest.Op, _ input: EmbedInput?) throws -> EmbedderResponse {
        let request = EmbedderRequest(id: nextID, op: op, input: input)
        nextID += 1
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        for attempt in 1...2 {
            do {
                if child == nil {
                    child = try ChildProcess(executableURL: executableURL, modelsDirectory: modelsDirectory)
                    mediaLoaded = false
                }
                let response = try JSONDecoder().decode(EmbedderResponse.self, from: child!.roundTrip(line))
                guard response.id == request.id else {
                    throw EmbedderError.badResponse("expected id \(request.id), got \(response.id)")
                }
                return response
            } catch EmbedderError.processDied where attempt == 1 {
                child?.stop()
                child = nil
            }
        }
        preconditionFailure("unreachable: second attempt either returns or throws")
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.assumeIsolated { $0.unloadMediaIfIdle() }
        }
        idleUnload = work
        let c = mediaIdleTimeout.components
        queue.asyncAfter(deadline: .now() + Double(c.seconds) + Double(c.attoseconds) / 1e18, execute: work)
    }

    /// A fresh process holds only the text model, so restarting is how the projector's memory comes back.
    private func unloadMediaIfIdle() {
        guard mediaLoaded, let old = child else { return }
        idleUnload = nil
        old.stop()
        child = try? ChildProcess(executableURL: executableURL, modelsDirectory: modelsDirectory) // keep text warm
        mediaLoaded = false
    }
}

/// The running DaemonEmbedder process and its pipes. Used only from EmbedderClient's queue.
private final class ChildProcess {
    private let process = Process()
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var buffer = Data()

    init(executableURL: URL, modelsDirectory: URL?) throws {
        let inPipe = Pipe(), outPipe = Pipe()
        process.executableURL = executableURL
        if let modelsDirectory { process.arguments = ["--models", modelsDirectory.path] }
        process.standardInput = inPipe
        process.standardOutput = outPipe // stderr is inherited, so model logs land in the app's log
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        // A write after the child died must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    func roundTrip(_ line: Data) throws -> Data {
        do {
            try stdin.write(contentsOf: line)
        } catch {
            throw EmbedderError.processDied
        }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let response = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(response)
            }
            // read(2), not FileHandle.read(upToCount:), which waits for the full count.
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(stdout.fileDescriptor, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw EmbedderError.processDied }
            buffer.append(contentsOf: chunk[..<n])
        }
    }

    /// Closing stdin makes the child free its models and exit; it is killed if it is not gone in 5 s.
    func stop() {
        try? stdin.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
