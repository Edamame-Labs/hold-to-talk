import Foundation

// MARK: - Cloud URLSession

/// Shared URLSession for cloud API requests. Uses default system TLS validation
/// (certificate chain + hostname check via ATS), with no cookies or disk cache
/// for audio/transcript traffic.
let cloudSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.httpCookieStorage = nil
    return URLSession(configuration: config)
}()

// MARK: - URL Validation

enum CloudURLError: LocalizedError {
    case invalidURL
    case insecureURL
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Cloud base URL must be a valid HTTPS URL."
        case .insecureURL:
            return "Refusing to send API request to a non-HTTPS URL. Check your base URL in Settings."
        case .credentialsNotAllowed:
            return "Cloud base URL must not include usernames or passwords."
        case .queryOrFragmentNotAllowed:
            return "Cloud base URL must not include query strings or fragments."
        }
    }
}

/// Normalize and validate a cloud base URL before sending API keys or audio over the network.
func normalizedCloudBaseURL(_ baseURL: String) throws -> URL {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
        throw CloudURLError.invalidURL
    }

    guard components.scheme?.lowercased() == "https" else {
        throw CloudURLError.insecureURL
    }
    components.scheme = "https"

    guard let host = components.host, !host.isEmpty else {
        throw CloudURLError.invalidURL
    }

    guard components.user == nil, components.password == nil else {
        throw CloudURLError.credentialsNotAllowed
    }

    guard components.query == nil, components.fragment == nil else {
        throw CloudURLError.queryOrFragmentNotAllowed
    }

    components.path = components.path.removingTrailingSlashesForBaseURL()

    guard let url = components.url else {
        throw CloudURLError.invalidURL
    }
    return url
}

/// Validate that a base URL uses HTTPS before sending API keys or audio over the network.
func validateCloudBaseURL(_ baseURL: String) throws {
    _ = try normalizedCloudBaseURL(baseURL)
}

private extension String {
    func removingTrailingSlashesForBaseURL() -> String {
        guard count > 1 else { return self == "/" ? "" : self }
        var value = self
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value == "/" ? "" : value
    }
}

// MARK: - Transcription Provider

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case local
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:  return "On-Device"
        case .openAI: return "OpenAI"
        }
    }
}

// MARK: - Cleanup Provider

enum CleanupProvider: String, CaseIterable, Identifiable {
    case appleIntelligence = "apple_intelligence"
    case openAI = "openai"
    case anthropic = "anthropic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI:            return "OpenAI"
        case .anthropic:         return "Anthropic"
        }
    }

    var defaultModel: String {
        switch self {
        case .appleIntelligence: return ""
        case .openAI:            return "gpt-4o-mini"
        case .anthropic:         return "claude-haiku-3-5-20241022"
        }
    }

    var keychainAccount: String {
        switch self {
        case .appleIntelligence: return ""
        case .openAI:            return "openai"
        case .anthropic:         return "anthropic"
        }
    }
}
