import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

extension Extractor {
    static let maxImageSide = 1_536

    /// Downscaled copy for the embedder plus on-device OCR text for keyword search.
    func imageDraft(_ url: URL, itemId: Int64, workDir: URL) throws -> SegmentDraft {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ExtractError.unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up

        let side = min(Self.maxImageSide, max(full.width, full.height))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ExtractError.unreadable(url)
        }
        let out = try writePNG(small, to: workDir)
        // OCR the full-resolution image: small text in screenshots doesn't survive the downscale.
        let text = try recognizeText(full, orientation: orientation)
        return SegmentDraft(segment: Segment(itemId: itemId, modality: .image, text: text), input: .image(out))
    }

    /// One text segment per page; scanned pages are rendered at 150 dpi and OCR'd.
    func pdfDrafts(_ url: URL, itemId: Int64, workDir: URL) throws -> [SegmentDraft] {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.unreadable(url) }
        var drafts: [SegmentDraft] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pageText.isEmpty {
                drafts += textDrafts(pageText, itemId: itemId, page: i + 1)
                continue
            }
            // Corrupt pages are skipped; the rest of the document still gets indexed.
            guard let image = page.pageRef.flatMap({ render($0, dpi: 150) }) else { continue }
            let ocr = (try? recognizeText(image, orientation: .up)) ?? nil
            if let ocr {
                drafts += textDrafts(ocr, itemId: itemId, page: i + 1)
            } else if let png = try? writePNG(image, to: workDir) {
                drafts.append(SegmentDraft(segment: Segment(itemId: itemId, modality: .image, page: i + 1), input: .image(png)))
            }
        }
        return drafts
    }

    func writePNG(_ image: CGImage, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExtractError.unreadable(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExtractError.unreadable(url) }
        return url
    }

    /// Accurate recognition with language correction; nil when nothing was found.
    func recognizeText(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func render(_ page: CGPDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}
