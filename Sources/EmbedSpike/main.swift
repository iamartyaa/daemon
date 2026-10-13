// Runtime spike (daemon-7tl): EmbeddingGemma 2 on llama.cpp from Swift.
// Usage: EmbedSpike <imageA> <imageB> <audioA.wav> <audioB.wav>
// Prints load times, per-embed latency, memory, and retrieval sanity checks.
import Foundation
import llama

let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Daemon/models")
let textModelPath = modelsDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path
let mmprojPath = modelsDir.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf").path

// Verbatim from google/embeddinggemma-2 config_sentence_transformers.json
let queryPrefix = "task: search result | query: "
let docPrefix = "title: none | text: "

// MARK: - measurement

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

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let result = try body()
    let d = ContinuousClock.now - start
    return (result, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

func mem(_ label: String) {
    let f = footprint()
    print(String(format: "  [mem] %@: %.0f MB (peak %.0f MB)", label, f.now, f.peak))
}

struct SpikeError: Error, CustomStringConvertible { let description: String }

// MARK: - embedder

final class Embedder {
    let model: OpaquePointer
    let ctx: OpaquePointer
    var mctx: OpaquePointer?
    let nEmbdInp: Int
    let nEmbdOut: Int

    init(path: String) throws {
        llama_backend_init()
        guard let m = llama_model_load_from_file(path, llama_model_default_params()) else {
            throw SpikeError(description: "failed to load \(path)")
        }
        var cp = llama_context_default_params()
        cp.embeddings = true
        // Whole input must land in one ubatch (no KV cache across calls). Largest PRD input:
        // 2,000-token text chunk; 60 s audio = 1,500 tokens; image = 280. 8192 reserved ~1.5 GB.
        cp.n_ctx = 2048
        cp.n_batch = 2048
        cp.n_ubatch = 2048
        guard let c = llama_init_from_model(m, cp) else { throw SpikeError(description: "failed to create context") }
        model = m
        ctx = c
        nEmbdInp = Int(llama_model_n_embd_inp(m))
        nEmbdOut = Int(llama_model_n_embd_out(m))
        print("  pooling=\(llama_pooling_type(c).rawValue) n_embd_inp=\(nEmbdInp) n_embd_out=\(nEmbdOut)")
    }

    /// Free before exit(): ggml's Metal device teardown aborts if a model or context is still alive.
    func close() {
        if let mctx { mtmd_free(mctx) }
        llama_free(ctx)
        llama_model_free(model)
        llama_backend_free()
    }

    func loadMedia(path: String) throws {
        var p = mtmd_context_params_default()
        p.warmup = false
        if ProcessInfo.processInfo.environment["SPIKE_MTMD_CPU"] != nil { p.use_gpu = false } // memory experiment
        p.image_max_tokens = 280 // model card default; llama.cpp otherwise uses the GGUF max (~1,100)
        guard let m = mtmd_init_from_file(path, model, p) else { throw SpikeError(description: "failed to load \(path)") }
        mctx = m
        print("  vision=\(mtmd_support_vision(m)) audio=\(mtmd_support_audio(m)) sample_rate=\(mtmd_get_audio_sample_rate(m))")
    }

    func embed(text: String) throws -> [Float] {
        let vocab = llama_model_get_vocab(model)
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 16)
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), true, false)
        guard n > 0 else { throw SpikeError(description: "tokenize failed (\(n))") }
        return try run { batch, addPos in
            for t in tokens.prefix(Int(n)) { addPos(llama_batch_ext_add_token(batch, 0, t)) }
        }
    }

    /// One media file (image or audio), no task prefix per the model card.
    func embed(media path: String) throws -> [Float] {
        guard let mctx else { throw SpikeError(description: "media model not loaded") }
        guard let bitmap = mtmd_helper_bitmap_init_from_file(mctx, path, false, mtmd_helper_init_opt_default()).bitmap else {
            throw SpikeError(description: "cannot decode \(path)")
        }
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()!
        defer { mtmd_input_chunks_free(chunks) }

        let marker = String(cString: mtmd_default_marker())
        let rc: Int32 = marker.withCString { cstr in
            var input = mtmd_input_text(text: cstr, text_len: strlen(cstr), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mctx, chunks, &input, $0.baseAddress, 1) }
        }
        guard rc == 0 else { throw SpikeError(description: "mtmd_tokenize failed (\(rc))") }

        // Encoder outputs are overwritten per encode, so copy each media chunk out before batching.
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }

        return try run { batch, addPos in
            for i in 0..<mtmd_input_chunks_size(chunks) {
                let chunk = mtmd_input_chunks_get(chunks, i)!
                let nTok = mtmd_input_chunk_get_n_tokens(chunk)
                if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                    var n = 0
                    let toks = mtmd_input_chunk_get_tokens_text(chunk, &n)!
                    for j in 0..<n { addPos(llama_batch_ext_add_token(batch, 0, toks[j])) }
                    continue
                }
                guard mtmd_encode_chunk(mctx, chunk) == 0 else { throw SpikeError(description: "mtmd_encode_chunk failed") }
                let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: nTok * nEmbdInp)
                _ = buf.initialize(from: UnsafeBufferPointer(start: mtmd_get_output_embd(mctx), count: nTok * nEmbdInp))
                buffers.append(buf)
                for r in 0..<nTok {
                    let row = llama_embd(data: buf.baseAddress! + r * nEmbdInp, n_rows: 1, n_embd: nEmbdInp)
                    addPos(llama_batch_ext_add_embd(batch, 0, row))
                }
            }
        }
    }

    /// Builds one batch (tokens and/or encoder rows), runs it, returns the pooled, L2-normalized vector.
    private func run(_ fill: (OpaquePointer, (Int32) -> Void) throws -> Void) throws -> [Float] {
        let batch = llama_batch_ext_init(ctx)!
        defer { llama_batch_ext_free(batch) }
        var pos: llama_pos = 0
        var failed: Int32 = 0
        try fill(batch) { idx in
            guard idx >= 0 else { failed = idx; return }
            var p = pos
            _ = llama_batch_ext_set_pos(batch, idx, &p)
            _ = llama_batch_ext_set_output_embd(batch, idx, true)
            pos += 1
        }
        guard failed == 0 else { throw SpikeError(description: "batch add failed (\(failed)), \(pos) tokens") }
        if let memory = llama_get_memory(ctx) { llama_memory_clear(memory, true) }
        let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard rc == 0 else { throw SpikeError(description: "llama_process failed (\(rc)) at \(pos) tokens") }
        guard let out = llama_get_embeddings_seq(ctx, 0) else { throw SpikeError(description: "no pooled embedding") }
        let v = Array(UnsafeBufferPointer(start: out, count: nEmbdOut))
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm.isNaN || norm == 0 { throw SpikeError(description: "degenerate vector (norm \(norm))") }
        return v.map { $0 / norm }
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

/// Embeds every doc and query, prints the score matrix, returns true when each query's best doc is its pair.
func retrievalCheck(_ title: String, docs: [(String, [Float])], queries: [String], embedQuery: (String) throws -> [Float]) rethrows -> Bool {
    print("\n\(title)")
    var ok = true
    for (qi, q) in queries.enumerated() {
        let qv = try embedQuery(q)
        let scores = docs.map { cosine(qv, $0.1) }
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        ok = ok && best == qi
        let row = scores.map { String(format: "%.3f", $0) }.joined(separator: "  ")
        print("  \(best == qi ? "✓" : "✗") \"\(q)\" → \(row)")
    }
    return ok
}

// MARK: - spike

let args = CommandLine.arguments.dropFirst().map { $0 }
guard args.count == 4 else {
    print("usage: EmbedSpike <imageA> <imageB> <audioA.wav> <audioB.wav>")
    exit(2)
}

print("chip: \(ProcessInfo.processInfo.machineHardwareName)  (budgets are for a base M1)")
mem("start")
print("\nLoading text model")
let embedder: Embedder
do {
    let (e, loadMs) = try timed { try Embedder(path: textModelPath) }
    embedder = e
    print(String(format: "  loaded in %.0f ms", loadMs))
} catch {
    print("ERROR: \(error)")
    exit(1)
}

do {
    mem("text model loaded (budget idle < 400 MB)")

    _ = try embedder.embed(text: queryPrefix + "warm up")

    let docTexts = [
        "Use host.docker.internal to reach services on the host machine from inside a Docker container.",
        "Default to yearly billing and show the monthly price small on the pricing page.",
        "The master theorem gives asymptotic bounds for divide and conquer recurrences.",
    ]
    var docs: [(String, [Float])] = []
    for d in docTexts {
        let (v, t) = try timed { try embedder.embed(text: docPrefix + d) }
        print(String(format: "  doc embed %.1f ms", t))
        docs.append((d, v))
    }
    let long = docPrefix + String(repeating: docTexts.joined(separator: " ") + " ", count: 38) // ~2,000 tokens, the PRD chunk max
    let (_, longColdMs) = try timed { try embedder.embed(text: long) }
    let (_, longMs) = try timed { try embedder.embed(text: long) }
    print(String(format: "  long doc (~%d words) cold %.1f ms, warm %.1f ms (budget < 300 ms)",
                 long.split(separator: " ").count, longColdMs, longMs))

    var allOK = try retrievalCheck("Text → text", docs: docs,
        queries: ["docker container can't reach host", "pricing toggle monthly yearly", "proof of the master theorem"]
    ) { q in
        let (v, t) = try timed { try embedder.embed(text: queryPrefix + q) }
        print(String(format: "    query embed %.1f ms", t))
        return v
    }

    print("\nLoading vision/audio projector")
    let (_, mmMs) = try timed { try embedder.loadMedia(path: mmprojPath) }
    print(String(format: "  loaded in %.0f ms", mmMs))
    mem("projector loaded")
    if ProcessInfo.processInfo.environment["SPIKE_PAUSE"] != nil { // lets vmmap inspect the process
        print("PAUSED pid=\(getpid())"); fflush(stdout); _ = readLine()
    }

    func embedMedia(_ path: String, budget: String) throws -> (String, [Float]) {
        _ = try embedder.embed(media: path) // first call pays one-time setup
        let (v, t) = try timed { try embedder.embed(media: path) }
        print(String(format: "  %@ %.0f ms (%@)", (path as NSString).lastPathComponent, t, budget))
        mem("after \((path as NSString).lastPathComponent) (budget embedding < 1 GB)")
        return (path, v)
    }

    print("\nImages")
    let images = try [args[0], args[1]].map { try embedMedia($0, budget: "budget < 1000 ms") }
    allOK = try retrievalCheck("Text → image", docs: images, queries: [
        "onboarding window teaching two keyboard shortcuts, keep and recall",
        "dark search panel listing pricing results with a preview",
    ]) { try embedder.embed(text: queryPrefix + $0) } && allOK

    print("\nAudio")
    let audio = try [args[2], args[3]].map { try embedMedia($0, budget: "1 h must finish < 2 min → ~2000 ms per 60 s") }
    allOK = try retrievalCheck("Text → audio", docs: audio, queries: [
        "the caching idea",
        "call Hana about the Tuesday review",
    ]) { try embedder.embed(text: queryPrefix + $0) } && allOK

    print("")
    mem("end")
    print(allOK ? "\nRESULT: all retrieval checks passed" : "\nRESULT: some retrieval checks failed")
    embedder.close()
    exit(allOK ? 0 : 1)
} catch {
    print("ERROR: \(error)")
    embedder.close()
    exit(1)
}

extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
