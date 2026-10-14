import Foundation
import os

/// Signpost intervals for the Recall path (Instruments: os_signpost, subsystem app.mydaemon.Daemon, category perf).
/// Benchmarks turn on `Perf.samples` to read the same intervals back without Instruments.
public enum Perf {
    public static let signposter = OSSignposter(subsystem: "app.mydaemon.Daemon", category: "perf")
    public static let samples = PerfSamples()

    public struct Interval: Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: ContinuousClock.Instant

        public func end() {
            Perf.signposter.endInterval(name, state)
            Perf.samples.record(name, start.duration(to: .now))
        }
    }

    public static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()), start: .now)
    }

    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try work()
    }

    public static func measure<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        defer { interval.end() }
        return try await work()
    }
}

/// Durations per interval name, collected only while `isRecording` (benchmarks); a no-op in the app.
public final class PerfSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var values: [String: [Double]] = [:]

    public var isRecording: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }

    func record(_ name: StaticString, _ duration: Duration) {
        lock.withLock {
            guard recording else { return }
            let c = duration.components
            values["\(name)", default: []].append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
        }
    }

    /// Milliseconds recorded for each interval name since the last call; clears them.
    public func drain() -> [String: [Double]] {
        lock.withLock {
            defer { values = [:] }
            return values
        }
    }
}
