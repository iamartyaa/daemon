import AppKit
import DaemonCore
import SwiftUI
import XCTest
@testable import DaemonUI

/// The Core Animation layers behind the toast's motion, hosted off screen at -10000,-10000.
@MainActor
final class ToastLayerTests: XCTestCase {
    private func host<V: View>(_ view: V, dark: Bool = false) -> NSWindow {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        return window
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }

    /// Writes the window's layers, with the band held mid-sweep, to .build/ui-snapshots for a look.
    private func render(_ window: NSWindow, _ name: String) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                                 pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.scaleBy(x: 2, y: 2)
        if view.isFlipped {   // SwiftUI's host is top-down; the bitmap is bottom-up
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        view.layer?.render(in: context)
        try FileManager.default.createDirectory(at: SnapshotTests.outputDir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: SnapshotTests.outputDir.appending(path: "\(name).png"))
        return rep
    }

    func testShimmerIsOneRepeatingLayerAnimationMaskedByTheView() async throws {
        // Left: the snapshot frame SwiftUI draws at mid-sweep. Right: the live layer, held at the same point.
        let window = host(HStack {
            HintThumb(kind: .image).keepingShimmer(true).environment(\.toastMotionPhase, Shimmer.sweepShare / 2)
            HintThumb(kind: .image).keepingShimmer(true)
        }.scaleEffect(3).frame(width: 300, height: 140), dark: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let band = try XCTUnwrap(find(ShimmerBandView.self, in: window.contentView!).first, "live shimmer is a layer view")
        let gradient = try XCTUnwrap(band.layer?.sublayers?.first as? CAGradientLayer)
        let sweep = try XCTUnwrap(gradient.animation(forKey: "sweep") as? CAKeyframeAnimation)
        XCTAssertEqual(sweep.repeatCount, .infinity)
        XCTAssertEqual(sweep.duration, Theme.Motion.shimmerCycle)
        XCTAssertNotNil(band.layer?.mask?.contents, "masked by the thumbnail's own shape")

        // Hold the band mid-sweep and look: light over the tile, nothing outside it.
        gradient.removeAllAnimations()
        gradient.position.x = Shimmer.bandCenter(0.5, viewWidth: band.bounds.width)
        _ = try render(window, "toast-shimmer-layer-smoked")

        // Tinted, over type: the band relights the letters and nothing between them.
        let text = host(VStack(alignment: .leading) {
            Text("stripe.com docs").foregroundStyle(.blue)   // reference, drawn by SwiftUI
            Text("stripe.com docs").keepingShimmer(true, tint: .red)
        }.font(.system(size: 30)).padding(10), dark: true)
        defer { text.close() }
        try await Task.sleep(for: .milliseconds(200))
        let textBand = try XCTUnwrap(find(ShimmerBandView.self, in: text.contentView!).first)
        let textGradient = try XCTUnwrap(textBand.layer?.sublayers?.first as? CAGradientLayer)
        textGradient.removeAllAnimations()
        textGradient.position.x = Shimmer.bandCenter(0.5, viewWidth: textBand.bounds.width)
        _ = try render(text, "toast-shimmer-layer-text-smoked")
    }

    func testShimmerStopsWhenKeepingEnds() async throws {
        let model = ToastModel()
        model.state = .keeping(.text, KeepingSummary(header: "Notes"))
        model.visible = true
        let window = host(ToastView(model: model))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(find(ShimmerBandView.self, in: window.contentView!).isEmpty)
        model.state = .kept(Item(kind: .text, sourceApp: "Notes", text: "hi"), nil, count: 1)
        model.countdown = Countdown(total: 1.5)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(find(ShimmerBandView.self, in: window.contentView!).isEmpty, "Kept removes the shimmer layer")
        let line = try XCTUnwrap(find(ProgressLayerView.self, in: window.contentView!).first, "Kept counts down with a layer")
        XCTAssertNotNil(line.layer?.sublayers?.first?.animation(forKey: "progress"))
    }

    func testLiveLevelGoesStraightToTheLayer() async throws {
        let model = ToastModel()
        model.state = .listening(Date(), ended: nil)
        model.visible = true
        let window = host(ToastView(model: model))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let meter = try XCTUnwrap(find(LevelMeterView.self, in: window.contentView!).first, "recording draws a layer")
        let bars = try XCTUnwrap(meter.layer?.sublayers?.first as? CAShapeLayer)
        let quiet = try XCTUnwrap(bars.path?.boundingBox)
        model.levels = model.levels.dropFirst() + [1]
        XCTAssertGreaterThan(try XCTUnwrap(bars.path?.boundingBox).height, quiet.height, "the newest bar grows at once")
        model.levels = (0..<ToastModel.barCount).map { Float(0.2 + 0.6 * abs(sin(Double($0) / 3))) }
        bars.removeAllAnimations()
        _ = try render(window, "toast-level-layer-ivory")
        XCTAssertFalse(find(PulsingDotView.self, in: window.contentView!).isEmpty, "the recording dot breathes in a layer")
    }

    func testFlightIsKeyframedFromThePath() {
        let path = FlightPath(from: CGPoint(x: 500, y: 90), to: CGPoint(x: 100, y: 20))
        let group = path.animation(height: 200, duration: Theme.Motion.flight)
        XCTAssertEqual(group.duration, Theme.Motion.flight)
        let position = group.animations?.first { ($0 as? CAKeyframeAnimation)?.keyPath == "position" } as? CAKeyframeAnimation
        let points = (position?.values as? [NSValue])?.map(\.pointValue) ?? []
        XCTAssertEqual(points.first?.x ?? 0, 500, accuracy: 1e-6)
        XCTAssertEqual(points.first?.y ?? 0, 110, accuracy: 1e-6, "flipped into the layer's bottom-left space")
        XCTAssertEqual(points.last?.x ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(points.last?.y ?? 0, 180, accuracy: 1e-6)
    }
}
