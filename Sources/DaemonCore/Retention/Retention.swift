import Foundation
import os

let retentionLog = Logger(subsystem: "app.mydaemon.Daemon", category: "retention")

/// How long Daemon keeps things. 90 days is the most; there is no "forever".
public enum RetentionPolicy: Int, CaseIterable, Identifiable, Sendable {
    case days7 = 7, days30 = 30, days90 = 90

    public static let `default` = RetentionPolicy.days30
    public static let defaultsKey = "retentionDays"

    public var id: Int { rawValue }
    public var days: Int { rawValue }
    public var title: String { "\(rawValue) days" }

    /// Items created before this moment are removed.
    public func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    /// The stored setting; anything unknown (or missing) falls back to 30 days.
    public static func load(from defaults: UserDefaults = .standard) -> RetentionPolicy {
        RetentionPolicy(rawValue: defaults.integer(forKey: defaultsKey)) ?? .default
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

public struct PurgeResult: Equatable, Sendable {
    public var items: Int
    public var bytes: Int64     // stored files and thumbnails removed (the database shrinks separately on VACUUM)
    public init(items: Int = 0, bytes: Int64 = 0) { self.items = items; self.bytes = bytes }
}

public enum Leftovers {
    /// Capture's temp files and the pipeline's work dirs. Both live under $TMPDIR; names match
    /// `CaptureFiles.tempDir` (DaemonCapture) and `Pipeline.workRoot`.
    public static var defaultDirs: [URL] {
        let tmp = FileManager.default.temporaryDirectory
        return [tmp.appendingPathComponent("DaemonCapture"), tmp.appendingPathComponent("DaemonWork")]
    }

    /// Removes entries directly inside `dirs` last modified more than `age` ago. Returns bytes freed.
    @discardableResult
    public static func sweep(_ dirs: [URL] = defaultDirs, olderThan age: TimeInterval = 24 * 3600,
                             now: Date = Date()) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        var freed: Int64 = 0
        for dir in dirs {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? [] {
                guard let modified = try? url.resourceValues(forKeys: keys).contentModificationDate,
                      now.timeIntervalSince(modified) > age else { continue }
                let size = diskSize(url)
                if (try? fm.removeItem(at: url)) != nil { freed += size }
            }
        }
        return freed
    }

    /// Allocated bytes of a file, or of everything inside a folder.
    static func diskSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total = Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let child as URL in walker {
                total += Int64((try? child.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
