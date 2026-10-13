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

    func testKeptToast() async throws {
        let model = ToastModel()
        let item = MockRecallDataSource.sampleHits(now: Date())[0].item
        model.state = .kept(item, nil)
        try await snapshot("3-keep-toast", ToastView(model: model))
        model.editingNote = true
        model.note = "Ask Dana"
        try await snapshot("3b-keep-toast-note", ToastView(model: model))
    }

    func testVoiceToast() async throws {
        let model = ToastModel()
        model.levels = Waveform.sample + Waveform.sample.prefix(4)
        model.state = .listening(Date().addingTimeInterval(-7))
        try await snapshot("4-voice-toast", ToastView(model: model))
        model.state = .message("Copied, press ⌘V")
        try await snapshot("4b-message-toast", ToastView(model: model))
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
