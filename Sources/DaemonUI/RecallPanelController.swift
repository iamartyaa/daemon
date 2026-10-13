import AppKit
import DaemonCore
import Quartz
import SwiftUI

/// The Recall panel: a floating, Spotlight-like panel that takes keyboard focus without activating Daemon,
/// so the app you were in stays frontmost for paste-back.
@MainActor
public final class RecallPanelController: NSObject {
    private let model: RecallViewModel
    private let panel: RecallPanel
    private let toasts: ToastPresenter
    private var keyMonitor: Any?

    public var isVisible: Bool { panel.isVisible }

    /// Pass the app's `ToastPresenter` so "Copied, press ⌘V" shows in the same place as other toasts.
    public init(dataSource: RecallDataSource, actions: RecallActions, toasts: ToastPresenter? = nil) {
        model = RecallViewModel(dataSource: dataSource, actions: actions)
        self.toasts = toasts ?? ToastPresenter()
        panel = RecallPanel(contentRect: NSRect(origin: .zero, size: Theme.Size.recallPanel),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: RecallView(model: model))

        model.close = { [weak self] in self?.hide() }
        model.showToast = { [weak self] in self?.toasts.showMessage($0) }
        model.quickLook = { [weak self] in self?.toggleQuickLook($0) }

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.panelLostFocus() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = RecallPanelController.key(for: event) else { return event }
            let window = event.windowNumber
            let handled = MainActor.assumeIsolated {
                guard let self, window == self.panel.windowNumber else { return false }
                return self.model.handle(key)
            }
            return handled ? nil : event
        }
    }

    public func show() {
        guard !panel.isVisible else { return panel.makeKey() }
        model.previousAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        position()
        panel.makeKeyAndOrderFront(nil)
        model.reset()   // after the panel is key, or SwiftUI drops the focus request and typing goes nowhere
    }

    public func hide() {
        guard panel.isVisible else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        model.finishPendingDelete()
        panel.orderOut(nil)
    }

    public func toggle() { isVisible ? hide() : show() }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return panel.center() }
        let size = Theme.Size.recallPanel
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.16))
    }

    private func panelLostFocus() {
        // Quick Look takes key focus while it is open; that doesn't count as leaving.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        hide()
    }

    private func toggleQuickLook(_ url: URL) {
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { return ql.orderOut(nil) }
        panel.previewURL = url
        ql.makeKeyAndOrderFront(nil)
        ql.reloadData()
    }

    nonisolated static func key(for event: NSEvent) -> RecallKey? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch (event.keyCode, mods) {
        case (126, []): return .up
        case (125, []): return .down
        case (123, []): return .left
        case (124, []): return .right
        case (36, []), (76, []): return .enter
        case (36, .command), (76, .command): return .cmdEnter
        case (51, .command): return .cmdDelete
        case (49, []): return .space
        case (48, []): return .tab
        case (48, .shift): return .shiftTab
        case (53, []): return .escape
        default: break
        }
        guard mods == .command else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return .cmdC
        case "v": return .cmdV
        case "r": return .cmdR
        case "z": return .cmdZ
        default: return nil
        }
    }
}

/// Borderless panels refuse key status by default; this one needs it for typing. It also feeds Quick Look.
final class RecallPanel: NSPanel, QLPreviewPanelDataSource {
    var previewURL: URL?

    override var canBecomeKey: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
}
