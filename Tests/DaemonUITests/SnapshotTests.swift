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

    /// The toast as it looks once its entrance has finished (motion pinned at the start of a cycle).
    private func settled(_ model: ToastModel) -> some View {
        ToastView(model: model).environment(\.toastMotionPhase, 0)
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

        try await snapshot("toast-text", settled(toast(kept(text))))
        try await snapshot("toast-text-long", settled(toast(kept(long), progress: 0.8)))
        try await snapshot("toast-screenshot", settled(toast(kept(screenshot, thumbnail: shot))))
        try await snapshot("toast-screenshot-drawn", settled(toast(kept(screenshot))))
        try await snapshot("toast-link", settled(toast(kept(link))))
        try await snapshot("toast-voice-kept", settled(toast(kept(voice))))
        try await snapshot("toast-files-3", settled(toast(kept(files, count: 3))))
        try await snapshot("toast-pdf", settled(toast(kept(pdf))))
        try await snapshot("toast-note-empty", settled(toast(kept(text)) { $0.editingNote = true }))
        try await snapshot("toast-note", settled(toast(kept(text)) {
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
            try await snapshot("toast-voice-listening-\(name)", settled(model))
        }
        try await snapshot("toast-voice-keeping", settled(toast(.listening(start, ended: Date()))))
        try await snapshot("toast-message", settled(toast(.message("Copied, press ⌘V"))))
        try await snapshot("toast-error", settled(toast(.message(
            "Voice notes need the microphone. Turn it on in System Settings → Privacy & Security → Microphone."))))
    }

    // MARK: Toast motion — key frames with the phase pinned, as motion-*.png

    private func frames(_ phases: [Double], reduceMotion: Bool = false, _ make: @escaping () -> ToastModel) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(phases, id: \.self) { phase in
                HStack(spacing: 12) {
                    Text("\(Int(phase * 100))%").font(Theme.Font.small).foregroundStyle(Theme.textTertiary).frame(width: 34)
                    KeepCard(model: make())
                }
                .environment(\.toastMotionPhase, phase)
                .environment(\.toastReduceMotion, reduceMotion)
            }
        }
        .padding(16)
    }

    func testShimmerFrames() async throws {
        let phases = [0, 0.25, 0.5, 0.75]
        let start = Date().addingTimeInterval(-7)
        let keeping: [(String, () -> ToastModel)] = [
            ("text", { self.toast(.keeping(.text, KeepingSummary(kind: .text, sourceApp: "Notes", windowTitle: nil, url: nil))) }),
            ("image", { self.toast(.keeping(.image, KeepingSummary(kind: .image, sourceApp: "Figma", windowTitle: "Pricing", url: nil))) }),
            ("link", { self.toast(.keeping(.link, KeepingSummary(kind: .link, sourceApp: "Safari", windowTitle: "Pricing table component — Stripe Docs",
                                                                  url: "https://www.stripe.com/docs/billing"))) }),
            ("files", { self.toast(.keeping(.files, KeepingSummary(kind: .files, sourceApp: "Finder", windowTitle: nil, url: nil))) }),
            ("voice", { self.toast(.listening(start, ended: Date())) { model in
                let wave = (Waveform.sample + Waveform.sample + Waveform.sample + Waveform.sample).prefix(ToastModel.barCount)
                model.levels = wave.map { max(ToastModel.floor, $0 * 0.7) }
            } }),
        ]
        for (name, make) in keeping {
            try await snapshot("motion-shimmer-\(name)", frames(phases, make))
        }
        try await snapshot("motion-reduced-voice", frames(phases, reduceMotion: true, keeping[4].1))
        try await snapshot("motion-reduced-text", frames(phases, reduceMotion: true, keeping[0].1))
    }

    /// Before and after the morph: same card, the lead word, thumbnail and detail line change.
    func testMorphFrames() async throws {
        let shot = Self.outputDir.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "design/screenshots/onboarding-3-keys-kept.png")
        let pairs: [(String, ToastModel.State, ToastModel.State)] = [
            ("text", .keeping(.text, KeepingSummary(header: "Notes")),
             kept(Item(kind: .text, sourceApp: "Notes", text: "Annual discount badge on Pro only."))),
            ("screenshot", .keeping(.image, KeepingSummary(header: "Screenshot", detail: "Figma · Pricing")),
             kept(Item(kind: .screenshot, sourceApp: "Figma", windowTitle: "Pricing"), thumbnail: shot)),
            ("link", .keeping(.link, KeepingSummary(header: "stripe.com", detail: "Stripe Docs")),
             kept(Item(kind: .link, sourceApp: "Safari", url: "https://www.stripe.com/docs", text: "Stripe Docs"))),
        ]
        for (name, before, after) in pairs {
            let view = VStack(spacing: 10) {
                KeepCard(model: toast(before))
                KeepCard(model: toast(after, progress: 0))
            }
            .environment(\.toastMotionPhase, 0.3)
            .padding(16)
            try await snapshot("motion-morph-\(name)", view)
        }
    }

    /// The thumbnail lifting off the card and gliding into the menu bar mark, at fixed points of its flight.
    func testFlightFrames() async throws {
        let shot = Self.outputDir.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "design/screenshots/onboarding-3-keys-kept.png")
        let item = Item(kind: .screenshot, sourceApp: "Figma", windowTitle: "Pricing")
        let width: CGFloat = 620, bar: CGFloat = 24
        let mark = CGPoint(x: 250, y: bar / 2)
        let panel = CGPoint(x: width - Theme.Size.toast.width, y: bar)
        // The whole toast area flies (the card is the only thing drawn in it); centre of the panel.
        let start = CGPoint(x: panel.x + Theme.Size.toast.width / 2, y: panel.y + Theme.Size.toast.height / 2)
        for progress in [0, 0.4, 0.8, 1.0] {
            let model = toast(kept(item, thumbnail: shot), progress: 0.1)
            let landed = progress >= FlightPath.arrival
            let scene = ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.panelTop.opacity(0.92)).frame(width: width, height: bar)
                Image(nsImage: MenuBarController.markImage(color: landed ? Theme.accentNS : NSColor.labelColor))
                    .shadow(color: landed ? Theme.accent : .clear, radius: 3)
                    .position(mark)
                FlightView(thumb: settled(model), path: FlightPath(from: start, to: mark, endScale: 0.08), progress: progress)
            }
            .frame(width: width, height: bar + Theme.Size.toast.height, alignment: .topLeading)
            .background(Theme.window)
            try await snapshot("motion-flight-\(String(format: "%03d", Int(progress * 100)))", scene)
        }
    }

    func testMenuParts() async throws {
        let counts = MenuCounts()
        counts.total = 1284
        counts.today = 12
        let view = VStack(spacing: 8) {
            MenuHeader(counts: counts)
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
