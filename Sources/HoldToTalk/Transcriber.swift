import Foundation

enum TranscriptionProfile: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case best

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .best: return "Best Quality"
        }
    }

    var summary: String {
        switch self {
        case .fast:
            return "Fastest transcription using all CPU cores."
        case .balanced:
            return "Recommended default balancing speed and CPU usage."
        case .best:
            return "Lower thread count, may yield slightly better quality on some systems."
        }
    }

    var numThreads: Int {
        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        switch self {
        case .fast: return min(12, cores)
        case .balanced: return max(2, min(cores / 2, 8))
        case .best: return max(2, min(cores / 2, 4))
        }
    }
}

/// Local speech-to-text via sherpa-onnx with NVIDIA Parakeet TDT model.
/// Actor isolation eliminates data races on the mutable recognizer property.
actor Transcriber {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var loadTask: Task<SherpaOnnxOfflineRecognizer, Error>?
    private var hasCompletedDecodeWarmup = false
    private var currentHotwords: String = ""

    func loadModel(numThreads: Int = 4, hotwords: String = "") async throws {
        // If hotwords changed, recreate the recognizer
        if recognizer != nil && hotwords != currentHotwords {
            print("[transcriber] Hotwords changed, recreating recognizer...")
            recognizer = nil
            hasCompletedDecodeWarmup = false
        }

        guard recognizer == nil else { return }

        if let loadTask {
            recognizer = try await loadTask.value
            return
        }

        currentHotwords = hotwords
        print("[transcriber] Loading Parakeet TDT 0.6B...")
        let task = Task { [currentHotwords] in
            try createRecognizer(numThreads: numThreads, hotwords: currentHotwords)
        }
        loadTask = task
        defer { loadTask = nil }

        recognizer = try await task.value
        print("[transcriber] Ready.")
    }

    func prepareForFirstTranscription(profile: TranscriptionProfile = .balanced, hotwords: String = "") async throws {
        if hasCompletedDecodeWarmup && hotwords == currentHotwords {
            return
        }

        try await loadModel(numThreads: profile.numThreads, hotwords: hotwords)
        guard let recognizer, !hasCompletedDecodeWarmup else { return }

        print("[transcriber] Running decode warm-up...")
        let silence = Array(repeating: Float(0), count: 16000) // 1 second of silence
        _ = recognizer.decode(samples: silence, sampleRate: 16000)
        hasCompletedDecodeWarmup = true
        print("[transcriber] Decode warm-up complete.")
    }

    /// Transcribe 16 kHz mono float audio to text.
    func transcribe(_ audio: [Float], profile: TranscriptionProfile = .balanced, hotwords: String = "") async throws -> String {
        if recognizer == nil || hotwords != currentHotwords {
            try await loadModel(numThreads: profile.numThreads, hotwords: hotwords)
        }
        guard let recognizer, !audio.isEmpty else { return "" }

        let normalized = Self.normalizeAudio(audio)

        // Use Silero VAD to extract speech segments to strip silence
        // and avoid transducer looping on very long audio.
        let segments = Self.extractSpeechSegments(normalized)
        let segInfo = segments.map { String(format: "%.1fs", Float($0.count) / 16000.0) }
        NSLog("[holdtotalk] VAD produced %d segments: %@", segments.count, segInfo.description)
        debugLog("[holdtotalk] VAD produced \(segments.count) segments: \(segInfo)")
        guard !segments.isEmpty else { return "" }

        var parts: [String] = []
        for (i, segment) in segments.enumerated() {
            let result = recognizer.decode(samples: segment, sampleRate: 16000)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("[holdtotalk] Segment \(i) (\(String(format: "%.1fs", Float(segment.count) / 16000.0))): \(text.count) chars")
            if !text.isEmpty {
                parts.append(text)
            }
        }
        guard !parts.isEmpty else { return "" }
        let joined = parts.joined(separator: " ")
        let final = Self.deduplicateRepeatedPhrases(joined)
        return final
    }

    /// Uses Silero VAD to extract speech segments from audio.
    /// Each segment contains only speech (no silence padding) and is
    /// capped at maxSpeechDuration (15s) to prevent transducer looping on very long audio.
    static func extractSpeechSegments(_ audio: [Float], sampleRate: Int = 16000) -> [[Float]] {
        guard !audio.isEmpty else { return [] }

        // Try the app's Contents/Resources path first (avoids Bundle.module fatalError in .app bundles),
        // then fall back to Bundle.module for debug/SwiftPM builds.
        let vadModelPath: String
        let appResourcePath = Bundle.main.bundlePath + "/Contents/Resources/HoldToTalk_HoldToTalk.bundle/silero_vad.onnx"
        if FileManager.default.fileExists(atPath: appResourcePath) {
            vadModelPath = appResourcePath
            NSLog("[holdtotalk] VAD model found via app Resources: %@", appResourcePath)
        } else if let bundlePath = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx")?.path {
            vadModelPath = bundlePath
            NSLog("[holdtotalk] VAD model found via Bundle.module: %@", bundlePath)
        } else {
            NSLog("[holdtotalk] WARNING: silero_vad.onnx not found. App path tried: %@",
                  appResourcePath)
            return splitAtSilenceGaps(audio, sampleRate: sampleRate)
        }

        let sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: vadModelPath,
            threshold: 0.45,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 15.0
        )
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: Int32(sampleRate),
            numThreads: 1,
            provider: "cpu"
        )

        guard let vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig,
            buffer_size_in_seconds: 120
        ) else {
            NSLog("[holdtotalk] WARNING: Failed to create VAD. Falling back to silence-gap splitting.")
            return splitAtSilenceGaps(audio, sampleRate: sampleRate)
        }

        // Feed audio in windowSize chunks as required by Silero VAD
        let windowSize = 512
        var offset = 0
        while offset + windowSize <= audio.count {
            let chunk = Array(audio[offset..<(offset + windowSize)])
            vad.acceptWaveform(samples: chunk)
            offset += windowSize
        }
        // Flush any remaining audio
        vad.flush()

        // Collect all speech segments
        var segments: [[Float]] = []
        while !vad.isEmpty() {
            let segment = vad.front()
            if segment.n > 0 {
                segments.append(segment.samples)
            }
            vad.pop()
        }

        // If VAD found nothing (e.g., very quiet speech), fall back
        if segments.isEmpty {
            let trimmed = trimSilence(audio, sampleRate: sampleRate)
            if !trimmed.isEmpty {
                return splitAtSilenceGaps(trimmed, sampleRate: sampleRate)
            }
        }

        return segments
    }

    // MARK: - Audio Preprocessing

    /// Trims leading and trailing silence from audio.
    /// Scans in 100ms windows to find the first and last speech activity,
    /// then returns audio between those points with a small buffer.
    static func trimSilence(_ audio: [Float], sampleRate: Int = 16000) -> [Float] {
        guard !audio.isEmpty else { return audio }
        let windowSize = sampleRate / 10  // 100ms
        let threshold: Float = 0.01       // RMS threshold for speech vs silence
        let bufferSamples = sampleRate / 10 // 100ms buffer on each side

        // Find first speech window (scan forward)
        var firstSpeechStart = 0
        var offset = 0
        while offset < audio.count {
            let end = min(offset + windowSize, audio.count)
            let window = audio[offset..<end]
            let rms = sqrtf(window.reduce(0) { $0 + $1 * $1 } / Float(window.count))
            if rms > threshold {
                firstSpeechStart = max(0, offset - bufferSamples)
                break
            }
            offset = end
        }
        // If no speech found at all, return empty
        guard offset < audio.count else { return [] }

        // Find last speech window (scan backward)
        var lastSpeechEnd = audio.count
        offset = audio.count
        while offset > firstSpeechStart {
            let start = max(firstSpeechStart, offset - windowSize)
            let window = audio[start..<offset]
            let rms = sqrtf(window.reduce(0) { $0 + $1 * $1 } / Float(window.count))
            if rms > threshold {
                lastSpeechEnd = min(offset + bufferSamples, audio.count)
                break
            }
            offset = start
        }

        return Array(audio[firstSpeechStart..<lastSpeechEnd])
    }

    /// Peak-normalizes audio to use the full [-1, 1] range.
    /// Consistent levels help the mel feature extractor and prevent the
    /// transducer from misinterpreting quiet audio as silence.
    static func normalizeAudio(_ audio: [Float]) -> [Float] {
        guard !audio.isEmpty else { return audio }
        let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.001 else { return audio } // essentially silent
        let gain = min(1.0 / peak, 10.0) // cap gain at 10x to avoid amplifying noise
        return audio.map { $0 * gain }
    }

    /// Splits audio into segments at silence gaps longer than 600ms.
    /// Prevents transducer models from looping on long continuous audio.
    /// Short recordings (< 8s) are returned as a single segment.
    static func splitAtSilenceGaps(_ audio: [Float], sampleRate: Int = 16000) -> [[Float]] {
        let maxSingleSegment = sampleRate * 8 // 8 seconds
        guard audio.count > maxSingleSegment else { return [audio] }

        let windowSize = sampleRate / 10       // 100ms analysis window
        let threshold: Float = 0.01            // RMS threshold
        let minGapWindows = 6                  // 600ms of silence = a gap
        let minSegmentSamples = sampleRate * 2 // minimum 2s segment

        // Classify each window as speech or silence
        var silenceRuns: [(start: Int, end: Int)] = []
        var currentSilenceStart: Int? = nil
        var consecutiveSilent = 0
        var offset = 0

        while offset < audio.count {
            let end = min(offset + windowSize, audio.count)
            let window = audio[offset..<end]
            let rms = sqrtf(window.reduce(0) { $0 + $1 * $1 } / Float(window.count))

            if rms <= threshold {
                if currentSilenceStart == nil { currentSilenceStart = offset }
                consecutiveSilent += 1
            } else {
                if let start = currentSilenceStart, consecutiveSilent >= minGapWindows {
                    silenceRuns.append((start: start, end: offset))
                }
                currentSilenceStart = nil
                consecutiveSilent = 0
            }
            offset = end
        }

        // No suitable gaps found -- return as single segment
        guard !silenceRuns.isEmpty else { return [audio] }

        // Split at the silence midpoints
        var segments: [[Float]] = []
        var segStart = 0
        for gap in silenceRuns {
            let splitPoint = (gap.start + gap.end) / 2
            if splitPoint - segStart >= minSegmentSamples {
                segments.append(Array(audio[segStart..<splitPoint]))
                segStart = splitPoint
            }
        }
        // Add remaining audio
        if segStart < audio.count {
            let remaining = Array(audio[segStart...])
            if remaining.count >= minSegmentSamples || segments.isEmpty {
                segments.append(remaining)
            } else if !segments.isEmpty {
                // Merge short tail into last segment
                segments[segments.count - 1].append(contentsOf: remaining)
            }
        }

        return segments
    }

    /// Removes repeated phrases that speech models sometimes hallucinate.
    ///
    /// **Pass 1** splits on sentence-ending punctuation (`.` `!` `?`) and removes
    /// consecutive duplicate clauses. Comparison ignores trailing punctuation and
    /// whitespace so `"I love dogs. I love dogs"` is still caught.
    ///
    /// **Pass 2** drops a trailing sentence whose last 2+ words match the tail of
    /// the previous sentence -- catches garbled suffix echoes like
    /// `"more changes? ore changes?"`.
    ///
    /// **Pass 3** collapses runs of 3+ identical consecutive words into one,
    /// preserving legitimate pairs like "that that" or "had had".
    ///
    /// **Pass 4** detects repeated multi-word n-gram loops where a phrase of 3-8
    /// words repeats consecutively (e.g. "part of the sentence part of the sentence").
    static func deduplicateRepeatedPhrases(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // --- Pass 1: sentence-level dedup (splits on . ! ?) ---
        let sentenceDelimiters: Set<Character> = [".", "!", "?"]
        let sentences: [String] = {
            var result: [String] = []
            var search = text.startIndex
            while search < text.endIndex {
                if let delimIdx = text[search...].firstIndex(where: { sentenceDelimiters.contains($0) }) {
                    let end = text.index(after: delimIdx)
                    var trailing = end
                    while trailing < text.endIndex && text[trailing].isWhitespace {
                        trailing = text.index(after: trailing)
                    }
                    result.append(String(text[search..<trailing]))
                    search = trailing
                } else {
                    result.append(String(text[search...]))
                    break
                }
            }
            return result
        }()

        var deduped: [String] = []
        for sentence in sentences {
            let normalized = sentence
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            if let last = deduped.last {
                let lastNormalized = last
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased()
                if lastNormalized == normalized { continue }
            }
            deduped.append(sentence)
        }

        // --- Pass 2: suffix-overlap trailing fragment removal ---
        // If the last sentence is shorter than the previous one, and its
        // tail words match the tail of the previous sentence, it's a
        // hallucinated echo (e.g. "more changes? ore changes?").
        while deduped.count >= 2 {
            let lastWords = normalizedWords(deduped[deduped.count - 1])
            let prevWords = normalizedWords(deduped[deduped.count - 2])

            // Only consider trailing fragments shorter than the previous sentence
            guard lastWords.count < prevWords.count else { break }

            // Very short fragments (1 char words like "e.") are likely garbage
            if lastWords.count <= 1 && deduped[deduped.count - 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters).count <= 2 {
                deduped.removeLast()
                continue
            }

            // Check if the last N words of the trailing sentence match
            // the last N words of the previous sentence (N >= 2).
            // Try from largest overlap down to 2 to handle garbled prefixes
            // like "s to complete" where "s" is a fragment of "minutes".
            let maxOverlap = min(lastWords.count, prevWords.count)
            var matched = false
            for overlapLen in stride(from: maxOverlap, through: 2, by: -1) {
                let trailingTail = Array(lastWords.suffix(overlapLen))
                let prevTail = Array(prevWords.suffix(overlapLen))
                if trailingTail == prevTail {
                    deduped.removeLast()
                    matched = true
                    break
                }
            }
            if matched { continue }
            break
        }

        var result = deduped.joined()

        // --- Pass 3: collapse runs of 3+ identical consecutive words ---
        let words = result.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 2 else { return result.trimmingCharacters(in: .whitespacesAndNewlines) }

        var dedupedWords: [String] = []
        var runCount = 1
        for i in 1...words.count {
            let prev = words[i - 1]
            let curr = i < words.count ? words[i] : nil
            if let curr, curr.lowercased() == prev.lowercased() {
                runCount += 1
            } else {
                dedupedWords.append(prev)
                if runCount == 2 {
                    dedupedWords.append(prev)
                }
                runCount = 1
            }
        }
        result = dedupedWords.joined(separator: " ")

        // --- Pass 4: n-gram loop detection (phrases of 3-8 words) ---
        result = collapseRepeatedNGrams(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detects and collapses repeated multi-word n-gram loops.
    /// Scans for n-grams of length 3..8 that repeat 2+ times consecutively
    /// and replaces them with a single occurrence.
    static func collapseRepeatedNGrams(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 6 else { return text } // need at least 2x3 words

        // Try largest n-grams first so we catch the longest repeating unit
        for n in stride(from: min(8, words.count / 2), through: 3, by: -1) {
            var i = 0
            var changed = false
            while i + n <= words.count {
                let phrase = words[i..<(i + n)].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                var repeatCount = 1
                var j = i + n
                while j + n <= words.count {
                    let next = words[j..<(j + n)].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                    if next == phrase {
                        repeatCount += 1
                        j += n
                    } else {
                        break
                    }
                }
                if repeatCount >= 2 {
                    // Remove the duplicate repetitions, keep the first occurrence
                    let removeStart = i + n
                    let removeEnd = i + n * repeatCount
                    words.removeSubrange(removeStart..<removeEnd)
                    changed = true
                    // Don't advance i -- re-check from same position
                } else {
                    i += 1
                }
            }
            if changed {
                // Restart from largest n-gram after a change
                break
            }
        }
        return words.joined(separator: " ")
    }

    /// Extracts lowercased words with punctuation stripped for comparison.
    private static func normalizedWords(_ sentence: String) -> [String] {
        sentence
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Private

    private func createRecognizer(numThreads: Int, hotwords: String = "") throws -> SherpaOnnxOfflineRecognizer {
        let modelDir = ModelManager.modelBase
            .appendingPathComponent(SpeechModelInfo.modelDirectoryName).path

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: modelDir + "/encoder.int8.onnx",
            decoder: modelDir + "/decoder.int8.onnx",
            joiner: modelDir + "/joiner.int8.onnx"
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: modelDir + "/tokens.txt",
            transducer: transducer,
            numThreads: numThreads,
            provider: "cpu",
            modelType: "nemo_transducer"
        )
        let featConfig = sherpaOnnxFeatureConfig(
            sampleRate: 16000,
            featureDim: 128
        )

        let trimmedHotwords = hotwords.trimmingCharacters(in: .whitespacesAndNewlines)
        let hotwordsFilePath: String
        let decodingMethod: String

        if !trimmedHotwords.isEmpty {
            let hotwordsURL = ModelManager.modelBase.appendingPathComponent("hotwords.txt")
            try trimmedHotwords.write(to: hotwordsURL, atomically: true, encoding: .utf8)
            hotwordsFilePath = hotwordsURL.path
            decodingMethod = "modified_beam_search"
            let entryCount = trimmedHotwords.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            print("[transcriber] Hotwords enabled (\(entryCount) entries), using modified_beam_search")
        } else {
            hotwordsFilePath = ""
            decodingMethod = "greedy_search"
            print("[transcriber] No hotwords, using greedy_search")
        }

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: decodingMethod,
            hotwordsFile: hotwordsFilePath,
            hotwordsScore: 1.5,
            blankPenalty: 2.0
        )
        guard let recognizer = SherpaOnnxOfflineRecognizer(config: &config) else {
            throw TranscriberError.modelLoadFailed
        }
        return recognizer
    }
}

enum TranscriberError: LocalizedError {
    case modelLoadFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load speech recognition model. The model files may be corrupt — try deleting and re-downloading."
        }
    }
}
