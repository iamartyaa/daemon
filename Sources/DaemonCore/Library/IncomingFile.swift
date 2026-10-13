import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A file about to be kept, with everything read from it up front (dimensions, duration, thumbnail)
/// so the library can store it and insert the row without suspending.
struct IncomingFile {
    let url: URL
    let bytes: Int64
    let isReference: Bool
    let move: Bool                  // Capture-owned temp file: move instead of copy
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var thumbnail: CGImage?

    init(url: URL, kind: ItemKind, bytes: Int64, isReference: Bool, move: Bool) async {
        self.url = url; self.bytes = bytes; self.isReference = isReference; self.move = move
        if [.image, .screenshot, .link].contains(kind),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int
            height = props[kCGImagePropertyPixelHeight] as? Int
        }
        if [.audio, .video, .voice].contains(kind), let duration = try? await AVURLAsset(url: url).load(.duration),
           duration.isNumeric {
            durationMs = Int(duration.seconds * 1000)
        }
        if [.image, .screenshot, .link, .pdf, .video].contains(kind) {
            thumbnail = await Self.thumbnail(of: url)
        }
    }

    /// ~400 px on the long side; QuickLook handles images, PDFs (first page) and video (a frame).
    private static func thumbnail(of url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 400, height: 400),
                                                   scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func writeJPEG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
