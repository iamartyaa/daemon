import AppKit
import DaemonCore
import KeyboardShortcuts
import SwiftUI

/// Toasts near the menu bar: "Kept", the voice-note listener, and short notices.
/// One panel is created up front so a toast appears in the same frame as the hotkey.
/// A new toast replaces the one showing in place (content cross-fades, the card never leaves),
/// so several keeps in a row read as one calm surface rather than a stack.
@MainActor
public final class ToastPresenter {
    let model = ToastModel()
    private let panel: ToastPanel
    private var hideTask: Task<Void, Never>?
    private var tabTask: Task<Void, Never>?
    private var hovering = false

    public init() {
        panel = ToastPanel(contentRect: NSRect(origin: .zero, size: Theme.Size.toast),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false             // clicks pass through the transparent margin around the card
        panel.backgroundColor = .clear
        panel.hasShadow = false            // the card draws its own shadow
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = ToastHostingView(rootView: ToastView(model: model))
        host.onMouse = { [weak self] point in self?.mouseMoved(to: point) }
        panel.contentView = host
        model.onNoteDone = { [weak self] in self?.dismiss() }
    }

    /// "Kept · Notes" over the first line of what was kept. Tab while it shows opens a one-line note;
    /// Enter calls `onNote`. Pass `count` when several things were kept at once ("Kept · 3 files from Finder").
    public func showKept(item: Item, thumbnailURL: URL?, count: Int = 1, onNote: @escaping (String) -> Void) {
        model.onNote = onNote
        show(.kept(item, thumbnailURL, count: max(1, count)), for: Theme.Motion.toastVisible)
        listenForTab()
    }

    public func showListening() {
        model.levels = ToastModel.silence
        show(.listening(Date(), ended: nil), for: nil)
    }

    /// Microphone level, 0...1. Call ~20 times a second.
    public func updateLevel(_ level: Float) {
        guard case .listening(_, nil) = model.state else { return }
        model.levels.removeFirst()
        model.levels.append(min(1, max(ToastModel.floor, level)))
    }

    /// The key came up. The toast holds "Keeping" briefly so the Kept toast can take its place without a flicker.
    public func finishListening() {
        guard case let .listening(start, nil) = model.state else { return }
        withAnimation(.easeOut(duration: Theme.Motion.toastSwap)) {
            model.state = .listening(start, ended: Date())
            model.levels = ToastModel.silence
        }
        model.countdown = Countdown(total: Theme.Motion.toastHandoff)
        scheduleHide()
    }

    /// Short notices like "Copied, press ⌘V", and calm errors (up to three lines). Longer text stays longer.
    public func showMessage(_ message: String) {
        show(.message(message), for: ToastModel.readingTime(message))
    }

    // MARK: -

    private func show(_ state: ToastModel.State, for seconds: Double?) {
        hideTask?.cancel()
        tabTask?.cancel()
        let update = { [model] in
            model.editingNote = false
            model.note = ""
            model.state = state
            model.serial &+= 1
            model.countdown = seconds.map { Countdown(total: $0) }
        }
        if model.visible && panel.isVisible {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: Theme.Motion.toastSwap), update)
        } else {
            placePanel()
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain, update)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: Theme.Motion.toastEnter)) { model.visible = true }
        }
        if hovering { model.countdown?.pause(at: Date()) }
        scheduleHide()
    }

    private func placePanel() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.maxX - Theme.Size.toast.width, y: f.maxY - Theme.Size.toast.height))
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard let countdown = model.countdown, !countdown.isPaused else { return }
        let remaining = countdown.remaining(at: Date())
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Hovering the card or writing a note holds the toast; the progress line stops with it.
    private func setPaused(_ paused: Bool) {
        let now = Date()
        if paused { model.countdown?.pause(at: now) } else { model.countdown?.resume(at: now) }
        if paused { hideTask?.cancel() } else { scheduleHide() }
    }

    private func mouseMoved(to point: CGPoint?) {
        let inside = point.map { model.cardFrame.contains($0) } ?? false
        guard inside != hovering, model.visible else { return }
        hovering = inside
        setPaused(inside || model.editingNote)
    }

    private func dismiss() {
        hideTask?.cancel()
        tabTask?.cancel()
        hovering = false
        let serial = model.serial
        withAnimation(.easeOut(duration: Theme.Motion.toastExit)) {
            model.visible = false
        } completion: { [weak self] in
            guard let self, !self.model.visible, self.model.serial == serial else { return }
            self.panel.orderOut(nil)
            self.model.editingNote = false
            self.model.state = .none   // so the next toast never cross-fades from a stale one
        }
    }

    /// Tab is grabbed system-wide only while the Kept toast is up.
    private func listenForTab() {
        tabTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: .init(.tab)) where event == .keyDown {
                self?.beginNote()
                return
            }
        }
    }

    private func beginNote() {
        tabTask?.cancel()
        setPaused(true)
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: Theme.Motion.toastSwap)) { model.editingNote = true }
        panel.makeKey()
    }
}

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Reports the pointer to the presenter even while Daemon is in the background (SwiftUI's onHover isn't).
final class ToastHostingView: NSHostingView<ToastView> {
    var onMouse: (CGPoint?) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); report(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); report(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onMouse(nil) }

    /// In SwiftUI's top-left coordinates, matching `ToastModel.cardFrame`.
    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMouse(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
    }
}

/// Time left on a toast, pausable. Drives both the hide timer and the progress line.
struct Countdown: Equatable {
    let total: Double
    private(set) var spent: Double = 0
    private(set) var since: Date?

    init(total: Double, start: Date = Date()) {
        self.total = total
        since = start
    }

    var isPaused: Bool { since == nil }
    func elapsed(at now: Date) -> Double { min(total, spent + (since.map { max(0, now.timeIntervalSince($0)) } ?? 0)) }
    func remaining(at now: Date) -> Double { total - elapsed(at: now) }
    func progress(at now: Date) -> Double { total > 0 ? elapsed(at: now) / total : 1 }

    mutating func pause(at now: Date) {
        guard since != nil else { return }
        spent = elapsed(at: now)
        since = nil
    }

    mutating func resume(at now: Date) {
        if since == nil { since = now }
    }
}

@MainActor
final class ToastModel: ObservableObject {
    enum State { case none, kept(Item, URL?, count: Int), listening(Date, ended: Date?), message(String) }
    static let barCount = 72
    static let floor: Float = 0.06
    static let silence = Array(repeating: floor, count: barCount)

    @Published var state = State.none
    @Published var visible = false
    @Published var serial = 0                    // bumps per toast; content keyed on it cross-fades
    @Published var countdown: Countdown?
    @Published var levels = silence
    @Published var editingNote = false
    @Published var note = ""
    var cardFrame = CGRect.zero                  // in the panel, top-left origin; for hover
    var onNote: (String) -> Void = { _ in }
    var onNoteDone: () -> Void = {}

    /// Seconds to show a notice: about 18 characters a second, within `Theme.Motion.toastMessage`.
    static func readingTime(_ text: String) -> Double {
        let range = Theme.Motion.toastMessage
        return min(range.upperBound, max(range.lowerBound, Double(text.count) / 18))
    }
}

/// What the Kept toast says: a short header ("Kept" + `header`) and the thing itself (`detail`).
struct KeptSummary: Equatable {
    var header: String
    var detail: String?
    var detailIsFileName = false   // file names truncate in the middle so the extension survives

    init(header: String, detail: String?, detailIsFileName: Bool = false) {
        self.header = header
        self.detail = detail
        self.detailIsFileName = detailIsFileName
    }

    init(item: Item, count: Int = 1) {
        let fileName = item.originalPath.map { ($0 as NSString).lastPathComponent }.flatMap(Self.clean)
        let firstLine = item.text.flatMap(Self.firstLine)
        let title = item.windowTitle.flatMap(Self.clean)
        let from = item.sourceApp.flatMap(Self.clean).map { " from \($0)" } ?? ""

        if count > 1 {
            let fileish: Set<ItemKind> = [.file, .pdf, .image, .audio, .video]
            header = "\(count) \(fileish.contains(item.kind) ? "files" : "items")\(from)"
            detail = (fileName ?? firstLine ?? title).map { "\($0) and \(count - 1) more" }
            return
        }
        switch item.kind {
        case .text:
            header = item.sourceApp.flatMap(Self.clean) ?? "Text"
            detail = firstLine ?? title
        case .screenshot:
            header = "Screenshot"
            detail = [item.sourceApp.flatMap(Self.clean), title].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .image:
            header = "Image\(from)"
            detail = title ?? fileName
            detailIsFileName = title == nil && fileName != nil
        case .voice:
            header = ["Voice note", item.durationMs.map { timecode(ms: $0) }].compactMap { $0 }.joined(separator: " · ")
            detail = firstLine.map { "“\($0)”" }
        case .audio, .video:
            header = [item.kind == .audio ? "Audio" : "Video", item.durationMs.map { timecode(ms: $0) }]
                .compactMap { $0 }.joined(separator: " · ")
            detail = title ?? fileName
            detailIsFileName = title == nil && fileName != nil
        case .link:
            header = item.url.flatMap(Self.host) ?? item.sourceApp.flatMap(Self.clean) ?? "Link"
            detail = firstLine ?? title ?? item.url
        case .pdf:
            header = "PDF\(from)"
            detail = fileName ?? title
            detailIsFileName = fileName != nil
        case .file:
            header = "File\(from)"
            detail = fileName ?? title
            detailIsFileName = fileName != nil
        }
    }

    /// "www.nytimes.com/2026/…" -> "nytimes.com"
    static func host(_ url: String) -> String? {
        guard let host = URL(string: url)?.host() ?? URL(string: "https://\(url)")?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// First non-empty line, whitespace collapsed.
    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.compactMap { clean(String($0)) }.first
    }

    private static func clean(_ s: String) -> String? {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
