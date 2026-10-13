import AppKit

/// QA aid, off unless `defaults write app.mydaemon.Daemon debugSnapshots -bool true`: every 0.4 s, writes each
/// visible Daemon window (panel, toasts, onboarding, menu) as a PNG to ~/Library/Caches/app.mydaemon.Daemon/snapshots,
/// keeping the last 8 frames per window. Drawing its own windows needs no Screen Recording permission.
@MainActor
enum DebugSnapshots {
    private static var timer: Timer?
    private static var frame = 0

    static func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "debugSnapshots") else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.mydaemon.Daemon/snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { capture(into: dir) }
        }
    }

    private static func capture(into dir: URL) {
        frame = (frame + 1) % 8
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 1,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = "\(String(describing: type(of: window)))-\(i)-f\(frame).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }
}
