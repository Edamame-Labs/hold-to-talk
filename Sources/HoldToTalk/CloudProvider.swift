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

enum CloudProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:    return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        }
    }

    var apiKeySavedDefaultsKey: String {
        switch self {
        case .openAI:    return openaiAPIKeySavedDefaultsKey
        case .anthropic: return anthropicAPIKeySavedDefaultsKey
        }
    }
}

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

    var defaultModel: String {
        switch self {
        case .local:  return ""
        case .openAI: return "gpt-4o-mini-transcribe"
        }
    }
}

// MARK: - Dictation Language

/// Which languages the user dictates in.
///
/// Cleanup providers differ in language coverage, so this decides which are
/// offered. It deliberately does not touch transcription — that already has its
/// own provider setting.
enum DictationLanguageMode: String, CaseIterable, Identifiable {
    case english
    case multilingual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english:      return "English"
        case .multilingual: return "Multilingual"
        }
    }

    var summary: String {
        switch self {
        case .english:
            return "Every cleanup option is available, including the on-device English-only model."
        case .multilingual:
            return "Only cleanup providers that handle other languages are offered. \(S1MiniModelInfo.displayName) is English-only, so it is hidden."
        }
    }
}

// MARK: - Cleanup Provider

enum CleanupProvider: String, CaseIterable, Identifiable {
    case appleIntelligence = "apple_intelligence"
    case localS1Mini = "local_s1_mini"
    case openAI = "openai"
    case anthropic = "anthropic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .localS1Mini:       return S1MiniModelInfo.displayName
        case .openAI:            return "OpenAI"
        case .anthropic:         return "Anthropic"
        }
    }

    var defaultModel: String {
        switch self {
        case .appleIntelligence: return ""
        case .localS1Mini:       return ""
        case .openAI:            return "gpt-4o-mini"
        case .anthropic:         return "claude-haiku-3-5-20241022"
        }
    }

    var cloudProvider: CloudProvider? {
        switch self {
        case .appleIntelligence, .localS1Mini: return nil
        case .openAI:                          return .openAI
        case .anthropic:                       return .anthropic
        }
    }

    /// Whether cleanup runs on this Mac with no network request.
    var isLocal: Bool {
        switch self {
        case .appleIntelligence, .localS1Mini: return true
        case .openAI, .anthropic:              return false
        }
    }

    /// Whether this provider handles languages other than English.
    ///
    /// S1-mini was trained on English only, and the model card warns that
    /// out-of-distribution input produces garbled output rather than failing
    /// loudly — so it is the one provider gated to English dictation.
    var supportsMultilingual: Bool {
        switch self {
        case .localS1Mini:                            return false
        case .appleIntelligence, .openAI, .anthropic: return true
        }
    }

    func supports(_ languageMode: DictationLanguageMode) -> Bool {
        languageMode == .english || supportsMultilingual
    }

    static func available(for languageMode: DictationLanguageMode) -> [CleanupProvider] {
        allCases.filter { $0.supports(languageMode) }
    }

    /// Resolves a persisted raw value against the current language mode.
    ///
    /// A stored provider can become invalid when the user switches language, so
    /// this clamps it rather than letting an English-only model see other
    /// languages. Unknown values fall back the same way.
    static func resolved(
        storedRawValue: String?,
        languageMode: DictationLanguageMode
    ) -> CleanupProvider {
        guard let storedRawValue,
              let stored = CleanupProvider(rawValue: storedRawValue),
              stored.supports(languageMode) else {
            return defaultForThisMac(languageMode: languageMode)
        }
        return stored
    }

    /// Whether this provider can run right now without the user setting
    /// anything up — no download, no API key, no OS feature to enable.
    var isReadyWithoutSetup: Bool {
        switch self {
        case .localS1Mini:       return CleanupModelManager.isModelDownloaded
        case .appleIntelligence: return TextCleanup.checkAvailability() == .available
        case .openAI, .anthropic: return false
        }
    }

    /// S1-mini wherever the language allows, otherwise Apple Intelligence.
    ///
    /// S1-mini is preferred even on Macs that have Apple Intelligence: it is
    /// trained for this one task rather than prompted into it, and it is fast
    /// and consistent where the alternatives are not. It costs a one-time
    /// download, which is why `textCleanupEnabled` defaults off until the model
    /// is actually present.
    ///
    /// The default never sends transcripts off the machine — a cloud provider is
    /// only ever an explicit choice.
    static func defaultForThisMac(
        languageMode: DictationLanguageMode = .english
    ) -> CleanupProvider {
        CleanupProvider.localS1Mini.supports(languageMode) ? .localS1Mini : .appleIntelligence
    }
}
