import AppKit
import DaemonCore
import Foundation
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "app.mydaemon.Daemon", category: "recall")

/// Keys the Recall panel handles itself. Anything else goes to the query field.
enum RecallKey {
    case up, down, left, right, enter, cmdEnter, cmdC, cmdV, cmdR, cmdZ, cmdDelete, space, tab, shiftTab, escape
}

@MainActor
final class RecallViewModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var hits: [SearchHit] = [] { didSet { derive() } }
    @Published var filter: RecallFilter = .all { didSet { selection = 0; derive() } }
    @Published var selection = 0
    @Published private(set) var similarTo: String?        // file name after a drop
    @Published private(set) var notice: String?           // small in-panel message
    @Published private(set) var pendingDelete: SearchHit?
    @Published private(set) var errorMessage: String?
    @Published private(set) var showingAll = false
    @Published var focusRequest = 0
    /// Moved with arrows since the last keystroke: Space previews instead of typing, and the grid shows its selection.
    @Published private(set) var browsing = false
    /// The recent grid is on screen. It follows the results, not the query: after the first keystroke the grid stays
    /// until that query's results land, so no frame ever shows recent items laid out as results.
    @Published private(set) var gridShown = true
    var previousAppName: String?

    /// Derived from `hits` and `filter` once per change, not on every read (the view reads them many times a frame).
    private(set) var visibleHits: [SearchHit] = []
    private(set) var chips: [(filter: RecallFilter, count: Int)] = [(.all, 0)]

    let dataSource: RecallDataSource
    let actions: RecallActions
    var close: () -> Void = {}
    var quickLook: (URL) -> Void = { _ in }
    var showToast: (String) -> Void = { _ in }
    /// After results change; the panel uses it to draw ahead while hidden.
    var didApply: () -> Void = {}

    static let recentLimit = 20
    /// Show all loads the library a page at a time, as the grid scrolls, so a large library opens as fast as a small one.
    static let allPageSize = 120
    static let gridColumns = 3
    static let resultRowsPrefetched = 20
    /// Keyword results wait this long for the full (meaning) results, so a keystroke usually updates the list once.
    /// When the model is busy or cold, keyword results show at this point and meaning merges in when it's ready.
    nonisolated static let refineBudget: Duration = .milliseconds(50)
    /// Visible thumbnails get this long to decode before results show, so rows don't flash a placeholder.
    static let thumbnailBudget: Duration = .milliseconds(12)

    private let debounce: Duration
    private let refineBudget: Duration
    private var generation = 0                       // bumped by every request; older answers are dropped
    private var refined = -1                          // generation whose full results are showing
    private var appliedGeneration = -1                // generation whose results are on screen
    private var quickTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var recentCache: [SearchHit] = []
    private var allPages = 1
    private var thumbnailURLs: [Int64: URL] = [:]
    private var noThumbnail: Set<Int64> = []
    private var openApps: [String: String] = [:]

    /// `debounce` delays the full search after a keystroke (tests); the app runs it at once, since keyword results
    /// and dropped stale answers already keep fast typing cheap.
    init(dataSource: RecallDataSource, actions: RecallActions, debounce: Duration = .zero,
         refineBudget: Duration = RecallViewModel.refineBudget) {
        self.dataSource = dataSource
        self.actions = actions
        self.debounce = debounce
        self.refineBudget = refineBudget
    }

    // MARK: - Derived

    var isRecent: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && similarTo == nil }

    var selectedHit: SearchHit? { visibleHits.indices.contains(selection) ? visibleHits[selection] : nil }

    private func derive() {
        visibleHits = filter == .all ? hits : hits.filter { filter.matches($0.item.kind) }
        chips = RecallFilter.allCases.compactMap { f in
            let n = f == .all ? hits.count : hits.reduce(0) { $0 + (f.matches($1.item.kind) ? 1 : 0) }
            return f == .all || n > 0 ? (f, n) : nil
        }
    }

    var emptyMessage: String {
        if let errorMessage { return errorMessage }
        if gridShown { return "Nothing kept yet. Press ⌃⌥S on anything." }
        if let similarTo { return "Nothing looks like \(similarTo) yet." }
        return "Nothing matches “\(query)”. Try fewer words, or describe it differently."
    }

    var countLine: String { "\(dataSource.totalCount.formatted()) kept" }

    /// Space previews only when the query field isn't taking it as a space, and Quick Look has a file to show.
    var canPreview: Bool {
        guard browsing || query.isEmpty, let hit = selectedHit else { return false }
        return dataSource.fileURL(for: hit.item) != nil
    }

    /// Thumbnail file per item, looked up once (the lookup touches the disk).
    func thumbnailURL(for hit: SearchHit) -> URL? {
        if let url = thumbnailURLs[hit.id] { return url }
        if noThumbnail.contains(hit.id) { return nil }
        guard let url = dataSource.thumbnailURL(for: hit.item) else { noThumbnail.insert(hit.id); return nil }
        thumbnailURLs[hit.id] = url
        return url
    }

    /// The app ⌘↵ opens this in, matching what `open()` does: links in the browser, text in the text editor,
    /// files in their default app. Cached per kind of target (asking Launch Services takes milliseconds).
    func openAppName(for hit: SearchHit) -> String? {
        let target: (key: String, app: () -> URL?)
        if hit.item.kind == .link, let link = hit.item.url, let url = URL(string: link) {
            target = ("scheme:\(url.scheme ?? "")", { NSWorkspace.shared.urlForApplication(toOpen: url) })
        } else if let file = dataSource.fileURL(for: hit.item) {
            target = ("ext:\(file.pathExtension.lowercased())", { NSWorkspace.shared.urlForApplication(toOpen: file) })
        } else if hit.item.text != nil {
            target = ("text", { NSWorkspace.shared.urlForApplication(toOpen: .plainText) })
        } else {
            return nil
        }
        if let cached = openApps[target.key] { return cached.isEmpty ? nil : cached }
        let name = target.app().map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        openApps[target.key] = name ?? ""
        return name
    }

    // MARK: - Loading

    /// Back to the recent grid with nothing typed. The panel calls it when it hides, so the next open draws the
    /// right thing in its very first frame instead of the last search.
    func reset() {
        similarTo = nil
        filter = .all
        showingAll = false
        allPages = 1
        pendingDelete = nil
        notice = nil
        openApps = [:]   // default apps may have changed since the last open
        if query.isEmpty { showRecent() } else { query = "" }
        focusRequest += 1
    }

    /// Re-reads recent items (something may have been kept while the panel was closed); changes only if they did.
    func refreshRecent() {
        if isRecent { loadRecent() }
    }

    private func queryChanged() {
        browsing = false
        similarTo = nil
        showingAll = false
        allPages = 1
        let gen = startRequest()
        if isRecent { return showRecent() }
        let q = query
        let start = ContinuousClock.now
        let firstResults = Perf.begin("keystroke to first results")
        let fullResults = Perf.begin("keystroke to full results")

        if debounce == .zero, let quick = dataSource as? QuickRecallSource {
            quickTask = Task { [weak self, refineBudget] in
                // Usually the full results are in by half the budget; only then is keyword-only work worth doing.
                try? await Task.sleep(until: start + refineBudget / 2, clock: .continuous)
                guard let self, self.generation == gen, self.refined != gen,
                      let hits = try? await quick.quickSearch(q), self.generation == gen else { return }
                await self.prefetchThumbnails(hits)
                try? await Task.sleep(until: start + refineBudget, clock: .continuous)
                guard self.generation == gen, self.refined != gen else { return }
                self.apply(hits, keepSelection: false)
                firstResults.end()
            }
        }
        searchTask = Task { [weak self, debounce] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard let self, self.generation == gen else { return }
            do {
                let hits = try await self.dataSource.search(q)
                guard self.generation == gen else { return }
                await self.prefetchThumbnails(hits)
                guard self.generation == gen else { return }
                let quickShown = self.appliedGeneration == gen
                self.refined = gen
                // Keyword results may already be up and the user arrowing through them: keep their place.
                self.apply(hits, keepSelection: self.browsing)
                if !quickShown { firstResults.end() }
                fullResults.end()
            } catch {
                guard self.generation == gen, !(error is CancellationError) else { return }
                self.fail()
            }
        }
    }

    /// Cached recent items right away (no flash of an empty grid), then the fresh ones.
    private func showRecent() {
        if !recentCache.isEmpty { apply(recentCache, keepSelection: false) }
        loadRecent()
    }

    func loadRecent() {
        let gen = startRequest()
        let limit = showingAll ? Self.allPageSize * allPages : Self.recentLimit
        let all = showingAll
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await self.dataSource.recent(limit: limit)
                guard self.generation == gen else { return }
                if !all { self.recentCache = hits }
                guard hits != self.hits || !self.gridShown else { return }   // unchanged: nothing to redraw
                await self.prefetchThumbnails(hits)
                guard self.generation == gen else { return }
                self.apply(hits, keepSelection: true)
            } catch {
                guard self.generation == gen else { return }
                self.fail()
            }
        }
    }

    /// Show all: the next page when the grid scrolls near the end of what's loaded.
    func loadMoreIfNeeded(after hit: SearchHit) {
        guard showingAll, isRecent, hits.count == Self.allPageSize * allPages,
              let i = hits.lastIndex(of: hit), i >= hits.count - Self.gridColumns * 4 else { return }
        allPages += 1
        loadRecent()
    }

    func searchSimilar(to file: URL) {
        if !query.isEmpty { query = "" }
        let gen = startRequest()
        similarTo = file.lastPathComponent
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await self.dataSource.searchSimilar(to: file)
                guard self.generation == gen else { return }
                self.apply(hits, keepSelection: false)
            } catch {
                guard self.generation == gen else { return }
                self.fail()
            }
        }
    }

    /// Supersedes whatever was loading: its answer will be dropped even if it still arrives.
    private func startRequest() -> Int {
        quickTask?.cancel()
        searchTask?.cancel()
        quickTask = nil
        generation += 1
        return generation
    }

    /// Puts results on screen. `keepSelection` keeps the selected item selected wherever it moved
    /// (refinement, refresh, next page); otherwise the first result is selected.
    func apply(_ result: [SearchHit], keepSelection: Bool = false) {
        let selected = keepSelection ? selectedHit?.id : nil
        gridShown = isRecent
        hits = result
        appliedGeneration = generation
        log.info("results query='\(self.query, privacy: .private)' ids=\(result.map { $0.item.id ?? -1 })")
        errorMessage = nil
        if filter != .all, !chips.contains(where: { $0.filter == filter }) { filter = .all }
        selection = selected.flatMap { id in visibleHits.firstIndex { $0.id == id } } ?? 0
        didApply()
    }

    private func fail() {
        gridShown = isRecent
        hits = []
        errorMessage = "Recall couldn’t read your library. Close the panel and try again."
        selection = 0
    }

    /// Decodes the thumbnails about to be on screen, waiting a few milliseconds at most. Only the first screenful:
    /// cards and rows further down decode as they scroll in.
    private func prefetchThumbnails(_ hits: [SearchHit]) async {
        let grid = isRecent
        let urls = hits.prefix(grid ? Self.recentLimit + Self.gridColumns : Self.resultRowsPrefetched)
            .compactMap(thumbnailURL(for:))
        guard !urls.isEmpty else { return }
        let size = grid ? ThumbnailCache.largePixels : ThumbnailCache.rowPixels
        ThumbnailCache.prefetch(urls, maxPixels: size)
        if !grid, let first = hits.first.flatMap(thumbnailURL(for:)) {
            ThumbnailCache.prefetch([first], maxPixels: ThumbnailCache.largePixels)   // the preview pane
        }
        let visible = urls.prefix(grid ? Self.recentLimit : 10)
        let deadline = ContinuousClock.now + Self.thumbnailBudget
        let wait = Perf.begin("thumbnail wait")
        while !visible.allSatisfy({ ThumbnailCache.cached($0, maxPixels: size) != nil }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        wait.end()
    }

    // MARK: - Keys

    /// Returns true when the key was handled and must not reach the query field.
    func handle(_ key: RecallKey) -> Bool {
        let count = visibleHits.count
        let step = gridShown ? Self.gridColumns : 1
        switch key {
        case .up:
            browsing = true
            selection = max(0, selection - step)
        case .down:
            browsing = true
            selection = min(max(0, count - 1), selection + step)
        case .left, .right:
            guard gridShown, count > 0 else { return false }
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
            guard gridShown, isRecent else { return false }
            showingAll.toggle()
            allPages = 1
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

    /// Links open the page itself, not the screenshot kept with them.
    func open() {
        guard let hit = selectedHit else { return }
        actions.open(hit, fileURL: hit.item.kind == .link ? nil : dataSource.fileURL(for: hit.item))
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
        recentCache.removeAll { $0 == hit }
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
