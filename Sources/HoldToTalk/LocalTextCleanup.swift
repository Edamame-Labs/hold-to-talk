import Foundation
import llama

enum LocalCleanupError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case promptTooLong
    case decodeFailed
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "The on-device cleanup model isn't downloaded yet. Download it in Settings › Cleanup."
        case .modelLoadFailed:
            return "The on-device cleanup model failed to load. Try deleting and re-downloading it in Settings."
        case .contextCreationFailed:
            return "Could not start the on-device cleanup model. Try again, or restart Hold to Talk."
        case .tokenizationFailed, .promptTooLong, .decodeFailed, .shuttingDown:
            return "On-device cleanup failed. Using the raw transcription."
        }
    }
}

// MARK: - llama.cpp Handles

/// Owns the llama.cpp model and context pointers.
///
/// These live behind a lock rather than inside the actor because they must be
/// releasable *synchronously*: llama.cpp's Metal backend asserts during static
/// destruction (`GGML_ASSERT([rsets->data count] == 0)`) if a context is still
/// alive when the process exits, which would turn every quit into a crash
/// report. `LocalTextCleanup.shutdownForTermination()` is the synchronous path
/// that prevents that.
private final class LlamaHandles: @unchecked Sendable {
    static let shared = LlamaHandles()

    private let lock = NSLock()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?

    /// Checked once per generated token so a pending shutdown does not have to
    /// wait out a full generation before it can free the context.
    private let flagLock = NSLock()
    private var _shutdownRequested = false

    var shutdownRequested: Bool {
        get { flagLock.withLock { _shutdownRequested } }
        set { flagLock.withLock { _shutdownRequested = newValue } }
    }

    var isLoaded: Bool {
        lock.withLock { model != nil && context != nil && vocab != nil }
    }

    func load(modelPath: String, contextTokens: UInt32, threads: Int32) throws {
        lock.lock()
        defer { lock.unlock() }

        if model != nil, context != nil, vocab != nil { return }
        shutdownRequested = false

        var modelParams = llama_model_default_params()
        // Negative means "every layer on the GPU"; at 0.6B the whole model fits.
        modelParams.n_gpu_layers = -1

        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            throw LocalCleanupError.modelLoadFailed
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextTokens
        contextParams.n_batch = contextTokens
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        contextParams.no_perf = true

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw LocalCleanupError.contextCreationFailed
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalCleanupError.modelLoadFailed
        }

        model = loadedModel
        context = loadedContext
        vocab = loadedVocab
    }

    func unload() {
        shutdownRequested = true
        lock.lock()
        defer {
            lock.unlock()
            shutdownRequested = false
        }

        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        vocab = nil
    }

    /// Runs `body` with the handles held. The lock is held for the whole call,
    /// so a concurrent `unload()` waits — bounded by the shutdown flag that
    /// `body` polls.
    func withHandles<T>(_ body: (_ context: OpaquePointer, _ vocab: OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let context, let vocab else { throw LocalCleanupError.modelLoadFailed }
        return try body(context, vocab)
    }
}

// MARK: - Cleanup Engine

/// Runs Superwhisper's S1-mini locally through llama.cpp.
///
/// This is the on-device cleanup path that does not require Apple Intelligence:
/// it works on any Apple Silicon Mac running macOS 15+, offloaded to Metal.
/// The model stays loaded between dictations so only the first cleanup after
/// launch pays the load cost.
actor LocalTextCleanup {
    static let shared = LocalTextCleanup()

    /// Wall-clock budget per chunk. Dictation should feel immediate, so a run
    /// that stalls falls back to the raw transcript rather than making the user
    /// wait indefinitely.
    ///
    /// This is deliberately per-chunk, not per-call: a long dictation is split
    /// into several chunks, and a single flat budget would make every long
    /// transcript time out and silently come back uncleaned.
    static let chunkBudget: TimeInterval = 12

    /// Ceiling for the whole call, so a pathologically long transcript cannot
    /// hold up the paste indefinitely.
    static let maximumBudget: TimeInterval = 60

    static func budget(forChunks count: Int) -> TimeInterval {
        min(Double(max(count, 1)) * chunkBudget, maximumBudget)
    }

    /// Context window. S1-mini takes ~1,000 input tokens at most (longer
    /// transcripts are chunked), so 2048 leaves room for prompt plus output
    /// while keeping the KV cache small.
    private static let contextTokens: UInt32 = 2048

    private static let backendReady: Bool = {
        llama_log_set({ level, text, _ in
            // llama.cpp narrates model loading on stderr. Keep the noise out of
            // the app log and forward only real problems.
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            debugLog("[llama.cpp] \(message)")
        }, nil)
        llama_backend_init()
        // Safety net for exit paths that skip `applicationWillTerminate`.
        // atexit handlers run before the C++ static destructors registered when
        // the library loaded, so this frees the context in time.
        atexit { LlamaHandles.shared.unload() }
        return true
    }()

    /// Releases the model synchronously. Must run before the process exits —
    /// see `LlamaHandles`. Safe to call when nothing is loaded.
    nonisolated static func shutdownForTermination() {
        LlamaHandles.shared.unload()
    }

    nonisolated static var isLoaded: Bool { LlamaHandles.shared.isLoaded }

    var isLoaded: Bool { LlamaHandles.shared.isLoaded }

    // MARK: - Lifecycle

    /// Loads the model if it isn't already resident. Safe to call repeatedly.
    func warmUp() throws {
        try ensureLoaded()
    }

    func unload() {
        LlamaHandles.shared.unload()
    }

    private func ensureLoaded() throws {
        if LlamaHandles.shared.isLoaded { return }
        _ = Self.backendReady

        let modelURL = CleanupModelManager.modelFileURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalCleanupError.modelMissing
        }

        let loadStart = Date()
        try LlamaHandles.shared.load(
            modelPath: modelURL.path,
            contextTokens: Self.contextTokens,
            threads: Self.threadCount
        )
        let elapsed = Date().timeIntervalSince(loadStart)
        debugLog("[holdtotalk] Loaded \(S1MiniModelInfo.displayName) in \(String(format: "%.2f", elapsed))s")
    }

    private static var threadCount: Int32 {
        Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    // MARK: - Cleanup

    /// Normalizes a raw transcript. Long transcripts are chunked and the pieces
    /// rejoined. Throws rather than returning partial text so callers can fall
    /// back to the raw transcription.
    func cleanup(
        _ text: String,
        styling: CleanupStyling,
        structure: CleanupStructure
    ) throws -> String {
        let chunks = S1MiniPrompt.chunks(for: text)
        guard !chunks.isEmpty else { return text }

        try ensureLoaded()

        let deadline = Date().addingTimeInterval(Self.budget(forChunks: chunks.count))
        var pieces: [String] = []
        pieces.reserveCapacity(chunks.count)

        for chunk in chunks {
            try Task.checkCancellation()
            let prompt = S1MiniPrompt.build(
                transcript: chunk,
                styling: styling,
                structure: structure
            )
            let generated = try generate(prompt: prompt, deadline: deadline)
            pieces.append(S1MiniPrompt.sanitize(generated))
        }

        return S1MiniPrompt.join(pieces)
    }

    // MARK: - Generation

    private func generate(prompt: String, deadline: Date) throws -> String {
        try LlamaHandles.shared.withHandles { context, vocab in
            // Reset the KV cache so each chunk is an independent request.
            llama_memory_clear(llama_get_memory(context), true)

            var promptTokens = try Self.tokenize(prompt, vocab: vocab)
            guard !promptTokens.isEmpty else { throw LocalCleanupError.tokenizationFailed }
            guard promptTokens.count < Int(Self.contextTokens) - 64 else {
                throw LocalCleanupError.promptTooLong
            }

            let decodeStatus = promptTokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
                return llama_decode(context, batch)
            }
            guard decodeStatus == 0 else { throw LocalCleanupError.decodeFailed }

            guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
                throw LocalCleanupError.decodeFailed
            }
            defer { llama_sampler_free(sampler) }
            // The model card measures its accuracy with greedy decoding.
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

            let maxNewTokens = Int(Self.contextTokens) - promptTokens.count
            // Collect raw bytes: a multi-byte character can straddle two tokens,
            // so decoding piece by piece would produce replacement characters.
            var outputBytes: [UInt8] = []
            var generated = 0

            while generated < maxNewTokens {
                try Task.checkCancellation()
                if LlamaHandles.shared.shutdownRequested {
                    throw LocalCleanupError.shuttingDown
                }
                if Date() >= deadline {
                    debugLog("[holdtotalk] Local cleanup hit its time budget after \(generated) tokens")
                    throw LocalCleanupError.decodeFailed
                }

                var token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }

                outputBytes.append(contentsOf: Self.piece(for: token, vocab: vocab))
                generated += 1

                let status = withUnsafeMutablePointer(to: &token) { pointer -> Int32 in
                    llama_decode(context, llama_batch_get_one(pointer, 1))
                }
                guard status == 0 else { throw LocalCleanupError.decodeFailed }
            }

            return String(decoding: outputBytes, as: UTF8.self)
        }
    }

    private static func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        // Worst case is one token per byte, plus room for the control tokens.
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)

        let count = tokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
            llama_tokenize(
                vocab,
                text,
                utf8Count,
                buffer.baseAddress,
                Int32(buffer.count),
                false,  // add_special: Qwen3 has no BOS and the prompt is already wrapped
                true    // parse_special: <|im_start|> and friends must be real tokens
            )
        }

        guard count > 0 else { throw LocalCleanupError.tokenizationFailed }
        tokens.removeSubrange(Int(count)...)
        return tokens
    }

    private static func piece(for token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)

        if written < 0 {
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            guard written > 0 else { return [] }
        }

        return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }
}
