import AppKit
import DaemonCore
import XCTest
@testable import DaemonCapture

final class ContextRulesTests: XCTestCase {
    let safari = "com.apple.Safari"
    let finder = "com.apple.finder"
    let file = URL(fileURLWithPath: "/tmp/a.pdf")
    let page = URL(string: "https://example.com")!

    func testEachRule() {
        XCTAssertEqual(ContextRules.decide(.init(heldPastThreshold: true, frontmostBundleID: "com.apple.TextEdit")), .voice)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: "com.apple.TextEdit", selectedText: "hello")), .text)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: finder, finderSelection: [file])), .files)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: safari, pageURL: page)), .link)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: "com.apple.TextEdit")), .region)
        XCTAssertEqual(ContextRules.decide(.init()), .region)
    }

    func testFirstMatchWins() {
        let everything = ContextSnapshot(heldPastThreshold: true, frontmostBundleID: safari, selectedText: "hi", pageURL: page)
        XCTAssertEqual(ContextRules.decide(everything), .voice)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: safari, selectedText: "hi", pageURL: page)), .text)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: finder, selectedText: "name.txt", finderSelection: [file])), .text)
    }

    func testExcludedAppIgnoresEverything() {
        let snapshot = ContextSnapshot(heldPastThreshold: true, isExcluded: true, frontmostBundleID: safari,
                                       selectedText: "secret", pageURL: page)
        XCTAssertEqual(ContextRules.decide(snapshot), .ignore)
    }

    func testEdgeCases() {
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: "com.apple.TextEdit", selectedText: " \n\t")), .region)
        // Files only count when Finder is in front.
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: "com.apple.TextEdit", finderSelection: [file])), .region)
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: finder)), .region)
        // Firefox is a browser, but without a readable URL it falls back to region.
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: "org.mozilla.firefox")), .region)
        // A URL from a non-browser doesn't make a link.
        XCTAssertEqual(ContextRules.decide(.init(frontmostBundleID: "com.apple.TextEdit", pageURL: page)), .region)
    }

    func testBrowserDetection() {
        for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                   "com.microsoft.edgemac", "org.mozilla.firefox", "com.kagi.kagimacOS"] {
            XCTAssertNotNil(Browser(bundleID: id), id)
        }
        XCTAssertNil(Browser(bundleID: "com.apple.finder"))
        XCTAssertNil(Browser(bundleID: nil))
        XCTAssertEqual(Browser(bundleID: "com.apple.Safari"), .safariLike)
        XCTAssertEqual(Browser(bundleID: "company.thebrowser.Browser"), .chromium)
        XCTAssertNil(Browser.firefox.pageScript(bundleID: "org.mozilla.firefox"))
        XCTAssertEqual(Browser.chromium.pageScript(bundleID: "com.google.Chrome"),
                       "tell application id \"com.google.Chrome\" to return {URL, title} of active tab of front window")
        XCTAssertTrue(Browser.safariLike.accessibilitySelectionIsReliable)
        XCTAssertFalse(Browser.chromium.accessibilitySelectionIsReliable)
    }
}

final class ExcludedAppsTests: XCTestCase {
    var suiteName = ""
    var store: UserDefaults!

    override func setUp() {
        suiteName = "DaemonCaptureTests-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() { store.removePersistentDomain(forName: suiteName) }

    func testDefaultsAndPersistence() {
        let apps = ExcludedApps(store: store)
        XCTAssertTrue(apps.contains("com.1password.1password"))
        XCTAssertTrue(apps.contains("com.bitwarden.desktop"))
        XCTAssertTrue(apps.contains("com.apple.keychainaccess"))
        XCTAssertFalse(apps.contains("com.apple.Safari"))
        XCTAssertFalse(apps.contains(nil))

        apps.add("com.example.vault")
        apps.add("com.example.vault")
        apps.remove("com.bitwarden.desktop")

        let reloaded = ExcludedApps(store: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(reloaded.contains("com.example.vault"))
        XCTAssertFalse(reloaded.contains("com.bitwarden.desktop"))
        XCTAssertEqual(reloaded.bundleIDs.filter { $0 == "com.example.vault" }.count, 1)
    }
}

final class PasteboardTests: XCTestCase {
    var pasteboard: NSPasteboard!
    var dir: URL!

    override func setUp() {
        pasteboard = NSPasteboard(name: .init("DaemonCaptureTests-\(UUID().uuidString)"))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    func makePNG() throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func hit(_ kind: ItemKind, text: String? = nil, url: String? = nil) -> SearchHit {
        SearchHit(item: Item(id: 1, kind: kind, url: url, text: text), score: 1)
    }

    func testSnapshotRestoresEveryItemAndType() throws {
        let png = try makePNG()
        let rich = NSPasteboardItem()
        rich.setString("hello", forType: .string)
        rich.setData(Data("{\\rtf1 hello}".utf8), forType: .rtf)
        let image = NSPasteboardItem()
        image.setData(png, forType: .png)
        let file = NSPasteboardItem()
        file.setString(URL(fileURLWithPath: "/tmp/x.txt").absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([rich, image, file])

        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        snapshot.restore(to: pasteboard)

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].string(forType: .string), "hello")
        XCTAssertEqual(items[0].data(forType: .rtf), Data("{\\rtf1 hello}".utf8))
        XCTAssertEqual(items[1].data(forType: .png), png)
        XCTAssertEqual(items[2].string(forType: .fileURL), "file:///tmp/x.txt")
        XCTAssertEqual(items.map(\.types), snapshot.items.map { $0.map(\.type) })
    }

    func testSnapshotOfEmptyPasteboardRestoresEmpty() {
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.setString("temp", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testWriteTextHit() {
        XCTAssertTrue(Clipboard.write(hit(.text, text: "kept words"), fileURL: nil, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "kept words")
        XCTAssertFalse(Clipboard.write(hit(.text), fileURL: nil, to: pasteboard))
    }

    func testWriteLinkHit() {
        Clipboard.write(hit(.link, text: "Example", url: "https://example.com/a"), fileURL: nil, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://example.com/a")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/a")
        XCTAssertEqual(pasteboard.string(forType: Clipboard.urlNameType), "Example")
    }

    func testWriteImageHitIsImageDataWithoutPath() throws {
        let file = dir.appendingPathComponent("shot.png")
        try makePNG().write(to: file)
        Clipboard.write(hit(.screenshot), fileURL: file, to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .fileURL))   // text fields would paste the path
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(pasteboard.data(forType: .png))))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testWriteFileHits() throws {
        let file = dir.appendingPathComponent("doc.pdf")
        try Data("%PDF".utf8).write(to: file)
        for kind in [ItemKind.pdf, .file, .voice, .audio, .video] {
            XCTAssertTrue(Clipboard.write(hit(kind), fileURL: file, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .fileURL), file.absoluteString)
            XCTAssertNil(pasteboard.data(forType: .png))
        }
        XCTAssertFalse(Clipboard.write(hit(.pdf), fileURL: nil, to: pasteboard))
    }

    func testClipboardText() {
        pasteboard.clearContents()
        pasteboard.setString("a thought worth keeping", forType: .string)
        XCTAssertEqual(Clipboard.payload(from: pasteboard, tempDir: dir), .text("a thought worth keeping"))
    }

    func testClipboardLoneURLBecomesLink() {
        pasteboard.clearContents()
        pasteboard.setString(" https://example.com/post \n", forType: .string)
        XCTAssertEqual(Clipboard.payload(from: pasteboard, tempDir: dir),
                       .link(url: URL(string: "https://example.com/post")!, title: nil, screenshot: nil))
    }

    func testClipboardFileURLs() {
        let a = URL(fileURLWithPath: "/tmp/a.txt"), b = URL(fileURLWithPath: "/tmp/b.png")
        pasteboard.clearContents()
        pasteboard.writeObjects([a as NSURL, b as NSURL])
        XCTAssertEqual(Clipboard.payload(from: pasteboard, tempDir: dir), .files([a, b]))
    }

    func testClipboardImageData() throws {
        let png = try makePNG()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        guard case let .screenshot(url) = Clipboard.payload(from: pasteboard, tempDir: dir) else {
            return XCTFail("expected an image")
        }
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    func testClipboardTIFFIsConvertedToPNG() throws {
        let tiff = try XCTUnwrap(NSImage(data: try makePNG())?.tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        guard case let .screenshot(url) = Clipboard.payload(from: pasteboard, tempDir: dir) else {
            return XCTFail("expected an image")
        }
        XCTAssertNotNil(NSImage(contentsOf: url))
        XCTAssertEqual(url.pathExtension, "png")
    }

    func testEmptyClipboard() {
        pasteboard.clearContents()
        XCTAssertNil(Clipboard.payload(from: pasteboard, tempDir: dir))
    }

    func testVoiceLevel() {
        XCTAssertEqual(VoiceRecorder.level(decibels: -160), 0)
        XCTAssertEqual(VoiceRecorder.level(decibels: -25), 0.5)
        XCTAssertEqual(VoiceRecorder.level(decibels: 3), 1)
    }
}

@MainActor
final class LonelyURLTests: XCTestCase {
    func testSelectedAddressesBecomeLinks() {
        XCTAssertEqual(CaptureCoordinator.lonelyURL("x.com/evilseyee")?.host, "x.com")
        XCTAssertEqual(CaptureCoordinator.lonelyURL("  https://example.com/a?b=1 \n")?.host, "example.com")
        XCTAssertNil(CaptureCoordinator.lonelyURL("see x.com/evilseyee"))       // prose around it
        XCTAssertNil(CaptureCoordinator.lonelyURL("file.txt"))
        XCTAssertNil(CaptureCoordinator.lonelyURL("README.md"))
        XCTAssertNil(CaptureCoordinator.lonelyURL("3.14"))
        XCTAssertNil(CaptureCoordinator.lonelyURL("ftp://example.com"))
        XCTAssertNil(CaptureCoordinator.lonelyURL(""))
    }
}
