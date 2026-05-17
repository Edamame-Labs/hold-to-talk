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
        let cloudBaseURL = try normalizedCloudBaseURL(baseURL)
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

        let url = cloudBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await cloudSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudCleanupError.apiError(provider: "OpenAI", statusCode: code)
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
        let cloudBaseURL = try normalizedCloudBaseURL(baseURL)
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

        let url = cloudBaseURL.appendingPathComponent("v1/messages")
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
            throw CloudCleanupError.apiError(provider: "Anthropic", statusCode: code)
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
    case apiError(provider: String, statusCode: Int)
    case invalidResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .apiError(let provider, let statusCode):
            switch statusCode {
            case 401:
                return "Invalid \(provider) API key. Check your key in Settings."
            case 403:
                return "\(provider) cleanup access was denied. Check your account, model access, and base URL."
            case 404:
                return "\(provider) cleanup endpoint was not found. Check your base URL and model settings."
            case 408, 425, 429:
                return "\(provider) cleanup is rate limited or temporarily busy. Try again shortly."
            case 500...599:
                return "\(provider) cleanup is temporarily unavailable. Try again later."
            default:
                return "\(provider) cleanup error (\(statusCode)). Check your cloud settings."
            }
        case .invalidResponse(let provider):
            return "Invalid response from \(provider) API."
        }
    }
}
