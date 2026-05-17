import SwiftUI
import AppKit
import Combine
import AVFoundation

/// Orchestrates the record -> transcribe -> insert pipeline.
@MainActor
final class DictationEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing

        var label: String {
            switch self {
            case .idle:         "Ready"
            case .recording:    "Recording..."
            case .transcribing: "Transcribing..."
            }
        }

        var icon: String {
            switch self {
            case .idle:         "mic"
            case .recording:    "mic.fill"
            case .transcribing: "bubble.left"
            }
        }

        var color: Color {
            switch self {
            case .idle:         .secondary
            case .recording:    .red
            case .transcribing: .accentColor
            }
        }
    }

    @Published var state: State = .idle
    private var hudBinding: AnyCancellable?
    @Published var lastRawText: String = ""
    @Published var lastCleanText: String = ""
    @Published var lastInsertDebug: String = ""
    @Published var recordingLevel: Float = 0
    /// Brief user-visible error message; cleared on next successful dictation.
    @Published var lastError: String?
    @Published var hasMicrophone: Bool = {
        #if DEBUG
        if DebugFlags.skipPermissions { return true }
        #endif
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }()
    @Published var hasPostEvent: Bool = {
        #if DEBUG
        if DebugFlags.skipPermissions { return true }
        #endif
        return checkPostEventAccess()
    }()

    @AppStorage(onboardingCompleteDefaultsKey) var onboardingComplete = false
    @AppStorage(transcriptionProfileDefaultsKey) var transcriptionProfile = TranscriptionProfile.balanced.rawValue
    @AppStorage(hotkeyChoiceDefaultsKey) var hotkeyChoice = HotkeyManager.Hotkey.fn.rawValue
    @AppStorage(textCleanupEnabledDefaultsKey) var textCleanupEnabled = TextCleanup.checkAvailability() == .available
    @AppStorage(textCleanupPromptDefaultsKey) var textCleanupPrompt = TextCleanup.defaultPrompt
    @AppStorage(hotwordsDefaultsKey) var hotwords: String = ""
    @AppStorage(transcriptionProviderDefaultsKey) var transcriptionProvider = TranscriptionProvider.local.rawValue
    @AppStorage(cleanupProviderDefaultsKey) var cleanupProvider = CleanupProvider.appleIntelligence.rawValue
    @AppStorage(openaiTranscriptionModelDefaultsKey) var openaiTranscriptionModel = "gpt-4o-mini-transcribe"
    @AppStorage(openaiCleanupModelDefaultsKey) var openaiCleanupModel = CleanupProvider.openAI.defaultModel
    @AppStorage(anthropicCleanupModelDefaultsKey) var anthropicCleanupModel = CleanupProvider.anthropic.defaultModel
    @AppStorage(openaiBaseURLDefaultsKey) var openaiBaseURL = ""
    @AppStorage(anthropicBaseURLDefaultsKey) var anthropicBaseURL = ""

    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private let hotkeyManager = HotkeyManager()
    let modelManager = ModelManager()
    private var didStart = false
    private var recordingTargetAppPID: pid_t?
    private var recordingTargetBundleID: String?
    private var axPollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var transcriberWarmupTask: Task<Void, Never>?
    private var completedWarmup = false

    init() {
        recorder.levelHandler = { [weak self] level in
            DispatchQueue.main.async {
                self?.recordingLevel = level
            }
        }

        if TranscriptionProfile(rawValue: transcriptionProfile) == nil {
            transcriptionProfile = TranscriptionProfile.balanced.rawValue
        }
        let preferredHotkey = HotkeyManager.Hotkey.preferredSelection(from: hotkeyChoice)
        if preferredHotkey.rawValue != hotkeyChoice {
            hotkeyChoice = preferredHotkey.rawValue
        }

        // One-time migration: clean up legacy WhisperKit models and defaults
        migrateLegacyWhisperKit()

        Task { @MainActor [weak self] in
            guard let self, self.onboardingComplete else { return }
            self.start()
        }
    }

    /// Called by OnboardingView when the user finishes the wizard.
    func completeOnboarding() {
        rememberCompletedOnboardingForCurrentInstall()
        onboardingComplete = true
        start()
    }

    func prewarmTranscriber() {
        guard resolvedTranscriptionProvider == .local else { return }
        guard !completedWarmup else { return }
        guard transcriberWarmupTask == nil else { return }

        let activeTranscriber = ensureActiveTranscriber()
        let profile = resolvedTranscriptionProfile

        let currentHotwords = hotwords
        transcriberWarmupTask = Task { [weak self] in
            do {
                try await activeTranscriber.prepareForFirstTranscription(profile: profile, hotwords: currentHotwords)
            } catch {
                debugLog("[holdtotalk] Model pre-warm failed: \(error)")
                guard let self else { return }
                self.transcriberWarmupTask = nil
                return
            }

            guard let self else { return }
            self.completedWarmup = true
            self.transcriberWarmupTask = nil
            debugLog("[holdtotalk] Model pre-warm complete")
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        refreshPermissionSnapshot()
        if !hasPostEvent { pollPostEventPermission() }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissionSnapshot()
            }
        }

        if !hasPostEvent {
            debugLog("[holdtotalk] PostEvent (keyboard access) missing -- prompt deferred to onboarding/settings.")
        }

        recorder.prepare()

        debugLog("[holdtotalk] Permissions Mic=\(hasMicrophone), PostEvent=\(hasPostEvent)")

        hotkeyManager.onPress = { [weak self] in
            DispatchQueue.main.async { self?.beginRecording() }
        }
        hotkeyManager.onRelease = { [weak self] in
            DispatchQueue.main.async {
                Task { await self?.endRecording() }
            }
        }
        hotkeyManager.update(hotkey: resolvedHotkey)
        hotkeyManager.start()

        hudBinding = Publishers.CombineLatest(
            $state.removeDuplicates(),
            $recordingLevel
        )
        .sink { state, level in
            RecordingHUD.shared.update(state, level: state == .recording ? CGFloat(level) : 0)
        }

        prewarmTranscriber()

        debugLog("[holdtotalk] Ready -- hold [\(resolvedHotkey.displayName)] to dictate.")
    }

    func stop() {
        hotkeyManager.stop()
        didStart = false
        axPollTask?.cancel()
        axPollTask = nil
        transcriberWarmupTask?.cancel()
        transcriberWarmupTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        hudBinding?.cancel()
        hudBinding = nil
        recordingLevel = 0
    }

    func resetForFreshOnboarding() {
        stop()
        resetPersistedAppStateForFreshOnboarding()

        state = .idle
        lastRawText = ""
        lastCleanText = ""
        lastInsertDebug = ""
        lastError = nil
        recordingTargetAppPID = nil
        recordingTargetBundleID = nil
        transcriber = nil
        completedWarmup = false

        onboardingComplete = false
        UserDefaults.standard.set(0, forKey: onboardingStepDefaultsKey)
        transcriptionProfile = TranscriptionProfile.balanced.rawValue
        hotkeyChoice = HotkeyManager.Hotkey.fn.rawValue
        textCleanupEnabled = TextCleanup.checkAvailability() == .available
        textCleanupPrompt = TextCleanup.defaultPrompt
        hotwords = ""
        transcriptionProvider = TranscriptionProvider.local.rawValue
        cleanupProvider = CleanupProvider.appleIntelligence.rawValue
        openaiTranscriptionModel = "gpt-4o-mini-transcribe"
        openaiCleanupModel = CleanupProvider.openAI.defaultModel
        anthropicCleanupModel = CleanupProvider.anthropic.defaultModel
        openaiBaseURL = ""
        anthropicBaseURL = ""
        KeychainHelper.delete(account: "openai")
        KeychainHelper.delete(account: "anthropic")
        UserDefaults.standard.set(false, forKey: openaiAPIKeySavedDefaultsKey)
        UserDefaults.standard.set(false, forKey: anthropicAPIKeySavedDefaultsKey)

        modelManager.handleFreshOnboardingReset()
        refreshPermissionSnapshot()
    }

    func reloadHotkey() {
        hotkeyManager.update(hotkey: resolvedHotkey)
    }

    /// Invalidates the current transcriber so the next dictation recreates it with updated hotwords.
    func reloadTranscriber() {
        transcriber = nil
        completedWarmup = false
    }

    // MARK: - Pipeline

    private func beginRecording() {
        debugLog("[holdtotalk] beginRecording called, state=\(state)")
        guard state == .idle else { return }

        refreshPermissionSnapshot()
        if !hasPostEvent {
            debugLog("[holdtotalk] PostEvent (keyboard access) not granted -- text insertion will be blocked by macOS.")
        }
        recordingTargetAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        recordingTargetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        debugLog("[holdtotalk] Recording target: \(recordingTargetBundleID ?? "nil")")
        state = .recording
        recordingLevel = 0
        prewarmTranscriber()

        do {
            try recorder.start()
            debugLog("[holdtotalk] Microphone started")
        } catch {
            debugLog("[holdtotalk] Microphone failed to start: \(error)")
            lastError = error.localizedDescription
            state = .idle
            recordingLevel = 0
            recordingTargetAppPID = nil
            recordingTargetBundleID = nil
            return
        }
    }

    private func endRecording() async {
        guard state == .recording else { return }
        let audio = recorder.stop()
        recordingLevel = 0
        guard !audio.isEmpty else {
            state = .idle
            lastError = nil
            recordingTargetAppPID = nil
            recordingTargetBundleID = nil
            return
        }

        let duration = Double(audio.count) / 16000.0
        debugLog("[holdtotalk] Captured \(String(format: "%.1f", duration))s of audio")

        state = .transcribing
        do {
            // -- Transcription --
            let transcribeStart = Date()
            let raw: String
            switch resolvedTranscriptionProvider {
            case .local:
                let activeTranscriber = ensureActiveTranscriber()
                let profile = resolvedTranscriptionProfile
                let currentHotwords = hotwords
                raw = try await activeTranscriber.transcribe(audio, profile: profile, hotwords: currentHotwords)
                let transcribeTime = Date().timeIntervalSince(transcribeStart)
                debugLog("[holdtotalk] Transcribed \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", transcribeTime))s [\(profile.rawValue)]")
            case .openAI:
                guard let apiKey = KeychainHelper.load(account: "openai"), !apiKey.isEmpty else {
                    UserDefaults.standard.set(false, forKey: openaiAPIKeySavedDefaultsKey)
                    throw CloudTranscriberError.noAPIKey
                }
                UserDefaults.standard.set(true, forKey: openaiAPIKeySavedDefaultsKey)
                let model = openaiTranscriptionModel.isEmpty ? "gpt-4o-mini-transcribe" : openaiTranscriptionModel
                let baseURL = openaiBaseURL.isEmpty ? "https://api.openai.com/v1" : openaiBaseURL
                // Fold cleanup instructions into the transcription prompt for
                // gpt-4o-transcribe models so we get clean output in a single
                // round-trip instead of two sequential API calls.
                let transcriptionPrompt: String? = textCleanupEnabled
                    ? (textCleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? TextCleanup.defaultPrompt : textCleanupPrompt)
                    : nil
                raw = try await CloudTranscriber.transcribe(
                    audio: audio, apiKey: apiKey, model: model, baseURL: baseURL,
                    prompt: transcriptionPrompt
                )
                let transcribeTime = Date().timeIntervalSince(transcribeStart)
                debugLog("[holdtotalk] Cloud transcribed \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", transcribeTime))s [openai/\(model)]")
            }

            guard !raw.isEmpty else {
                debugLog("[holdtotalk] (no speech detected)")
                state = .idle
                recordingTargetAppPID = nil
                recordingTargetBundleID = nil
                return
            }
            lastError = nil
            lastRawText = raw
            debugLogSensitive("[holdtotalk] Raw", text: raw)

            // -- Text Cleanup --
            let finalText: String
            if textCleanupEnabled {
                // When using OpenAI transcription, cleanup instructions are
                // already folded into the transcription prompt — skip the
                // separate cleanup round-trip to cut latency in half.
                let cloudTranscriptionHandledCleanup = resolvedTranscriptionProvider == .openAI

                if cloudTranscriptionHandledCleanup {
                    debugLog("[holdtotalk] Cleanup folded into cloud transcription prompt (0 extra latency)")
                    finalText = raw
                } else {
                    let cleanupStart = Date()
                    let cleaned: String
                    switch resolvedCleanupProvider {
                    case .appleIntelligence:
                        cleaned = await TextCleanup.cleanup(raw, prompt: textCleanupPrompt)
                    case .openAI:
                        let apiKey = KeychainHelper.load(account: "openai") ?? ""
                        UserDefaults.standard.set(!apiKey.isEmpty, forKey: openaiAPIKeySavedDefaultsKey)
                        let model = openaiCleanupModel.isEmpty ? CleanupProvider.openAI.defaultModel : openaiCleanupModel
                        let baseURL = openaiBaseURL.isEmpty ? nil : openaiBaseURL
                        cleaned = await CloudTextCleanup.cleanup(raw, provider: .openAI, apiKey: apiKey, model: model, prompt: textCleanupPrompt, baseURL: baseURL)
                    case .anthropic:
                        let apiKey = KeychainHelper.load(account: "anthropic") ?? ""
                        UserDefaults.standard.set(!apiKey.isEmpty, forKey: anthropicAPIKeySavedDefaultsKey)
                        let model = anthropicCleanupModel.isEmpty ? CleanupProvider.anthropic.defaultModel : anthropicCleanupModel
                        let baseURL = anthropicBaseURL.isEmpty ? nil : anthropicBaseURL
                        cleaned = await CloudTextCleanup.cleanup(raw, provider: .anthropic, apiKey: apiKey, model: model, prompt: textCleanupPrompt, baseURL: baseURL)
                    }
                    let cleanupTime = Date().timeIntervalSince(cleanupStart)
                    let changed = cleaned != raw
                    debugLog("[holdtotalk] Text cleanup \(changed ? "modified" : "unchanged") in \(String(format: "%.2f", cleanupTime))s [\(resolvedCleanupProvider.rawValue)]")
                    finalText = cleaned
                }
            } else {
                finalText = raw
            }
            lastCleanText = finalText

            reactivateRecordingTargetAppIfNeeded()
            try? await Task.sleep(nanoseconds: 80_000_000)
            let insertText = finalText + " "
            let insertBundleID = recordingTargetBundleID
            let report = await Task.detached(priority: .userInitiated) {
                TextInserter.insert(
                    insertText,
                    targetBundleID: insertBundleID
                )
            }.value
            if report.success {
                lastInsertDebug = report.summary
                debugLog("[holdtotalk] Inserted via \(report.method ?? "unknown").")
            } else {
                lastInsertDebug = report.summary
                if let userFacingError = report.userFacingError {
                    lastError = userFacingError
                }
                debugLog("[holdtotalk] Insert unconfirmed. \(report.attempts.joined(separator: " | "))")
            }
        } catch {
            lastError = error.localizedDescription
            debugLog("[holdtotalk] Error: \(error)")
        }

        state = .idle
        recordingLevel = 0
        recordingTargetAppPID = nil
        recordingTargetBundleID = nil
    }

    private var resolvedHotkey: HotkeyManager.Hotkey {
        HotkeyManager.Hotkey.preferredSelection(from: hotkeyChoice)
    }

    private func ensureActiveTranscriber() -> Transcriber {
        if transcriber == nil {
            transcriber = Transcriber()
        }
        return transcriber!
    }

    var resolvedTranscriptionProvider: TranscriptionProvider {
        TranscriptionProvider(rawValue: transcriptionProvider) ?? .local
    }

    var resolvedCleanupProvider: CleanupProvider {
        CleanupProvider(rawValue: cleanupProvider) ?? .appleIntelligence
    }

    private var resolvedTranscriptionProfile: TranscriptionProfile {
        TranscriptionProfile(rawValue: transcriptionProfile) ?? .balanced
    }

    /// Polls until PostEvent (keyboard access) is granted so the UI updates live.
    private func pollPostEventPermission() {
        axPollTask = Task { @MainActor in
            do {
                while !checkPostEventAccess() {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch {
                return
            }
            hasPostEvent = true
            print("[holdtotalk] PostEvent (keyboard access) permission granted.")
        }
    }

    private func reactivateRecordingTargetAppIfNeeded() {
        guard let pid = recordingTargetAppPID else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        app.activate()
    }

    /// Reads current macOS permission state into the engine's published properties.
    func refreshPermissionSnapshot() {
        #if DEBUG
        if DebugFlags.skipPermissions {
                hasMicrophone = true
            hasPostEvent = true
            return
        }
        #endif
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasPostEvent = checkPostEventAccess()
    }

    // MARK: - Legacy Migration

    private func migrateLegacyWhisperKit() {
        let defaults = UserDefaults.standard
        // Clear legacy whisperModel key
        if defaults.string(forKey: whisperModelDefaultsKey) != nil {
            defaults.removeObject(forKey: whisperModelDefaultsKey)
        }
        // Clean up old WhisperKit model files
        modelManager.cleanupLegacyWhisperKitModels()
    }
}
