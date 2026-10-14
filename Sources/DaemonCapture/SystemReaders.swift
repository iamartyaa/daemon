import os
import AppKit
import ApplicationServices
import DaemonCore

enum AX {
    // ponytail: one serial queue for every Accessibility call. Each is IPC to another app (up to the 0.3 s timeout),
    // so none runs on the main thread, where a slow app would stall the toast.
    private static let queue = DispatchQueue(label: "daemon.capture.ax", qos: .userInitiated)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return app
    }

    static func focusedWindowTitle(_ pid: pid_t) -> String? {
        guard let window = element(app(pid), kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Time, app and window title for a keep. The page URL is added later for browsers.
@MainActor
func currentContext(of app: NSRunningApplication?) async -> CaptureContext {
    let pid = app?.processIdentifier
    let title = await AX.run { pid.flatMap(AX.focusedWindowTitle) }
    return CaptureContext(createdAt: Date(), sourceApp: app?.localizedName, sourceBundleID: app?.bundleIdentifier,
                          windowTitle: title)
}

/// Everything about the app in front that can be read without touching it, started the moment the Keep keys go
/// down: its window title and selection (Accessibility), and for a browser or Finder the page or the selected
/// files (Apple Events). By the time the keys come up it's usually all here, so Keeping shows at once.
struct FrontReading: Sendable {
    var ax: Task<SelectionReader.AXSelection, Never>
    var apple: Task<(page: BrowserPage?, files: [URL]), Never>

    init(pid: pid_t, bundleID: String?) {
        ax = Task { await SelectionReader.readAX(pid: pid, bundleID: bundleID) }
        apple = Task {
            if bundleID == ContextRules.finderBundleID { return (nil, await FinderSelection.read()) }
            return (await BrowserPage.read(bundleID: bundleID), [])
        }
    }
}

enum SelectionReader {
    struct AXSelection: Sendable {
        var windowTitle: String?
        var text: String?             // non-empty selected text
        var reliablyEmpty = false     // Accessibility answered "nothing selected" and the app can be trusted on it
    }

    /// Window title and selected text via Accessibility, off the main thread.
    static func readAX(pid: pid_t, bundleID: String?) async -> AXSelection {
        await AX.run {
            Perf.measure("selection.ax", bundleID ?? "") {
                let app = AX.app(pid)
                let title = AX.element(app, kAXFocusedWindowAttribute).flatMap { AX.string($0, kAXTitleAttribute) }
                var read = AXSelection(windowTitle: title?.isEmpty == false ? title : nil)
                // ⌘C in Finder copies files, so there's no fallback there.
                guard bundleID != ContextRules.finderBundleID else { read.reliablyEmpty = true; return read }
                let text = AX.element(app, kAXFocusedUIElementAttribute).flatMap { AX.string($0, kAXSelectedTextAttribute) }
                if let text, !text.isEmpty { read.text = text; return read }
                read.reliablyEmpty = text != nil && (Browser(bundleID: bundleID)?.accessibilitySelectionIsReliable ?? true)
                return read
            }
        }
    }

    /// The selection: what Accessibility read, else a synthesized ⌘C for apps that don't expose it.
    @MainActor static func selectedText(_ ax: AXSelection) async -> String? {
        if let text = ax.text { return text }
        if ax.reliablyEmpty || !AXIsProcessTrusted() { return nil }
        let state = Perf.begin("selection.copy")
        defer { Perf.end("selection.copy", state) }
        return await copyViaCommandC()
    }

    /// Save the clipboard, ⌘C, read the new string if one shows up within the timeout, put the clipboard back.
    @MainActor static func copyViaCommandC(pasteboard: NSPasteboard = .general, timeout: Duration = .milliseconds(150)) async -> String? {
        let snapshot = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        guard Keystroke.post(virtualKey: 0x08) else { return nil } // kVK_ANSI_C
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while pasteboard.changeCount == before, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        return text
    }
}

enum Keystroke {
    /// Posts ⌘+key to whatever app is in front. Needs Accessibility.
    static func post(virtualKey: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

private let scriptLog = Logger(subsystem: "app.mydaemon.Daemon", category: "applescript")

enum AppleScript {
    // ponytail: one serial queue so a slow app or an Automation prompt never blocks the main thread
    private static let queue = DispatchQueue(label: "daemon.capture.applescript")

    /// Runs the script and returns its result as strings (a list's items, or the single value). nil on error.
    static func run(_ source: String) async -> [String?]? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let script = "with timeout of 2 seconds\n\(source)\nend timeout"
                guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil else {
                    // -1743: the user hasn't allowed Automation for that app; -600: app not running.
                    scriptLog.error("AppleScript failed \(error?[NSAppleScript.errorNumber] as? Int ?? 0): \(error?[NSAppleScript.errorMessage] as? String ?? "")")
                    return continuation.resume(returning: nil)
                }
                guard result.descriptorType == typeAEList else { return continuation.resume(returning: [result.stringValue]) }
                let count = result.numberOfItems
                continuation.resume(returning: count == 0 ? [] : (1...count).map { result.atIndex($0)?.stringValue })
            }
        }
    }
}

enum FinderSelection {
    static func read() async -> [URL] {
        let script = """
        tell application id "com.apple.finder"
            set paths to {}
            repeat with f in (get selection as alias list)
                set end of paths to POSIX path of f
            end repeat
            return paths
        end tell
        """
        return (await AppleScript.run(script) ?? []).compactMap { $0.map { URL(fileURLWithPath: $0) } }
    }
}

struct BrowserPage: Equatable, Sendable {
    var url: URL
    var title: String?

    static func read(bundleID: String?) async -> BrowserPage? {
        guard let bundleID, let script = Browser(bundleID: bundleID)?.pageScript(bundleID: bundleID),
              let result = await AppleScript.run(script), let first = result.first, let link = first,
              let url = URL(string: link), url.scheme != nil else { return nil }
        let title = result.count > 1 ? result[1] : nil
        return BrowserPage(url: url, title: title?.isEmpty == false ? title : nil)
    }
}
