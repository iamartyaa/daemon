import Foundation

public struct ModelFile: Sendable, Hashable {
    public var name: String
    public var size: Int64
    public var sha256: String   // lowercase hex

    public init(name: String, size: Int64, sha256: String) {
        self.name = name; self.size = size; self.sha256 = sha256
    }

    /// Text model. Required for anything to work.
    public static let embeddingGemma2 = ModelFile(
        name: "embeddinggemma-2-Q8_0.gguf", size: 309_855_456,
        sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")

    /// Vision/audio projector for images and audio.
    public static let embeddingGemma2Projector = ModelFile(
        name: "mmproj-embeddinggemma-2-Q8_0.gguf", size: 554_821_024,
        sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
}

/// The files to fetch, in download order (text model first).
public struct ModelManifest: Sendable {
    public var baseURL: URL
    public var files: [ModelFile]

    public init(baseURL: URL, files: [ModelFile]) {
        self.baseURL = baseURL; self.files = files
    }

    public static let embeddingGemma2 = ModelManifest(
        baseURL: URL(string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/")!,
        files: [.embeddingGemma2, .embeddingGemma2Projector])

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func remoteURL(for file: ModelFile) -> URL { baseURL.appendingPathComponent(file.name) }
}
