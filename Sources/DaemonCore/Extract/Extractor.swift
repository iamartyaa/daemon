import AppKit
import UniformTypeIdentifiers

public enum ExtractError: Error {
    case unreadable(URL)
    case missingFile(Int64)
    case unsavedItem
}

/// Splits a kept item into searchable segments (PRD "What gets embedded").
public struct Extractor {
    public init() {}

    /// `fileURL` is the stored file (nil for pure text items). Derived media goes into `workDir`.
    public func segments(for item: Item, fileURL: URL?, workDir: URL) async throws -> [SegmentDraft] {
        guard let itemId = item.id else { throw ExtractError.unsavedItem }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        if item.kind == .link {
            let title = [item.text, item.url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            var drafts = textDrafts(title, itemId: itemId)
            if let fileURL { drafts.append(try imageDraft(fileURL, itemId: itemId, workDir: workDir)) }
            return drafts
        }
        guard let fileURL else {
            if item.kind == .text { return textDrafts(item.text ?? "", itemId: itemId) }
            throw ExtractError.missingFile(itemId)
        }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { throw ExtractError.unreadable(fileURL) }

        // Stored files may be named by hash, so prefer the item's recorded extension.
        let ext = item.fileExtension ?? fileURL.pathExtension
        let type = UTType(filenameExtension: ext) ?? .data

        switch item.kind {
        case .image, .screenshot: return [try imageDraft(fileURL, itemId: itemId, workDir: workDir)]
        case .pdf: return try pdfDrafts(fileURL, itemId: itemId, workDir: workDir)
        case .audio, .voice: return try await audioDrafts(fileURL, itemId: itemId, workDir: workDir)
        case .video: return try await videoDrafts(fileURL, itemId: itemId, workDir: workDir)
        case .text, .file, .link: break
        }

        if type.conforms(to: .pdf) { return try pdfDrafts(fileURL, itemId: itemId, workDir: workDir) }
        if type.conforms(to: .image) { return [try imageDraft(fileURL, itemId: itemId, workDir: workDir)] }
        if type.conforms(to: .movie) { return try await videoDrafts(fileURL, itemId: itemId, workDir: workDir) }
        if type.conforms(to: .audio) { return try await audioDrafts(fileURL, itemId: itemId, workDir: workDir) }
        if let docType = Self.richTextTypes[ext.lowercased()] {
            let doc = try NSAttributedString(url: fileURL, options: [.documentType: docType], documentAttributes: nil)
            return textDrafts(doc.string, itemId: itemId)
        }
        if type.conforms(to: .text) || item.kind == .text { return textDrafts(try readText(fileURL), itemId: itemId) }

        let name = item.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fileURL.lastPathComponent
        return [SegmentDraft(segment: Segment(itemId: itemId, modality: .text, text: name), input: nil)]
    }

    private static let richTextTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument,
    ]

    private func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func textDrafts(_ text: String, itemId: Int64, page: Int? = nil) -> [SegmentDraft] {
        Self.chunks(text).map {
            SegmentDraft(segment: Segment(itemId: itemId, modality: .text, page: page, text: $0), input: .document($0))
        }
    }
}

// MARK: - Chunking

extension Extractor {
    static let maxTokens = 2_000, chunkTokens = 1_000, overlapTokens = 100

    /// No tokenizer here, so estimate. Gemma's SentencePiece averages ~4 chars/token on English prose, but splits
    /// every digit into its own token and spends ~1 token per CJK/emoji/symbol char. We count letters and whitespace
    /// at 3 chars/token and everything else at 1 token/char, so the estimate runs high and chunks stay under the
    /// embedder's 2,048-token context.
    static func estimatedTokens<S: StringProtocol>(_ s: S) -> Double {
        var cheap = 0, dear = 0
        for u in s.unicodeScalars {
            if u.isASCII && (CharacterSet.letters.contains(u) || CharacterSet.whitespacesAndNewlines.contains(u)) {
                cheap += 1
            } else {
                dear += 1
            }
        }
        return Double(cheap) / 3 + Double(dear)
    }

    /// Whole text if it fits in `maxTokens`; else ~`chunkTokens` chunks overlapping by ~`overlapTokens`, cut
    /// between words and preferably at a sentence end. Chunks are slices of the original, so formatting survives.
    static func chunks(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if estimatedTokens(trimmed) <= Double(maxTokens) { return [trimmed] }

        // A "word" over 500 chars (base64, minified code) can't stay whole, so it gets hard-split.
        var words: [Substring] = []
        for w in text.split(whereSeparator: \.isWhitespace) {
            var i = w.startIndex
            while i < w.endIndex {
                let j = w.index(i, offsetBy: 500, limitedBy: w.endIndex) ?? w.endIndex
                words.append(w[i..<j])
                i = j
            }
        }
        let costs = words.map { estimatedTokens($0) + 1.0 / 3 }  // + the separating space

        var out: [String] = []
        var start = 0
        while start < words.count {
            var end = start, sum = 0.0
            while end < words.count, sum + costs[end] <= Double(chunkTokens) { sum += costs[end]; end += 1 }
            end = max(end, start + 1)
            // Back up to a sentence end if one falls in the chunk's last 20%.
            if end < words.count {
                let floor = start + (end - start) * 4 / 5
                if let k = (max(floor, start + 1)...end).reversed().first(where: { words[$0 - 1].last.map { ".!?".contains($0) } ?? false }) {
                    end = k
                }
            }
            out.append(String(text[words[start].startIndex..<words[end - 1].endIndex]))
            if end == words.count { break }
            var next = end, overlap = 0.0
            while next > start + 1, overlap + costs[next - 1] <= Double(overlapTokens) { overlap += costs[next - 1]; next -= 1 }
            start = next
        }
        return out
    }
}
