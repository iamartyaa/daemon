import Foundation

// Wire protocol between EmbedderClient and the DaemonEmbedder process:
// newline-delimited JSON, one request per stdin line, one response per stdout line.
//   {"id":1,"op":"embed","input":{"query":"..."}}   input keys: query | document | image | audio (file path)
//   {"id":2,"op":"stats"}
//   -> {"id":1,"vector":[...]}  |  {"id":1,"error":"..."}  |  {"id":2,"footprintMB":412.5,"mediaLoaded":false,"pid":123}

public struct EmbedderRequest: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case embed, stats }

    public var id: Int
    public var op: Op
    public var input: WireInput?

    public init(id: Int, op: Op, input: EmbedInput? = nil) {
        self.id = id; self.op = op; self.input = input.map(WireInput.init)
    }

    /// EmbedInput as a single-key object. Kept here rather than as a Codable conformance on the shared type.
    public struct WireInput: Codable, Equatable, Sendable {
        var query, document, image, audio: String?

        init(_ input: EmbedInput) {
            switch input {
            case .query(let s): query = s
            case .document(let s): document = s
            case .image(let url): image = url.path
            case .audio(let url): audio = url.path
            }
        }

        public var embedInput: EmbedInput? {
            switch (query, document, image, audio) {
            case let (q?, nil, nil, nil): return .query(q)
            case let (nil, d?, nil, nil): return .document(d)
            case let (nil, nil, i?, nil): return .image(URL(fileURLWithPath: i))
            case let (nil, nil, nil, a?): return .audio(URL(fileURLWithPath: a))
            default: return nil
            }
        }
    }
}

public struct EmbedderResponse: Codable, Equatable, Sendable {
    public var id: Int
    public var vector: [Float]?
    public var error: String?
    public var footprintMB: Double?
    public var mediaLoaded: Bool?
    public var pid: Int32?

    public init(id: Int, vector: [Float]? = nil, error: String? = nil,
                footprintMB: Double? = nil, mediaLoaded: Bool? = nil, pid: Int32? = nil) {
        self.id = id; self.vector = vector; self.error = error
        self.footprintMB = footprintMB; self.mediaLoaded = mediaLoaded; self.pid = pid
    }
}

public struct EmbedderStats: Sendable, Equatable {
    public var footprintMB: Double   // phys_footprint of the model process
    public var mediaLoaded: Bool     // vision/audio projector resident
    public var pid: Int32
}
