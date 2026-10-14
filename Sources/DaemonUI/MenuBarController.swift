import AppKit
import DaemonCore
import SwiftUI

/// The status item: the dot-in-ring mark, its menu, the glow after a keep, and file drops.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let counts = MenuCounts()
    private let recentMenu = NSMenu()
    private let glow = CALayer()
    private var hintPopover: NSPopover?

    private let onRecall: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    private let onDropFiles: ([URL]) -> Void
    private let recentItems: () -> [Item]
    private let onOpenRecent: (Item) -> Void

    public init(onRecall: @escaping () -> Void, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void,
                onDropFiles: @escaping ([URL]) -> Void, recentItems: @escaping () -> [Item],
                onOpenRecent: @escaping (Item) -> Void) {
        self.onRecall = onRecall
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.onDropFiles = onDropFiles
        self.recentItems = recentItems
        self.onOpenRecent = onOpenRecent
        super.init()

        guard let button = statusItem.button else { return }
        button.image = Self.markImage(color: nil)
        button.setAccessibilityLabel("Daemon")
        button.wantsLayer = true
        glow.opacity = 0
        glow.contentsGravity = .center
        button.layer?.addSublayer(glow)

        // A drop target inside the button: the status bar window doesn't reliably forward drags to a delegate.
        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onEnter = { [weak self] in self?.statusItem.button?.highlight(true) }
        drop.onExit = { [weak self] in self?.statusItem.button?.highlight(false) }
        drop.onDrop = { [weak self] urls in
            self?.statusItem.button?.highlight(false)
            self?.onDropFiles(urls)
        }
        button.addSubview(drop)

        statusItem.menu = makeMenu()
    }

    public func updateCounts(total: Int, today: Int) {
        counts.total = total
        counts.today = today
    }

    /// The mark's frame on screen, where a kept thumbnail flies. Nil while the status item isn't shown.
    public var markScreenFrame: NSRect? {
        guard statusItem.isVisible, let button = statusItem.button, let window = button.window, window.isVisible
        else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// The one daily moment of motion: the mark glows in the accent color and fades over 1.2 s.
    public func pulse() {
        guard let button = statusItem.button, let layer = button.layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var accent = CGColor(gray: 0, alpha: 1)
        button.effectiveAppearance.performAsCurrentDrawingAppearance { accent = Theme.accentNS.cgColor }

        glow.frame = layer.bounds
        glow.contentsScale = button.window?.backingScaleFactor ?? 2
        glow.contents = Self.markImage(color: NSColor(cgColor: accent))
        glow.shadowColor = accent
        glow.shadowOffset = .zero
        glow.shadowOpacity = reduceMotion ? 0 : 0.9
        glow.removeAllAnimations()

        let fade = Theme.Motion.keepGlowFade
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        // A quick bloom in, a short hold, then a long ease-out. Reduce Motion: no bloom, just the fade.
        opacity.values = reduceMotion ? [1, 1, 0] : [0, 1, 1, 0]
        opacity.keyTimes = reduceMotion ? [0, 0.15, 1] : [0, 0.08, 0.2, 1]
        opacity.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
                                   CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)]
        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 6
        radius.toValue = 1
        radius.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = reduceMotion ? [opacity] : [opacity, radius]
        group.duration = fade + (reduceMotion ? 0 : 0.15)
        glow.add(group, forKey: "pulse")
    }

    /// The last onboarding step: a small popover under the mark.
    public func showLivesHereHint() {
        guard let button = statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        // Anchored to the status button, a popover takes the menu bar's appearance; follow Daemon's instead.
        popover.appearance = NSApp.effectiveAppearance
        popover.contentViewController = NSHostingController(rootView: LivesHereHint())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hintPopover = popover
        Task { [weak popover] in
            try? await Task.sleep(for: .seconds(8))
            popover?.performClose(nil)
        }
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(viewItem(MenuHeader(counts: counts), height: 58))
        menu.addItem(.separator())

        let recall = item("Recall", key: " ", #selector(recall))
        recall.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(recall)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        menu.addItem(recent)

        menu.addItem(item("Settings…", key: ",", #selector(settings)))
        menu.addItem(item("Quit Daemon", key: "q", #selector(quit)))
        return menu
    }

    private func item(_ title: String, key: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func viewItem<V: View>(_ view: V, height: CGFloat) -> NSMenuItem {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 250, height: height)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let items = recentItems()
        if items.isEmpty {
            let empty = NSMenuItem(title: "Nothing kept yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for recent in items.prefix(10) {
            let entry = item(String(recent.displayTitle.prefix(48)), key: "", #selector(openRecent(_:)))
            entry.representedObject = recent
            menu.addItem(entry)
        }
    }

    @objc private func recall() { onRecall() }
    @objc private func settings() { onSettings() }
    @objc private func quit() { onQuit() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? Item { onOpenRecent(item) }
    }

    // MARK: - Mark image

    /// Template image when `color` is nil, so the menu bar tints it.
    static func markImage(color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            (color ?? .black).set()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.25, dy: 2.25))
            ring.lineWidth = 1.5
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 2.25, y: rect.midY - 2.25, width: 4.5, height: 4.5)).fill()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

final class MenuCounts: ObservableObject {
    @Published var total = 0
    @Published var today = 0
}

struct MenuHeader: View {
    @ObservedObject var counts: MenuCounts

    var body: some View {
        HStack(spacing: 12) {
            Mark(size: 18, color: .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Daemon").font(Theme.Font.menuTitle).foregroundStyle(.primary)
                Text("\(counts.total.formatted()) kept · \(counts.today.formatted()) today")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(width: 250, height: 58)
    }
}

struct LivesHereHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("Daemon lives here").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            hintRow("Keep what you see", keys: ["⌃", "⌥", "S"])
            hintRow("Recall anything", keys: ["⌃", "⌥", "Space"])
        }
        .padding(14)
        .frame(width: 250)
    }

    private func hintRow(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 4) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize()
            Spacer(minLength: 12)
            ForEach(keys, id: \.self) { Kbd(label: $0, font: Theme.Font.small) }
        }
    }
}


/// Accepts files dropped on the menu bar mark; clicks fall through to the status button underneath.
final class StatusDropView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { (superview as? NSButton)?.performClick(nil) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEnter()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onExit() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { onExit(); return false }
        onDrop(urls)
        return true
    }
}
