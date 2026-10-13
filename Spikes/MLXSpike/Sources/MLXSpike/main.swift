// Same inputs and checks as Sources/EmbedSpike (llama.cpp), so the numbers compare directly.
// Usage: MLXSpike <imageA> <imageB> <audioA.wav> <audioB.wav>
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Daemon/models/embeddinggemma-2-mlx-8bit")

// Local-only adapter: swift-transformers tokenizer → mlx-swift-lm protocol (no Hub downloader).
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
    struct Bridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            throw MLXLMCommon.TokenizerError.missingChatTemplate // embedding model, never chats
        }
    }
}

func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

func mem(_ label: String) {
    let f = footprint()
    print(String(format: "  [mem] %@: %.0f MB (peak %.0f MB)", label, f.now, f.peak))
}

func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let result = try await body()
    let d = ContinuousClock.now - start
    return (result, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

func retrievalCheck(_ title: String, docs: [[Float]], queries: [String],
                    embedQuery: (String) async throws -> [Float]) async rethrows -> Bool {
    print("\n\(title)")
    var ok = true
    for (qi, q) in queries.enumerated() {
        let qv = try await embedQuery(q)
        let scores = docs.map { cosine(qv, $0) }
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        ok = ok && best == qi
        print("  \(best == qi ? "✓" : "✗") \"\(q)\" → \(scores.map { String(format: "%.3f", $0) }.joined(separator: "  "))")
    }
    return ok
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 4 else { print("usage: MLXSpike <imageA> <imageB> <audioA.wav> <audioB.wav>"); exit(2) }

// MLX keeps freed GPU buffers in a cache for reuse; uncapped it grew to ~4 GB here.
Memory.cacheLimit = 64 * 1024 * 1024

do {
    mem("start")
    print("\nLoading text model (vision/audio load on first use)")
    let (e, loadMs) = try await timed {
        try await EmbeddingGemma2Embedding(modelDirectory: modelDir, tokenizerLoader: LocalTokenizerLoader())
    }
    let modalities = await e.supportedModalities
    print(String(format: "  loaded in %.0f ms, modalities %@", loadMs, "\(modalities)"))
    mem("text model loaded (budget idle < 400 MB)")

    func text(_ s: String, _ task: EmbeddingGemma2Embedding.Task) async throws -> [Float] {
        try await e.embed(.init(text: s), task: task)
    }
    _ = try await text("warm up", .searchQuery)

    let docTexts = [
        "Use host.docker.internal to reach services on the host machine from inside a Docker container.",
        "Default to yearly billing and show the monthly price small on the pricing page.",
        "The master theorem gives asymptotic bounds for divide and conquer recurrences.",
    ]
    var docs: [[Float]] = []
    for d in docTexts {
        let (v, t) = try await timed { try await text(d, .document) }
        print(String(format: "  doc embed %.1f ms", t))
        docs.append(v)
    }
    let long = String(repeating: docTexts.joined(separator: " ") + " ", count: 38) // ~2,000 tokens
    let (_, coldMs) = try await timed { try await text(long, .document) }
    let (_, warmMs) = try await timed { try await text(long, .document) }
    print(String(format: "  long doc cold %.1f ms, warm %.1f ms (budget < 300 ms)", coldMs, warmMs))

    var allOK = try await retrievalCheck("Text → text", docs: docs, queries: [
        "docker container can't reach host", "pricing toggle monthly yearly", "proof of the master theorem",
    ]) { q in
        let (v, t) = try await timed { try await text(q, .searchQuery) }
        print(String(format: "    query embed %.1f ms", t))
        return v
    }
    mem("after text work")

    func media(_ part: EmbeddingGemma2Embedding.Input.Part, _ name: String, budget: String) async throws -> [Float] {
        let (_, firstMs) = try await timed { try await e.embed(.init([part]), task: .document) } // pays encoder load
        let (v, t) = try await timed { try await e.embed(.init([part]), task: .document) }
        print(String(format: "  %@ first %.0f ms (includes encoder load), warm %.0f ms (%@)", name, firstMs, t, budget))
        mem("after \(name) (budget embedding < 1 GB)")
        return v
    }

    print("\nImages")
    var images: [[Float]] = []
    for p in args[0...1] {
        let url = URL(fileURLWithPath: p)
        images.append(try await media(.image(.url(url)), url.lastPathComponent, budget: "budget < 1000 ms"))
    }
    allOK = try await retrievalCheck("Text → image", docs: images, queries: [
        "onboarding window teaching two keyboard shortcuts, keep and recall",
        "dark search panel listing pricing results with a preview",
    ]) { try await text($0, .searchQuery) } && allOK

    print("\nAudio (mlx-swift-lm keeps only the first 30 s)")
    var audio: [[Float]] = []
    for p in args[2...3] {
        let url = URL(fileURLWithPath: p)
        audio.append(try await media(.audio(.url(url)), url.lastPathComponent, budget: "~2000 ms per 60 s"))
    }
    allOK = try await retrievalCheck("Text → audio", docs: audio, queries: [
        "the caching idea", "call Hana about the Tuesday review",
    ]) { try await text($0, .searchQuery) } && allOK

    print("")
    mem("end")
    print(String(format: "  MLX active %.0f MB, cache %.0f MB, peak %.0f MB",
                 Double(Memory.activeMemory) / 1_048_576, Double(Memory.cacheMemory) / 1_048_576,
                 Double(Memory.peakMemory) / 1_048_576))
    print(allOK ? "\nRESULT: all retrieval checks passed" : "\nRESULT: some retrieval checks failed")
    exit(allOK ? 0 : 1)
} catch {
    print("ERROR: \(error)")
    exit(1)
}
