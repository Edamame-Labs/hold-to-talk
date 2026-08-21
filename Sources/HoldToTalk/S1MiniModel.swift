import Foundation

/// Metadata for the on-device cleanup model (Superwhisper S1-mini, GGUF build).
///
/// S1-mini is a 0.6B Qwen3 fine-tune that does exactly one job: turn a raw ASR
/// transcript into clean written text. It is not a chat model and ignores
/// free-form instructions — steering happens through the control line built by
/// `S1MiniPrompt`.
struct S1MiniModelInfo {
    static let id = "s1-mini-q4_k_m"
    static let displayName = "S1-mini"
    /// The licence's additional term requires the model to be identified as
    /// "S1-mini" by "Superwhisper", with that exact capitalization, wherever it
    /// is used or integrated. Use this on user-facing surfaces.
    static let attributedName = "S1-mini by Superwhisper"
    static let sizeLabel = "~462 MB"
    static let fileName = "s1-mini-q4_k_m.gguf"
    static let englishOnly = true
    static let languageSummary = "English only"

    /// Pinned to a specific repository revision so the checksum below stays valid.
    static let revision = "8eab4779866f477ae6e7f237ca45fc2c65153f50"

    static let downloadURL = URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/\(revision)/\(fileName)")!

    /// SHA-256 of the GGUF file for integrity verification after download.
    static let expectedSHA256 = "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    static let expectedByteCount: Int64 = 484_219_808

    static let modelCardURL = URL(string: "https://huggingface.co/superwhisper/s1-mini")!
    static let ggufURL = URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF")!
    static let llamaCppURL = URL(string: "https://github.com/ggml-org/llama.cpp")!
    static let superwhisperURL = URL(string: "https://superwhisper.com")!

    static let trustSummary = "Runs fully on your Mac after download. Hold to Talk downloads Superwhisper's S1-mini (0.6B, 4-bit quantized) from Hugging Face and runs it locally with llama.cpp. It is a text normalizer trained only to clean up transcripts — English-only, and it never sees the network."
}

// MARK: - Control Line Settings

/// Register the cleaned text is written in. Values must match the strings the
/// model was trained on exactly; anything else makes it hallucinate.
enum CleanupStyling: String, CaseIterable, Identifiable, Sendable {
    case casual = "casual"
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal = "formal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .casual:     return "Casual"
        case .semiCasual: return "Semi-casual"
        case .semiFormal: return "Semi-formal"
        case .formal:     return "Formal"
        }
    }

    var summary: String {
        switch self {
        case .casual:     return "All lowercase, no apostrophes, slang kept."
        case .semiCasual: return "Speaker's phrasing kept, only \"I\" capitalized."
        case .semiFormal: return "Standard written English. Contractions kept."
        case .formal:     return "Standard written English with contractions expanded."
        }
    }
}

/// Whether the model may reflow enumerable content into Markdown bullets.
enum CleanupStructure: String, CaseIterable, Identifiable, Sendable {
    case prose = "prose"
    case lists = "lists"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .prose: return "Prose"
        case .lists: return "Allow lists"
        }
    }

    var summary: String {
        switch self {
        case .prose: return "Always sentences and paragraphs."
        case .lists: return "May turn three or more enumerated items into bullets."
        }
    }
}

// MARK: - Prompt Construction

/// Builds the exact prompt format S1-mini was trained on.
///
/// The system prompt and control line are part of the input format, not
/// suggestions: changing their wording, or sending control values outside the
/// trained sets, produces garbled output. The assistant prefix carries an empty
/// think block because the model was trained with Qwen3 thinking disabled —
/// omitting it yields an empty response.
enum S1MiniPrompt {
    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    /// Destination conventions. `email` reshapes the transcript into greeting /
    /// body / sign-off blocks, which is wrong for general dictation, so Hold to
    /// Talk always sends `general`.
    static let context = "general"

    /// Roughly 1,000 input tokens is the model's recommended ceiling. English
    /// runs about 1.3 tokens per word, and the wrapper costs ~60 tokens, so 400
    /// words per chunk leaves comfortable headroom.
    static let maxWordsPerChunk = 400

    static func controlLine(styling: CleanupStyling, structure: CleanupStructure) -> String {
        "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context)]"
    }

    static func build(
        transcript: String,
        styling: CleanupStyling,
        structure: CleanupStructure
    ) -> String {
        let control = controlLine(styling: styling, structure: structure)
        return """
            <|im_start|>system
            \(systemPrompt)<|im_end|>
            <|im_start|>user
            \(control)
            \(transcript)<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """
    }

    /// Splits a long transcript into model-sized pieces, preferring sentence
    /// boundaries so each chunk stays independently cleanable.
    static func chunks(for transcript: String, maxWords: Int = maxWordsPerChunk) -> [String] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard maxWords > 0 else { return [trimmed] }
        guard trimmed.split(whereSeparator: \.isWhitespace).count > maxWords else { return [trimmed] }

        var chunks: [String] = []
        var current: [String] = []

        for sentence in sentences(in: trimmed) {
            let sentenceWords = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !sentenceWords.isEmpty else { continue }

            // A single sentence longer than the budget gets split on word count.
            if sentenceWords.count > maxWords {
                if !current.isEmpty {
                    chunks.append(current.joined(separator: " "))
                    current = []
                }
                var start = 0
                while start < sentenceWords.count {
                    let end = min(start + maxWords, sentenceWords.count)
                    chunks.append(sentenceWords[start..<end].joined(separator: " "))
                    start = end
                }
                continue
            }

            if current.count + sentenceWords.count > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
            }
            current.append(contentsOf: sentenceWords)
        }

        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result.isEmpty ? [text] : result
    }

    /// Strips control tokens or a stray think block if the model leaks them.
    static func sanitize(_ output: String) -> String {
        var result = output

        if let thinkEnd = result.range(of: "</think>") {
            result = String(result[thinkEnd.upperBound...])
        }
        for token in ["<|im_start|>", "<|im_end|>", "<|endoftext|>", "<think>", "</think>"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        // "assistant" can survive as the role name of a leaked turn header.
        if result.hasPrefix("assistant\n") {
            result.removeFirst("assistant\n".count)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rejoins per-chunk output. Chunks that normalize to nothing (pure filler)
    /// are dropped rather than contributing blank lines.
    static func join(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
