import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureFailed: Error {}

enum Screenshot {
    /// PNG of the app's frontmost on-screen window (the browser page for link keeps).
    static func frontWindow(of pid: pid_t) async throws -> URL {
        // CGWindowList is ordered front to back; SCShareableContent's order isn't documented.
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let windowID = infos.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        })?[kCGWindowNumber as String] as? CGWindowID else { throw CaptureFailed() }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureFailed() }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await capture(filter, rect: nil)
    }

    /// PNG of `rect` (display points, top-left origin) on the display, without Daemon's own windows.
    static func region(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureFailed() }
        let daemon = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: daemon, exceptingWindows: [])
        return try await capture(filter, rect: rect)
    }

    private static func capture(_ filter: SCContentFilter, rect: CGRect?) async throws -> URL {
        let scale = CGFloat(filter.pointPixelScale)
        let size = rect?.size ?? filter.contentRect.size
        let config = SCStreamConfiguration()
        if let rect { config.sourceRect = rect }
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try writePNG(image)
    }

    static func writePNG(_ image: CGImage) throws -> URL {
        let url = CaptureFiles.newURL(ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CaptureFailed() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureFailed() }
        return url
    }
}

/// Region screenshot mode: a dimmed overlay on every screen, drag a rectangle, Esc cancels.
@MainActor
final class RegionPicker {
    struct Selection { var rect: CGRect; var displayID: CGDirectDisplayID }

    private static var active: RegionPicker?
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?

    /// The picked rectangle in display points (top-left origin), or nil when cancelled.
    static func pick() async -> Selection? {
        guard active == nil else { return nil }
        let picker = RegionPicker()
        active = picker
        return await withCheckedContinuation { picker.begin($0) }
    }

    private func begin(_ continuation: CheckedContinuation<Selection?, Never>) {
        self.continuation = continuation
        windows = NSScreen.screens.map { OverlayWindow(screen: $0, picker: self) }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.orderFrontRegardless()
            if window.frame.contains(mouse) { window.makeKey() }
        }
    }

    fileprivate func finish(_ rect: CGRect?, on screen: NSScreen?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        Self.active = nil
        var selection: Selection?
        if let rect, let screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            // AppKit is bottom-left; ScreenCaptureKit's sourceRect is top-left.
            selection = Selection(rect: CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                                               width: rect.width, height: rect.height), displayID: id)
        }
        continuation?.resume(returning: selection)
        continuation = nil
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, picker: RegionPicker) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = OverlayView(picker: picker)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private weak var picker: RegionPicker?
    private var start: NSPoint?
    private var current: NSPoint?

    init(picker: RegionPicker) {
        self.picker = picker
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let selection else { return }
        selection.fill(using: .clear)
        NSColor.white.setStroke()
        NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let selection, selection.width >= 4, selection.height >= 4 else { return cancel() }
        picker?.finish(selection, on: window?.screen)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel() } else { super.keyDown(with: event) } // Esc
    }

    override func cancelOperation(_ sender: Any?) { cancel() }

    private func cancel() { picker?.finish(nil, on: nil) }
}
