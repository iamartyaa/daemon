import AppKit
import AVFoundation
import XCTest
@testable import DaemonCore

final class ExtractTests: XCTestCase {
    var dir: URL!
    var workDir: URL { dir.appendingPathComponent("work") }
    let extractor = Extractor()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExtractTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Text

    func testShortTextIsOneSegment() async throws {
        let item = Item(id: 7, kind: .text, text: "  Remember the milk.\n")
        let drafts = try await extractor.segments(for: item, fileURL: nil, workDir: workDir)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].segment.itemId, 7)
        XCTAssertNil(drafts[0].segment.id)
        XCTAssertEqual(drafts[0].segment.modality, .text)
        XCTAssertEqual(drafts[0].segment.text, "Remember the milk.")
        XCTAssertEqual(drafts[0].input, .document("Remember the milk."))
    }

    func testLongTextChunksOverlapWithoutSplittingWords() async throws {
        // 10k unique letter-only words (so each maps back to its position), a sentence every 12 words.
        let words = (0..<10_000).map { i -> String in
            var n = i, w = "w"
            repeat { w.append(Character(UnicodeScalar(UInt8(97 + n % 26)))); n /= 26 } while n > 0
            return i % 12 == 11 ? w + "." : w
        }
        let index = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        let item = Item(id: 1, kind: .text, text: words.joined(separator: " "))

        let drafts = try await extractor.segments(for: item, fileURL: nil, workDir: workDir)
        XCTAssertGreaterThan(drafts.count, 1)

        var previous: ClosedRange<Int>?
        for draft in drafts {
            let text = try XCTUnwrap(draft.segment.text)
            XCTAssertEqual(draft.input, .document(text))
            XCTAssertLessThanOrEqual(Extractor.estimatedTokens(text), Double(Extractor.chunkTokens))
            let positions = text.split(separator: " ").map { index[String($0)] }
            XCTAssertFalse(positions.contains(nil), "a chunk contains a split word")
            let ints = positions.compactMap { $0 }
            XCTAssertEqual(ints, Array(ints[0]...ints[ints.count - 1]), "chunk words must be contiguous")
            let range = ints[0]...ints[ints.count - 1]
            if let previous {
                XCTAssertTrue(range.lowerBound > previous.lowerBound && range.lowerBound <= previous.upperBound, "chunks must overlap")
                let overlap = words[range.lowerBound...previous.upperBound].joined(separator: " ")
                XCTAssertGreaterThan(Extractor.estimatedTokens(overlap), 50)
                XCTAssertLessThanOrEqual(Extractor.estimatedTokens(overlap), Double(Extractor.overlapTokens) + 1)
            } else {
                XCTAssertEqual(range.lowerBound, 0)
            }
            previous = range
        }
        XCTAssertEqual(previous?.upperBound, words.count - 1)
    }

    func testDigitsAndCJKCountAsFullTokens() {
        XCTAssertEqual(Extractor.estimatedTokens("abc"), 1)
        XCTAssertEqual(Extractor.estimatedTokens("1234"), 4)
        XCTAssertEqual(Extractor.estimatedTokens("日本語"), 3)
    }

    func testRTFAndDocxBecomeText() async throws {
        let doc = NSAttributedString(string: "Quarterly llama census.\nSecond paragraph.")
        for (ext, type) in [("rtf", NSAttributedString.DocumentType.rtf), ("docx", .officeOpenXML)] {
            let url = dir.appendingPathComponent("note.\(ext)")
            try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: type]).write(to: url)
            let item = Item(id: 2, kind: .file, fileExtension: ext)
            let drafts = try await extractor.segments(for: item, fileURL: url, workDir: workDir)
            XCTAssertEqual(drafts.count, 1, ext)
            XCTAssertTrue(drafts[0].segment.text?.contains("llama census") == true, ext)
            XCTAssertTrue(drafts[0].segment.text?.contains("Second paragraph") == true, ext)
        }
    }

    func testPlainTextFileAndOtherFile() async throws {
        let code = dir.appendingPathComponent("main.swift")
        try "print(\"hi\")".write(to: code, atomically: true, encoding: .utf8)
        let codeDrafts = try await extractor.segments(for: Item(id: 3, kind: .file, fileExtension: "swift"), fileURL: code, workDir: workDir)
        XCTAssertEqual(codeDrafts.map(\.input), [.document("print(\"hi\")")])

        let zip = dir.appendingPathComponent("abc123")
        try Data([0x50, 0x4B, 3, 4]).write(to: zip)
        let item = Item(id: 3, kind: .file, fileExtension: "zip", originalPath: "/Users/me/Backup.zip")
        let drafts = try await extractor.segments(for: item, fileURL: zip, workDir: workDir)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].segment.text, "Backup.zip")
        XCTAssertNil(drafts[0].input)
    }

    func testUnreadableFileThrows() async {
        let item = Item(id: 4, kind: .pdf, fileExtension: "pdf")
        do {
            _ = try await extractor.segments(for: item, fileURL: dir.appendingPathComponent("missing.pdf"), workDir: workDir)
            XCTFail("expected a throw")
        } catch {}
    }

    // MARK: - Images and PDFs

    func testImageIsDownscaledAndOCRd() async throws {
        let url = dir.appendingPathComponent("shot.png")
        try png(textImage("HELLO DAEMON", width: 3000, height: 1000, fontSize: 200), to: url)
        let drafts = try await extractor.segments(for: Item(id: 5, kind: .screenshot), fileURL: url, workDir: workDir)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].segment.modality, .image)
        XCTAssertTrue(drafts[0].segment.text?.uppercased().contains("DAEMON") == true, drafts[0].segment.text ?? "nil")
        guard case .image(let out) = drafts[0].input else { return XCTFail("expected image input") }
        XCTAssertTrue(out.path.hasPrefix(workDir.path))
        let image = try XCTUnwrap(NSImage(contentsOf: out)?.representations.first)
        XCTAssertEqual(max(image.pixelsWide, image.pixelsHigh), Extractor.maxImageSide)
        XCTAssertEqual(min(image.pixelsWide, image.pixelsHigh), 512)
    }

    func testLinkIsTitleAndURLPlusScreenshot() async throws {
        let shot = dir.appendingPathComponent("page.png")
        try png(textImage("Llama Farm", width: 800, height: 400, fontSize: 80), to: shot)
        let item = Item(id: 10, kind: .link, url: "https://example.com/llamas", text: "Llama facts")
        let drafts = try await extractor.segments(for: item, fileURL: shot, workDir: workDir)
        XCTAssertEqual(drafts.map(\.segment.modality), [.text, .image])
        XCTAssertEqual(drafts[0].input, .document("Llama facts\nhttps://example.com/llamas"))
    }

    func testPDFTextPageAndScannedPage() async throws {
        let url = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        draw("Quarterly report about llamas", in: ctx, at: CGPoint(x: 72, y: 700), fontSize: 18)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        ctx.draw(textImage("INVOICE 4721", width: 1600, height: 400, fontSize: 160), in: CGRect(x: 56, y: 500, width: 500, height: 125))
        ctx.endPDFPage()
        ctx.closePDF()

        let drafts = try await extractor.segments(for: Item(id: 6, kind: .pdf), fileURL: url, workDir: workDir)
        XCTAssertEqual(drafts.map(\.segment.page), [1, 2])
        XCTAssertTrue(drafts[0].segment.text?.contains("llamas") == true)
        XCTAssertEqual(drafts[0].input, .document(drafts[0].segment.text!))
        let ocr = try XCTUnwrap(drafts[1].segment.text)
        XCTAssertTrue(ocr.contains("4721"), ocr)
        XCTAssertEqual(drafts[1].input, .document(ocr))
    }

    // MARK: - Audio and video

    func testAudioSplitsInto60SecondWindowsEvery55() async throws {
        let url = dir.appendingPathComponent("tone.wav")
        try writeSine(to: url, seconds: 130, sampleRate: 44_100, channels: 2)

        let drafts = try await extractor.segments(for: Item(id: 8, kind: .audio), fileURL: url, workDir: workDir)
        XCTAssertEqual(drafts.map(\.segment.startMs), [0, 55_000, 110_000])
        let ends = drafts.compactMap(\.segment.endMs)
        XCTAssertEqual(ends.count, 3)
        for (end, expected) in zip(ends, [60_000, 115_000, 130_000]) { XCTAssertEqual(end, expected, accuracy: 50) }

        for draft in drafts {
            XCTAssertEqual(draft.segment.modality, .audio)
            guard case .audio(let wav) = draft.input else { return XCTFail("expected audio input") }
            let file = try AVAudioFile(forReading: wav)
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
            let ms = Int(file.length) * 1000 / 16_000
            XCTAssertEqual(ms, draft.segment.endMs! - draft.segment.startMs!, accuracy: 1)
        }
    }

    func testVideoFramesEveryTenSeconds() async throws {
        let url = dir.appendingPathComponent("clip.mp4")
        try await writeMovie(to: url, seconds: 25)

        let drafts = try await extractor.segments(for: Item(id: 9, kind: .video), fileURL: url, workDir: workDir)
        XCTAssertEqual(drafts.map(\.segment.modality), [.video, .video, .video])
        XCTAssertEqual(drafts.map(\.segment.startMs), [0, 10_000, 20_000])
        XCTAssertEqual(drafts.map(\.segment.endMs), [10_000, 20_000, 25_000])
        for draft in drafts {
            guard case .image(let frame) = draft.input else { return XCTFail("expected image input") }
            XCTAssertNotNil(NSImage(contentsOf: frame))
        }
    }

    // MARK: - Fixtures

    private func draw(_ text: String, in ctx: CGContext, at point: CGPoint, fontSize: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: fontSize)]))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    private func textImage(_ text: String, width: Int, height: Int, fontSize: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, in: ctx, at: CGPoint(x: fontSize / 2, y: CGFloat(height) / 2 - fontSize / 3), fontSize: fontSize)
        return ctx.makeImage()!
    }

    private func png(_ image: CGImage, to url: URL) throws {
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func writeSine(to url: URL, seconds: Int, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let format = file.processingFormat
        let frames = AVAudioFrameCount(sampleRate)
        for second in 0..<seconds {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for c in 0..<Int(channels) {
                let data = buffer.floatChannelData![c]
                for i in 0..<Int(frames) {
                    data[i] = 0.5 * sin(2 * .pi * 440 * Float(second * Int(frames) + i) / Float(sampleRate))
                }
            }
            try file.write(from: buffer)
        }
    }

    private func writeMovie(to url: URL, seconds: Int) async throws {
        let (width, height) = (160, 120)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("AVAssetWriter unavailable: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        for second in 0..<seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw XCTSkip("no pixel buffer pool")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(second * 10 % 256), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(second), timescale: 1))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw XCTSkip("writing MP4 failed: \(String(describing: writer.error))") }
    }
}
