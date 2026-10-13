import AppKit
import DaemonCore
import Foundation
import os

private let log = Logger(subsystem: "app.mydaemon.Daemon", category: "recall")

/// Keys the Recall panel handles itself. Anything else goes to the query field.
enum RecallKey {
    case up, down, left, right, enter, cmdEnter, cmdC, cmdV, cmdR, cmdZ, cmdDelete, space, tab, shiftTab, escape
}

@MainActor
final class RecallViewModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var hits: [SearchHit] = []
    @Published var filter: RecallFilter = .all { didSet { selection = 0 } }
    @Published var selection = 0
    @Published private(set) var similarTo: String?        // file name after a drop
    @Published private(set) var notice: String?           // small in-panel message
    @Published private(set) var pendingDelete: SearchHit?
    @Published private(set) var errorMessage: String?
    @Published private(set) var showingAll = false
    @Published var focusRequest = 0
    var previousAppName: String?

    let dataSource: RecallDataSource
    let actions: RecallActions
    var close: () -> Void = {}
    var quickLook: (URL) -> Void = { _ in }
    var showToast: (String) -> Void = { _ in }

    static let recentLimit = 20
    static let gridColumns = 3
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    /// Moved with arrows since the last keystroke: Space previews instead of typing, and the grid shows its selection.
    @Published private(set) var browsing = false

    init(dataSource: RecallDataSource, actions: RecallActions,
         debounce: Duration = .milliseconds(Int(Theme.Motion.searchDebounce * 1000))) {
        self.dataSource = dataSource
        self.actions = actions
        self.debounce = debounce
    }

    // MARK: - Derived

    var isRecent: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && similarTo == nil }

    var visibleHits: [SearchHit] { hits.filter { filter.matches($0.item.kind) } }

    var selectedHit: SearchHit? {
        let visible = visibleHits
        return visible.indices.contains(selection) ? visible[selection] : nil
    }

    /// All plus every chip with at least one hit, with counts.
    var chips: [(filter: RecallFilter, count: Int)] {
        RecallFilter.allCases.compactMap { f in
            let n = hits.filter { f.matches($0.item.kind) }.count
            return f == .all || n > 0 ? (f, n) : nil
        }
    }

    var emptyMessage: String {
        if let errorMessage { return errorMessage }
        if isRecent { return "Nothing kept yet. Press ⌃⌥S on anything." }
        if let similarTo { return "Nothing looks like \(similarTo) yet." }
        return "Nothing matches “\(query)”. Try fewer words, or describe it differently."
    }

    var countLine: String { "\(dataSource.totalCount.formatted()) kept · private to this Mac" }

    func openAppName(for hit: SearchHit) -> String? {
        if let url = dataSource.fileURL(for: hit.item), let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
        return hit.item.sourceApp
    }

    // MARK: - Loading

    func reset() {
        searchTask?.cancel()
        similarTo = nil
        filter = .all
        showingAll = false
        pendingDelete = nil
        notice = nil
        if query.isEmpty { loadRecent() } else { query = "" }
        focusRequest += 1
    }

    private func queryChanged() {
        browsing = false
        similarTo = nil
        showingAll = false
        searchTask?.cancel()
        if isRecent { return loadRecent() }
        let q = query
        searchTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.run { try await self.dataSource.search(q) }
        }
    }

    func loadRecent() {
        searchTask?.cancel()
        let limit = showingAll ? max(dataSource.totalCount, Self.recentLimit) : Self.recentLimit
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.run { try await self.dataSource.recent(limit: limit) }
        }
    }

    func searchSimilar(to file: URL) {
        searchTask?.cancel()
        if !query.isEmpty { query = "" }
        searchTask?.cancel()
        similarTo = file.lastPathComponent
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.run { try await self.dataSource.searchSimilar(to: file) }
        }
    }

    private func run(_ fetch: () async throws -> [SearchHit]) async {
        do {
            let result = try await fetch()
            guard !Task.isCancelled else { return }
            hits = result
            log.info("results query='\(self.query, privacy: .private)' ids=\(result.map { $0.item.id ?? -1 })")
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            hits = []
            errorMessage = "Recall couldn’t read your library. Close the panel and try again."
        }
        selection = 0
        if filter != .all, !chips.contains(where: { $0.filter == filter }) { filter = .all }
    }

    // MARK: - Keys

    /// Returns true when the key was handled and must not reach the query field.
    func handle(_ key: RecallKey) -> Bool {
        let count = visibleHits.count
        let step = isRecent ? Self.gridColumns : 1
        switch key {
        case .up:
            browsing = true
            selection = max(0, selection - step)
        case .down:
            browsing = true
            selection = min(max(0, count - 1), selection + step)
        case .left, .right:
            guard isRecent, count > 0 else { return false }
            browsing = true
            selection = key == .left ? max(0, selection - 1) : min(count - 1, selection + 1)
        case .tab, .shiftTab:
            let all = chips.map(\.filter)
            let i = all.firstIndex(of: filter) ?? 0
            filter = all[(i + (key == .tab ? 1 : all.count - 1)) % all.count]
        case .enter: paste()
        case .cmdEnter: open()
        case .cmdC: copy()
        case .cmdDelete: delete()
        case .cmdZ:
            guard pendingDelete != nil else { return false }
            undoDelete()
        case .cmdV: keepClipboard()
        case .cmdR:
            guard isRecent else { return false }
            showingAll.toggle()
            loadRecent()
        case .space:
            guard browsing || query.isEmpty else { return false }
            preview()
        case .escape: close()
        }
        return true
    }

    // MARK: - Actions

    func select(_ hit: SearchHit) {
        if let i = visibleHits.firstIndex(of: hit) { selection = i; browsing = true }
    }

    func paste() {
        log.info("paste query='\(self.query, privacy: .private)' selection=\(self.selection) recent=\(self.isRecent) hits=\(self.visibleHits.map { $0.item.id ?? -1 })")
        guard let hit = selectedHit else { return }
        let url = dataSource.fileURL(for: hit.item)
        close()
        Task {
            if await !actions.paste(hit, fileURL: url) { showToast("Copied, press ⌘V") }
        }
    }

    func copy() {
        guard let hit = selectedHit else { return }
        actions.copy(hit, fileURL: dataSource.fileURL(for: hit.item))
        close()
    }

    func open() {
        guard let hit = selectedHit else { return }
        actions.open(hit, fileURL: dataSource.fileURL(for: hit.item))
        close()
    }

    func preview() {
        guard let hit = selectedHit else { return }
        if let url = dataSource.fileURL(for: hit.item) {
            quickLook(url)
        } else {
            show("Nothing to preview for this one. Press ↵ to paste it.")
        }
    }

    func delete() {
        guard let hit = selectedHit else { return }
        finishPendingDelete()
        hits.removeAll { $0 == hit }
        selection = min(selection, max(0, visibleHits.count - 1))
        pendingDelete = hit
        Task {
            do { try await dataSource.delete(hit.item) } catch {
                hits.append(hit)
                pendingDelete = nil
                show("Couldn’t delete that. Try again.")
            }
        }
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Motion.deleteUndo))
            guard !Task.isCancelled else { return }
            self?.pendingDelete = nil
        }
    }

    func undoDelete() {
        guard let hit = pendingDelete else { return }
        undoTask?.cancel()
        pendingDelete = nil
        hits.append(hit)
        hits.sort { $0.score == $1.score ? $0.item.createdAt > $1.item.createdAt : $0.score > $1.score }
        Task {
            do { try await dataSource.undoDelete(hit.item) } catch { show("Couldn’t bring that back.") }
        }
    }

    /// Closing the panel ends the undo window.
    func finishPendingDelete() {
        undoTask?.cancel()
        pendingDelete = nil
    }

    func keepClipboard() {
        Task {
            do {
                try await dataSource.keepClipboard()
                show("Kept from the clipboard")
                if isRecent { loadRecent() }
            } catch {
                show("Couldn’t keep the clipboard. Copy something, then press ⌘V.")
            }
        }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
