import AppKit
import DaemonCore
import SwiftUI
import XCTest
@testable import DaemonUI

@MainActor
final class ModelDownloadViewTests: XCTestCase {
    private let midway = ModelDownloadProgress(fileName: "mmproj-embeddinggemma-2-Q8_0.gguf",
                                               fileBytesDone: 2_144_544, fileBytesTotal: 554_821_024,
                                               bytesDone: 312_000_000, bytesTotal: 864_676_480,
                                               bytesPerSecond: 4_500_000)

    func testCaption() {
        XCTAssertEqual(ModelDownloadView.caption(midway, .downloading), "312 MB of 865 MB · about 3 min left")
        XCTAssertEqual(ModelDownloadView.caption(midway, .paused), "312 MB of 865 MB · Paused")
        var unmeasured = midway
        unmeasured.bytesPerSecond = nil
        XCTAssertEqual(ModelDownloadView.caption(unmeasured, .downloading), "312 MB of 865 MB")
        XCTAssertEqual(ModelDownloadView.timeLeft(20), "less than a minute left")
        XCTAssertEqual(ModelDownloadView.timeLeft(3_900), "about 1 hr 5 min left")
    }

    /// Writes PNGs to .build/ui-snapshots/ for eyeballing; asserts only that rendering works.
    func testRenderSnapshots() throws {
        let failed = ModelDownloadError.network(.notConnectedToInternet)
        let states: [(String, ModelDownloadView.Phase)] = [
            ("downloading", .downloading),
            ("paused", .paused),
            ("failed", .failed(problem: failed.errorDescription!, remedy: failed.recoverySuggestion!)),
        ]
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../.build/ui-snapshots").standardized
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for (name, phase) in states {
            for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
                let view = ModelDownloadView(progress: midway, phase: phase, onPause: {}, onResume: {})
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                var png: Data?
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    png = renderer.nsImage
                        .flatMap { $0.tiffRepresentation }
                        .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                }
                let data = try XCTUnwrap(png)
                try data.write(to: out.appendingPathComponent("model-download-\(name)-\(scheme == .dark ? "smoked" : "ivory").png"))
            }
        }
    }
}
