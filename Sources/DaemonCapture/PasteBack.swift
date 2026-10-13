import AppKit
import DaemonCore

/// Recall's Enter / ⌘C / ⌘Enter. Create it at launch so it can track the app that was in front before the panel.
@MainActor
public final class PasteBack: RecallActions {
    public private(set) var previousApp: NSRunningApplication?
    private let pasteboard: NSPasteboard
    private var observer: NSObjectProtocol?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { previousApp = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != me else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Item on the clipboard → previous app in front → ⌘V → original clipboard back after ~250 ms.
    /// Returns false when it couldn't paste; the item then stays on the clipboard ("Copied, press ⌘V").
    public func paste(_ hit: SearchHit, fileURL: URL?) async -> Bool {
        let original = PasteboardSnapshot(pasteboard)
        guard Clipboard.write(hit, fileURL: fileURL, to: pasteboard) else { return false }
        let written = pasteboard.changeCount
        guard Permissions.accessibility, let app = previousApp, !app.isTerminated else { return false }

        app.activate()
        for _ in 0..<50 where NSWorkspace.shared.frontmostApplication != app {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard NSWorkspace.shared.frontmostApplication == app, Keystroke.post(virtualKey: 0x09) else { return false } // kVK_ANSI_V

        try? await Task.sleep(for: .milliseconds(250))
        if pasteboard.changeCount == written { original.restore(to: pasteboard) } // don't clobber a newer copy
        return true
    }

    public func copy(_ hit: SearchHit, fileURL: URL?) {
        Clipboard.write(hit, fileURL: fileURL, to: pasteboard)
    }

    public func open(_ hit: SearchHit, fileURL: URL?) {
        if let fileURL { NSWorkspace.shared.open(fileURL); return }
        if let link = hit.item.url, let url = URL(string: link) { NSWorkspace.shared.open(url); return }
        guard let text = hit.item.text else { return }
        let file = CaptureFiles.newURL(ext: "txt")
        if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil { NSWorkspace.shared.open(file) }
    }
}
