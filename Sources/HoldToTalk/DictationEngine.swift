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
    // Enabled only when the default provider can actually run — otherwise the
    // first dictation would report a missing model instead of just working.
    @AppStorage(textCleanupEnabledDefaultsKey) var textCleanupEnabled = CleanupProvider.defaultForThisMac().isReadyWithoutSetup
    @AppStorage(textCleanupPromptDefaultsKey) var textCleanupPrompt = TextCleanup.defaultPrompt
    @AppStorage(hotwordsDefaultsKey) var hotwords: String = ""
    /// Empty means "mirror the system's chosen input" — the app does not pick a
    /// microphone for the user.
    @AppStorage(preferredInputDeviceUIDDefaultsKey) var preferredInputDeviceUID = ""
    @AppStorage(transcriptionProviderDefaultsKey) var transcriptionProvider = TranscriptionProvider.local.rawValue
    @AppStorage(dictationLanguageModeDefaultsKey) var dictationLanguageMode = DictationLanguageMode.english.rawValue
    @AppStorage(cleanupProviderDefaultsKey) var cleanupProvider = CleanupProvider.defaultForThisMac().rawValue
    @AppStorage(cleanupStylingDefaultsKey) var cleanupStyling = CleanupStyling.semiFormal.rawValue
    @AppStorage(cleanupStructureDefaultsKey) var cleanupStructure = CleanupStructure.prose.rawValue
    @AppStorage(openaiTranscriptionModelDefaultsKey) var openaiTranscriptionModel = TranscriptionProvider.openAI.defaultModel
    @AppStorage(openaiCleanupModelDefaultsKey) var openaiCleanupModel = CleanupProvider.openAI.defaultModel
    @AppStorage(anthropicCleanupModelDefaultsKey) var anthropicCleanupModel = CleanupProvider.anthropic.defaultModel
    @AppStorage(openaiBaseURLDefaultsKey) var openaiBaseURL = ""
    @AppStorage(anthropicBaseURLDefaultsKey) var anthropicBaseURL = ""

    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private let hotkeyManager = HotkeyManager()
    let modelManager = ModelManager()
    let cleanupModelManager = CleanupModelManager()
    private var didStart = false
    private var recordingTargetAppPID: pid_t?
    private var recordingTargetBundleID: String?
    private var axPollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var transcriberWarmupTask: Task<Void, Never>?
    private var completedWarmup = false
    private var cleanupWarmupTask: Task<Void, Never>?
    private var audioInputObservation: AudioInputObservation?
    private var dictationTask: Task<Void, Never>?
    private var activeDictationID = 0

    init() {
        recorder.levelHandler = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.recordingLevel = level
            }
        }
        recorder.onMaxDurationReached = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.lastError = "Maximum recording length reached (\(AudioRecorder.maxRecordingSeconds / 60) minutes)."
                self.finishActiveRecording()
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

    /// Loads the on-device cleanup model ahead of the first dictation so the
    /// user does not pay the load cost mid-pipeline.
    func prewarmCleanupModel() {
        guard textCleanupEnabled, resolvedCleanupProvider == .localS1Mini else { return }
        guard CleanupModelManager.isModelDownloaded else { return }
        guard !LocalTextCleanup.isLoaded, cleanupWarmupTask == nil else { return }

        cleanupWarmupTask = Task { [weak self] in
            do {
                try await LocalTextCleanup.shared.warmUp()
                debugLog("[holdtotalk] Cleanup model pre-warm complete")
            } catch {
                debugLog("[holdtotalk] Cleanup model pre-warm failed: \(error)")
            }
            guard let self else { return }
            self.cleanupWarmupTask = nil
        }
    }

    /// Moves the stored cleanup provider onto one that handles the selected
    /// language. Called when the language mode changes so the Settings picker
    /// reflects the switch instead of silently disagreeing with what runs.
    func normalizeCleanupProviderForLanguage() {
        let mode = resolvedLanguageMode
        guard let stored = CleanupProvider(rawValue: cleanupProvider) else {
            cleanupProvider = CleanupProvider.defaultForThisMac(languageMode: mode).rawValue
            reloadCleanupProvider()
            return
        }
        guard !stored.supports(mode) else { return }

        let replacement = CleanupProvider.defaultForThisMac(languageMode: mode)
        debugLog("[holdtotalk] Cleanup provider \(stored.rawValue) does not support \(mode.rawValue); switching to \(replacement.rawValue)")
        cleanupProvider = replacement.rawValue
        reloadCleanupProvider()
    }

    /// Drops the on-device cleanup model when it is no longer the selected
    /// provider, so an unused 462 MB model does not stay resident.
    func reloadCleanupProvider() {
        cleanupWarmupTask?.cancel()
        cleanupWarmupTask = nil
        if resolvedCleanupProvider == .localS1Mini, textCleanupEnabled {
            prewarmCleanupModel()
        } else {
            Task { await LocalTextCleanup.shared.unload() }
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

        recorder.setPreferredInputUID(preferredInputDeviceUID)
        recorder.prepare()
        // Connecting AirPods while the app is idle would otherwise leave the
        // input pre-warmed and playback stuck in call quality.
        audioInputObservation = AudioInputDevice.observeDefaultInputChanges { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.state == .idle else { return }
                self.recorder.refreshPrewarmForCurrentInput()
            }
        }

        debugLog("[holdtotalk] Permissions Mic=\(hasMicrophone), PostEvent=\(hasPostEvent)")

        hotkeyManager.onPress = { [weak self] in
            DispatchQueue.main.async { self?.handleHotkeyPress() }
        }
        hotkeyManager.onRelease = { [weak self] in
            DispatchQueue.main.async { self?.handleHotkeyRelease() }
        }
        hotkeyManager.onRegistrationFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.lastError = message
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
        prewarmCleanupModel()

        debugLog("[holdtotalk] Ready -- hold [\(resolvedHotkey.displayName)] to dictate.")
    }

    func stop() {
        dictationTask?.cancel()
        dictationTask = nil
        cancelActiveRecording()
        hotkeyManager.stop()
        didStart = false
        axPollTask?.cancel()
        axPollTask = nil
        transcriberWarmupTask?.cancel()
        transcriberWarmupTask = nil
        cleanupWarmupTask?.cancel()
        cleanupWarmupTask = nil
        audioInputObservation = nil
        recorder.releasePrewarmedInput()
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
        textCleanupEnabled = CleanupProvider.defaultForThisMac().isReadyWithoutSetup
        textCleanupPrompt = TextCleanup.defaultPrompt
        hotwords = ""
        preferredInputDeviceUID = ""
        transcriptionProvider = TranscriptionProvider.local.rawValue
        dictationLanguageMode = DictationLanguageMode.english.rawValue
        cleanupProvider = CleanupProvider.defaultForThisMac().rawValue
        cleanupStyling = CleanupStyling.semiFormal.rawValue
        cleanupStructure = CleanupStructure.prose.rawValue
        openaiTranscriptionModel = TranscriptionProvider.openAI.defaultModel
        openaiCleanupModel = CleanupProvider.openAI.defaultModel
        anthropicCleanupModel = CleanupProvider.anthropic.defaultModel
        openaiBaseURL = ""
        anthropicBaseURL = ""
        for provider in CloudProvider.allCases {
            KeychainHelper.delete(provider: provider)
            UserDefaults.standard.set(false, forKey: provider.apiKeySavedDefaultsKey)
        }

        modelManager.handleFreshOnboardingReset()
        cleanupModelManager.handleFreshOnboardingReset()
        refreshPermissionSnapshot()
    }

    func reloadHotkey() {
        if state == .recording {
            cancelActiveRecording()
        }
        hotkeyManager.update(hotkey: resolvedHotkey)
        if let failure = hotkeyManager.lastRegistrationFailure {
            lastError = failure
        }
    }

    /// Applies a microphone change immediately, including releasing a pre-warmed
    /// input when the new choice is a Bluetooth device.
    func reloadInputDevice() {
        recorder.setPreferredInputUID(preferredInputDeviceUID)
    }

    /// The microphone capture will actually use, after falling back to the
    /// system default when the chosen device is absent.
    var resolvedInputDevice: AudioInputDeviceInfo? {
        AudioInputDevice.resolvedInput(preferredUID: preferredInputDeviceUID)
    }

    /// Invalidates the current transcriber so the next dictation recreates it with updated hotwords.
    func reloadTranscriber() {
        transcriberWarmupTask?.cancel()
        transcriberWarmupTask = nil
        transcriber = nil
        completedWarmup = false
    }

    // MARK: - Pipeline

    private func handleHotkeyPress() {
        if state == .transcribing {
            dictationTask?.cancel()
            dictationTask = nil
            activeDictationID += 1
            state = .idle
            recordingLevel = 0
            recordingTargetAppPID = nil
            recordingTargetBundleID = nil
            lastError = "Previous dictation cancelled."
        }
        beginRecording()
    }

    private func handleHotkeyRelease() {
        finishActiveRecording()
    }

    private func finishActiveRecording() {
        guard state == .recording else { return }
        dictationTask?.cancel()
        activeDictationID += 1
        let taskID = activeDictationID
        dictationTask = Task { [weak self] in
            await self?.endRecording(taskID: taskID)
        }
    }

    private func cancelActiveRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .idle
        recordingLevel = 0
        recordingTargetAppPID = nil
        recordingTargetBundleID = nil
    }

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
        prewarmCleanupModel()

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

    private func endRecording(taskID: Int) async {
        guard taskID == activeDictationID else { return }
        guard state == .recording else { return }
        var audio = recorder.stop()
        recordingLevel = 0
        defer { zeroAudioSamples(&audio) }
        guard !Task.isCancelled else {
            completeDictationIfCurrent(taskID: taskID)
            return
        }
        guard !audio.isEmpty else {
            lastError = nil
            completeDictationIfCurrent(taskID: taskID)
            return
        }

        let duration = Double(audio.count) / 16000.0
        debugLog("[holdtotalk] Captured \(String(format: "%.1f", duration))s of audio")

        state = .transcribing
        do {
            try Task.checkCancellation()
            let transcribeStart = Date()
            let transcription = try await transcribe(audio, duration: duration)
            let raw = transcription.text
            let transcribeTime = Date().timeIntervalSince(transcribeStart)
            debugLog("[holdtotalk] Transcribed \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", transcribeTime))s [\(transcription.source)]\(completedWarmup ? "" : " (cold: model was not pre-warmed)")")

            try Task.checkCancellation()

            guard !raw.isEmpty else {
                debugLog("[holdtotalk] (no speech detected)")
                completeDictationIfCurrent(taskID: taskID)
                return
            }
            lastError = nil
            lastRawText = raw
            debugLogSensitive("[holdtotalk] Raw", text: raw)

            let cleanup = await cleanUp(raw)
            let finalText = cleanup.text
            let cleanupWarning = cleanup.warning

            try Task.checkCancellation()
            guard taskID == activeDictationID else { return }
            lastCleanText = finalText
            if let cleanupWarning {
                lastError = cleanupWarning
            }

            try Task.checkCancellation()

            reactivateRecordingTargetAppIfNeeded()
            try? await Task.sleep(nanoseconds: 80_000_000)
            try Task.checkCancellation()
            guard taskID == activeDictationID else { return }
            let insertText = finalText + " "
            let insertBundleID = recordingTargetBundleID
            let insertPID = recordingTargetAppPID
            let report = await MainActor.run {
                TextInserter.insert(
                    insertText,
                    targetBundleID: insertBundleID,
                    targetPID: insertPID
                )
            }
            if report.success && report.confirmed {
                lastInsertDebug = report.summary
                if cleanupWarning == nil {
                    lastError = nil
                }
                debugLog("[holdtotalk] Inserted via \(report.method ?? "unknown").")
            } else {
                lastInsertDebug = report.summary
                if let userFacingError = report.userFacingError {
                    lastError = userFacingError
                }
                debugLog("[holdtotalk] Insert unconfirmed. \(report.attempts.joined(separator: " | "))")
            }
        } catch is CancellationError {
            if taskID == activeDictationID {
                debugLog("[holdtotalk] Dictation cancelled.")
            }
        } catch {
            if taskID == activeDictationID {
                lastError = error.localizedDescription
                debugLog("[holdtotalk] Error: \(error)")
            }
        }

        completeDictationIfCurrent(taskID: taskID)
    }

    private func completeDictationIfCurrent(taskID: Int) {
        guard taskID == activeDictationID else { return }
        state = .idle
        recordingLevel = 0
        recordingTargetAppPID = nil
        recordingTargetBundleID = nil
        dictationTask = nil
    }

    private func transcribe(_ audio: [Float], duration: TimeInterval) async throws -> (text: String, source: String) {
        switch resolvedTranscriptionProvider {
        case .local:
            let profile = resolvedTranscriptionProfile
            let text = try await ensureActiveTranscriber().transcribe(
                audio,
                profile: profile,
                hotwords: hotwords
            )
            return (text, profile.rawValue)

        case .openAI:
            let provider = CloudProvider.openAI
            try CloudTranscriber.validateRecordingDuration(duration)
            try Task.checkCancellation()
            guard let apiKey = KeychainHelper.load(provider: provider), !apiKey.isEmpty else {
                UserDefaults.standard.set(false, forKey: provider.apiKeySavedDefaultsKey)
                throw CloudTranscriberError.noAPIKey
            }

            UserDefaults.standard.set(true, forKey: provider.apiKeySavedDefaultsKey)
            let model = openaiTranscriptionModel.isEmpty
                ? TranscriptionProvider.openAI.defaultModel
                : openaiTranscriptionModel
            let baseURL = openaiBaseURL.isEmpty ? provider.defaultBaseURL : openaiBaseURL
            let text = try await CloudTranscriber.transcribe(
                audio: audio,
                apiKey: apiKey,
                model: model,
                baseURL: baseURL
            )
            return (text, "\(provider.rawValue)/\(model)")
        }
    }

    private func cleanUp(_ raw: String) async -> (text: String, warning: String?) {
        guard textCleanupEnabled else { return (raw, nil) }

        let provider = resolvedCleanupProvider
        guard provider.supports(resolvedLanguageMode) else {
            // resolvedCleanupProvider already clamps, so this is unreachable in
            // practice — but never hand non-English text to an English-only model.
            debugLog("[holdtotalk] Cleanup skipped: \(provider.rawValue) does not support \(resolvedLanguageMode.rawValue)")
            return (raw, nil)
        }
        let cleanupStart = Date()
        let result: (text: String, warning: String?)
        switch provider {
        case .appleIntelligence:
            result = (await TextCleanup.cleanup(raw, prompt: textCleanupPrompt), nil)

        case .localS1Mini:
            result = await localCleanUp(raw)

        case .openAI, .anthropic:
            guard let cloudProvider = provider.cloudProvider else { return (raw, nil) }
            let apiKey = KeychainHelper.load(provider: cloudProvider) ?? ""
            UserDefaults.standard.set(!apiKey.isEmpty, forKey: cloudProvider.apiKeySavedDefaultsKey)

            let configuredModel: String
            let configuredBaseURL: String
            switch provider {
            case .openAI:
                configuredModel = openaiCleanupModel
                configuredBaseURL = openaiBaseURL
            case .anthropic:
                configuredModel = anthropicCleanupModel
                configuredBaseURL = anthropicBaseURL
            case .appleIntelligence, .localS1Mini:
                return (raw, nil)
            }

            let cleanup = await CloudTextCleanup.cleanup(
                raw,
                provider: provider,
                apiKey: apiKey,
                model: configuredModel.isEmpty ? provider.defaultModel : configuredModel,
                prompt: textCleanupPrompt,
                baseURL: configuredBaseURL.isEmpty ? nil : configuredBaseURL
            )
            result = (cleanup.text, cleanup.userFacingError)
        }

        let cleanupTime = Date().timeIntervalSince(cleanupStart)
        let changed = result.text != raw
        debugLog("[holdtotalk] Text cleanup \(changed ? "modified" : "unchanged") in \(String(format: "%.2f", cleanupTime))s [\(provider.rawValue)]")
        return result
    }

    /// Runs S1-mini on this Mac. Any failure keeps the raw transcription — a
    /// literal transcript is always better than a lost one.
    private func localCleanUp(_ raw: String) async -> (text: String, warning: String?) {
        guard CleanupModelManager.isModelDownloaded else {
            cleanupModelManager.refreshDownloadStatus()
            return (raw, LocalCleanupError.modelMissing.localizedDescription)
        }

        do {
            let cleaned = try await LocalTextCleanup.shared.cleanup(
                raw,
                styling: resolvedCleanupStyling,
                structure: resolvedCleanupStructure
            )
            return (TextCleanup.validatedCleanedOutput(raw: raw, cleaned: cleaned), nil)
        } catch is CancellationError {
            return (raw, nil)
        } catch {
            debugLog("[holdtotalk] Local cleanup failed: \(error)")
            let message = (error as? LocalizedError)?.errorDescription
                ?? "On-device cleanup failed. Using the raw transcription."
            return (raw, message)
        }
    }

    private var resolvedHotkey: HotkeyManager.Hotkey {
        HotkeyManager.Hotkey.preferredSelection(from: hotkeyChoice)
    }

    private func ensureActiveTranscriber() -> Transcriber {
        if let transcriber { return transcriber }
        let newTranscriber = Transcriber()
        transcriber = newTranscriber
        return newTranscriber
    }

    private func zeroAudioSamples(_ audio: inout [Float]) {
        guard !audio.isEmpty else { return }
        audio.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memset(base, 0, buffer.count * MemoryLayout<Float>.size)
        }
        audio.removeAll(keepingCapacity: false)
    }

    var resolvedTranscriptionProvider: TranscriptionProvider {
        TranscriptionProvider(rawValue: transcriptionProvider) ?? .local
    }

    var resolvedLanguageMode: DictationLanguageMode {
        DictationLanguageMode(rawValue: dictationLanguageMode) ?? .english
    }

    /// Clamped to the selected language mode, so a provider that cannot handle
    /// the user's language can never run even if it is still stored in defaults.
    var resolvedCleanupProvider: CleanupProvider {
        CleanupProvider.resolved(
            storedRawValue: cleanupProvider,
            languageMode: resolvedLanguageMode
        )
    }

    var resolvedCleanupStyling: CleanupStyling {
        CleanupStyling(rawValue: cleanupStyling) ?? .semiFormal
    }

    var resolvedCleanupStructure: CleanupStructure {
        CleanupStructure(rawValue: cleanupStructure) ?? .prose
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
