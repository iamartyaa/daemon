import AppKit
import DaemonCore
import DaemonUI
import SwiftUI

/// First launch: download the model with a progress window; pause, resume and retry until it's on disk.
@MainActor
final class FirstRunDownload: ObservableObject {
    @Published var progress: ModelDownloadProgress
    @Published var phase: ModelDownloadView.Phase = .downloading
    private let downloader = ModelDownloader()
    private var resume: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Error>?

    init() {
        progress = ModelDownloadProgress(fileName: "", fileBytesDone: 0, fileBytesTotal: 0,
                                         bytesDone: 0, bytesTotal: ModelManifest.embeddingGemma2.totalBytes)
    }

    func runIfNeeded() async {
        let status = await downloader.status()
        guard !status.isComplete else { return }
        progress.bytesDone = status.downloadedBytes

        let window = NSWindow(contentViewController: NSHostingController(rootView: Screen(model: self)))
        window.styleMask = [.titled]
        window.title = "Daemon"
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        while true {
            phase = .downloading
            let downloader = self.downloader
            let task = Task { [weak self] in
                try await downloader.download { p in Task { @MainActor in self?.progress = p } }
            }
            self.task = task
            do {
                try await task.value
                return
            } catch is CancellationError {
                phase = .paused
            } catch {
                let e = error as? LocalizedError
                phase = .failed(problem: e?.errorDescription ?? error.localizedDescription,
                                remedy: e?.recoverySuggestion ?? "Check your connection, then try again.")
            }
            await withCheckedContinuation { resume = $0 }
        }
    }

    private func pause() { task?.cancel() }

    private func resumeDownload() {
        resume?.resume()
        resume = nil
    }

    private struct Screen: View {
        @ObservedObject var model: FirstRunDownload
        var body: some View {
            ModelDownloadView(progress: model.progress, phase: model.phase,
                              onPause: { model.pause() }, onResume: { model.resumeDownload() })
        }
    }
}

/// Where the library lives. Settings can move it; the move happens at the next launch, before it opens.
enum LibraryLocation {
    private static let rootKey = "libraryRoot"
    private static let pendingKey = "pendingLibraryMove"

    static func prepare() throws -> URL {
        let defaults = UserDefaults.standard
        var root = defaults.string(forKey: rootKey).map(URL.init(fileURLWithPath:)) ?? Library.defaultRoot
        if let pending = defaults.string(forKey: pendingKey).map(URL.init(fileURLWithPath:)) {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: root, to: pending)
            }
            root = pending
            defaults.set(root.path, forKey: rootKey)
            defaults.removeObject(forKey: pendingKey)
        }
        return root
    }

    static func scheduleMove(to url: URL) {
        UserDefaults.standard.set(url.path, forKey: pendingKey)
    }
}
