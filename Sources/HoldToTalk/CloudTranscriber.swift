import Foundation

/// Speech-to-text via an OpenAI-compatible `/audio/transcriptions` endpoint.
enum CloudTranscriber {
    /// Maximum recording length accepted for cloud transcription (seconds).
    static let maxRecordingSeconds: TimeInterval = 300

    static func validateRecordingDuration(_ duration: TimeInterval) throws {
        guard duration <= maxRecordingSeconds else {
            throw CloudTranscriberError.recordingTooLong(maxSeconds: Int(maxRecordingSeconds))
        }
    }

    /// Transcribe 16 kHz mono float audio via the OpenAI transcription API.
    ///
    /// - Parameter prompt: Optional instructions injected as a user message for
    ///   gpt-4o-transcribe models. Used to fold cleanup instructions into the
    ///   transcription call so a separate cleanup round-trip can be skipped.
    static func transcribe(
        audio: [Float],
        apiKey: String,
        model: String = "gpt-4o-mini-transcribe",
        baseURL: String = "https://api.openai.com/v1",
        prompt: String? = nil
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }
        guard !apiKey.isEmpty else { throw CloudTranscriberError.noAPIKey }
        let cloudBaseURL = try normalizedCloudBaseURL(baseURL)

        let wavData = encodeWAV(audio, sampleRate: 16000)

        let boundary = UUID().uuidString
        let url = cloudBaseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        body.appendFormField(named: "model", value: model, boundary: boundary)
        body.appendFormField(named: "response_format", value: "text", boundary: boundary)
        if let prompt, !prompt.isEmpty {
            body.appendFormField(named: "prompt", value: prompt, boundary: boundary)
        }
        body.appendFileField(named: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData, boundary: boundary)
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await cloudSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriberError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw CloudTranscriberError.apiError(statusCode: httpResponse.statusCode)
        }

        // response_format=text returns plain text
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - WAV Encoding

    /// Encode 16 kHz mono float32 samples as 16-bit PCM WAV data.
    private static func encodeWAV(_ samples: [Float], sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.appendLittleEndian(chunkSize)
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        // fmt subchunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))  // subchunk1 size
        data.appendLittleEndian(UInt16(1))   // PCM
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        // data subchunk
        data.append(contentsOf: [UInt8]("data".utf8))
        data.appendLittleEndian(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.appendLittleEndian(int16)
        }

        return data
    }
}

// MARK: - Errors

enum CloudTranscriberError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int)
    case recordingTooLong(maxSeconds: Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "OpenAI API key is not set. Add your key in Settings."
        case .invalidResponse:
            return "Invalid response from transcription API."
        case .recordingTooLong(let maxSeconds):
            let minutes = maxSeconds / 60
            return "Recording is too long for cloud transcription (max \(minutes) minutes). Use local transcription or record a shorter clip."
        case .apiError(let statusCode):
            switch statusCode {
            case 401:
                return "Invalid OpenAI API key. Check your key in Settings."
            case 403:
                return "Transcription API access was denied. Check your account, model access, and base URL."
            case 404:
                return "Transcription API endpoint was not found. Check your base URL and model settings."
            case 408, 425, 429:
                return "Transcription API is rate limited or temporarily busy. Try again shortly."
            case 500...599:
                return "Transcription API is temporarily unavailable. Try again later."
            default:
                return "Transcription API error (\(statusCode)). Check your cloud settings."
            }
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: [UInt8](string.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendFormField(named name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func appendFileField(named name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
