import Foundation

/// Local counters behind the PRD success metrics. Never leaves the Mac; "Copy my stats" copies numbers only.
public final class UsageStats: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case keep            // an item kept
        case recall          // a search run in the Recall panel
        case recallSuccess   // a result pasted, copied or opened
    }

    private struct Store: Codable {
        var firstLaunch: Date
        var events: [Event: [Date]] = [:]
    }

    private let defaults: UserDefaults
    private let key = "usageStats"
    private let lock = NSLock()
    private var store: Store

    public init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Store.self, from: data) {
            store = s
        } else {
            store = Store(firstLaunch: now)
        }
    }

    public func record(_ event: Event, at date: Date = Date()) {
        lock.withLock {
            // ponytail: one Date per event, ~10 KB/year at heavy use; switch to daily buckets if it ever matters
            store.events[event, default: []].append(date)
            if let data = try? JSONEncoder().encode(store) { defaults.set(data, forKey: key) }
        }
    }

    private func count(_ event: Event, in range: Range<Date>) -> Int {
        lock.withLock { store.events[event, default: []].filter(range.contains).count }
    }

    public func recallsLast7Days(now: Date = Date()) -> Int {
        count(.recall, in: now.addingTimeInterval(-7 * 86_400)..<now.addingTimeInterval(1))
    }

    /// Share of recalls that ended in paste, copy or open. nil before the first recall.
    public func recallSuccessRate() -> Double? {
        let all = Date.distantPast..<Date.distantFuture
        let recalls = count(.recall, in: all)
        return recalls == 0 ? nil : min(1, Double(count(.recallSuccess, in: all)) / Double(recalls))
    }

    public func keepsInFirst3Days() -> Int {
        let start = lock.withLock { store.firstLaunch }
        return count(.keep, in: start..<start.addingTimeInterval(3 * 86_400))
    }

    /// The text "Copy my stats" puts on the clipboard: numbers only, no content.
    public func summary(now: Date = Date()) -> String {
        let all = Date.distantPast..<Date.distantFuture
        let days = Int(now.timeIntervalSince(lock.withLock { store.firstLaunch }) / 86_400)
        let rate = recallSuccessRate().map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
        return """
        Daemon stats (numbers only)
        Days since first launch: \(days)
        Items kept: \(count(.keep, in: all))
        Kept in first 3 days: \(keepsInFirst3Days())
        Recalls, last 7 days: \(recallsLast7Days(now: now))
        Recall success: \(rate)
        """
    }
}
