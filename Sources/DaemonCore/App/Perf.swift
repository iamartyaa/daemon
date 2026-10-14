import Foundation
import os

/// Signposts for the moments that decide whether Daemon feels instant: subsystem `app.mydaemon.Daemon`, category `perf`.
/// Instruments shows them under os_signpost / Points of Interest; `log stream --signpost --predicate
/// 'subsystem == "app.mydaemon.Daemon"'` prints them live. Disabled signposts cost a few nanoseconds.
/// Benchmarks turn on `Perf.samples` to read the same intervals back without Instruments.
public enum Perf {
    public static let signposter = OSSignposter(subsystem: "app.mydaemon.Daemon", category: "perf")
    public static let samples = PerfSamples()

    public struct Interval: Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: ContinuousClock.Instant

        public func end(_ detail: String = "") {
            Perf.signposter.endInterval(name, state, "\(detail, privacy: .public)")
            Perf.samples.record(name, start.duration(to: .now))
        }
    }

    public static func begin(_ name: StaticString, _ detail: String = "") -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(detail, privacy: .public)"),
                 start: .now)
    }

    public static func end(_ name: StaticString, _ interval: Interval, _ detail: String = "") {
        interval.end(detail)
    }

    public static func event(_ name: StaticString, _ detail: String = "") {
        signposter.emitEvent(name, "\(detail, privacy: .public)")
    }

    @discardableResult
    public static func measure<T>(_ name: StaticString, _ detail: String = "", _ body: () throws -> T) rethrows -> T {
        let interval = begin(name, detail)
        defer { interval.end() }
        return try body()
    }

    @discardableResult
    public static func measure<T>(_ name: StaticString, _ detail: String = "", _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(name, detail)
        defer { interval.end() }
        return try await body()
    }

    /// Keep keys down -> the Keeping (or Listening) toast on screen. Capture opens it, the toast closes it.
    @MainActor public static var keepPressed: Interval?

    /// Ends the hotkey interval if one is open. `outcome` says how it ended ("Keeping", "Listening", "region", ...).
    @MainActor public static func keepAnswered(_ outcome: String) {
        guard let interval = keepPressed else { return }
        keepPressed = nil
        interval.end(outcome)
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
