import SwiftUI
import ServiceManagement
import AVFoundation

struct SettingsView: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject var modelManager: ModelManager
    var updater: (any AppUpdateDriver)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: launchAtLoginDefaultsKey)
    @State private var isRunningEnvironmentFix = false
    @State private var pendingFixKeyboardAccess = false
    @State private var diagnosticsMessage: String?
    @State private var selectedSection: SettingsSection = .general
    @AppStorage(diagnosticLoggingEnabledDefaultsKey) private var diagnosticLoggingEnabled = false
    @AppStorage(openaiAPIKeySavedDefaultsKey) private var hasSavedOpenAIKey = false
    @AppStorage(anthropicAPIKeySavedDefaultsKey) private var hasSavedAnthropicKey = false

    @State private var openaiAPIKey: String = ""
    @State private var anthropicAPIKey: String = ""

    private var activeTranscriptionProfile: TranscriptionProfile {
        TranscriptionProfile(rawValue: engine.transcriptionProfile) ?? .balanced
    }
    private var allChecksHealthy: Bool {
        let modelOK = modelManager.isDownloaded || engine.resolvedTranscriptionProvider != .local
        return engine.hasMicrophone && engine.hasPostEvent && modelOK
    }

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case dictation
        case cleanup
        case connections
        case diagnostics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .dictation: return "Dictation"
            case .cleanup: return "Cleanup"
            case .connections: return "Connections"
            case .diagnostics: return "Diagnostics"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .dictation: return "waveform"
            case .cleanup: return "sparkles"
            case .connections: return "point.3.connected.trianglepath.dotted"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            VStack(spacing: 12) {
                settingsHeader
                settingsForm {
                    selectedSettingsContent
                }
            }
            .padding(16)
        }
        .frame(width: 760, height: 660)
        .onAppear {
            modelManager.refreshDownloadStatus()
            refreshPermissionSnapshot()
            if TranscriptionProfile(rawValue: engine.transcriptionProfile) == nil {
                engine.transcriptionProfile = TranscriptionProfile.balanced.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionSnapshot()
            continueGuidedFixIfNeeded()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.icon)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedSection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary)
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 170)
        .background(Color.secondary.opacity(0.08))
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedSection {
        case .general:
            generalSection
            hotkeySection
        case .dictation:
            dictationSection
            if engine.resolvedTranscriptionProvider == .local {
                speechModelSection
            }
        case .cleanup:
            cleanupSection
        case .connections:
            connectionsSection
        case .diagnostics:
            diagnosticsSection
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = HoldToTalkApp.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "mic")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Hold to Talk")
                    .font(.title2.bold())
                Text("Dictation and cleanup are configured separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Link(destination: URL(string: "https://github.com/jxucoder/hold-to-talk")!) {
                Image(systemName: "star")
            }
            Link(destination: URL(string: "https://buymeacoffee.com/jerryxu")!) {
                Image(systemName: "cup.and.saucer.fill")
            }
        }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
    }

    private func helperText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func providerKeyStatus(_ provider: String, isSaved: Bool, use: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSaved ? "checkmark.circle.fill" : "key.fill")
                .foregroundStyle(isSaved ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSaved ? "\(provider) key saved" : "\(provider) key not saved")
                    .font(.caption.weight(.semibold))
                Text(use)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var generalSection: some View {
        Section("General") {
            helperText("Control app startup, updates, and the key you hold to record.")

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        UserDefaults.standard.set(enabled, forKey: launchAtLoginDefaultsKey)
                    } catch {
                        launchAtLogin = !enabled
                    }
                }

            if let updater {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
            } else {
                helperText(
                    appHasStableCodeIdentity()
                    ? "Updates are not available in this build."
                    : "This is a local test build. Install a signed release to use automatic updates."
                )
            }
        }
    }

    private var hotkeySection: some View {
        Section("Hold Key") {
            helperText("Choose what you hold while speaking. Release the key to transcribe and insert text.")

            HotkeySelectionView(selection: $engine.hotkeyChoice, keyLabel: "Hold to record") {
                engine.reloadHotkey()
            }

            helperText("Choose Either, Left, or Right for modifier keys. Modifier-only keys use Keyboard Access.")
        }
    }

    private var dictationSection: some View {
        Section("Dictation") {
            helperText("Dictation turns speech into text. Cleanup happens afterward and can use a different provider.")

            Picker("Dictation Provider", selection: $engine.transcriptionProvider) {
                ForEach(TranscriptionProvider.allCases) { provider in
                    Text(transcriptionProviderLabel(provider)).tag(provider.rawValue)
                }
            }

            if engine.resolvedTranscriptionProvider == .openAI {
                providerKeyStatus(
                    "OpenAI",
                    isSaved: hasSavedOpenAIKey,
                    use: "Required for cloud dictation. Set it up in Connections."
                )
                if !hasSavedOpenAIKey {
                    Button("Open Connections") {
                        selectedSection = .connections
                    }
                    .controlSize(.small)
                }
                helperText("Audio is sent directly from your Mac to the endpoint you configure.")
                DisclosureGroup("Advanced") {
                    TextField("Model", text: $engine.openaiTranscriptionModel,
                              prompt: Text("gpt-4o-mini-transcribe"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Base URL", text: $engine.openaiBaseURL,
                              prompt: Text("https://api.openai.com/v1"))
                        .font(.system(.body, design: .monospaced))
                }
            }

            if engine.resolvedTranscriptionProvider == .local {
                helperText("Local dictation uses the model below and does not send audio to a cloud provider.")

                Picker("Profile", selection: $engine.transcriptionProfile) {
                    ForEach(TranscriptionProfile.allCases) { profile in
                        Text(profile.displayName)
                            .tag(profile.rawValue)
                    }
                }
                Text(activeTranscriptionProfile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Advanced") {
                    TextEditor(text: $engine.hotwords)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.separator)
                        )

                    Text("Boost recognition of specific words or phrases. One per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        if !engine.hotwords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear") {
                                engine.hotwords = ""
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .onChange(of: engine.hotwords) {
                    engine.reloadTranscriber()
                }
            }
        }
    }

    private var speechModelSection: some View {
        Section("Local Model") {
            helperText("Used for local dictation. Hidden when cloud dictation is selected.")
            modelStatusView
            DisclosureGroup("Model Details") {
                ModelTrustView()
            }
        }
    }

    private var cleanupSection: some View {
        Section("Cleanup") {
            helperText("Cleanup edits the transcript after dictation. Turn it off for the fastest, literal output.")

            Toggle("Clean up transcribed text", isOn: $engine.textCleanupEnabled)

            if engine.textCleanupEnabled {
                Picker("Cleanup Provider", selection: $engine.cleanupProvider) {
                    ForEach(CleanupProvider.allCases) { provider in
                        Text(cleanupProviderLabel(provider)).tag(provider.rawValue)
                    }
                }

                if engine.resolvedCleanupProvider == .appleIntelligence {
                    let availability = TextCleanup.checkAvailability()
                    HStack(spacing: 6) {
                        if availability == .available {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Apple Intelligence is available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(textCleanupUnavailableReason(availability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Text is cleaned up on-device to fix punctuation, repeated words, and filler words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if engine.resolvedCleanupProvider == .openAI {
                    providerKeyStatus(
                        "OpenAI",
                        isSaved: hasSavedOpenAIKey,
                        use: "Required for OpenAI cleanup. Set it up in Connections."
                    )
                    if !hasSavedOpenAIKey {
                        Button("Open Connections") {
                            selectedSection = .connections
                        }
                        .controlSize(.small)
                    }
                    DisclosureGroup("Advanced") {
                        TextField("Model", text: $engine.openaiCleanupModel,
                                  prompt: Text(CleanupProvider.openAI.defaultModel))
                            .font(.system(.body, design: .monospaced))
                        if engine.resolvedTranscriptionProvider != .openAI {
                            TextField("Base URL", text: $engine.openaiBaseURL,
                                      prompt: Text("https://api.openai.com/v1"))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    helperText("Uses the OpenAI-compatible chat completions API.")
                }

                if engine.resolvedCleanupProvider == .anthropic {
                    providerKeyStatus(
                        "Anthropic",
                        isSaved: hasSavedAnthropicKey,
                        use: "Required for Anthropic cleanup. Set it up in Connections."
                    )
                    if !hasSavedAnthropicKey {
                        Button("Open Connections") {
                            selectedSection = .connections
                        }
                        .controlSize(.small)
                    }
                    DisclosureGroup("Advanced") {
                        TextField("Model", text: $engine.anthropicCleanupModel,
                                  prompt: Text(CleanupProvider.anthropic.defaultModel))
                            .font(.system(.body, design: .monospaced))
                        TextField("Base URL", text: $engine.anthropicBaseURL,
                                  prompt: Text("https://api.anthropic.com"))
                            .font(.system(.body, design: .monospaced))
                    }
                    helperText("Uses the Anthropic messages API.")
                }

                DisclosureGroup("Cleanup Instructions") {
                    TextEditor(text: $engine.textCleanupPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.separator)
                        )

                    HStack {
                        Spacer()
                        if engine.textCleanupPrompt != TextCleanup.defaultPrompt {
                            Button("Reset to Default") {
                                engine.textCleanupPrompt = TextCleanup.defaultPrompt
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var connectionsSection: some View {
        Group {
        Section("OpenAI") {
            helperText("Used for cloud dictation and OpenAI cleanup.")

            connectionEditor(
                provider: "OpenAI",
                account: "openai",
                key: $openaiAPIKey,
                isSaved: $hasSavedOpenAIKey,
                placeholder: "Paste your OpenAI API key"
            )
        }

        Section("Anthropic") {
            helperText("Used for Anthropic cleanup. Dictation does not use Anthropic.")

            connectionEditor(
                provider: "Anthropic",
                account: "anthropic",
                key: $anthropicAPIKey,
                isSaved: $hasSavedAnthropicKey,
                placeholder: "Paste your Anthropic API key"
            )
        }

        Section("Storage") {
            helperText("Connections are stored in the macOS Keychain for this Mac only. Hold to Talk reads them only when cloud dictation or cloud cleanup is used.")
        }
        }
    }

    private func connectionEditor(
        provider: String,
        account: String,
        key: Binding<String>,
        isSaved: Binding<Bool>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    isSaved.wrappedValue ? "Connected" : "Not connected",
                    systemImage: isSaved.wrappedValue ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSaved.wrappedValue ? .green : .orange)

                Spacer()

                if isSaved.wrappedValue {
                    Button("Remove", role: .destructive) {
                        KeychainHelper.delete(account: account)
                        isSaved.wrappedValue = false
                        key.wrappedValue = ""
                    }
                    .controlSize(.small)
                }
            }

            Text("Paste your \(provider) API key below, then click Save Connection.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField(placeholder, text: key)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(isSaved.wrappedValue ? "Leave blank to keep the saved key." : "No key is saved yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(isSaved.wrappedValue ? "Replace Connection" : "Save Connection") {
                    if KeychainHelper.save(account: account, key: key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        isSaved.wrappedValue = true
                        key.wrappedValue = ""
                    }
                }
                .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            helperText("Use this tab when something is not recording, transcribing, or inserting text.")

            statusRow(
                title: "Microphone",
                ok: engine.hasMicrophone,
                details: engine.hasMicrophone ? "Granted" : "Needed to record your voice"
            )
            statusRow(
                title: "Keyboard Access",
                ok: engine.hasPostEvent,
                details: engine.hasPostEvent ? "Granted" : "Needed to type text into other apps"
            )
            statusRow(
                title: "Speech model",
                ok: modelManager.isDownloaded || engine.resolvedTranscriptionProvider != .local,
                details: modelManager.isDownloaded
                    ? "\(SpeechModelInfo.displayName) ready"
                    : (modelManager.isDownloading
                        ? "Downloading \(SpeechModelInfo.displayName)..."
                        : (engine.resolvedTranscriptionProvider != .local
                            ? "Using cloud dictation"
                            : "\(SpeechModelInfo.displayName) not downloaded"))
            )
            Toggle("Store diagnostic logs", isOn: $diagnosticLoggingEnabled)
                .onChange(of: diagnosticLoggingEnabled) { _, enabled in
                    if enabled {
                        debugLog("[holdtotalk] Diagnostic logging enabled.")
                    } else {
                        clearDebugLog()
                    }
                }

            Text(diagnosticLoggingEnabled
                 ? "Local diagnostic logging is enabled. Logs stay on your Mac and transcript text is redacted."
                 : "Diagnostic logging is off by default. Turn it on only when troubleshooting; transcript text stays redacted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let diagnosticsMessage {
                Text(diagnosticsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(allChecksHealthy ? "Environment Healthy" : "Repair Missing Setup") {
                runGuidedEnvironmentFix()
            }
            .disabled(isRunningEnvironmentFix || allChecksHealthy)

            if isRunningEnvironmentFix {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func transcriptionProviderLabel(_ provider: TranscriptionProvider) -> String {
        switch provider {
        case .local:
            return "Local (on this Mac)"
        case .openAI:
            return "Cloud (OpenAI-compatible)"
        }
    }

    private func cleanupProviderLabel(_ provider: CleanupProvider) -> String {
        switch provider {
        case .appleIntelligence:
            return "Local (Apple Intelligence)"
        case .openAI:
            return "Cloud (OpenAI)"
        case .anthropic:
            return "Cloud (Anthropic)"
        }
    }

    // MARK: - Model Status

    @ViewBuilder
    private var modelStatusView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(SpeechModelInfo.displayName)
                        .fontWeight(.semibold)
                    Text(modelManager.isDownloaded
                         ? (modelManager.diskSize() ?? SpeechModelInfo.sizeLabel)
                         : SpeechModelInfo.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if modelManager.isDownloaded {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button(role: .destructive) {
                            modelManager.deleteModel()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                } else if modelManager.isDownloading {
                    Button("Cancel") {
                        modelManager.cancelDownload()
                    }
                    .controlSize(.small)
                } else {
                    Button("Download") {
                        modelManager.download()
                    }
                    .controlSize(.small)
                }
            }

            if modelManager.isDownloading {
                ProgressView(value: modelManager.downloadProgress)
                    .progressViewStyle(.linear)
                Text("\(Int(modelManager.downloadProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = modelManager.downloadError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Diagnostics

    private func statusRow(title: String, ok: Bool, details: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func refreshPermissionSnapshot() {
        engine.refreshPermissionSnapshot()
    }

    private func runGuidedEnvironmentFix() {
        isRunningEnvironmentFix = true
        pendingFixKeyboardAccess = false
        diagnosticsMessage = nil

        refreshPermissionSnapshot()

        requestMicrophonePermission(openSettings: true) {
            Task { @MainActor in
                refreshPermissionSnapshot()
                continueAfterMicrophoneFix()
            }
        }
    }

    private func continueAfterMicrophoneFix() {
        guard engine.hasMicrophone else {
            diagnosticsMessage = "Enable Microphone access in System Settings, then return here."
            isRunningEnvironmentFix = false
            return
        }

        _ = requestPostEventPermission()
        refreshPermissionSnapshot()
        if !engine.hasPostEvent {
            pendingFixKeyboardAccess = true
            diagnosticsMessage = "Enable Keyboard Access, then return to Hold to Talk."
            isRunningEnvironmentFix = false
            return
        }

        finishGuidedEnvironmentFix()
    }

    private func continueGuidedFixIfNeeded() {
        guard pendingFixKeyboardAccess else { return }
        guard engine.hasPostEvent else { return }

        pendingFixKeyboardAccess = false
        finishGuidedEnvironmentFix()
    }

    private func finishGuidedEnvironmentFix() {
        refreshPermissionSnapshot()

        if !modelManager.isDownloaded && !modelManager.isDownloading {
            modelManager.download()
            diagnosticsMessage = "Downloading \(SpeechModelInfo.displayName)…"
        } else if modelManager.isDownloading {
            diagnosticsMessage = "Downloading \(SpeechModelInfo.displayName)…"
        } else {
            diagnosticsMessage = "Environment is healthy."
        }

        isRunningEnvironmentFix = false
    }

    private func requestMicrophonePermission(openSettings: Bool, completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in
                    completion()
                }
            }
        case .denied, .restricted:
            if openSettings {
                openSystemSettings("Privacy_Microphone")
            }
            completion()
        @unknown default:
            completion()
        }
    }

    @discardableResult
    private func requestPostEventPermission() -> PermissionRequestResult {
        requestPostEventAccess()
    }

    private func textCleanupUnavailableReason(_ availability: TextCleanupAvailability) -> String {
        switch availability {
        case .available:
            return "Apple Intelligence is available"
        case .unavailableOSVersion:
            return "Requires macOS 26 or later"
        case .unavailableNotEnabled:
            return "Enable Apple Intelligence in System Settings"
        case .unavailableDeviceNotEligible:
            return "This Mac does not support Apple Intelligence"
        case .unavailableModelNotReady:
            return "Apple Intelligence model is downloading"
        }
    }
}
