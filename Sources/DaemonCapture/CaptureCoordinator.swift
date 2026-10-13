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
        case pressed(NSRunningApplication?, CaptureContext, holdTimer: Task<Void, Never>)
        case recording(VoiceRecorder, CaptureContext)
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
        let context = currentContext(of: NSWorkspace.shared.frontmostApplication)
        onKeepStarted?(context)
        Task { await send(.files(files), context) }
    }

    /// ⌘V inside the Recall panel.
    public func keepClipboard() {
        guard let payload = Clipboard.payload(from: .general) else {
            onError?("The clipboard is empty. Copy something first, then press ⌘V.")
            return
        }
        let context = CaptureContext()
        onKeepStarted?(context)
        Task { await send(payload, context) }
    }

    // MARK: - Hotkey

    private func keepKeyDown() {
        guard case .idle = state else { return }
        let app = NSWorkspace.shared.frontmostApplication
        guard !excludedApps.contains(app?.bundleIdentifier) else { state = .waitingForKeyUp; return }
        let context = currentContext(of: app)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: ContextRules.holdThreshold)
            guard !Task.isCancelled else { return }
            self?.startVoice(context)
        }
        state = .pressed(app, context, holdTimer: timer)
    }

    private func keepKeyUp() {
        switch state {
        case let .pressed(app, context, timer):
            timer.cancel()
            state = .working
            Task {
                await keepFromContext(app, context)
                state = .idle
            }
        case let .recording(recorder, context):
            state = .working
            let url = recorder.stop()
            onVoiceFinished?()
            Task {
                await send(.voiceNote(url), context)
                state = .idle
            }
        case .waitingForKeyUp:
            state = .idle
        case .idle, .working:
            break
        }
    }

    private func startVoice(_ context: CaptureContext) {
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
            state = .recording(recorder, context)
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

    private func keepFromContext(_ app: NSRunningApplication?, _ context: CaptureContext) async {
        if !Permissions.accessibility, !toldAboutAccessibility {
            // No system prompt here: say it once per launch and keep what's possible without it (region capture).
            toldAboutAccessibility = true
            onError?("Daemon can't read selected text yet. Turn on Daemon in System Settings → Privacy & Security → Accessibility.")
        }
        var context = context
        let bundleID = app?.bundleIdentifier
        async let page = BrowserPage.read(bundleID: bundleID)
        async let finderFiles = bundleID == ContextRules.finderBundleID ? FinderSelection.read() : []
        var text: String?
        if let app { text = await SelectionReader.selectedText(in: app) }
        let browserPage = await page
        context.url = browserPage?.url.absoluteString

        let snapshot = ContextSnapshot(frontmostBundleID: bundleID, selectedText: text,
                                       finderSelection: await finderFiles, pageURL: browserPage?.url)
        let action = ContextRules.decide(snapshot)
        log.info("keep app=\(bundleID ?? "-") action=\(String(describing: action)) selection=\(text?.count ?? 0) chars finder=\(snapshot.finderSelection.count) page=\(browserPage != nil)")
        switch action {
        case .text:
            onKeepStarted?(context)
            if let link = Self.lonelyURL(text ?? "") {
                await send(.link(url: link, title: nil, screenshot: nil), context)   // selected just an address
            } else {
                await send(.text(text ?? ""), context)
            }
        case .files:
            onKeepStarted?(context)
            await send(.files(snapshot.finderSelection), context)
        case .link:
            guard let browserPage, let app else { return }
            onKeepStarted?(context)
            // Link keeps never prompt for Screen Recording; the first region screenshot does.
            var shot: URL?
            if Permissions.screenRecording { shot = try? await Screenshot.frontWindow(of: app.processIdentifier) }
            await send(.link(url: browserPage.url, title: browserPage.title, screenshot: shot), context)
        case .region:
            await keepRegion(context, returningTo: app)
        case .voice, .ignore:
            break
        }
    }

    private func keepRegion(_ context: CaptureContext, returningTo app: NSRunningApplication?) async {
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            onError?("Screenshots need Screen Recording. Turn it on in System Settings → Privacy & Security, then try again.")
            return
        }
        let selection = await RegionPicker.pick()
        app?.activate()
        guard let selection else { return }
        onKeepStarted?(context)
        do {
            let url = try await Screenshot.region(selection.rect, displayID: selection.displayID)
            await send(.screenshot(url), context)
        } catch {
            onError?("Couldn't take that screenshot. Check Screen Recording in System Settings, then try again.")
        }
    }

    private func send(_ payload: CapturePayload, _ context: CaptureContext) async {
        do {
            onKept?(try await sink.keep(Capture(payload: payload, context: context)))
        } catch let error as LocalizedError where error.errorDescription != nil {
            onError?(error.errorDescription!)   // e.g. trial ended: the sink explains why
        } catch {
            onError?("Couldn't keep that just now. Try again in a moment.")
        }
    }
}
