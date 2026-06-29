#!/usr/bin/swift
/// TranscribeCmd - CLI tool for testing the sherpa-onnx transcription pipeline.
///
/// Usage:
///   TranscribeCmd <wav-file>              # transcribe a single WAV file
///   TranscribeCmd --batch <dir>           # transcribe all .wav files in a directory
///   TranscribeCmd --record <output.wav>   # record from mic, save, then transcribe
///
/// The tool uses the exact same model config, VAD, preprocessing, and deduplication
/// as the HoldToTalk app, so results here match what the app would produce.

import AVFoundation
import Foundation
import sherpa_onnx

// MARK: - Configuration (mirrors Transcriber.swift)

let modelBase: URL = {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return appSupport.appendingPathComponent("HoldToTalk/models")
}()

let modelDirName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
let vadModelPath: String = {
    // Try several known locations for silero_vad.onnx
    let candidates = [
        Bundle.main.bundlePath + "/Contents/Resources/HoldToTalk_HoldToTalk.bundle/silero_vad.onnx",
        Bundle.main.bundlePath + "/HoldToTalk_HoldToTalk.bundle/silero_vad.onnx",
        // Sources directory (dev convenience)
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HoldToTalk/Resources/silero_vad.onnx").path,
        // Built resource bundle fallback
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("HoldToTalk_HoldToTalk.bundle/silero_vad.onnx").path,
    ]
    for path in candidates {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return ""
}()

// MARK: - Recognizer Setup

func createRecognizer(numThreads: Int = 4) -> SherpaOnnxOfflineRecognizer {
    let modelDir = modelBase.appendingPathComponent(modelDirName).path

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
    var config = sherpaOnnxOfflineRecognizerConfig(
        featConfig: featConfig,
        modelConfig: modelConfig,
        blankPenalty: 2.0
    )
    guard let recognizer = SherpaOnnxOfflineRecognizer(config: &config) else {
        fatalError("Failed to create SherpaOnnxOfflineRecognizer")
    }
    return recognizer
}

// MARK: - Audio Preprocessing (mirrors Transcriber.swift exactly)

func normalizeAudio(_ audio: [Float]) -> [Float] {
    guard !audio.isEmpty else { return audio }
    let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
    guard peak > 0.001 else { return audio }
    let gain = min(1.0 / peak, 10.0)
    return audio.map { $0 * gain }
}

func trimSilence(_ audio: [Float], sampleRate: Int = 16000) -> [Float] {
    guard !audio.isEmpty else { return audio }
    let windowSize = sampleRate / 10
    let threshold: Float = 0.01
    let bufferSamples = sampleRate / 10

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
    guard offset < audio.count else { return [] }

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

func splitAtSilenceGaps(_ audio: [Float], sampleRate: Int = 16000) -> [[Float]] {
    let maxSingleSegment = sampleRate * 8
    guard audio.count > maxSingleSegment else { return [audio] }

    let windowSize = sampleRate / 10
    let threshold: Float = 0.01
    let minGapWindows = 6
    let minSegmentSamples = sampleRate * 2

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

    guard !silenceRuns.isEmpty else { return [audio] }

    var segments: [[Float]] = []
    var segStart = 0
    for gap in silenceRuns {
        let splitPoint = (gap.start + gap.end) / 2
        if splitPoint - segStart >= minSegmentSamples {
            segments.append(Array(audio[segStart..<splitPoint]))
            segStart = splitPoint
        }
    }
    if segStart < audio.count {
        let remaining = Array(audio[segStart...])
        if remaining.count >= minSegmentSamples || segments.isEmpty {
            segments.append(remaining)
        } else if !segments.isEmpty {
            segments[segments.count - 1].append(contentsOf: remaining)
        }
    }
    return segments
}

func extractSpeechSegments(_ audio: [Float], sampleRate: Int = 16000, useVAD: Bool = true)
    -> [[Float]]
{
    guard !audio.isEmpty else { return [] }

    guard useVAD, !vadModelPath.isEmpty else {
        fputs("[info] Using simple silence-based splitting\n", stderr)
        let trimmed = trimSilence(audio, sampleRate: sampleRate)
        if !trimmed.isEmpty {
            return splitAtSilenceGaps(trimmed, sampleRate: sampleRate)
        }
        return [audio]
    }

    let sileroConfig = sherpaOnnxSileroVadModelConfig(
        model: vadModelPath,
        threshold: 0.5,
        minSilenceDuration: 0.25,
        minSpeechDuration: 0.25,
        windowSize: 512,
        maxSpeechDuration: 3.0
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
        fputs("[warning] Failed to create VAD. Falling back to silence-based splitting.\n", stderr)
        let trimmed = trimSilence(audio, sampleRate: sampleRate)
        if !trimmed.isEmpty {
            return splitAtSilenceGaps(trimmed, sampleRate: sampleRate)
        }
        return [audio]
    }

    let windowSize = 512
    var offset = 0
    while offset + windowSize <= audio.count {
        let chunk = Array(audio[offset..<(offset + windowSize)])
        vad.acceptWaveform(samples: chunk)
        offset += windowSize
    }
    vad.flush()

    var segments: [[Float]] = []
    while !vad.isEmpty() {
        let segment = vad.front()
        if segment.n > 0 {
            segments.append(segment.samples)
        }
        vad.pop()
    }

    if segments.isEmpty {
        let trimmed = trimSilence(audio, sampleRate: sampleRate)
        if !trimmed.isEmpty {
            return splitAtSilenceGaps(trimmed, sampleRate: sampleRate)
        }
    }

    return segments
}

// MARK: - Text Deduplication (mirrors Transcriber.swift exactly)

func normalizedWords(_ sentence: String) -> [String] {
    sentence
        .split(separator: " ", omittingEmptySubsequences: true)
        .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        .filter { !$0.isEmpty }
}

func collapseRepeatedNGrams(_ text: String) -> String {
    var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count >= 6 else { return text }

    for n in stride(from: min(8, words.count / 2), through: 3, by: -1) {
        var i = 0
        var changed = false
        while i + n <= words.count {
            let phrase = words[i..<(i + n)].map {
                $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
            }
            var repeatCount = 1
            var j = i + n
            while j + n <= words.count {
                let next = words[j..<(j + n)].map {
                    $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
                }
                if next == phrase {
                    repeatCount += 1
                    j += n
                } else {
                    break
                }
            }
            if repeatCount >= 2 {
                let removeStart = i + n
                let removeEnd = i + n * repeatCount
                words.removeSubrange(removeStart..<removeEnd)
                changed = true
            } else {
                i += 1
            }
        }
        if changed { break }
    }
    return words.joined(separator: " ")
}

func deduplicateRepeatedPhrases(_ text: String) -> String {
    guard !text.isEmpty else { return text }

    let sentenceDelimiters: Set<Character> = [".", "!", "?"]
    let sentences: [String] = {
        var result: [String] = []
        var search = text.startIndex
        while search < text.endIndex {
            if let delimIdx = text[search...].firstIndex(where: { sentenceDelimiters.contains($0) })
            {
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
        let normalized =
            sentence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        if let last = deduped.last {
            let lastNormalized =
                last
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            if lastNormalized == normalized { continue }
        }
        deduped.append(sentence)
    }

    while deduped.count >= 2 {
        let lastWords = normalizedWords(deduped[deduped.count - 1])
        let prevWords = normalizedWords(deduped[deduped.count - 2])
        guard lastWords.count < prevWords.count else { break }
        if lastWords.count <= 1
            && deduped[deduped.count - 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters).count <= 2
        {
            deduped.removeLast()
            continue
        }
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

    let words = result.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count > 2 else {
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    result = collapseRepeatedNGrams(result)

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Transcription Pipeline

func transcribe(
    _ audio: [Float], recognizer: SherpaOnnxOfflineRecognizer, verbose: Bool = false,
    useVAD: Bool = true
) -> String {
    let normalized = normalizeAudio(audio)
    let segments = extractSpeechSegments(normalized, useVAD: useVAD)

    if verbose {
        let segInfo = segments.map { String(format: "%.1fs", Float($0.count) / 16000.0) }
        fputs("  VAD segments: \(segments.count) \(segInfo)\n", stderr)
    }

    guard !segments.isEmpty else { return "" }

    var parts: [String] = []
    for (i, segment) in segments.enumerated() {
        let result = recognizer.decode(samples: segment, sampleRate: 16000)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if verbose {
            fputs(
                "  Seg \(i) (\(String(format: "%.1fs", Float(segment.count) / 16000.0))): \"\(text)\"\n",
                stderr)
        }
        if !text.isEmpty {
            parts.append(text)
        }
    }

    guard !parts.isEmpty else { return "" }
    let joined = parts.joined(separator: " ")
    let final = deduplicateRepeatedPhrases(joined)

    if verbose && final != joined {
        fputs("  Dedup: \"\(joined)\" -> \"\(final)\"\n", stderr)
    }

    return final
}

// MARK: - WAV Reading

func readWav(_ path: String) -> (samples: [Float], sampleRate: Int)? {
    let wave = SherpaOnnxWaveWrapper.readWave(filename: path)
    guard wave.numSamples > 0 else {
        fputs("Error: could not read WAV file: \(path)\n", stderr)
        return nil
    }
    return (wave.samples, wave.sampleRate)
}

/// Resample audio from sourceSR to targetSR using linear interpolation.
func resample(_ samples: [Float], from sourceSR: Int, to targetSR: Int) -> [Float] {
    guard sourceSR != targetSR, !samples.isEmpty else { return samples }
    let ratio = Double(targetSR) / Double(sourceSR)
    let newCount = Int(Double(samples.count) * ratio)
    var resampled = [Float](repeating: 0, count: newCount)
    for i in 0..<newCount {
        let srcIdx = Double(i) / ratio
        let lo = Int(srcIdx)
        let hi = min(lo + 1, samples.count - 1)
        let frac = Float(srcIdx - Double(lo))
        resampled[i] = samples[lo] * (1 - frac) + samples[hi] * frac
    }
    return resampled
}

// MARK: - Recording

func recordFromMic(outputPath: String, verbose: Bool) -> Bool {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let hwFormat = inputNode.outputFormat(forBus: 0)

    guard hwFormat.sampleRate > 0 else {
        fputs("Error: no microphone available\n", stderr)
        return false
    }

    var allBuffers: [AVAudioPCMBuffer] = []
    let lock = NSLock()

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
        lock.lock()
        allBuffers.append(buffer)
        lock.unlock()
    }

    do {
        try engine.start()
    } catch {
        fputs("Error starting audio engine: \(error)\n", stderr)
        return false
    }

    fputs("Recording... press ENTER to stop.\n", stderr)
    _ = readLine()
    engine.stop()
    inputNode.removeTap(onBus: 0)

    // Combine all buffers into a single float array
    var allSamples: [Float] = []
    lock.lock()
    for buffer in allBuffers {
        guard let channelData = buffer.floatChannelData else { continue }
        let frameCount = Int(buffer.frameLength)
        // Take first channel only (mono)
        allSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
    lock.unlock()

    // Resample to 16kHz if needed
    let sourceSR = Int(hwFormat.sampleRate)
    let samples16k = resample(allSamples, from: sourceSR, to: 16000)

    if verbose {
        let duration = Float(samples16k.count) / 16000.0
        fputs("  Recorded \(String(format: "%.1f", duration))s (\(sourceSR)Hz -> 16kHz)\n", stderr)
    }

    // Write as 16kHz mono WAV using sherpa-onnx's wave writer
    let result = SherpaOnnxWriteWave(samples16k, Int32(samples16k.count), 16000, toCPointer(outputPath))
    if result == 0 {
        fputs("Error: failed to write WAV to \(outputPath)\n", stderr)
        return false
    }
    return true
}

// MARK: - WER Computation

func computeWER(reference: String, hypothesis: String) -> (errors: Int, words: Int, wer: Double) {
    func normalize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
    }

    let r = normalize(reference)
    let h = normalize(hypothesis)

    // Levenshtein distance on word arrays
    var d = Array(repeating: Array(repeating: 0, count: h.count + 1), count: r.count + 1)
    for i in 0...r.count { d[i][0] = i }
    for j in 0...h.count { d[0][j] = j }
    for i in 1...r.count {
        for j in 1...h.count {
            if r[i - 1] == h[j - 1] {
                d[i][j] = d[i - 1][j - 1]
            } else {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + 1)
            }
        }
    }

    let errors = d[r.count][h.count]
    let wer = r.isEmpty ? (h.isEmpty ? 0.0 : 1.0) : Double(errors) / Double(r.count)
    return (errors, r.count, wer)
}

// MARK: - JSON Output

struct TranscriptionResult: Codable {
    let file: String
    let reference: String?
    let hypothesis: String
    let wer: Double?
    let errors: Int?
    let refWords: Int?
    let segments: Int
    let audioDuration: Double
    let transcribeTime: Double
}

// MARK: - Main

func printUsage() {
    fputs(
        """
        Usage:
          TranscribeCmd <wav-file> [--ref "reference text"] [-v]
          TranscribeCmd --batch <dir> [--refs <refs.txt>] [-v]
          TranscribeCmd --record <output.wav> [--ref "reference text"] [-v]
          TranscribeCmd --interactive [-v]

        Options:
          --ref "text"    Reference text for WER computation
          --refs file     File with one reference per line (for --batch mode)
          -v, --verbose   Show per-segment details
          --json          Output results as JSON

        Interactive mode:
          Shows sentences one at a time. Press ENTER to start recording,
          ENTER again to stop. Results are saved to test_data/ directory.

        """, stderr)
}

// Parse arguments
var args = Array(CommandLine.arguments.dropFirst())
var verbose = false
var jsonOutput = false
var useVAD = true
var refText: String? = nil
var refsFile: String? = nil
var mode = "single"  // single, batch, record, interactive
var target = ""

// Extract flags
args = args.filter { arg in
    switch arg {
    case "-v", "--verbose": verbose = true; return false
    case "--json": jsonOutput = true; return false
    case "--no-vad": useVAD = false; return false
    default: return true
    }
}

// Parse mode and positional args
if args.isEmpty {
    printUsage()
    exit(1)
}

var i = 0
while i < args.count {
    switch args[i] {
    case "--batch":
        mode = "batch"
        i += 1
        if i < args.count { target = args[i] }
    case "--record":
        mode = "record"
        i += 1
        if i < args.count { target = args[i] }
    case "--interactive":
        mode = "interactive"
    case "--ref":
        i += 1
        if i < args.count { refText = args[i] }
    case "--refs":
        i += 1
        if i < args.count { refsFile = args[i] }
    default:
        if target.isEmpty { target = args[i] }
    }
    i += 1
}

// Validate model exists
let modelDir = modelBase.appendingPathComponent(modelDirName).path
guard FileManager.default.fileExists(atPath: modelDir + "/tokens.txt") else {
    fputs("Error: model not found at \(modelDir)\n", stderr)
    fputs("Download it first via the HoldToTalk app.\n", stderr)
    exit(1)
}

fputs("Loading model from \(modelDir)...\n", stderr)
fputs("VAD model: \(vadModelPath.isEmpty ? "NOT FOUND" : vadModelPath)\n", stderr)
let recognizer = createRecognizer()
fputs("Model loaded.\n", stderr)

// Reference sentences for interactive mode
let interactiveSentences = [
    "The quick brown fox jumps over the lazy dog.",
    "Hello, my name is Kevin and I live in San Francisco.",
    "Can you please send me the quarterly report by Friday?",
    "The meeting starts at three thirty in conference room B.",
    "I think we should refactor the authentication module first.",
    "She ordered a large coffee with oat milk and no sugar.",
    "The temperature outside is seventy two degrees Fahrenheit.",
    "Please remind me to call the dentist tomorrow morning.",
    "We need to deploy the hotfix to production before midnight.",
    "The restaurant on Fifth Avenue has excellent pasta.",
    "I am going to the grocery store to buy eggs and bread.",
    "Machine learning models require large amounts of training data.",
    "Turn left at the next intersection and then go straight.",
    "The annual budget review is scheduled for next Wednesday.",
    "Python is a popular programming language for data science.",
    "Could you pick up the kids from school at four o'clock?",
    "The new feature reduces latency by approximately forty percent.",
    "It is raining outside so do not forget your umbrella.",
    "The board approved the merger with a unanimous vote.",
    "Open the terminal and run the build command.",
]

switch mode {
case "single":
    guard !target.isEmpty else {
        fputs("Error: no WAV file specified\n", stderr)
        exit(1)
    }
    guard let (samples, sr) = readWav(target) else { exit(1) }
    let audio16k = resample(samples, from: sr, to: 16000)
    let duration = Double(audio16k.count) / 16000.0

    let start = Date()
    let hyp = transcribe(audio16k, recognizer: recognizer, verbose: verbose, useVAD: useVAD)
    let elapsed = Date().timeIntervalSince(start)

    if let ref = refText {
        let (errors, words, wer) = computeWER(reference: ref, hypothesis: hyp)
        if jsonOutput {
            let result = TranscriptionResult(
                file: target, reference: ref, hypothesis: hyp,
                wer: wer, errors: errors, refWords: words,
                segments: 0, audioDuration: duration, transcribeTime: elapsed)
            if let data = try? JSONEncoder().encode(result),
                let json = String(data: data, encoding: .utf8)
            {
                print(json)
            }
        } else {
            print("REF: \(ref)")
            print("HYP: \(hyp)")
            print("WER: \(String(format: "%.1f", wer * 100))% (\(errors)/\(words) words)")
            print("Time: \(String(format: "%.2f", elapsed))s for \(String(format: "%.1f", duration))s audio")
        }
    } else {
        if jsonOutput {
            let result = TranscriptionResult(
                file: target, reference: nil, hypothesis: hyp,
                wer: nil, errors: nil, refWords: nil,
                segments: 0, audioDuration: duration, transcribeTime: elapsed)
            if let data = try? JSONEncoder().encode(result),
                let json = String(data: data, encoding: .utf8)
            {
                print(json)
            }
        } else {
            print(hyp)
        }
    }

case "batch":
    guard !target.isEmpty else {
        fputs("Error: no directory specified for --batch\n", stderr)
        exit(1)
    }
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: target) else {
        fputs("Error: cannot list directory \(target)\n", stderr)
        exit(1)
    }
    let wavFiles = files.filter { $0.hasSuffix(".wav") }.sorted()

    // Load refs if provided
    var refs: [String] = []
    if let refsFile, let content = try? String(contentsOfFile: refsFile, encoding: .utf8) {
        refs = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    var totalErrors = 0
    var totalWords = 0
    var results: [TranscriptionResult] = []

    for (idx, file) in wavFiles.enumerated() {
        let path = (target as NSString).appendingPathComponent(file)
        guard let (samples, sr) = readWav(path) else { continue }
        let audio16k = resample(samples, from: sr, to: 16000)
        let duration = Double(audio16k.count) / 16000.0

        let start = Date()
        let hyp = transcribe(audio16k, recognizer: recognizer, verbose: verbose, useVAD: useVAD)
        let elapsed = Date().timeIntervalSince(start)

        let ref = idx < refs.count ? refs[idx] : nil
        if let ref {
            let (errors, words, wer) = computeWER(reference: ref, hypothesis: hyp)
            totalErrors += errors
            totalWords += words
            let status =
                errors == 0
                ? "PERFECT"
                : "WER \(String(format: "%.0f", wer * 100))% (\(errors)/\(words))"
            fputs("[\(idx + 1)/\(wavFiles.count)] \(file): \(status)\n", stderr)
            fputs("  REF: \(ref)\n", stderr)
            fputs("  HYP: \(hyp)\n", stderr)
            results.append(
                TranscriptionResult(
                    file: file, reference: ref, hypothesis: hyp,
                    wer: wer, errors: errors, refWords: words,
                    segments: 0, audioDuration: duration, transcribeTime: elapsed))
        } else {
            fputs("[\(idx + 1)/\(wavFiles.count)] \(file): \(hyp)\n", stderr)
            results.append(
                TranscriptionResult(
                    file: file, reference: nil, hypothesis: hyp,
                    wer: nil, errors: nil, refWords: nil,
                    segments: 0, audioDuration: duration, transcribeTime: elapsed))
        }
    }

    if totalWords > 0 {
        let overallWER = Double(totalErrors) / Double(totalWords) * 100
        let perfect = results.filter { $0.wer == 0 }.count
        fputs(
            "\nOverall WER: \(String(format: "%.1f", overallWER))% (\(totalErrors)/\(totalWords) words)\n",
            stderr)
        fputs("Perfect: \(perfect)/\(results.count)\n", stderr)
    }

    if jsonOutput {
        if let data = try? JSONEncoder().encode(results),
            let json = String(data: data, encoding: .utf8)
        {
            print(json)
        }
    }

case "record":
    guard !target.isEmpty else {
        fputs("Error: no output path specified for --record\n", stderr)
        exit(1)
    }
    guard recordFromMic(outputPath: target, verbose: verbose) else { exit(1) }
    guard let (samples, sr) = readWav(target) else { exit(1) }
    let audio16k = resample(samples, from: sr, to: 16000)
    let duration = Double(audio16k.count) / 16000.0

    let start = Date()
    let hyp = transcribe(audio16k, recognizer: recognizer, verbose: verbose, useVAD: useVAD)
    let elapsed = Date().timeIntervalSince(start)

    if let ref = refText {
        let (errors, words, wer) = computeWER(reference: ref, hypothesis: hyp)
        print("REF: \(ref)")
        print("HYP: \(hyp)")
        print("WER: \(String(format: "%.1f", wer * 100))% (\(errors)/\(words) words)")
    } else {
        print(hyp)
    }
    fputs(
        "Time: \(String(format: "%.2f", elapsed))s for \(String(format: "%.1f", duration))s audio\n",
        stderr)

case "interactive":
    let testDir = "test_data"
    try? FileManager.default.createDirectory(
        atPath: testDir, withIntermediateDirectories: true)

    var allResults: [TranscriptionResult] = []
    var totalErrors = 0
    var totalWords = 0

    fputs("\n=== Transcription Accuracy Test ===\n", stderr)
    fputs("For each sentence: press ENTER to start recording, ENTER to stop.\n", stderr)
    fputs("Type 'skip' to skip, 'quit' to finish early.\n\n", stderr)

    for (idx, ref) in interactiveSentences.enumerated() {
        fputs("[\(idx + 1)/\(interactiveSentences.count)] \(ref)\n", stderr)
        fputs("Press ENTER to record (or type skip/quit): ", stderr)

        guard let input = readLine() else { break }
        if input.lowercased() == "quit" { break }
        if input.lowercased() == "skip" {
            fputs("  Skipped.\n\n", stderr)
            continue
        }

        let wavPath = "\(testDir)/sentence_\(String(format: "%02d", idx + 1)).wav"
        guard recordFromMic(outputPath: wavPath, verbose: verbose) else { continue }
        guard let (samples, sr) = readWav(wavPath) else { continue }
        let audio16k = resample(samples, from: sr, to: 16000)
        let duration = Double(audio16k.count) / 16000.0

        let start = Date()
        let hyp = transcribe(audio16k, recognizer: recognizer, verbose: verbose, useVAD: useVAD)
        let elapsed = Date().timeIntervalSince(start)

        let (errors, words, wer) = computeWER(reference: ref, hypothesis: hyp)
        totalErrors += errors
        totalWords += words

        let status =
            errors == 0
            ? "PERFECT" : "WER \(String(format: "%.0f", wer * 100))% (\(errors)/\(words))"
        fputs("  HYP: \(hyp)\n", stderr)
        fputs("  --> \(status) [\(String(format: "%.2f", elapsed))s]\n\n", stderr)

        allResults.append(
            TranscriptionResult(
                file: wavPath, reference: ref, hypothesis: hyp,
                wer: wer, errors: errors, refWords: words,
                segments: 0, audioDuration: duration, transcribeTime: elapsed))
    }

    // Summary
    fputs("\n=== RESULTS ===\n", stderr)
    for (idx, r) in allResults.enumerated() {
        let status =
            r.errors == 0
            ? "PERFECT"
            : "WER \(String(format: "%.0f", (r.wer ?? 0) * 100))% (\(r.errors ?? 0)/\(r.refWords ?? 0))"
        fputs("  [\(idx + 1)] \(status)\n", stderr)
        if r.errors != 0 {
            fputs("       REF: \(r.reference ?? "")\n", stderr)
            fputs("       HYP: \(r.hypothesis)\n", stderr)
        }
    }
    if totalWords > 0 {
        let overallWER = Double(totalErrors) / Double(totalWords) * 100
        let perfect = allResults.filter { ($0.errors ?? 1) == 0 }.count
        fputs(
            "\nOverall WER: \(String(format: "%.1f", overallWER))% (\(totalErrors)/\(totalWords) words)\n",
            stderr)
        fputs("Perfect: \(perfect)/\(allResults.count)\n", stderr)
    }

    // Save results as JSON
    let jsonPath = "\(testDir)/results.json"
    if let data = try? JSONEncoder().encode(allResults) {
        try? data.write(to: URL(fileURLWithPath: jsonPath))
        fputs("Results saved to \(jsonPath)\n", stderr)
    }

    // Also save results for re-run
    let refsPath = "\(testDir)/refs.txt"
    let refsContent = allResults.compactMap { $0.reference }.joined(separator: "\n")
    try? refsContent.write(toFile: refsPath, atomically: true, encoding: .utf8)
    fputs("Reference text saved to \(refsPath)\n", stderr)
    fputs("\nTo re-test after code changes:\n", stderr)
    fputs("  swift run TranscribeCmd --batch test_data --refs test_data/refs.txt -v\n", stderr)

default:
    printUsage()
    exit(1)
}
