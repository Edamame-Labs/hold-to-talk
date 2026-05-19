import AVFoundation

enum AudioRecorderError: LocalizedError {
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        }
    }
}

/// Captures microphone audio into a 16 kHz mono float buffer for speech recognition.
/// Thread-safe via NSLock; marked Sendable for cross-actor usage.
///
/// The audio engine is pre-warmed on `prepare()` so that `start()` only installs
/// a tap and resumes — cutting hotkey-to-recording latency from ~150ms to <10ms.
final class AudioRecorder: @unchecked Sendable {
    /// Maximum recording length before `onMaxDurationReached` fires (seconds).
    static let maxRecordingSeconds = 300

    private let engine = AVAudioEngine()
    private var buffers: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private var isPrepared = false
    private var tapInstalled = false
    private var smoothedLevel: Float = 0
    private var capturedFrameCount = 0
    private var didNotifyMaxDuration = false
    var levelHandler: (@Sendable (Float) -> Void)?
    var onMaxDurationReached: (@Sendable () -> Void)?

    /// Pre-warms the audio engine so subsequent start() calls are near-instant.
    /// Call once at app startup. Safe to call multiple times.
    func prepare() {
        lock.lock()
        guard !isPrepared else { lock.unlock(); return }
        isPrepared = true
        lock.unlock()
        // Accessing inputNode implicitly connects it to the engine graph.
        _ = engine.inputNode
        engine.prepare()
    }

    func start() throws {
        lock.lock()
        if tapInstalled {
            lock.unlock()
            throw AudioRecorderError.alreadyRecording
        }
        buffers.removeAll()
        smoothedLevel = 0
        capturedFrameCount = 0
        didNotifyMaxDuration = false
        let levelHandler = self.levelHandler
        lock.unlock()
        levelHandler?(0)

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        let maxFrames = Int(nativeFormat.sampleRate) * Self.maxRecordingSeconds

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Fix #8: use safe conditional cast — force-cast crashes if copy() returns unexpected type
            guard let copied = buffer.copy() as? AVAudioPCMBuffer else { return }
            let normalizedLevel = Self.normalizedLevel(for: copied)
            let callbackLevel: Float
            let handler: (@Sendable (Float) -> Void)?
            let maxDurationHandler: (@Sendable () -> Void)?
            self.lock.lock()
            self.buffers.append(copied)
            self.capturedFrameCount += Int(copied.frameLength)
            let reachedMax = self.capturedFrameCount >= maxFrames
            let shouldNotifyMax = reachedMax && !self.didNotifyMaxDuration
            if shouldNotifyMax {
                self.didNotifyMaxDuration = true
            }
            self.smoothedLevel = max(normalizedLevel, self.smoothedLevel * 0.82)
            callbackLevel = self.smoothedLevel
            handler = self.levelHandler
            maxDurationHandler = shouldNotifyMax ? self.onMaxDurationReached : nil
            self.lock.unlock()
            handler?(callbackLevel)
            maxDurationHandler?()
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stop() -> [Float] {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        // Re-prepare so the next start() is fast again.
        // Calls AVAudioEngine.prepare() directly — intentionally bypasses AudioRecorder.prepare()'s
        // isPrepared guard so the engine is re-warmed on every stop, keeping it hot-standby.
        engine.prepare()

        lock.lock()
        let captured = buffers
        buffers.removeAll()
        smoothedLevel = 0
        capturedFrameCount = 0
        didNotifyMaxDuration = false
        let levelHandler = self.levelHandler
        lock.unlock()
        levelHandler?(0)

        guard !captured.isEmpty else { return [] }
        let result = resample(buffers: captured)

        // Zero audio buffer memory before releasing to prevent recovery from memory dumps.
        for buf in captured {
            Self.zeroBuffer(buf)
        }

        return result
    }

    // MARK: - Resampling

    /// Concatenates captured buffers and resamples to 16 kHz mono for speech recognition.
    private func resample(buffers: [AVAudioPCMBuffer]) -> [Float] {
        let srcFormat = buffers[0].format
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }

        guard let combined = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            return []
        }
        for buf in buffers {
            guard let dst = combined.floatChannelData?[0].advanced(by: Int(combined.frameLength)),
                  let src = buf.floatChannelData?[0] else { continue }
            dst.update(from: src, count: Int(buf.frameLength))
            combined.frameLength += buf.frameLength
        }

        // If already 16 kHz mono, skip conversion
        if Int(srcFormat.sampleRate) == 16000 && srcFormat.channelCount == 1 {
            let result = Array(UnsafeBufferPointer(start: combined.floatChannelData?[0],
                                                    count: Int(combined.frameLength)))
            Self.zeroBuffer(combined)
            return result
        }

        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            let result = Array(UnsafeBufferPointer(start: combined.floatChannelData?[0],
                                                    count: Int(combined.frameLength)))
            Self.zeroBuffer(combined)
            return result
        }

        let ratio = 16000.0 / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(combined.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else {
            Self.zeroBuffer(combined)
            return []
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return combined
        }

        if let error {
            debugLog("[audio] resample error: \(error)")
            Self.zeroBuffer(combined)
            Self.zeroBuffer(output)
            return []
        }

        let result = Array(UnsafeBufferPointer(start: output.floatChannelData?[0],
                                                count: Int(output.frameLength)))
        Self.zeroBuffer(combined)
        Self.zeroBuffer(output)
        return result
    }

    /// Zero the backing memory of an audio buffer to prevent recovery from memory dumps.
    private static func zeroBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let byteCount = Int(buffer.frameCapacity) * MemoryLayout<Float>.size
        for ch in 0..<Int(buffer.format.channelCount) {
            memset(channelData[ch], 0, byteCount)
        }
    }

    private static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        guard rms.isFinite else { return 0 }

        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
    }
}
