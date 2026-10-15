import AppKit
import DaemonCore
import SwiftUI
import XCTest
@testable import DaemonUI

@MainActor
final class AppearanceTests: XCTestCase {
    private var saved: NSAppearance?

    override func setUp() { saved = NSApplication.shared.appearance }
    override func tearDown() { NSApplication.shared.appearance = saved }

    func testPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppearanceTests-\(UUID().uuidString)"))
        XCTAssertEqual(Appearance.load(from: defaults), .system)   // default
        for appearance in Appearance.allCases {
            appearance.save(to: defaults)
            XCTAssertEqual(defaults.string(forKey: "appearance"), appearance.rawValue)
            XCTAssertEqual(Appearance.load(from: defaults), appearance)
        }
        defaults.set("neon", forKey: "appearance")
        XCTAssertEqual(Appearance.load(from: defaults), .system)
    }

    /// An open window (no appearance of its own) follows each change without being recreated.
    func testApplySetsAppAppearanceAndWindowsFollowLive() async throws {
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 10, height: 10),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func windowMatch() async throws -> NSAppearance.Name? {
            try await Task.sleep(for: .milliseconds(50))   // AppKit propagates effectiveAppearance on the next pass
            return window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        }
        Appearance.smoked.apply()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        let dark = try await windowMatch()
        XCTAssertEqual(dark, .darkAqua)
        Appearance.ivory.apply()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        let light = try await windowMatch()
        XCTAssertEqual(light, .aqua)
        Appearance.system.apply()
        XCTAssertNil(NSApplication.shared.appearance)
    }

    func testThemeResolvesToIvoryAndSmoked() {
        let cases: [(Appearance, window: UInt32, accent: UInt32)] = [(.ivory, 0xF4ECDE, 0x7A1F2B), (.smoked, 0x262B33, 0x7FB8E8)]
        for (appearance, window, accent) in cases {
            appearance.apply()
            XCTAssertEqual(hex(Theme.windowNS), window, appearance.title)
            XCTAssertEqual(hex(Theme.accentNS), accent, appearance.title)
        }
    }

    func testSettingsModelCarriesAppearance() {
        let model = SettingsModel(appearance: .smoked, storageLocation: URL(filePath: "/tmp"), version: "1")
        XCTAssertEqual(model.appearance, .smoked)
        XCTAssertFalse(model.updatesAvailable)   // the update toggle stays hidden until Sparkle is configured
        XCTAssertEqual(Appearance.allCases.map(\.title), ["System", "Ivory", "Smoked"])
    }

    private func hex(_ color: NSColor) -> UInt32 {
        var value: UInt32 = 0
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            value = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8
                | UInt32((c.blueComponent * 255).rounded())
        }
        return value
    }
}

/// Before/after renders for the declutter pass, to .build/ui-snapshots/declutter-after-*.png. Appearance goes
/// through `Appearance.apply()` (NSApplication.shared.appearance), the same path the app uses. Offscreen windows only.
@MainActor
final class DeclutterSnapshotTests: XCTestCase {
    private var saved: NSAppearance?
    override func setUp() { saved = NSApplication.shared.appearance }
    override func tearDown() { NSApplication.shared.appearance = saved }

    private func render<V: View>(_ name: String, _ view: V, settle: Duration = .milliseconds(200)) async throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/ui-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for appearance in [Appearance.ivory, .smoked] {
            appearance.apply()
            let host = NSHostingView(rootView: view.fixedSize().background(Theme.window))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.backgroundColor = Theme.windowNS
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            try await Task.sleep(for: settle)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appending(path: "declutter-after-\(name)-\(appearance.rawValue).png"))
        }
    }

    func testSettings() async throws {
        let model = SettingsModel(excludedApps: [URL(filePath: "/System/Applications/Notes.app")],
                                  storageLocation: URL(filePath: "/Users/me/Library/Application Support/Daemon"),
                                  librarySize: 2_480_000_000, isFileVaultOn: false,
                                  oldestItemDate: Date().addingTimeInterval(-23 * 86_400), version: "1.2")
        let view = SettingsView(keepShortcut: .init("snapshotKeep"), recallShortcut: .init("snapshotRecall"),
                                model: model, height: 1200)
        try await render("settings", view)
    }

    func testMenuHeader() async throws {
        let counts = MenuCounts()
        counts.total = 1284
        counts.today = 12
        try await render("menu-header", MenuHeader(counts: counts).background(Theme.panelBottom))
    }

    func testOnboarding() async throws {
        let cases: [(String, OnboardingModel.Step, Bool, Bool)] = OnboardingModel.Step.allCases
            .map { ("\($0.rawValue + 1)-\($0)", $0, false, false) }
            + [("5b-practice-trusted", .practice, true, false), ("5c-practice-kept", .practice, true, true)]
        for (name, step, trusted, kept) in cases {
            let model = OnboardingModel(step: step, isTrusted: { trusted })
            model.stop()
            if kept { model.didKeep() }
            try await render("onboarding-\(name)", OnboardingView(model: model), settle: .milliseconds(900))
        }
    }

    func testModelDownload() async throws {
        let progress = ModelDownloadProgress(fileName: "model.gguf", fileBytesDone: 0, fileBytesTotal: 1,
                                             bytesDone: 312_000_000, bytesTotal: 864_676_480, bytesPerSecond: 4_500_000)
        try await render("model-download", ModelDownloadView(progress: progress, phase: .downloading, onPause: {}, onResume: {}))
    }
}
