// Background model process: EmbeddingGemma 2 on llama.cpp, driven by EmbedderClient.
// Protocol (see DaemonCore/Embedding/EmbedderProtocol.swift): JSON lines on stdin/stdout; logs on stderr only.
// Usage: DaemonEmbedder [--models <dir>]
import DaemonCore
import Foundation
import llama

// Verbatim from the model card (config_sentence_transformers.json). Images and audio take no prefix.
let queryPrefix = "task: search result | query: "
let documentPrefix = "title: none | text: "
let contextSize: Int32 = 2048 // whole input must fit one ubatch; no KV cache across calls

struct EmbedError: Error, CustomStringConvertible { let description: String }

func log(_ message: String) { FileHandle.standardError.write(Data("[DaemonEmbedder] \(message)\n".utf8)) }

/// Only warnings and errors reach stderr; model-load chatter is dropped.
let logCallback: ggml_log_callback = { level, text, _ in
    guard let text, level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR else { return }
    fputs(text, stderr)
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

final class Model {
    let model: OpaquePointer
    let ctx: OpaquePointer
    let projectorPath: String
    var mctx: OpaquePointer?
    let nEmbdInp: Int
    let nEmbdOut: Int

    init(directory: URL) throws {
        llama_backend_init()
        let path = directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path
        projectorPath = directory.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf").path
        guard let m = llama_model_load_from_file(path, llama_model_default_params()) else {
            llama_backend_free()
            throw EmbedError(description: "failed to load \(path)")
        }
        var cp = llama_context_default_params()
        cp.embeddings = true
        cp.n_ctx = UInt32(contextSize)
        cp.n_batch = UInt32(contextSize)
        cp.n_ubatch = UInt32(contextSize)
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            llama_backend_free()
            throw EmbedError(description: "failed to create context")
        }
        model = m
        ctx = c
        nEmbdInp = Int(llama_model_n_embd_inp(m))
        nEmbdOut = Int(llama_model_n_embd_out(m))
    }

    /// Free before exit(): ggml's Metal device teardown aborts if a model or context is still alive.
    func close() {
        if let mctx { mtmd_free(mctx) }
        llama_free(ctx)
        llama_model_free(model)
        llama_backend_free()
    }

    func embed(_ input: EmbedInput) throws -> [Float] {
        switch input {
        case .query(let s): return try embed(text: queryPrefix + s)
        case .document(let s): return try embed(text: documentPrefix + s)
        case .image(let url), .audio(let url): return try embed(media: url.path)
        }
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        let vocab = llama_model_get_vocab(model)
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 16)
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), addSpecial, false)
        guard n >= 0 else { throw EmbedError(description: "tokenize failed (\(n))") }
        return Array(tokens.prefix(Int(n)))
    }

    private func embed(text: String) throws -> [Float] {
        var tokens = try tokenize(text, addSpecial: true)
        if tokens.count > Int(contextSize) {
            // Too long for one pass: keep the head, then re-add the special tokens the vocab wants.
            let vocab = llama_model_get_vocab(model)
            let bos = llama_vocab_get_add_bos(vocab), eos = llama_vocab_get_add_eos(vocab)
            let room = Int(contextSize) - (bos ? 1 : 0) - (eos ? 1 : 0)
            tokens = Array(try tokenize(text, addSpecial: false).prefix(room))
            if bos { tokens.insert(llama_vocab_bos(vocab), at: 0) }
            if eos { tokens.append(llama_vocab_eos(vocab)) }
        }
        guard !tokens.isEmpty else { throw EmbedError(description: "empty input") }
        return try run { batch, addPos in
            for t in tokens { addPos(llama_batch_ext_add_token(batch, 0, t)) }
        }
    }

    private func loadProjector() throws -> OpaquePointer {
        if let mctx { return mctx }
        var p = mtmd_context_params_default()
        p.warmup = false
        p.image_max_tokens = 280 // model card default; llama.cpp otherwise uses the GGUF max (~1,100), 7x slower
        guard let m = mtmd_init_from_file(projectorPath, model, p) else {
            throw EmbedError(description: "failed to load \(projectorPath)")
        }
        mctx = m
        log(String(format: "projector loaded, footprint %.0f MB", footprintMB()))
        return m
    }

    private func embed(media path: String) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: path) else { throw EmbedError(description: "no file at \(path)") }
        let mctx = try loadProjector()
        guard let bitmap = mtmd_helper_bitmap_init_from_file(mctx, path, false, mtmd_helper_init_opt_default()).bitmap else {
            throw EmbedError(description: "cannot decode \(path)")
        }
        defer { mtmd_bitmap_free(bitmap) }
        guard let chunks = mtmd_input_chunks_init() else { throw EmbedError(description: "mtmd_input_chunks_init failed") }
        defer { mtmd_input_chunks_free(chunks) }

        let marker = String(cString: mtmd_default_marker())
        let rc: Int32 = marker.withCString { cstr in
            var input = mtmd_input_text(text: cstr, text_len: strlen(cstr), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mctx, chunks, &input, $0.baseAddress, 1) }
        }
        guard rc == 0 else { throw EmbedError(description: "mtmd_tokenize failed (\(rc))") }

        // Encoder outputs are overwritten per encode, so copy each media chunk out before batching.
        var buffers: [UnsafeMutableBufferPointer<Float>] = []
        defer { buffers.forEach { $0.deallocate() } }

        return try run { batch, addPos in
            for i in 0..<mtmd_input_chunks_size(chunks) {
                let chunk = mtmd_input_chunks_get(chunks, i)!
                if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                    var n = 0
                    let toks = mtmd_input_chunk_get_tokens_text(chunk, &n)!
                    for j in 0..<n { addPos(llama_batch_ext_add_token(batch, 0, toks[j])) }
                    continue
                }
                let nTok = mtmd_input_chunk_get_n_tokens(chunk)
                guard mtmd_encode_chunk(mctx, chunk) == 0 else { throw EmbedError(description: "mtmd_encode_chunk failed") }
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
        guard let batch = llama_batch_ext_init(ctx) else { throw EmbedError(description: "llama_batch_ext_init failed") }
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
        guard failed == 0 else { throw EmbedError(description: "batch add failed (\(failed)) after \(pos) tokens") }
        if let memory = llama_get_memory(ctx) { llama_memory_clear(memory, true) }
        let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard rc == 0 else { throw EmbedError(description: "llama_process failed (\(rc)) at \(pos) tokens") }
        guard let out = llama_get_embeddings_seq(ctx, 0) else { throw EmbedError(description: "no pooled embedding") }
        let v = Array(UnsafeBufferPointer(start: out, count: nEmbdOut))
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm.isNaN || norm == 0 { throw EmbedError(description: "degenerate vector (norm \(norm))") }
        return v.map { $0 / norm }
    }
}

// MARK: - main

llama_log_set(logCallback, nil)
mtmd_log_set(logCallback, nil)

var modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Daemon/models")
if let i = CommandLine.arguments.firstIndex(of: "--models"), i + 1 < CommandLine.arguments.count {
    modelsDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
}

let model: Model
do {
    model = try Model(directory: modelsDir)
    log(String(format: "text model loaded, footprint %.0f MB", footprintMB()))
} catch {
    log("\(error)")
    exit(1)
}

let encoder = JSONEncoder()
let decoder = JSONDecoder()

func reply(_ response: EmbedderResponse) {
    var line = (try? encoder.encode(response)) ?? Data(#"{"id":\#(response.id),"error":"encode failed"}"#.utf8)
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

while let line = readLine() {
    guard !line.isEmpty else { continue }
    guard let request = try? decoder.decode(EmbedderRequest.self, from: Data(line.utf8)) else {
        log("malformed request: \(line.prefix(200))")
        reply(EmbedderResponse(id: -1, error: "malformed request"))
        continue
    }
    switch request.op {
    case .stats:
        reply(EmbedderResponse(id: request.id, footprintMB: footprintMB(), mediaLoaded: model.mctx != nil, pid: getpid()))
    case .embed:
        guard let input = request.input?.embedInput else {
            reply(EmbedderResponse(id: request.id, error: "embed needs exactly one of query/document/image/audio"))
            continue
        }
        do {
            reply(EmbedderResponse(id: request.id, vector: try model.embed(input)))
        } catch {
            reply(EmbedderResponse(id: request.id, error: "\(error)"))
        }
    }
}

model.close()
exit(0)
