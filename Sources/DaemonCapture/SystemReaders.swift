import AppKit
import ApplicationServices
import DaemonCore

enum AX {
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

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard let window = element(app(pid), kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Time, app and window title for a keep. The page URL is added later for browsers.
@MainActor
func currentContext(of app: NSRunningApplication?) -> CaptureContext {
    CaptureContext(createdAt: Date(), sourceApp: app?.localizedName, sourceBundleID: app?.bundleIdentifier,
                   windowTitle: app.flatMap { AX.focusedWindowTitle(pid: $0.processIdentifier) })
}

@MainActor
enum SelectionReader {
    /// Selected text in the app, via Accessibility; falls back to a synthesized ⌘C for apps that don't expose it.
    static func selectedText(in app: NSRunningApplication) async -> String? {
        let bundleID = app.bundleIdentifier
        guard bundleID != ContextRules.finderBundleID else { return nil } // ⌘C in Finder copies files
        let focused = AX.element(AX.app(app.processIdentifier), kAXFocusedUIElementAttribute)
        let axText = focused.flatMap { AX.string($0, kAXSelectedTextAttribute) }
        if let axText, !axText.isEmpty { return axText }
        let axSaidEmpty = axText != nil && (Browser(bundleID: bundleID)?.accessibilitySelectionIsReliable ?? true)
        if axSaidEmpty || !AXIsProcessTrusted() { return nil }
        return await copyViaCommandC()
    }

    /// Save the clipboard, ⌘C, read the new string if one shows up within the timeout, put the clipboard back.
    static func copyViaCommandC(pasteboard: NSPasteboard = .general, timeout: Duration = .milliseconds(150)) async -> String? {
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
