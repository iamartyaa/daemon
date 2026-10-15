import AppKit
import AVFoundation
import DaemonCore
import KeyboardShortcuts

import os
private let log = Logger(subsystem: "app.mydaemon.Daemon", category: "capture")

public extension KeyboardShortcuts.Name {
    static let keep = Self("keep", initial: .init(.s, modifiers: [.control, .option]))
    static let recall = Self("recall", initial: .init(.space, modifiers: [.control, .option]))
}

/// Owns the Keep and Recall hotkeys and turns a Keep press into a Capture for the sink.
/// Callbacks fire on the main actor, before slow work, so the toast can show right away.
@MainActor
public final class CaptureCoordinator {
    /// Something is being kept (text, files, link, or a region once drawn).
    public var onKeepStarted: ((CaptureContext) -> Void)?
    /// Same moment as `onKeepStarted`, with what's being kept (a selection that is only an address is `.link`).
    public var onKeepStartedKind: ((KeepAction, CaptureContext) -> Void)?
    public var onVoiceStarted: ((CaptureContext) -> Void)?
    public var onVoiceLevel: ((Float) -> Void)?
    public var onVoiceFinished: (() -> Void)?
    public var onKept: (([Item]) -> Void)?
    /// Calm, says what to do next.
    public var onError: ((String) -> Void)?
    public var onRecall: (() -> Void)?

    public let excludedApps: ExcludedApps
    private let sink: CaptureSink

    private enum State {
        case idle
        case pressed(NSRunningApplication?, CaptureContext, FrontReading?, holdTimer: Task<Void, Never>)
        case recording(VoiceRecorder, CaptureContext, FrontReading?)
        case waitingForKeyUp   // excluded app, or the microphone wasn't available
        case working
    }
    private var state = State.idle

    public init(sink: CaptureSink, excludedApps: ExcludedApps = ExcludedApps()) {
        self.sink = sink
        self.excludedApps = excludedApps
        KeyboardShortcuts.onKeyDown(for: .keep) { [weak self] in self?.keepKeyDown() }
        KeyboardShortcuts.onKeyUp(for: .keep) { [weak self] in self?.keepKeyUp() }
        KeyboardShortcuts.onKeyDown(for: .recall) { [weak self] in self?.onRecall?() }
    }

    /// Files dropped on the menu bar icon.
    public func keep(files: [URL]) {
        guard !files.isEmpty else { return }
        let app = NSWorkspace.shared.frontmostApplication
        Task {
            let context = await currentContext(of: app)
            keepStarted(.files, context)
            await send(.files(files), context)
        }
    }

    /// ⌘V inside the Recall panel.
    public func keepClipboard() {
        guard let payload = Clipboard.payload(from: .general) else {
            onError?("The clipboard is empty. Copy something first, then press ⌘V.")
            return
        }
        let context = CaptureContext(sourceApp: "Clipboard")   // ⌘V in Recall: no app or window to credit
        keepStarted(Self.action(for: payload), context)
        Task { await send(payload, context) }
    }

    // MARK: - Hotkey

    /// Nothing slow happens here: what's in front is read off the main thread while the keys are still down.
    private func keepKeyDown() {
        guard case .idle = state else { return }
        Perf.keepPressed = Perf.begin("keep.hotkey-to-toast")
        let app = NSWorkspace.shared.frontmostApplication
        guard !excludedApps.contains(app?.bundleIdentifier) else {
            Perf.keepAnswered("excluded app")
            state = .waitingForKeyUp
            return
        }
        let context = CaptureContext(createdAt: Date(), sourceApp: app?.localizedName, sourceBundleID: app?.bundleIdentifier)
        let reading = app.map { FrontReading(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: ContextRules.holdThreshold)
            guard !Task.isCancelled else { return }
            self?.startVoice(context, reading)
        }
        state = .pressed(app, context, reading, holdTimer: timer)
    }

    private func keepKeyUp() {
        switch state {
        case let .pressed(app, context, reading, timer):
            timer.cancel()
            state = .working
            Task {
                await keepFromContext(app, context, reading)
                state = .idle
            }
        case let .recording(recorder, context, reading):
            state = .working
            let url = recorder.stop()
            onVoiceFinished?()
            Task {
                var context = context
                context.windowTitle = await reading?.ax.value.windowTitle
                await send(.voiceNote(url), context)
                state = .idle
            }
        case .waitingForKeyUp:
            state = .idle
        case .idle, .working:
            break
        }
    }

    private func startVoice(_ context: CaptureContext, _ reading: FrontReading?) {
        guard case .pressed = state else { return }
        state = .waitingForKeyUp
        switch Permissions.microphone {
        case .authorized:
            let recorder = VoiceRecorder()
            do {
                try recorder.start { [weak self] in self?.onVoiceLevel?($0) }
            } catch {
                onError?("Couldn't start recording. Check that a microphone is connected, then hold the Keep keys again.")
                return
            }
            state = .recording(recorder, context, reading)
            onVoiceStarted?(context)
        case .notDetermined:
            Task { _ = await Permissions.requestMicrophone() }
            onError?("Allow the microphone for voice notes, then hold the Keep keys again.")
        default:
            onError?("Voice notes need the microphone. Turn it on in System Settings → Privacy & Security → Microphone.")
        }
    }

    // MARK: - Rules 2–5

    private var toldAboutAccessibility = false

    /// A selection that is only a web address ("x.com/evilseyee", "https://…") is kept as a link.
    static func lonelyURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              match.range.length == (t as NSString).length,   // the whole selection, not an address inside prose
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    private func keepFromContext(_ app: NSRunningApplication?, _ context: CaptureContext, _ reading: FrontReading?) async {
        if !Permissions.accessibility, !toldAboutAccessibility {
            // No system prompt here: say it once per launch and keep what's possible without it (region capture).
            toldAboutAccessibility = true
            onError?("Daemon can't read selected text yet. Turn on Daemon in System Settings → Privacy & Security → Accessibility.")
        }
        var context = context
        let bundleID = app?.bundleIdentifier
        var text: String?
        if let ax = await reading?.ax.value {
            context.windowTitle = ax.windowTitle
            text = await SelectionReader.selectedText(ax)
        }
        let apple = await reading?.apple.value
        let browserPage = apple?.page
        context.url = browserPage?.url.absoluteString

        let snapshot = ContextSnapshot(frontmostBundleID: bundleID, selectedText: text,
                                       finderSelection: apple?.files ?? [], pageURL: browserPage?.url)
        var action = ContextRules.decide(snapshot)
        if action == .region, !Permissions.accessibility, !Permissions.screenRecording {
            action = .ignore   // the Accessibility message above already said what to do; no second prompt
        }
        log.notice("keep app=\(bundleID ?? "-") action=\(String(describing: action), privacy: .public) selection=\(text?.count ?? 0) chars finder=\(snapshot.finderSelection.count) page=\(browserPage != nil)")
        switch action {
        case .text:
            let link = Self.lonelyURL(text ?? "")
            keepStarted(link == nil ? .text : .link, context)
            if let link {
                await send(.link(url: link, title: nil, screenshot: nil), context)   // selected just an address
            } else {
                await send(.text(text ?? ""), context)
            }
        case .files:
            keepStarted(.files, context)
            await send(.files(snapshot.finderSelection), context)
        case .link:
            guard let browserPage, let app else { return }
            keepStarted(.link, context)
            // Link keeps never prompt for Screen Recording; the first region screenshot does.
            var shot: URL?
            if Permissions.screenRecording { shot = try? await Screenshot.frontWindow(of: app.processIdentifier) }
            await send(.link(url: browserPage.url, title: browserPage.title, screenshot: shot), context)
        case .region:
            Perf.keepAnswered("region picker")
            await keepRegion(context, returningTo: app)
        case .voice, .ignore:
            Perf.keepAnswered("nothing to keep")
        }
    }

    private func keepRegion(_ context: CaptureContext, returningTo app: NSRunningApplication?) async {
        guard Permissions.screenRecording else {
            // The system dialog is shown once, ever. After that a grant only takes effect when Daemon restarts,
            // so asking again would loop; say what to do instead.
            let asked = UserDefaults.standard.bool(forKey: "askedScreenRecording")
            if !asked {
                UserDefaults.standard.set(true, forKey: "askedScreenRecording")
                Permissions.requestScreenRecording()
                onError?("Screenshots need Screen Recording. Turn it on for Daemon, then quit and reopen Daemon.")
            } else {
                onError?("Screenshots need Screen Recording. Turn it on for Daemon in the settings that just opened, then quit and reopen Daemon.")
                Permissions.openSettings(.screenRecording)
            }
            return
        }
        let selection = await RegionPicker.pick()
        app?.activate()
        guard let selection else { return }
        keepStarted(.region, context)
        do {
            let url = try await Screenshot.region(selection.rect, displayID: selection.displayID)
            await send(.screenshot(url), context)
        } catch {
            onError?("Couldn't take that screenshot. Check Screen Recording in System Settings, then try again.")
        }
    }

    private func keepStarted(_ action: KeepAction, _ context: CaptureContext) {
        onKeepStarted?(context)
        onKeepStartedKind?(action, context)
    }

    private static func action(for payload: CapturePayload) -> KeepAction {
        switch payload {
        case .text: .text
        case .files: .files
        case .screenshot: .region
        case .voiceNote: .voice
        case .link: .link
        }
    }

    private func send(_ payload: CapturePayload, _ context: CaptureContext) async {
        do {
            let state = Perf.begin("keep.store", String(describing: Self.action(for: payload)))
            let items = try await sink.keep(Capture(payload: payload, context: context))
            Perf.end("keep.store", state)
            onKept?(items)
        } catch let error as LocalizedError where error.errorDescription != nil {
            onError?(error.errorDescription!)
        } catch {
            onError?("Couldn't keep that just now. Try again in a moment.")
        }
    }
}
