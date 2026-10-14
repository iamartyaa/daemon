import AppKit
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

    /// Accurate recognition, corrected where it needs it; nil when nothing was found.
    ///
    /// Vision's language correction is most of the cost: on a full-screen screenshot it takes ~2.3 s of CPU across
    /// ~4 cores, against ~0.5 s without it. So the whole image is read once without correction, and only lines with a
    /// word the system dictionary doesn't know ("lurn", "slarter"), a run-together word ("SecurityAccessibility") or
    /// stray letters from another script (uncorrected, "Copy" can come out in Cyrillic) are read again, cropped, with
    /// correction. On the design screenshots that's the same words for about a third of the CPU. When most lines
    /// need it (a language the dictionary doesn't know), or the image is rotated, one corrected pass reads it all.
    func recognizeText(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> String? {
        try Perf.measure("ocr", "\(image.width)x\(image.height)") {
            let quick = try Self.recognize(image, orientation: orientation, correction: false)
            guard !quick.isEmpty else { return nil }
            var lines = quick.map { $0.topCandidates(1).first?.string ?? "" }
            let suspect = orientation == .up ? Self.linesNeedingCorrection(lines) : IndexSet(lines.indices)
            if suspect.count * 5 > lines.count * 2 {   // over 40%: one pass over the whole image is cheaper
                lines = try Self.recognize(image, orientation: orientation, correction: true)
                    .compactMap { $0.topCandidates(1).first?.string }
            } else {
                for i in suspect {
                    if let fixed = try Self.recognizeLine(quick[i].boundingBox, in: image) { lines[i] = fixed }
                }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    private static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation,
                                  correction: Bool) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correction
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return request.results ?? []
    }

    /// The line at `box` (Vision's normalized, bottom-up coordinates), read again with correction.
    private static func recognizeLine(_ box: CGRect, in image: CGImage) throws -> String? {
        let w = CGFloat(image.width), h = CGFloat(image.height), lineHeight = box.height * h
        let rect = CGRect(x: box.minX * w - 0.5 * lineHeight, y: (1 - box.maxY) * h - 0.25 * lineHeight,
                          width: box.width * w + lineHeight, height: 1.5 * lineHeight)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        // Only what sits on this line's middle, not the edges of the lines above and below.
        let words = try recognize(crop, orientation: .up, correction: true)
            .filter { abs($0.boundingBox.midY - 0.5) < 0.25 }
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Lines that uncorrected recognition likely got wrong: a misspelling, a lowercase-to-capital join inside a word,
    /// or (in text that is mostly Latin) any letter from another script.
    static func linesNeedingCorrection(_ lines: [String]) -> IndexSet {
        var suspect = IndexSet()
        let letters = lines.joined().unicodeScalars.filter(\.properties.isAlphabetic)
        let mostlyLatin = letters.filter { $0.value < 0x250 }.count * 5 >= letters.count * 4
        for (i, line) in lines.enumerated() {
            let foreign = mostlyLatin && line.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value >= 0x250 }
            let joined = zip(line, line.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
            if foreign || joined { suspect.insert(i) }
        }
        let text = lines.joined(separator: "\n") as NSString
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        for range in misspellings(in: text as String) {
            let line = starts.lastIndex { $0 <= range.location } ?? 0
            let word = text.substring(with: range)
            if word.count >= 3, word.allSatisfy(\.isLetter) { suspect.insert(line) }
        }
        return suspect
    }

    /// Ranges of misspelled words: one synchronous request to the system spell checker for all the text. (Its
    /// background variant does this same call on a queue of its own; this keeps the pipeline's own thread.)
    private static func misspellings(in text: String) -> [NSRange] {
        NSSpellChecker.shared.check(text, range: NSRange(location: 0, length: (text as NSString).length),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: nil,
                                    inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil).map(\.range)
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
