import DaemonCore
import Foundation

/// Plain-word relative dates: "Just now", "2 min ago", "1 hr ago", "Today", "Yesterday", "3 days ago", "2 weeks ago".
func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if seconds < 3 * 3600 { return "\(Int(seconds / 3600)) hr ago" }
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case ...1: return "Yesterday"
    case ..<7: return "\(days) days ago"
    case ..<30: return plural(days / 7, "week")
    case ..<365: return plural(max(1, days / 30), "month")
    default: return plural(days / 365, "year")
    }
}

private func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }

/// "0:42", "47:20", "1:02:03"
func timecode(ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

extension Item {
    /// First line of text, page/window title, or file name.
    var displayTitle: String {
        if let line = text?.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty {
            return kind == .voice ? "“\(line)”" : line
        }
        if kind == .voice {
            // The window title is wherever the user happened to be while speaking; not what the note is.
            return durationMs.map { "Voice note · \(timecode(ms: $0))" } ?? "Voice note"
        }
        if let title = windowTitle, !title.isEmpty, kind != .text { return title }
        if let path = originalPath { return (path as NSString).lastPathComponent }
        if let url { return url }
        return kind.rawValue.capitalized
    }

    var sourceLabel: String {
        sourceApp ?? (kind == .voice ? "Voice" : kind.rawValue.capitalized)
    }
}

extension SearchHit {
    /// Title with the matched PDF page: "SaaS Pricing Playbook, page 12".
    var displayTitle: String {
        if item.kind == .pdf, let page = matchedSegment?.page { return "\(item.displayTitle), page \(page)" }
        return item.displayTitle
    }

    /// "at 0:42" for audio/video matches.
    var timeBadge: String? {
        guard [.voice, .audio, .video].contains(item.kind), let ms = matchedSegment?.startMs else { return nil }
        return "at \(timecode(ms: ms))"
    }
}

/// Filter chips in the Recall panel. Text and plain files only appear under All.
enum RecallFilter: String, CaseIterable, Identifiable {
    case all = "All", images = "Images", audio = "Audio", video = "Video", pdfs = "PDFs", links = "Links"
    var id: String { rawValue }

    func matches(_ kind: ItemKind) -> Bool {
        switch self {
        case .all: return true
        case .images: return kind == .image || kind == .screenshot
        case .audio: return kind == .voice || kind == .audio
        case .video: return kind == .video
        case .pdfs: return kind == .pdf
        case .links: return kind == .link
        }
    }
}
