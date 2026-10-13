import AppKit
import SwiftUI
import XCTest
@testable import DaemonUI

@MainActor
final class OnboardingTests: XCTestCase {
    private var trusted = false
    private var finished = 0

    private func model(_ step: OnboardingModel.Step = .welcome) -> OnboardingModel {
        OnboardingModel(step: step, isTrusted: { [unowned self] in self.trusted },
                        onFinish: { [unowned self] in self.finished += 1 },
                        pollInterval: .milliseconds(10), trustedHold: .milliseconds(10))
    }

    func testAdvanceAndBack() {
        let m = model()
        XCTAssertFalse(m.canGoBack)
        m.advance()
        XCTAssertEqual(m.step, .keep)
        XCTAssertTrue(m.forward)
        m.advance()
        m.advance()
        XCTAssertEqual(m.step, .accessibility)
        m.back()
        XCTAssertEqual(m.step, .recall)
        XCTAssertFalse(m.forward)
    }

    func testArrowsOnlyPageTheExplainers() {
        let m = model()
        XCTAssertFalse(m.arrowBack())
        XCTAssertTrue(m.arrowForward())
        XCTAssertTrue(m.arrowForward())
        XCTAssertTrue(m.arrowForward())
        XCTAssertEqual(m.step, .accessibility)
        XCTAssertFalse(m.arrowForward(), "Accessibility wants a deliberate choice")
        XCTAssertTrue(m.arrowBack())
        XCTAssertEqual(m.step, .recall)
    }

    func testAccessibilityAdvancesOnceTrusted() async throws {
        let m = model(.recall)
        var broughtFront = false
        m.onTrusted = { broughtFront = true }
        m.advance()
        XCTAssertEqual(m.step, .accessibility)
        XCTAssertFalse(m.trusted)
        trusted = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(m.trusted)
        XCTAssertEqual(m.step, .practice)
        XCTAssertTrue(broughtFront)
    }

    func testTrustedSkipsAccessibilityBothWays() {
        trusted = true
        let m = model(.recall)
        m.advance()
        XCTAssertEqual(m.step, .practice)
        m.back()
        XCTAssertEqual(m.step, .recall)
    }

    func testNotNowLeavesAccessibilityUntrusted() {
        let m = model(.accessibility)
        m.advance()
        XCTAssertEqual(m.step, .practice)
        XCTAssertFalse(m.trusted)
    }

    func testPracticeReactsToKeepThenRecall() {
        let m = model(.practice)
        m.didOpenRecall()
        XCTAssertEqual(m.step, .practice, "Recall before a keep doesn't count")
        m.didKeep()
        XCTAssertTrue(m.kept)
        m.didOpenRecall()
        XCTAssertEqual(m.step, .done)
        m.advance()
        XCTAssertEqual(finished, 1)
    }

    func testKeepsOutsidePracticeAreIgnored() {
        let m = model(.keep)
        m.didKeep()
        m.didOpenRecall()
        XCTAssertFalse(m.kept)
        XCTAssertEqual(m.step, .keep)
    }

    func testSkipPracticeAndPracticeResetsOnReturn() {
        let m = model(.practice)
        m.didKeep()
        m.back()
        m.advance()   // Not now, back to practice
        XCTAssertEqual(m.step, .practice)
        XCTAssertFalse(m.kept)
        m.advance()   // Skip
        XCTAssertEqual(m.step, .done)
    }

    func testMissingVideosFallBack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(OnboardingVideo.url("keep-text", dark: false, in: [dir]))
        try Data().write(to: dir.appending(path: "keep-text-smoked.mp4"))
        XCTAssertNil(OnboardingVideo.url("keep-text", dark: false, in: [dir]))
        XCTAssertEqual(OnboardingVideo.url("keep-text", dark: true, in: [dir])?.lastPathComponent, "keep-text-smoked.mp4")
        XCTAssertNil(OnboardingVideo.url("no-such-clip", dark: true))
        XCTAssertFalse(OnboardingVideo.exists("no-such-clip"))
    }

    /// Every step in Ivory and Smoked, after the entrance has settled, to .build/ui-snapshots/onboarding-*.png,
    /// plus the drawings that stand in for the Keep videos.
    func testSnapshots() async throws {
        // (name, trusted, step, kept)
        let cases = OnboardingModel.Step.allCases.map { ("\($0.rawValue + 1)-\($0)", false, $0, false) }
            + [("4b-accessibility-on", true, .accessibility, false), ("5b-practice-kept", true, .practice, true)]
        for (name, isTrusted, step, kept) in cases {
            trusted = isTrusted
            let m = model(step)
            m.stop()   // no auto-advance while rendering
            if kept { m.didKeep() }
            try await render(OnboardingView(model: m), size: Theme.Onboarding.window, name: name)
        }
        for clip in KeepStep.clips.map(\.0) {
            let media = Theme.Onboarding.media
            try await render(ExplainerVideo(name: clip).frame(width: media.width, height: media.height).padding(20),
                             size: media, name: "clip-\(clip)")
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let outputDir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/ui-snapshots")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for (suffix, appearance) in [("ivory", NSAppearance.Name.aqua), ("smoked", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Theme.window))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize == .zero ? size : host.fittingSize),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(900))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: outputDir.appending(path: "onboarding-\(name)-\(suffix).png"))
        }
    }
}
