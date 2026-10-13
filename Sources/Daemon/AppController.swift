import AppKit
import Combine
import DaemonCapture
import DaemonCore
import DaemonUI
import KeyboardShortcuts
import SwiftUI
import os

/// Wires the modules together. Launch order: model download (first run only) -> engine + capture ->
/// onboarding (first run) or trial-ended notice.
@MainActor
final class AppController {
    private let stats = UsageStats()
    private let license = LicenseManager()
    private let updates = Updates()
    private let toasts = ToastPresenter()
    private let pasteBack = PasteBack()
    private let defaults = UserDefaults.standard

    private var engine: Engine!
    private var capture: CaptureCoordinator!
    private var recall: RecallPanelController!
    private var menuBar: MenuBarController!
    private var settings: SettingsWindowController?
    private var settingsModel: SettingsModel?
    private var onboarding: OnboardingWindowController?
    private var trialWindow: NSWindow?
    private var recentCache: [Item] = []
    private var retentionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    static let buyURL = URL(string: "https://mydaemon.app/buy")!   // placeholder until the domain is chosen

    func launch() {
        DebugSnapshots.startIfEnabled()
        let library: Library
        do {
            library = try Library(root: LibraryLocation.prepare())
        } catch {
            fail("Daemon couldn't open its library.", error)
            return
        }
        guard let embedderURL = EmbedderClient.bundledExecutableURL() else {
            fail("Daemon's model process is missing. Reinstall Daemon.", nil)
            return
        }
        let embedder = EmbedderClient(executableURL: embedderURL)
        engine = Engine(library: library, embedder: embedder, stats: stats)

        Task {
            // The model must be on disk before anything is processed, or new items would be marked failed.
            await FirstRunDownload().runIfNeeded()
            startUI()
            await engine.start()
            runRetention()
            _ = try? await embedder.stats()   // warm the model process so the first Recall is instant
        }
    }

    private func startUI() {
        Logger(subsystem: "app.mydaemon.Daemon", category: "permissions").notice(
            "accessibility=\(Permissions.accessibility, privacy: .public) screenRecording=\(Permissions.screenRecording, privacy: .public) microphone=\(Permissions.microphone.rawValue, privacy: .public)")
        menuBar = MenuBarController(
            onRecall: { [weak self] in self?.toggleRecall() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) },
            onDropFiles: { [weak self] urls in self?.capture.keep(files: urls) },
            recentItems: { [weak self] in self?.recentCache ?? [] },
            onOpenRecent: { [weak self] item in
                guard let self else { return }
                self.pasteBack.open(SearchHit(item: item, score: 0), fileURL: self.engine.fileURL(for: item))
            })

        capture = CaptureCoordinator(sink: LicenseGatedSink(engine: engine, license: license))
        capture.onRecall = { [weak self] in self?.toggleRecall() }
        capture.onVoiceStarted = { [weak self] _ in self?.toasts.showListening() }
        capture.onVoiceLevel = { [weak self] level in self?.toasts.updateLevel(level) }
        capture.onVoiceFinished = { [weak self] in self?.toasts.finishListening() }
        capture.onError = { [weak self] message in self?.toasts.showMessage(message) }
        capture.onKept = { [weak self] items in
            self?.showKept(items)
            self?.onboarding?.didKeep()
        }

        engine.onKeepClipboard = { [weak self] in self?.capture.keepClipboard() }
        engine.onCountsChanged = { [weak self] total, today in
            self?.menuBar.updateCounts(total: total, today: today)
            Task { [weak self] in self?.recentCache = (try? await self?.engine.recent(limit: 10).map(\.item)) ?? [] }
        }

        recall = RecallPanelController(dataSource: engine,
                                       actions: CountingActions(base: pasteBack, stats: stats),
                                       toasts: toasts)

        if !defaults.bool(forKey: "onboarded") {
            showOnboarding()

        } else if case .trialExpired = license.state {
            showTrialEnded()
        }
    }

    // MARK: Keep and Recall

    private func toggleRecall() {
        let opening = !recall.isVisible
        if opening { stats.record(.recall) }
        recall.toggle()
        if opening { onboarding?.didOpenRecall() }
    }

    private func showKept(_ items: [Item]) {
        guard let item = items.first else { return }
        menuBar.pulse()
        toasts.showKept(item: item, thumbnailURL: engine.thumbnailURL(for: item), count: items.count) { [weak self] note in
            Task { try? await self?.engine.setNote(note, for: item) }
        }
    }

    // MARK: Windows

    private func showOnboarding() {
        onboarding = OnboardingWindowController(
            isAccessibilityTrusted: { Permissions.accessibility },
            openAccessibilitySettings: { [weak self] in
                // First time: the system prompt adds Daemon to the list and offers its own "Open System Settings".
                // Doing both at once showed two things; later clicks just open the pane.
                if self?.defaults.bool(forKey: "askedAccessibility") == false {
                    self?.defaults.set(true, forKey: "askedAccessibility")
                    _ = Permissions.requestAccessibility()
                } else {
                    Permissions.openSettings(.accessibility)
                }
            },
            onFinish: { [weak self] in
                self?.defaults.set(true, forKey: "onboarded")
                self?.menuBar.showLivesHereHint()
                self?.onboarding = nil
            })
        onboarding?.show()
    }

    private func showTrialEnded() {
        let view = TrialEndedView(onBuy: { NSWorkspace.shared.open(Self.buyURL) },
                                  onEnterKey: { [weak self] in
                                      self?.trialWindow?.close()
                                      self?.showSettings()
                                  })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "Daemon"
        window.isReleasedWhenClosed = false
        window.center()
        trialWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        if settings == nil {
            let excluded = capture.excludedApps
            let model = SettingsModel(
                excludedApps: excluded.bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                checkForUpdates: updates.isAvailable ? updates.automaticallyChecks : defaults.object(forKey: "checkForUpdates") as? Bool ?? true,
                sendCrashReports: defaults.bool(forKey: "sendCrashReports"),
                storageLocation: engine.library.root,
                isFileVaultOn: FileVault.isOn() ?? true,
                retention: .load(from: defaults),
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                onMoveStorage: { [weak self] in self?.moveStorage() },
                onExport: { [weak self] in self?.exportLibrary() },
                stats: { [stats] in stats.summary() })
            model.license = license
            model.countRemoved = { [engine] policy in await engine!.library.count(before: policy.cutoff()) }
            model.onBuy = { NSWorkspace.shared.open(Self.buyURL) }

            model.$excludedApps.dropFirst().sink { urls in
                let kept = Set(urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
                for id in excluded.bundleIDs where !kept.contains(id) {
                    // Only installed apps are listed, so an ID without an app (a default) stays excluded.
                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { excluded.remove(id) }
                }
                kept.forEach(excluded.add)
            }.store(in: &cancellables)
            model.$checkForUpdates.dropFirst().sink { [weak self] on in
                self?.defaults.set(on, forKey: "checkForUpdates")
                self?.updates.automaticallyChecks = on
            }.store(in: &cancellables)
            // ponytail: preference only; v1 ships no crash reporter (PRD: opt-in, no item content)
            model.$sendCrashReports.dropFirst().sink { [weak self] on in
                self?.defaults.set(on, forKey: "sendCrashReports")
            }.store(in: &cancellables)

            model.$retention.dropFirst().sink { [weak self] policy in
                guard let self else { return }
                policy.save(to: self.defaults)
                self.runRetention()
            }.store(in: &cancellables)

            settingsModel = model
            settings = SettingsWindowController(keepShortcut: .keep, recallShortcut: .recall, model: model)
        }
        Task { [weak self] in await self?.refreshStorageInfo() }
        settings?.show()
    }

    private func refreshStorageInfo() async {
        guard let model = settingsModel else { return }
        model.librarySize = await engine.library.librarySize()
        model.oldestItemDate = await engine.library.oldestDate()
    }

    // MARK: Retention

    /// Purges now, then every hour. Called after the engine starts and whenever the setting changes.
    private func runRetention() {
        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.engine.applyRetention(.load(from: self.defaults))
                await self.refreshStorageInfo()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func moveStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        LibraryLocation.scheduleMove(to: folder.appendingPathComponent("Daemon Library"))
        settingsModel?.storageLocation = folder.appendingPathComponent("Daemon Library")
        toasts.showMessage("Daemon will move your library the next time it opens.")
    }

    private func exportLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let destination = folder.appendingPathComponent("Daemon Export \(Date().formatted(.iso8601.year().month().day()))")
        Task { [weak self] in
            do {
                try await self?.engine.library.export(to: destination)
                self?.toasts.showMessage("Exported everything to \(destination.lastPathComponent).")
            } catch {
                self?.toasts.showMessage("Couldn't export. Check there's space in that folder, then try again.")
            }
        }
    }

    private func fail(_ message: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error?.localizedDescription ?? ""
        alert.runModal()
        NSApp.terminate(nil)
    }
}

/// Keep is paused when the trial ends; Recall keeps working so nobody loses their things.
@MainActor
private final class LicenseGatedSink: CaptureSink {
    struct Paused: LocalizedError {
        var errorDescription: String? { "Your trial has ended. Buy Daemon to keep new things. Recall still works." }
    }
    let engine: Engine
    let license: LicenseManager
    init(engine: Engine, license: LicenseManager) { self.engine = engine; self.license = license }

    func keep(_ capture: Capture) async throws -> [Item] {
        guard license.state.canKeep else { throw Paused() }
        return try await engine.keep(capture)
    }
}

/// Counts recall successes (a result pasted, copied or opened) for "Copy my stats".
@MainActor
private final class CountingActions: RecallActions {
    let base: RecallActions
    let stats: UsageStats
    init(base: RecallActions, stats: UsageStats) { self.base = base; self.stats = stats }

    func paste(_ hit: SearchHit, fileURL: URL?) async -> Bool {
        stats.record(.recallSuccess)
        return await base.paste(hit, fileURL: fileURL)
    }
    func copy(_ hit: SearchHit, fileURL: URL?) { stats.record(.recallSuccess); base.copy(hit, fileURL: fileURL) }
    func open(_ hit: SearchHit, fileURL: URL?) { stats.record(.recallSuccess); base.open(hit, fileURL: fileURL) }
}
