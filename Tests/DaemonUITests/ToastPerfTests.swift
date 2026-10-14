import AppKit
import DaemonCore
import XCTest
@testable import DaemonUI

/// What a keep's toast costs the app: CPU while Keeping shimmers, and over a whole keep (Keeping, the morph,
/// the flight, the countdown, the exit). Off screen at -10000,-10000, so nothing shows.
/// Opt in with DAEMON_BENCH=1: while Kept is up the presenter listens for Tab system-wide.
@MainActor
final class ToastPerfTests: XCTestCase {
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    private func presenter() -> ToastPresenter {
        let toasts = ToastPresenter()
        toasts.origin = NSPoint(x: -10_000, y: -10_000)
        toasts.flightTarget = { NSRect(x: -9_900, y: -9_800, width: 22, height: 22) }
        return toasts
    }

    private func keep(_ toasts: ToastPresenter) async throws {
        toasts.showKeeping(kind: .text, sourceApp: "Notes")
        try await Task.sleep(for: .milliseconds(150))   // reading the selection and Library.add
        toasts.showKept(item: Item(kind: .text, sourceApp: "Notes", text: "Annual badge on Pro"), thumbnailURL: nil) { _ in }
        while toasts.model.visible || toasts.model.state.isKeeping { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))    // exit and flight window teardown
    }

    func testKeepToastCPU() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAEMON_BENCH"] != nil, "benchmark; set DAEMON_BENCH=1")
        let idle0 = cpuSeconds(), idleT = Date()
        try await Task.sleep(for: .seconds(1))
        print(String(format: "[bench] idle test process: %.1f%% of a core", (cpuSeconds() - idle0) / Date().timeIntervalSince(idleT) * 100))

        let toasts = presenter()
        try await keep(toasts)   // first keep builds the view graph and loads fonts

        var shares: [Double] = []
        for _ in 0..<3 {
            let c0 = cpuSeconds(), t0 = Date()
            try await keep(toasts)
            let wall = Date().timeIntervalSince(t0)
            shares.append((cpuSeconds() - c0) / wall)
            print(String(format: "[bench] keep toast: %.2f s wall, %.1f%% of a core", wall, shares.last! * 100))
        }

        // Where in a keep the time goes, 100 ms at a time.
        var timeline: [String] = []
        var last = cpuSeconds()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let now = cpuSeconds()
                timeline.append(String(format: "%.0f", (now - last) * 1000))
                last = now
            }
        }
        try await keep(toasts)
        sampler.cancel()
        print("[bench] CPU ms per 100 ms through a keep: \(timeline.joined(separator: " "))")

        // Keeping alone, as when a link or a long selection takes a while.
        toasts.showKeeping(kind: .text, sourceApp: "Notes")
        try await Task.sleep(for: .milliseconds(300))
        let c0 = cpuSeconds(), t0 = Date()
        try await Task.sleep(for: .seconds(2))
        let keeping = (cpuSeconds() - c0) / Date().timeIntervalSince(t0)
        print(String(format: "[bench] Keeping shimmer: %.1f%% of a core", keeping * 100))
        toasts.showMessage("done")

        // Holding for a voice note: the live level arrives 20 times a second.
        toasts.showListening()
        try await Task.sleep(for: .milliseconds(300))
        let v0 = cpuSeconds(), vt = Date()
        for i in 0..<40 {
            toasts.updateLevel(Float(0.2 + 0.6 * abs(sin(Double(i) / 3))))
            try await Task.sleep(for: .milliseconds(50))
        }
        print(String(format: "[bench] Listening: %.1f%% of a core", (cpuSeconds() - v0) / Date().timeIntervalSince(vt) * 100))
        toasts.finishListening()
        try await Task.sleep(for: .milliseconds(300))
        let f0 = cpuSeconds(), ft = Date()
        try await Task.sleep(for: .seconds(1))
        print(String(format: "[bench] voice Keeping (frozen waveform shimmer): %.1f%% of a core", (cpuSeconds() - f0) / Date().timeIntervalSince(ft) * 100))
        toasts.showMessage("done")

        // Showing Keeping is on the hotkey path: it must return within a frame, the first time too.
        try await Task.sleep(for: .seconds(2.5))
        for warm in [false, true] {
            let fresh = presenter()
            if warm { fresh.prewarm() }
            let t = Date()
            fresh.showKeeping(kind: .text, sourceApp: "Notes")
            print(String(format: "[bench] first showKeeping, %@: %.1f ms", warm ? "prewarmed" : "cold", Date().timeIntervalSince(t) * 1000))
            fresh.showMessage("x")
        }
        try await Task.sleep(for: .seconds(2.5))
        var calls: [Double] = []
        for _ in 0..<5 {
            let t = Date()
            toasts.showKeeping(kind: .image, sourceApp: "Figma", windowTitle: "Pricing")
            calls.append(Date().timeIntervalSince(t) * 1000)
            toasts.showMessage("x")
            try await Task.sleep(for: .seconds(2.3))
        }
        print("[bench] showKeeping call: \(calls.map { String(format: "%.1f", $0) }.joined(separator: ", ")) ms")
    }
    /// Main-thread stalls through a screenshot keep (Keeping, the thumbnail, the morph, the flight). Target: none over 8 ms.
    func testScreenshotKeepMainThread() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAEMON_BENCH"] != nil, "benchmark; set DAEMON_BENCH=1")
        let toasts = presenter()
        toasts.prewarm()   // as launch does
        try await keep(toasts)
        // The longest the main thread is busy at once during a keep of a screenshot (thumbnail, morph, flight).
        let thumb = FileManager.default.temporaryDirectory.appendingPathComponent("toast-bench-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: thumb) }
        let design = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "design/screenshots/screens-ivory.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(design as CFURL, nil))
        let small = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary))
        let jpeg = try XCTUnwrap(CGImageDestinationCreateWithURL(thumb as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(jpeg, small, nil)
        CGImageDestinationFinalize(jpeg)
        var gaps: [(at: Double, ms: Double)] = [], previous = CACurrentMediaTime(), began = previous
        let ticker = Timer(timeInterval: 0.001, repeats: true) { _ in
            let now = CACurrentMediaTime()
            if now - previous > 0.004 { gaps.append(((previous - began) * 1000, (now - previous) * 1000)) }
            previous = now
        }
        RunLoop.main.add(ticker, forMode: .common)
        defer { ticker.invalidate() }
        for _ in 0..<3 {
            gaps = []
            began = CACurrentMediaTime()
            toasts.showKeeping(kind: .image, sourceApp: "Figma", windowTitle: "Pricing")
            try await Task.sleep(for: .milliseconds(150))
            toasts.showKept(item: Item(kind: .screenshot, sourceApp: "Figma", windowTitle: "Pricing"), thumbnailURL: thumb) { _ in }
            while toasts.model.visible || toasts.model.state.isKeeping { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(400))
            let worst = gaps.sorted { $0.ms > $1.ms }.prefix(4)
            print("[bench] main-thread stalls over 4 ms in a screenshot keep (at ms: long ms): "
                  + worst.map { String(format: "%.0f: %.1f", $0.at, $0.ms) }.joined(separator: ", "))
        }
    }
}

