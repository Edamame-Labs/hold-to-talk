import Foundation

/// Text cleanup via OpenAI or Anthropic cloud APIs.
enum CloudTextCleanup {

    static func cleanup(
        _ text: String,
        provider: CleanupProvider,
        apiKey: String,
        model: String,
        prompt: String,
        baseURL: String? = nil
    ) async -> String {
        guard !apiKey.isEmpty else {
            debugLog("[holdtotalk] Cloud cleanup skipped: no API key")
            return text
        }

        do {
            let result: String
            switch provider {
            case .openAI:
                result = try await openAI(
                    text, apiKey: apiKey, model: model, prompt: prompt,
                    baseURL: baseURL ?? "https://api.openai.com/v1"
                )
            case .anthropic:
                result = try await anthropic(
                    text, apiKey: apiKey, model: model, prompt: prompt,
                    baseURL: baseURL ?? "https://api.anthropic.com"
                )
            case .appleIntelligence:
                return text // not handled here
            }
            return result.isEmpty ? text : result
        } catch {
            debugLog("[holdtotalk] Cloud cleanup failed: \(error)")
            return text
        }
    }

    // MARK: - OpenAI Chat Completions

    private static func openAI(
        _ text: String,
        apiKey: String,
        model: String,
        prompt: String,
        baseURL: String
    ) async throws -> String {
        try validateCloudBaseURL(baseURL)
        let systemPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TextCleanup.defaultPrompt : prompt

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(text)],
            ],
            "temperature": 0.3,
            "max_tokens": 2048,
        ]

        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await cloudSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CloudCleanupError.apiError(provider: "OpenAI", statusCode: code, message: msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CloudCleanupError.invalidResponse(provider: "OpenAI")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anthropic Messages

    private static func anthropic(
        _ text: String,
        apiKey: String,
        model: String,
        prompt: String,
        baseURL: String
    ) async throws -> String {
        try validateCloudBaseURL(baseURL)
        let systemPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TextCleanup.defaultPrompt : prompt

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage(text)],
            ],
        ]

        let url = URL(string: "\(baseURL)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await cloudSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CloudCleanupError.apiError(provider: "Anthropic", statusCode: code, message: msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let responseText = first["text"] as? String else {
            throw CloudCleanupError.invalidResponse(provider: "Anthropic")
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func userMessage(_ raw: String) -> String {
        "Clean up this transcription. Return ONLY the corrected text, no explanation.\n\n\(raw)"
    }
}

// MARK: - Errors

enum CloudCleanupError: LocalizedError {
    case apiError(provider: String, statusCode: Int, message: String)
    case invalidResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .apiError(let provider, let statusCode, let message):
            if statusCode == 401 {
                return "Invalid \(provider) API key. Check your key in Settings."
            }
            return "\(provider) cleanup error (\(statusCode)): \(message)"
        case .invalidResponse(let provider):
            return "Invalid response from \(provider) API."
        }
    }
}
