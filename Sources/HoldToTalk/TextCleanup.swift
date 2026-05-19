import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TextCleanupAvailability: Equatable {
    case available
    case unavailableOSVersion
    case unavailableNotEnabled
    case unavailableDeviceNotEligible
    case unavailableModelNotReady
}

enum TextCleanup {
    static func checkAvailability() -> TextCleanupAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return _checkAvailability()
        }
        #endif
        return .unavailableOSVersion
    }

    static func cleanup(_ text: String, prompt: String = "") async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return await _cleanup(text, prompt: prompt)
        }
        #endif
        return text
    }

    static let defaultPrompt = """
        You fix grammar and punctuation in speech-to-text transcriptions. \
        Output ONLY the cleaned transcription — nothing else.
        - Remove filler words (um, uh, like, you know) unless intentional.
        - Resolve self-corrections: "Tuesday no Wednesday" → "Wednesday".
        - Do NOT add, remove, or change any other words.
        """

    static func validatedCleanedOutput(raw: String, cleaned: String) -> String {
        let candidate = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return raw }

        let rawCharacterCount = max(raw.count, 1)
        let maximumCharacterCount = rawCharacterCount < 40
            ? rawCharacterCount + 80
            : max(rawCharacterCount * 2, rawCharacterCount + 200)
        guard candidate.count <= maximumCharacterCount else {
            debugLog("[holdtotalk] Cleanup output rejected: too long")
            return raw
        }

        let rawWords = normalizedWords(raw)
        let cleanedWords = normalizedWords(candidate)
        guard !cleanedWords.isEmpty else { return raw }

        let maximumWordCount = rawWords.count < 6
            ? max(rawWords.count * 3, rawWords.count + 4)
            : max(rawWords.count * 2, rawWords.count + 20)
        guard cleanedWords.count <= maximumWordCount else {
            debugLog("[holdtotalk] Cleanup output rejected: too many words")
            return raw
        }

        guard rawWords.count >= 6 else { return candidate }

        let rawVocabulary = Set(rawWords)
        let retained = cleanedWords.filter { rawVocabulary.contains($0) }.count
        let retainedRatio = Double(retained) / Double(cleanedWords.count)
        guard retainedRatio >= 0.45 else {
            debugLog("[holdtotalk] Cleanup output rejected: low transcript overlap")
            return raw
        }

        return candidate
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func _checkAvailability() -> TextCleanupAvailability {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailableDeviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailableNotEnabled
        case .unavailable(.modelNotReady):
            return .unavailableModelNotReady
        default:
            return .unavailableNotEnabled
        }
    }

    private static func userMessage(_ raw: String) -> String {
        """
        Clean up this transcription. Return ONLY the corrected text, no explanation.

        \(raw)
        """
    }

    private static func stripLeakedTags(_ text: String) -> String {
        var result = text
        let patterns = [
            #"</?transcription>"#,
            #"</?model>"#,
            #"/model"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26, *)
    private static func _cleanup(_ text: String, prompt: String) async -> String {
        guard _checkAvailability() == .available else { return text }

        let instructions = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPrompt
            : prompt

        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: userMessage(text))
                    let cleaned = stripLeakedTags(response.content)
                    return validatedCleanedOutput(raw: text, cleaned: cleaned)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    throw CancellationError()
                }
                guard let result = try await group.next() else {
                    return text
                }
                group.cancelAll()
                return result
            }
        } catch {
            debugLog("[holdtotalk] Text cleanup failed: \(error)")
            return text
        }
    }
    #endif
}
