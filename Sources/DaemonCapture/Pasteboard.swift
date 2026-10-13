import AppKit
import DaemonCore
import UniformTypeIdentifiers

/// Every item and type on a pasteboard, in order, so it can be put back after Daemon borrows the clipboard.
struct PasteboardSnapshot {
    let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        })
    }
}

enum Clipboard {
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    /// Puts a Recall result on the pasteboard. Text → string; link → URL + string; files → file URL (+ image data).
    @discardableResult
    static func write(_ hit: SearchHit, fileURL: URL?, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        let kept = hit.item
        switch kept.kind {
        case .text:
            guard let text = kept.text else { return false }
            item.setString(text, forType: .string)
        case .link:
            guard let link = kept.url ?? kept.text else { return false }
            if URL(string: link) != nil { item.setString(link, forType: .URL) }
            item.setString(link, forType: .string)
            if let title = kept.text, kept.url != nil { item.setString(title, forType: urlNameType) }
        case .image, .screenshot, .voice, .audio, .video, .pdf, .file:
            guard let fileURL else { return false }
            item.setString(fileURL.absoluteString, forType: .fileURL)
            if kept.kind == .image || kept.kind == .screenshot,
               let type = UTType(filenameExtension: fileURL.pathExtension), type.conforms(to: .image),
               let data = try? Data(contentsOf: fileURL) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Reads the pasteboard as something to keep: files, then text (a lone web URL becomes a link), then image data.
    static func payload(from pasteboard: NSPasteboard, tempDir: URL = CaptureFiles.tempDir) -> CapturePayload? {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            return .files(files)
        }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil {
                return .link(url: url, title: nil, screenshot: nil)
            }
            return .text(text)
        }
        if let png = pngData(from: pasteboard) {
            let url = CaptureFiles.newURL(ext: "png", in: tempDir)
            guard (try? png.write(to: url)) != nil else { return nil }
            return .screenshot(url) // ponytail: no .image payload in Contracts; pasted images are kept as screenshots
        }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL {
            return .link(url: url, title: pasteboard.string(forType: urlNameType), screenshot: nil)
        }
        return nil
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

/// Files Capture writes (screenshots, voice notes). The sink copies them into the library.
enum CaptureFiles {
    static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DaemonCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func newURL(ext: String, in dir: URL = tempDir) -> URL {
        dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}
