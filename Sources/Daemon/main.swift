import AppKit

// Menu bar shell. Hotkeys, Recall panel and Keep arrive in the capture/recall phases.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "smallcircle.filled.circle", accessibilityDescription: "Daemon")

        let menu = NSMenu()
        menu.addItem(disabled("Daemon · 0 kept"))
        menu.addItem(.separator())
        let recall = NSMenuItem(title: "Recall", action: nil, keyEquivalent: " ")
        recall.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(recall)
        menu.addItem(NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Daemon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.addItem(.separator())
        menu.addItem(disabled("Private · on this Mac"))
        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
