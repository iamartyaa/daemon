import AppKit
import PDFKit
import XCTest
@testable import DaemonCore

/// PRD v1 use cases through the real pipeline: Library -> Extract -> DaemonEmbedder (llama.cpp) -> hybrid search.
/// Skips when the model files or the embedder binary aren't there.
@MainActor
final class EndToEndTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "DaemonEmbedder not built")
        let modelsReady = await ModelDownloader().status().isComplete
        try XCTSkipUnless(modelsReady, "model files not downloaded")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EndToEnd-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testUseCases() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DaemonEmbedder")
        let embedder = EmbedderClient(executableURL: binary)
        let engine = Engine(library: try Library(root: root.appendingPathComponent("lib")), embedder: embedder,
                            stats: UsageStats(defaults: UserDefaults(suiteName: "EndToEnd-\(UUID())")!))
        await engine.start()

        let safari = CaptureContext(sourceApp: "Safari", sourceBundleID: "com.apple.Safari")
        let figma = CaptureContext(sourceApp: "Figma", sourceBundleID: "com.figma.Desktop")
        let slack = CaptureContext(sourceApp: "Slack", sourceBundleID: "com.tinyspeck.slackmacgap")

        // 1 Developer: selected code fix on a web page
        let docker = try await engine.keep(Capture(payload: .text(
            "docker run --add-host=host.docker.internal:host-gateway lets a container reach services running on the host machine"),
            context: safari))[0]
        // 4/5 Designer: pricing reference
        let pricing = try await engine.keep(Capture(payload: .text(
            "Pricing page: default to yearly billing, show the monthly price small, annual discount badge on Pro"),
            context: figma))[0]
        // 2 Developer: region screenshot of a stack trace
        let trace = try await engine.keep(Capture(payload: .screenshot(try renderPNG(
            "java.lang.NullPointerException\n  at com.shop.CheckoutService.charge(Cart.java:88)\n  at com.shop.Api.pay")),
            context: slack))[0]
        // 9 Everyday: a warranty PDF kept from Finder
        let warranty = try await engine.keep(Capture(payload: .files([try makePDF(
            "Laptop warranty certificate. MacBook Pro, coverage two years from purchase, order 4471.")]),
            context: CaptureContext(sourceApp: "Finder", sourceBundleID: "com.apple.finder")))[0]

        await engine.waitUntilIdle()
        for item in [docker, pricing, trace, warranty] {
            let stored = await engine.library.item(id: item.id!)
            XCTAssertEqual(stored?.status, .ready, "\(item.kind) not processed")
        }

        try await assertTop("docker container can't reach host", is: docker, engine)
        try await assertTop("pricing toggle monthly yearly", is: pricing, engine)
        try await assertTop("NullPointerException checkout service", is: trace, engine)
        try await assertTop("laptop warranty", is: warranty, engine)
        // 10 filters: source and type
        let fromFigma = try await engine.search("from:figma")
        XCTAssertEqual(fromFigma.map(\.item.id), [pricing.id])
        let pdfs = try await engine.search("pdf warranty")
        XCTAssertEqual(pdfs.first?.item.id, warranty.id)
        XCTAssertEqual(pdfs.first?.matchedSegment?.page, 1)

        await embedder.shutdown()
    }

    private func assertTop(_ query: String, is expected: Item, _ engine: Engine,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let start = ContinuousClock.now
        let hits = try await engine.search(query)
        print("recall '\(query)' -> \(hits.prefix(3).map { $0.item.kind.rawValue }) in \(ContinuousClock.now - start)")
        XCTAssertEqual(hits.first?.item.id, expected.id, "'\(query)' ranked \(hits.map(\.item.kind))", file: file, line: line)
    }

    private func renderPNG(_ text: String) throws -> URL {
        let size = NSSize(width: 900, height: 220)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 20, y: 40),
                                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)])
        NSGraphicsContext.restoreGraphicsState()
        let url = root.appendingPathComponent("trace-\(UUID()).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func makePDF(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("warranty.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(in: CGRect(x: 72, y: 500, width: 468, height: 200),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
}
