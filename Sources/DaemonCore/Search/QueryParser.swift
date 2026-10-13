import Foundation

/// Pulls filters out of a Recall query: `from:safari last week flight` -> text "flight",
/// sources ["safari"], dateRange = last week.
public enum QueryParser {
    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let lower = words.map { $0.lowercased() }
        var filters = SearchFilters()
        var kept: [String] = []
        var i = 0

        while i < words.count {
            let w = lower[i]
            let next = i + 1 < lower.count ? lower[i + 1] : nil

            if w.hasPrefix("from:"), w.count > 5 {
                filters.sources.append(String(w.dropFirst(5)))
                i += 1
            } else if w.hasPrefix("type:"), let kinds = typeKinds(String(w.dropFirst(5))) {
                filters.kinds.formUnion(kinds)
                i += 1
            } else if w == "voice", next == "note" || next == "notes" {
                filters.kinds.formUnion([.audio, .voice])
                i += 2
            } else if let kinds = bareTypes[w] {
                filters.kinds.formUnion(kinds)
                i += 1
            } else if let (range, used) = timePhrase(lower[i...], now: now, calendar: calendar) {
                filters.dateRange = range
                i += used
            } else {
                kept.append(words[i])
                i += 1
            }
        }
        return ParsedQuery(text: kept.joined(separator: " "), filters: filters)
    }

    // Bare "text" is too common a word to treat as a filter; only `type:text` means it.
    private static let bareTypes: [String: Set<ItemKind>] = {
        let image: Set<ItemKind> = [.image, .screenshot], audio: Set<ItemKind> = [.audio, .voice]
        return ["image": image, "images": image, "screenshot": image, "screenshots": image,
                "audio": audio, "voice": audio,
                "video": [.video], "videos": [.video], "pdf": [.pdf], "pdfs": [.pdf],
                "link": [.link], "links": [.link]]
    }()

    private static func typeKinds(_ value: String) -> Set<ItemKind>? {
        bareTypes[value] ?? ItemKind(rawValue: value).map { [$0] }
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july",
                                 "august", "september", "october", "november", "december"]

    private static func month(_ word: String) -> Int? {
        if word == "sept" { return 9 }
        return months.firstIndex { $0 == word || ($0.prefix(3) == word) }.map { $0 + 1 }
    }

    /// Matches a time phrase at the start of `w`; returns the range and how many words it used.
    private static func timePhrase(_ w: ArraySlice<String>, now: Date, calendar: Calendar) -> (Range<Date>, Int)? {
        func interval(_ unit: Calendar.Component, _ offset: Int) -> Range<Date>? {
            guard let date = calendar.date(byAdding: unit, value: offset, to: now),
                  let span = calendar.dateInterval(of: unit, for: date) else { return nil }
            return span.start..<span.end
        }
        let words = Array(w.prefix(3))
        let first = words[0], second = words.count > 1 ? words[1] : nil

        switch first {
        case "today": return interval(.day, 0).map { ($0, 1) }
        case "yesterday": return interval(.day, -1).map { ($0, 1) }
        case "this", "last":
            let unit: [String: Calendar.Component] = ["week": .weekOfYear, "month": .month, "year": .year]
            guard let second, let u = unit[second] else { return nil }
            return interval(u, first == "this" ? 0 : -1).map { ($0, 2) }
        case "in":
            // Most recent occurrence that isn't in the future (the current month counts).
            guard let second, let m = month(second) else { return nil }
            let current = calendar.component(.month, from: now)
            let year = calendar.component(.year, from: now) - (m > current ? 1 : 0)
            guard let date = calendar.date(from: DateComponents(year: year, month: m, day: 1)),
                  let span = calendar.dateInterval(of: .month, for: date) else { return nil }
            return (span.start..<span.end, 2)
        default:
            // "3 days ago", "2 weeks ago"
            guard words.count == 3, words[2] == "ago", let n = Int(first), n >= 0, let second else { return nil }
            let unit: [String: Calendar.Component] = ["day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear]
            guard let u = unit[second] else { return nil }
            return interval(u, -n).map { ($0, 3) }
        }
    }
}
