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
    /// Screen frame of the menu bar mark, where a kept thumbnail flies. Nil (hidden, other screen): no flight.
    public var flightTarget: () -> NSRect? = { nil }
    /// The thumbnail reached the mark (or there was no flight). Glow the mark here.
    public var onArrive: () -> Void = {}

    let model = ToastModel()
    private let panel: ToastPanel
    private let flight = ToastFlight()
    private var hideTask: Task<Void, Never>?
    private var tabTask: Task<Void, Never>?
    private var keptTask: Task<Void, Never>?
    private var keepingSince: Date?
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
        panel.animationBehavior = .none     // the stage layer animates; AppKit's own window animation would run per frame in-process
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = ToastHostingView(rootView: ToastView(model: model))
        host.onMouse = { [weak self] point in self?.mouseMoved(to: point) }
        host.frame = stage.bounds
        host.autoresizingMask = [.width, .height]
        stage.wantsLayer = true
        stage.addSubview(host)
        panel.contentView = stage
        model.onNoteDone = { [weak self] in self?.dismiss() }
    }

    /// Holds the SwiftUI card. Entering and leaving animate this layer, so the render server moves the card
    /// and SwiftUI draws nothing per frame (a SwiftUI enter or exit cost about a core for its quarter second).
    private let stage = NSView(frame: NSRect(origin: .zero, size: Theme.Size.toast))

    /// Builds the card once, unseen (fonts, the view graph, the shimmer's layers), so the first keep after launch
    /// shows as fast as every later one. Call once launch has settled.
    public func prewarm() {
        guard !panel.isVisible else { return }
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) { model.state = .keeping(.text, KeepingSummary(header: "Daemon")) }
        stage.layoutSubtreeIfNeeded()
        withTransaction(plain) { model.state = .none }
        stage.layoutSubtreeIfNeeded()
        flight.prewarm()
    }

    /// The Keep keys went down and Daemon knows what it's keeping. Shows "Keeping" with the content
    /// shimmering until `showKept` morphs the same card into Kept.
    public func showKeeping(kind: KeepKindHint, sourceApp: String? = nil, windowTitle: String? = nil, url: String? = nil) {
        keptTask?.cancel()
        keepingSince = Date()
        let summary = KeepingSummary(kind: kind, sourceApp: sourceApp, windowTitle: windowTitle, url: url)
        show(.keeping(kind, summary), for: Theme.Motion.keepingTimeout)
    }

    /// "Kept · Notes" over the first line of what was kept. Tab while it shows opens a one-line note;
    /// Enter calls `onNote`. Pass `count` when several things were kept at once ("Kept · 3 files from Finder").
    /// Morphs from Keeping (or the voice toast) in place, then the thumbnail flies into the menu bar mark.
    public func showKept(item: Item, thumbnailURL: URL?, count: Int = 1, onNote: @escaping (String) -> Void) {
        keptTask?.cancel()
        // Keeping that only just appeared holds a moment, so it reads as a step rather than a flicker.
        let wait = keepingSince.map { Theme.Motion.keepingMin - Date().timeIntervalSince($0) } ?? 0
        let asked = Date()
        keepingSince = nil
        let present = { [weak self] in
            guard let self else { return }
            let morph = self.model.state.isKeeping && self.model.visible && self.panel.isVisible
            let settle = morph ? Theme.Motion.toastSwap : Theme.Motion.toastEnter
            self.model.onNote = onNote
            Perf.measure("toast.kept", morph ? "morph" : "enter") {
                self.show(.kept(item, thumbnailURL, count: max(1, count)), for: Theme.Motion.toastVisible,
                          startingIn: settle, morph: morph)
            }
            self.listenForTab()
            self.fly(after: settle + Theme.Motion.flightDelay)
        }
        if wait <= 0 && thumbnailURL == nil { return present() }
        keptTask = Task {
            // Decode the thumbnail off the main thread while Keeping holds, so Kept draws it without reading a file.
            if let thumbnailURL { await ToastImages.load(thumbnailURL) }
            let left = wait - Date().timeIntervalSince(asked)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled else { return }
            present()
        }
    }

    public func showListening() {
        keptTask?.cancel()
        keepingSince = nil
        model.levels = ToastModel.silence
        show(.listening(Date(), ended: nil), for: nil)
    }

    /// Microphone level, 0...1. Call ~20 times a second.
    public func updateLevel(_ level: Float) {
        guard case .listening(_, nil) = model.state else { return }
        model.levels.removeFirst()
        model.levels.append(min(1, max(ToastModel.floor, level)))
    }

    /// The key came up. The waveform freezes where it was and shimmers as "Keeping" until Kept takes its place.
    public func finishListening() {
        guard case let .listening(start, nil) = model.state else { return }
        keepingSince = Date()
        crossfade(Theme.Motion.toastSwap) { model.state = .listening(start, ended: Date()) }
        model.countdown = Countdown(total: Theme.Motion.keepingTimeout)
        scheduleHide()
    }

    /// Short notices like "Copied, press ⌘V", and calm errors (up to three lines). Longer text stays longer.
    public func showMessage(_ message: String) {
        keptTask?.cancel()
        keepingSince = nil
        show(.message(message), for: ToastModel.readingTime(message))
    }

    // MARK: -

    /// `morph` keeps the card and changes only what's inside it (Keeping -> Kept);
    /// otherwise the new card cross-fades over the old one. `startingIn` delays the progress line.
    private func show(_ state: ToastModel.State, for seconds: Double?, startingIn delay: Double = 0, morph: Bool = false) {
        hideTask?.cancel()
        tabTask?.cancel()
        let update = { [model] in
            model.editingNote = false
            model.note = ""
            model.flying = false
            model.state = state
            if !morph { model.serial &+= 1 }
            model.countdown = seconds.map { Countdown(total: $0, start: Date().addingTimeInterval(delay)) }
        }
        if model.visible && panel.isVisible {
            crossfade(Theme.Motion.toastSwap, update)
        } else {
            placePanel()
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain, update)
            model.visible = true
            panel.alphaValue = 1
            animateStage(entering: true)   // before ordering in: it starts from hidden only when off screen
            panel.orderFrontRegardless()
        }
        if hovering { model.countdown?.pause(at: Date()) }
        scheduleHide()
        if Perf.keepPressed != nil {
            // The Keep keys are waiting on this toast: commit it now, then the hotkey interval ends on screen.
            stage.layoutSubtreeIfNeeded()
            CATransaction.flush()
            Perf.keepAnswered(state.signpostName)
        }
    }

    /// Where the panel goes instead of under the menu bar. Tests and benchmarks put it off screen.
    var origin: NSPoint?

    private func placePanel() {
        if let origin { return panel.setFrameOrigin(origin) }
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

    /// The kept thumbnail lifts out of the card and glides into the menu bar mark, which glows as it lands.
    /// Reduce Motion, a hidden mark, or a mark on another screen: no flight, the mark just glows.
    private func fly(after delay: Double) {
        let serial = model.serial
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.model.serial == serial, case let .kept(item, url, count) = self.model.state else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  let target = self.flightTarget(), let start = self.thumbScreenFrame(),
                  Self.screen(containing: target) === Self.screen(containing: start)
            else { return self.onArrive() }
            Perf.measure("toast.flight") {
                self.flight.fly(ToastThumb(item: item, url: url, count: count), from: start, to: target,
                                appearance: self.panel.effectiveAppearance)
            }
            // The thumbnail has left the card: what stays is a faint imprint, so it reads as moved, not copied.
            self.crossfade(Theme.Motion.flight * FlightPath.lift) { self.model.flying = true }
            try? await Task.sleep(for: .seconds(Theme.Motion.flight * FlightPath.arrival))
            self.onArrive()
        }
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
    }

    /// The thumbnail's frame on screen (bottom-left origin), from the frame the card reports in the panel.
    private func thumbScreenFrame() -> NSRect? {
        let f = model.thumbFrame
        guard f.width > 0 else { return nil }
        return NSRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    private func dismiss() {
        hideTask?.cancel()
        tabTask?.cancel()
        keptTask?.cancel()
        hovering = false
        let serial = model.serial
        model.visible = false
        animateStage(entering: false) { [weak self] in
            guard let self, !self.model.visible, self.model.serial == serial else { return }
            self.panel.orderOut(nil)
            self.model.editingNote = false
            // The last card stays built (off screen): the next keep updates it instead of building it again.
        }
    }

    /// Changes the card without SwiftUI animating it: the render server cross-fades the old card into the new one.
    /// SwiftUI renders the change in this same Core Animation transaction, so the fade captures both.
    private func crossfade(_ duration: Double, _ update: () -> Void) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        stage.layer?.add(fade, forKey: "crossfade")
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain, update)
    }

    /// Enter: drops 8 pt from the menu bar and settles, strong ease-out. Exit: rises back the way it came, faster.
    /// Reduce Motion: a fade. Starts from wherever the card is, so a toast arriving mid-exit turns it around.
    private func animateStage(entering: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let layer = stage.layer else { completion?(); return }
        let shown = CATransform3DIdentity
        let hidden = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? shown : Self.liftedTransform(layer)
        let current = layer.presentation() ?? layer
        let fromHidden = entering && !panel.isVisible
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromHidden ? 0 : current.opacity
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = fromHidden ? hidden : current.transform
        for animation in [opacity, transform] {
            animation.duration = entering ? Theme.Motion.toastEnter : Theme.Motion.toastExit
            animation.timingFunction = entering ? CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                                                : CAMediaTimingFunction(name: .easeOut)
        }
        CATransaction.setDisableActions(true)
        layer.opacity = entering ? 1 : 0
        layer.transform = entering ? shown : hidden
        layer.add(opacity, forKey: "stage.opacity")
        layer.add(transform, forKey: "stage.transform")
        CATransaction.commit()
    }

    /// 8 pt up and 98% around the top of the card, in the stage layer's bottom-up space.
    private static func liftedTransform(_ layer: CALayer) -> CATransform3D {
        let size = layer.bounds.size
        let pivot = CGPoint(x: size.width - 10 - Theme.Size.toastCard.width / 2 - layer.anchorPoint.x * size.width,
                            y: size.height - 8 - layer.anchorPoint.y * size.height)
        var t = CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(0.98, 0.98, 1))
        return CATransform3DConcat(t, CATransform3DMakeTranslation(pivot.x, pivot.y + 8, 0))
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
    /// Includes any wait before a delayed start, so the hide timer and the progress line end together.
    func remaining(at now: Date) -> Double {
        total - elapsed(at: now) + max(0, since.map { $0.timeIntervalSince(now) } ?? 0)
    }
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
    enum State {
        case none, keeping(KeepKindHint, KeepingSummary), kept(Item, URL?, count: Int), listening(Date, ended: Date?)
        case message(String)

        var signpostName: String {
            switch self {
            case .none: "none"
            case .keeping: "Keeping"
            case .kept: "Kept"
            case .listening: "Listening"
            case .message: "message"
            }
        }

        /// Keeping, or the voice toast after the key came up: Kept morphs from it in place.
        var isKeeping: Bool {
            switch self {
            case .keeping, .listening(_, .some): true
            default: false
            }
        }
    }
    static let barCount = 72
    static let floor: Float = 0.06
    static let silence = Array(repeating: floor, count: barCount)

    @Published var state = State.none
    var visible = false                          // on screen or entering; no view reads it, so it's not published
    var serial = 0                               // bumps per toast, so late timers know theirs has gone
    @Published var countdown: Countdown?
    /// The live level, newest last. Not published: `LevelMeter` takes each one straight into its layer, so a level
    /// never makes SwiftUI redraw the card (that cost ~12 ms twenty times a second, a quarter of a core).
    var levels = silence { didSet { onLevels?(levels) } }
    var onLevels: (([Float]) -> Void)?
    @Published var editingNote = false
    @Published var flying = false                // the kept thumbnail is on its way to the menu bar mark
    @Published var note = ""
    var cardFrame = CGRect.zero                  // in the panel, top-left origin; for hover
    var thumbFrame = CGRect.zero                 // in the panel, top-left origin; where the flight starts
    var onNote: (String) -> Void = { _ in }
    var onNoteDone: () -> Void = {}

    /// Seconds to show a notice: about 18 characters a second, within `Theme.Motion.toastMessage`.
    static func readingTime(_ text: String) -> Double {
        let range = Theme.Motion.toastMessage
        return min(range.upperBound, max(range.lowerBound, Double(text.count) / 18))
    }
}

/// What's being kept, known the moment the keys are pressed (before anything is stored).
public enum KeepKindHint: Sendable {
    case text, image, voice, link, files, unknown   // image covers screenshots
}

/// What the Keeping toast says before the item exists: the header Kept will show, where it can be known already.
struct KeepingSummary: Equatable {
    var header: String
    var detail: String?

    init(header: String, detail: String? = nil) {
        self.header = header
        self.detail = detail
    }

    init(kind: KeepKindHint, sourceApp: String?, windowTitle: String?, url: String?) {
        let app = sourceApp.flatMap(KeptSummary.clean)
        let title = windowTitle.flatMap(KeptSummary.clean)
        switch kind {
        case .text: header = app ?? "Text"
        case .image:
            header = "Screenshot"
            detail = [app, title].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .voice: header = "Voice note"
        case .link:
            header = url.flatMap(KeptSummary.host) ?? app ?? "Link"
            detail = title
        case .files: header = app.map { "Files from \($0)" } ?? "Files"
        case .unknown: header = app ?? ""
        }
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

    static func clean(_ s: String) -> String? {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
