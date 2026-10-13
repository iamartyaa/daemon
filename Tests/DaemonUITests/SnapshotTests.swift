import AppKit
import DaemonCore
import KeyboardShortcuts
import SwiftUI
import XCTest
@testable import DaemonUI

/// Renders the main views in Ivory (light) and Smoked (dark) to .build/ui-snapshots/ for side-by-side
/// comparison with design/screenshots. Uses NSHostingView in an offscreen window rather than ImageRenderer,
/// because ImageRenderer leaves AppKit-backed controls (text fields, scroll views, forms) blank.
@MainActor
final class SnapshotTests: XCTestCase {
    static let outputDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/ui-snapshots")

    private func snapshot<V: View>(_ name: String, _ view: V, settle: Duration = .milliseconds(150)) async throws {
        for (suffix, appearance) in [("ivory", NSAppearance.Name.aqua), ("smoked", .darkAqua)] {
            let host = NSHostingView(rootView: view.fixedSize())
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.backgroundColor = appearance == .aqua ? NSColor(hex: 0xDED7C8) : NSColor(hex: 0x1A1E24)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            try await Task.sleep(for: settle)
            host.layoutSubtreeIfNeeded()
            guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { return XCTFail("no bitmap for \(name)") }
            content.cacheDisplay(in: content.bounds, to: rep)
            window.orderOut(nil)
            try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
            let url = Self.outputDir.appending(path: "\(name)-\(suffix).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            XCTAssertGreaterThan(size.width, 0)
        }
    }

    private func recallModel(query: String?) async throws -> RecallViewModel {
        let model = RecallViewModel(dataSource: MockRecallDataSource(), actions: FakeActions(), debounce: .zero)
        model.previousAppName = "Linear"
        if let query { model.query = query } else { model.reset() }
        try await Task.sleep(for: .milliseconds(50))
        return model
    }

    func testRecallResults() async throws {
        let model = try await recallModel(query: "pricing toggle monthly yearly dark")
        try await snapshot("1-recall-results", RecallView(model: model).padding(24))
    }

    func testRecallEmpty() async throws {
        let model = try await recallModel(query: nil)
        try await snapshot("2-recall-recent", RecallView(model: model).padding(24))
    }

    func testRecallNothingKept() async throws {
        let data = MockRecallDataSource()
        data.recentHits = []
        let model = RecallViewModel(dataSource: data, actions: FakeActions())
        model.reset()
        try await Task.sleep(for: .milliseconds(50))
        try await snapshot("2b-recall-nothing-kept", RecallView(model: model).padding(24))
    }

    // MARK: Toasts — every state, Ivory and Smoked, as toast-*.png

    private func toast(_ state: ToastModel.State, progress: Double = 0.45, configure: (ToastModel) -> Void = { _ in })
        -> ToastModel {
        let model = ToastModel()
        model.state = state
        model.visible = true
        var countdown = Countdown(total: 1, start: Date().addingTimeInterval(-progress))
        countdown.pause(at: Date())
        model.countdown = countdown
        configure(model)
        return model
    }

    private func kept(_ item: Item, thumbnail: URL? = nil, count: Int = 1) -> ToastModel.State {
        .kept(item, thumbnail, count: count)
    }

    func testKeptToasts() async throws {
        let shot = Self.outputDir.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "design/screenshots/onboarding-3-keys-kept.png")
        let text = Item(kind: .text, sourceApp: "Notes", windowTitle: "Pricing",
                        text: "Annual discount badge on Pro only.\nMonthly stays the default.")
        let long = Item(kind: .text, sourceApp: "Slack", windowTitle: "#design",
                        text: "Can we hold the yearly toggle until the billing migration lands, otherwise the annual price shows twice in the receipt")
        let screenshot = Item(kind: .screenshot, sourceApp: "Figma", windowTitle: "Pricing — Monthly / Yearly toggle, dark")
        let link = Item(kind: .link, sourceApp: "Safari", url: "https://www.stripe.com/docs/billing/pricing-table",
                        text: "Pricing table component — Stripe Docs")
        let voice = Item(kind: .voice, text: "Default to yearly, show the monthly price struck through", durationMs: 7_000)
        let files = Item(kind: .file, sourceApp: "Finder", originalPath: "/Users/me/Desktop/Q3 roadmap.key")
        let pdf = Item(kind: .pdf, sourceApp: "Preview", originalPath: "/Users/me/Downloads/SaaS Pricing Playbook 2026 final.pdf")

        try await snapshot("toast-text", ToastView(model: toast(kept(text))))
        try await snapshot("toast-text-long", ToastView(model: toast(kept(long), progress: 0.8)))
        try await snapshot("toast-screenshot", ToastView(model: toast(kept(screenshot, thumbnail: shot))))
        try await snapshot("toast-screenshot-drawn", ToastView(model: toast(kept(screenshot))))
        try await snapshot("toast-link", ToastView(model: toast(kept(link))))
        try await snapshot("toast-voice-kept", ToastView(model: toast(kept(voice))))
        try await snapshot("toast-files-3", ToastView(model: toast(kept(files, count: 3))))
        try await snapshot("toast-pdf", ToastView(model: toast(kept(pdf))))
        try await snapshot("toast-note-empty", ToastView(model: toast(kept(text)) { $0.editingNote = true }))
        try await snapshot("toast-note", ToastView(model: toast(kept(text)) {
            $0.editingNote = true
            $0.note = "Ask Dana before Thursday"
        }))
    }

    func testVoiceAndNoticeToasts() async throws {
        let start = Date().addingTimeInterval(-7)
        for (name, scale) in [("quiet", Float(0.25)), ("speaking", 0.7), ("loud", 1.0)] {
            let model = toast(.listening(start, ended: nil)) { model in
                let wave = (Waveform.sample + Waveform.sample + Waveform.sample + Waveform.sample).prefix(ToastModel.barCount)
                model.levels = wave.map { max(ToastModel.floor, $0 * scale) }
            }
            try await snapshot("toast-voice-listening-\(name)", ToastView(model: model))
        }
        try await snapshot("toast-voice-keeping", ToastView(model: toast(.listening(start, ended: Date()))))
        try await snapshot("toast-message", ToastView(model: toast(.message("Copied, press ⌘V"))))
        try await snapshot("toast-error", ToastView(model: toast(.message(
            "Voice notes need the microphone. Turn it on in System Settings → Privacy & Security → Microphone."))))
    }

    func testMenuParts() async throws {
        let counts = MenuCounts()
        counts.total = 1284
        counts.today = 12
        let view = VStack(spacing: 8) {
            MenuHeader(counts: counts)
            MenuFooter(version: "1.2")
            LivesHereHint()
            HStack(spacing: 20) {
                Image(nsImage: MenuBarController.markImage(color: nil))
                Image(nsImage: MenuBarController.markImage(color: Theme.accentNS))
            }
        }
        .padding(12)
        .background(Theme.panelBottom)
        try await snapshot("5-menu", view)
    }

    func testOnboarding() async throws {
        for step in OnboardingModel.Step.allCases {
            try await snapshot("6-onboarding-\(step.rawValue + 1)-\(step)", OnboardingView(model: OnboardingModel(step: step)))
        }
    }

    func testSettings() async throws {
        let model = SettingsModel(excludedApps: [URL(filePath: "/System/Applications/Notes.app")],
                                  storageLocation: URL(filePath: "/Users/me/Library/Application Support/Daemon"),
                                  librarySize: 2_480_000_000, isFileVaultOn: false, version: "1.2")
        let view = SettingsView(keepShortcut: .init("snapshotKeep"),
                                recallShortcut: .init("snapshotRecall"),
                                model: model)
        try await snapshot("7-settings", view)
    }
}
