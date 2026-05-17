import SwiftUI
import AppKit
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject var modelManager: ModelManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private let systemCompatibility: SystemCompatibility
    private let onboardingContentWidth: CGFloat = 500

    @AppStorage(onboardingStepDefaultsKey) private var step = 0
    @State private var hasMicrophone = false
    @State private var hasPostEvent = false
    @AppStorage(postEventPromptedDefaultsKey) private var hasShownPostEventPrompt = false
    @State private var isRequestingPermissions = false
    @State private var pendingPermissionReturn: PermissionRequirement?
    @State private var shouldOfferKeyboardAccessRelaunch = false
    @State private var isInstallingToApplications = false
    @State private var installErrorMessage: String?
    @State private var onboardingWindow: NSWindow?
    @State private var settingsReturnTask: Task<Void, Never>?
    @State private var speechSetupMode: SpeechSetupMode = .local
    @State private var isDictationAdvancedExpanded = false
    @State private var cleanupSetupMode: CleanupSetupMode = .off
    @State private var isCleanupAdvancedExpanded = false
    @State private var onboardingOpenAIAPIKey = ""
    @State private var onboardingAnthropicAPIKey = ""
    @AppStorage(openaiAPIKeySavedDefaultsKey) private var hasSavedOnboardingOpenAIKey = false
    @AppStorage(anthropicAPIKeySavedDefaultsKey) private var hasSavedOnboardingAnthropicKey = false
    @StateObject private var hotkeyTester = HotkeyTester()

    init(engine: DictationEngine, modelManager: ModelManager) {
        self.engine = engine
        self.modelManager = modelManager
        self.systemCompatibility = .current()
        #if DEBUG
        if let override = DebugFlags.onboardingStep {
            let clamped = max(0, min(override, 3))
            UserDefaults.standard.set(clamped, forKey: onboardingStepDefaultsKey)
            print("[debug] Starting onboarding at step \(clamped).")
        }
        #endif
    }

    private enum PermissionRequirement: Int, CaseIterable, Identifiable {
        case microphone
        case keyboardAccess

        var id: Self { self }

        var icon: String {
            switch self {
            case .microphone: "mic.fill"
            case .keyboardAccess: "keyboard.badge.ellipsis"
            }
        }

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .keyboardAccess: "Keyboard Access"
            }
        }

        var subtitle: String {
            switch self {
            case .microphone: "Record your voice for transcription."
            case .keyboardAccess: "Type dictated text into any application."
            }
        }
    }

    private enum SpeechSetupMode: String, CaseIterable, Identifiable {
        case local
        case openAI

        var id: String { rawValue }

        var label: String {
            switch self {
            case .local:
                return "Local model"
            case .openAI:
                return "Use OpenAI instead"
            }
        }
    }

    private enum CleanupSetupMode: String, CaseIterable, Identifiable {
        case off
        case appleIntelligence
        case openAI
        case anthropic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .appleIntelligence: return "Apple Intelligence"
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            }
        }

        var subtitle: String {
            switch self {
            case .off:
                return "Insert the transcript exactly as dictated."
            case .appleIntelligence:
                return "Polish text on this Mac when Apple Intelligence is available."
            case .openAI:
                return "Use your OpenAI key for punctuation and cleanup."
            case .anthropic:
                return "Use your Anthropic key for punctuation and cleanup."
            }
        }

        var icon: String {
            switch self {
            case .off: return "text.quote"
            case .appleIntelligence: return "sparkles"
            case .openAI: return "cloud.fill"
            case .anthropic: return "cloud.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)

            Spacer()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: dictationStep
                case 3: cleanupStep
                default: hotkeyStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer()
        }
        .frame(width: 560, height: onboardingWindowHeight)
        .animation(.easeInOut(duration: 0.3), value: step)
        .background(OnboardingWindowReader(window: $onboardingWindow))
    }

    private var onboardingWindowHeight: CGFloat {
        switch step {
        case 0:
            return 640
        case 1:
            return 650
        case 2:
            return 680
        case 3:
            return 620
        default:
            return 540
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        let installed = isInstalledInApplicationsFolder()

        return VStack(spacing: 16) {
            VStack(spacing: 14) {
                appIcon
                    .frame(width: 80, height: 80)

                Text("Welcome to Hold to Talk")
                    .font(.title.bold())

                Text("Hold a key, speak, and your words appear where your cursor is.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: onboardingContentWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 8) {
                featureRow("lock.fill", "Local dictation by default")
                featureRow("key.fill", "Cloud only when you bring your own key")
                featureRow("sparkles", "Optional cleanup after transcription")
            }
            .frame(maxWidth: onboardingContentWidth, alignment: .leading)

            systemRequirementsCard

            if !installed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Install to /Applications", systemImage: "arrow.down.app.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Hold to Talk works best when installed in /Applications. Requires \(systemCompatibility.requirements.summaryText).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Install to Applications") {
                        installErrorMessage = nil
                        isInstallingToApplications = true
                        switch installToApplicationsAndRelaunch() {
                        case .success:
                            break
                        case .failure(let message):
                            installErrorMessage = message
                            isInstallingToApplications = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    if isInstallingToApplications {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: onboardingContentWidth, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                )

                if let installErrorMessage {
                    Text(installErrorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: onboardingContentWidth)
                }
            }

            Button(welcomeActionTitle(installed: installed)) {
                step = 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!installed || !systemCompatibility.isSupported)
            .padding(.top, 4)

            if !systemCompatibility.isSupported {
                Text(systemCompatibility.statusDetailText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: onboardingContentWidth)
            }
        }
        .padding(32)
    }

    private func welcomeActionTitle(installed: Bool) -> String {
        if !systemCompatibility.isSupported {
            return "This Mac Is Not Supported"
        }
        return installed ? "Get Started" : "Install to /Applications First"
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func choiceHeader(
        selected: Bool,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : icon)
                .font(.title3)
                .foregroundStyle(selected ? .green : Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func choiceBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.10))
    }

    private func choiceBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor.opacity(0.40) : Color.secondary.opacity(0.12))
    }

    private func advancedDisclosure<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var systemRequirementsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("System requirements", systemImage: "desktopcomputer")
                .font(.headline)

            requirementRow(
                title: "Requires",
                value: systemCompatibility.requirements.summaryText
            )
            requirementRow(
                title: "This Mac",
                value: "macOS \(systemCompatibility.currentMacOSDisplayName)"
            )
            requirementRow(
                title: "Mode",
                value: defaultSpeechModeDescription
            )

            HStack(spacing: 8) {
                Image(systemName: systemCompatibility.isSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text(systemCompatibility.statusText)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(systemCompatibility.isSupported ? .green : .red)
        }
        .frame(maxWidth: onboardingContentWidth, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
        )
    }

    private var defaultSpeechModeDescription: String {
        systemCompatibility.isAppleSiliconMac
            ? "Local Parakeet model + Apple Intelligence cleanup when available"
            : "Apple Silicon required for local Parakeet transcription"
    }

    private func requirementRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Permissions

    private var hasAllPermissions: Bool {
        hasMicrophone && hasPostEvent
    }

    private var permissionsGrantedCount: Int {
        [hasMicrophone, hasPostEvent].filter { $0 }.count
    }

    private var currentPermission: PermissionRequirement? {
        PermissionRequirement.allCases.first(where: { !isGranted($0) })
    }

    private var microphoneActionTitle: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return "Allow Microphone"
        case .authorized: return "Microphone Granted"
        case .denied, .restricted: return "Open Microphone Settings"
        @unknown default: return "Allow Microphone"
        }
    }

    private var keyboardAccessActionTitle: String {
        if hasPostEvent { return "Keyboard Access Granted" }
        return hasShownPostEventPrompt ? "Open Keyboard Access Settings" : "Allow Keyboard Access"
    }

    private var keyboardAccessCanUseRelaunchRecovery: Bool {
        appHasStableCodeIdentity()
    }

    private var permissionsStep: some View {
        VStack(spacing: 18) {
            Text("Permissions")
                .font(.title2.bold())

            Text("Enable the required permissions one at a time. This keeps the macOS prompts clear and predictable.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: onboardingContentWidth)

            permissionsProgressCard

            VStack(spacing: 10) {
                ForEach(PermissionRequirement.allCases) { permission in
                    permissionRow(permission)
                }
            }
            .frame(maxWidth: onboardingContentWidth)

            if isRequestingPermissions {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for macOS permission dialog…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            permissionRecoveryMessage

            if currentPermission == .keyboardAccess && shouldOfferKeyboardAccessRelaunch {
                VStack(spacing: 8) {
                    if keyboardAccessCanUseRelaunchRecovery {
                        Text("If Keyboard Access is already enabled but still looks pending, relaunch Hold to Talk once.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("macOS can keep this permission stale until the app restarts.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Relaunch Hold to Talk") {
                            relaunchApp()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text("This build is ad-hoc signed, so relaunch may not refresh Keyboard Access after a rebuild.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("If HoldToTalk is enabled in Accessibility but still stays pending, remove it and add it again, or rebuild with a stable signing identity.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: onboardingContentWidth)
            }

            HStack(spacing: 12) {
                Button("Recheck") {
                    refreshPermissions()
                    refocusOnboardingWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Next: Dictation") {
                    step = 2
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasAllPermissions)
            }
            .padding(.top, 8)

            if !hasAllPermissions, let currentPermission {
                Text("Finish \(currentPermission.title) before continuing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("All required permissions are ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            VStack(spacing: 6) {
                Text("Debug helper for local permission testing.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button("Skip Permissions (Debug)") {
                    hasMicrophone = true
                    hasPostEvent = true
                    engine.hasPostEvent = true
                    engine.hasMicrophone = true
                    step = 2
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
            #endif
        }
        .padding(32)
        .frame(maxWidth: onboardingContentWidth + 64)
        .task {
            refreshPermissions()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshPermissions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isRequestingPermissions = false
            refreshPermissions()
            if pendingPermissionReturn == .keyboardAccess && !hasPostEvent {
                shouldOfferKeyboardAccessRelaunch = true
            }
            pendingPermissionReturn = nil
            refocusOnboardingWindow()
        }
        .onDisappear {
            if engine.onboardingComplete || step != 1 {
                settingsReturnTask?.cancel()
                settingsReturnTask = nil
            }
        }
    }

    private var permissionsProgressCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Setup Progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(permissionsGrantedCount)/2 granted")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(permissionsGrantedCount), total: 2)
                .progressViewStyle(.linear)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
        )
        .frame(maxWidth: onboardingContentWidth)
    }

    private func permissionRow(_ permission: PermissionRequirement) -> some View {
        let granted = isGranted(permission)
        let active = permission == currentPermission

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : permission.icon)
                    .font(.title3)
                    .foregroundStyle(granted ? .green : (active ? Color.accentColor : .secondary))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                        .font(.headline)
                    Text(permission.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(granted ? "Granted" : (active ? "Current" : "Next"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(granted ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if active && !granted {
                Button(permissionActionTitle(for: permission)) {
                    requestPermission(permission)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequestingPermissions)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(active && !granted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(active && !granted ? Color.accentColor.opacity(0.40) : Color.clear)
        )
    }

    @ViewBuilder
    private var permissionRecoveryMessage: some View {
        if hasAllPermissions {
            Label("All required permissions are ready.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if currentPermission == .keyboardAccess {
            Text("After enabling Hold To Talk in Accessibility, return here or press Recheck.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: onboardingContentWidth)
        }
    }

    // MARK: - Step 3: Dictation

    private var dictationStep: some View {
        VStack(spacing: 18) {
            Text("Dictation")
                .font(.title2.bold())

            Text("Choose where speech becomes text.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: onboardingContentWidth)

            VStack(spacing: 12) {
                dictationChoiceCard(
                    mode: .local,
                    title: "Local",
                    subtitle: "Recommended. Audio stays on this Mac.",
                    icon: "lock.fill"
                ) {
                    localDictationDetails
                }

                dictationChoiceCard(
                    mode: .openAI,
                    title: "Cloud",
                    subtitle: "Use your own OpenAI-compatible key.",
                    icon: "cloud.fill"
                ) {
                    cloudDictationDetails
                }
            }
            .frame(maxWidth: onboardingContentWidth)

            HStack(spacing: 12) {
                Button("Back") {
                    step = 1
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Continue") {
                    finishDictationSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinueDictationSetup)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: onboardingContentWidth + 64)
        .onAppear {
            prepareDictationSetup()
        }
        .onChange(of: modelManager.isDownloaded) {
            warmUpModelIfReady()
        }
    }

    private func dictationChoiceCard<Details: View>(
        mode: SpeechSetupMode,
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder details: () -> Details
    ) -> some View {
        let selected = speechSetupMode == mode

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                guard systemCompatibility.isAppleSiliconMac else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    speechSetupMode = mode
                }
            } label: {
                choiceHeader(selected: selected, title: title, subtitle: subtitle, icon: icon)
            }
            .buttonStyle(.plain)
            .disabled(!systemCompatibility.isAppleSiliconMac)

            if selected {
                details()
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(choiceBackground(selected: selected))
        .overlay(choiceBorder(selected: selected))
    }

    private var localDictationDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if modelManager.isDownloaded {
                Label("Ready for local dictation", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.weight(.semibold))
            } else if modelManager.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: modelManager.downloadProgress)
                    Text("Downloading local model... \(Int(modelManager.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download Local Model") {
                    modelManager.download()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if let error = modelManager.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cloudDictationDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio is sent directly from your Mac to the endpoint you configure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(hasSavedOnboardingOpenAIKey ? "New OpenAI API Key" : "OpenAI API Key", text: $onboardingOpenAIAPIKey)

            advancedDisclosure(title: "Advanced", isExpanded: $isDictationAdvancedExpanded) {
                TextField("Model", text: $engine.openaiTranscriptionModel,
                          prompt: Text("gpt-4o-mini-transcribe"))
                    .font(.system(.body, design: .monospaced))

                TextField("Base URL", text: $engine.openaiBaseURL,
                          prompt: Text("https://api.openai.com/v1"))
                    .font(.system(.body, design: .monospaced))
            }

            if hasSavedOnboardingOpenAIKey && onboardingOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("OpenAI key saved. Enter a new key only to replace it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !hasOnboardingOpenAIKey {
                Text("Enter an OpenAI API key to continue with cloud dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasOnboardingOpenAIKey: Bool {
        hasSavedOnboardingOpenAIKey || !onboardingOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasOnboardingAnthropicKey: Bool {
        hasSavedOnboardingAnthropicKey || !onboardingAnthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canContinueDictationSetup: Bool {
        guard systemCompatibility.isAppleSiliconMac else { return false }
        switch speechSetupMode {
        case .local:
            return modelManager.isDownloaded
        case .openAI:
            return hasOnboardingOpenAIKey
        }
    }

    private func prepareDictationSetup() {
        modelManager.refreshDownloadStatus()
        if !systemCompatibility.isAppleSiliconMac {
            speechSetupMode = .local
        } else if engine.resolvedTranscriptionProvider == .openAI {
            speechSetupMode = .openAI
        } else {
            speechSetupMode = .local
        }
        warmUpModelIfReady()
    }

    private func finishDictationSetup() {
        switch speechSetupMode {
        case .local:
            engine.transcriptionProvider = TranscriptionProvider.local.rawValue
            warmUpModelIfReady()
        case .openAI:
            saveOnboardingOpenAIKeyIfNeeded()
            engine.transcriptionProvider = TranscriptionProvider.openAI.rawValue
            if engine.openaiTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.openaiTranscriptionModel = "gpt-4o-mini-transcribe"
            }
            if engine.openaiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.openaiBaseURL = ""
            }
        }
        step = 3
    }

    // MARK: - Step 4: Cleanup

    private var cleanupStep: some View {
        VStack(spacing: 18) {
            Text("Cleanup")
                .font(.title2.bold())

            Text("Choose what happens after transcription.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: onboardingContentWidth)

            VStack(spacing: 10) {
                cleanupChoiceCard(.off)
                cleanupChoiceCard(.appleIntelligence)
                cleanupChoiceCard(.openAI)
                cleanupChoiceCard(.anthropic)
            }
            .frame(maxWidth: onboardingContentWidth)

            HStack(spacing: 12) {
                Button("Back") {
                    step = 2
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Continue") {
                    finishCleanupSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinueCleanupSetup)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: onboardingContentWidth + 64)
        .onAppear {
            prepareCleanupSetup()
        }
    }

    private func cleanupChoiceCard(_ mode: CleanupSetupMode) -> some View {
        let selected = cleanupSetupMode == mode
        let disabled = mode == .appleIntelligence && TextCleanup.checkAvailability() != .available

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !disabled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    cleanupSetupMode = mode
                }
            } label: {
                choiceHeader(
                    selected: selected,
                    title: mode.title,
                    subtitle: cleanupSubtitle(for: mode),
                    icon: mode.icon
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            if selected {
                cleanupDetails(for: mode)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(choiceBackground(selected: selected))
        .overlay(choiceBorder(selected: selected))
        .opacity(disabled ? 0.62 : 1)
    }

    private func cleanupSubtitle(for mode: CleanupSetupMode) -> String {
        if mode == .appleIntelligence {
            let availability = TextCleanup.checkAvailability()
            if availability != .available {
                return textCleanupUnavailableReason(availability)
            }
        }
        return mode.subtitle
    }

    @ViewBuilder
    private func cleanupDetails(for mode: CleanupSetupMode) -> some View {
        switch mode {
        case .off:
            Text("Fastest path. You can turn cleanup on later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .appleIntelligence:
            Label("Cleanup runs on this Mac", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .openAI:
            cloudCleanupFields(
                keyPrompt: hasSavedOnboardingOpenAIKey ? "New OpenAI API Key" : "OpenAI API Key",
                key: $onboardingOpenAIAPIKey,
                saved: hasSavedOnboardingOpenAIKey,
                missingText: "Enter an OpenAI API key to continue with cloud cleanup."
            ) {
                TextField("Model", text: $engine.openaiCleanupModel,
                          prompt: Text(CleanupProvider.openAI.defaultModel))
                    .font(.system(.body, design: .monospaced))

                TextField("Base URL", text: $engine.openaiBaseURL,
                          prompt: Text("https://api.openai.com/v1"))
                    .font(.system(.body, design: .monospaced))
            }
        case .anthropic:
            cloudCleanupFields(
                keyPrompt: hasSavedOnboardingAnthropicKey ? "New Anthropic API Key" : "Anthropic API Key",
                key: $onboardingAnthropicAPIKey,
                saved: hasSavedOnboardingAnthropicKey,
                missingText: "Enter an Anthropic API key to continue with cloud cleanup."
            ) {
                TextField("Model", text: $engine.anthropicCleanupModel,
                          prompt: Text(CleanupProvider.anthropic.defaultModel))
                    .font(.system(.body, design: .monospaced))

                TextField("Base URL", text: $engine.anthropicBaseURL,
                          prompt: Text("https://api.anthropic.com"))
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private func cloudCleanupFields<Advanced: View>(
        keyPrompt: String,
        key: Binding<String>,
        saved: Bool,
        missingText: String,
        @ViewBuilder advanced: () -> Advanced
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(keyPrompt, text: key)

            advancedDisclosure(title: "Advanced", isExpanded: $isCleanupAdvancedExpanded) {
                advanced()
            }

            if saved && key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Key saved. Enter a new key only to replace it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(missingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canContinueCleanupSetup: Bool {
        switch cleanupSetupMode {
        case .off:
            return true
        case .appleIntelligence:
            return TextCleanup.checkAvailability() == .available
        case .openAI:
            return hasOnboardingOpenAIKey
        case .anthropic:
            return hasOnboardingAnthropicKey
        }
    }

    private func prepareCleanupSetup() {
        if !engine.textCleanupEnabled {
            cleanupSetupMode = .off
            return
        }

        switch engine.resolvedCleanupProvider {
        case .appleIntelligence:
            cleanupSetupMode = TextCleanup.checkAvailability() == .available ? .appleIntelligence : .off
        case .openAI:
            cleanupSetupMode = .openAI
        case .anthropic:
            cleanupSetupMode = .anthropic
        }
    }

    private func finishCleanupSetup() {
        switch cleanupSetupMode {
        case .off:
            engine.textCleanupEnabled = false
        case .appleIntelligence:
            engine.cleanupProvider = CleanupProvider.appleIntelligence.rawValue
            engine.textCleanupEnabled = true
        case .openAI:
            saveOnboardingOpenAIKeyIfNeeded()
            engine.cleanupProvider = CleanupProvider.openAI.rawValue
            engine.textCleanupEnabled = true
            if engine.openaiCleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.openaiCleanupModel = CleanupProvider.openAI.defaultModel
            }
        case .anthropic:
            saveOnboardingAnthropicKeyIfNeeded()
            engine.cleanupProvider = CleanupProvider.anthropic.rawValue
            engine.textCleanupEnabled = true
            if engine.anthropicCleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.anthropicCleanupModel = CleanupProvider.anthropic.defaultModel
            }
        }
        step = 4
    }

    // MARK: - Step 5: Hotkey

    private var resolvedHotkey: HotkeyManager.Hotkey {
        HotkeyManager.Hotkey.preferredSelection(from: engine.hotkeyChoice)
    }

    private var hotkeyStep: some View {
        VStack(spacing: 20) {
            Text("Hold Key")
                .font(.title2.bold())

            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Hold this key to record:")
                        .font(.body)

                    HotkeySelectionView(selection: $engine.hotkeyChoice, keyLabel: "Hotkey", maxWidth: 340) {
                        engine.reloadHotkey()
                        hotkeyTester.remove()
                        hotkeyTester.install(for: resolvedHotkey)
                    }
                }

                VStack(spacing: 8) {
                    switch hotkeyTester.phase {
                    case .waiting:
                        Image(systemName: "keyboard")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Press and hold [\(resolvedHotkey.displayName)] to test")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .holding:
                        Image(systemName: "mic.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                            .symbolEffect(.pulse)
                        Text("Holding [\(resolvedHotkey.displayName)]... release to finish")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                        Text("Hotkey works! You're ready to go.")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(height: 80)
                .animation(.easeInOut(duration: 0.2), value: hotkeyTester.phase)

                HStack(spacing: 8) {
                    Image(systemName: "dock.rectangle")
                        .font(.caption.bold())
                    Text("Hold to Talk stays in the Dock and menu bar")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }

            Button("Start Using Hold to Talk") {
                completeOnboardingAndCloseWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: onboardingContentWidth + 64)
        .onAppear {
            engine.prewarmTranscriber()
            hotkeyTester.install(for: resolvedHotkey)
        }
        .onDisappear {
            hotkeyTester.remove()
            if engine.onboardingComplete {
                step = 0
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var appIcon: some View {
        if let icon = HoldToTalkApp.appIcon {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: "mic.circle.fill")
                .resizable()
                .foregroundStyle(Color.accentColor)
        }
    }

    private func warmUpModelIfReady() {
        guard modelManager.isDownloaded else { return }
        engine.prewarmTranscriber()
    }

    private func saveOnboardingOpenAIKeyIfNeeded() {
        let trimmedAPIKey = onboardingOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { return }
        if KeychainHelper.save(account: "openai", key: trimmedAPIKey) {
            hasSavedOnboardingOpenAIKey = true
            onboardingOpenAIAPIKey = ""
        }
    }

    private func saveOnboardingAnthropicKeyIfNeeded() {
        let trimmedAPIKey = onboardingAnthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { return }
        if KeychainHelper.save(account: "anthropic", key: trimmedAPIKey) {
            hasSavedOnboardingAnthropicKey = true
            onboardingAnthropicAPIKey = ""
        }
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

    private func isGranted(_ permission: PermissionRequirement) -> Bool {
        switch permission {
        case .microphone:
            hasMicrophone
        case .keyboardAccess:
            hasPostEvent
        }
    }

    private func permissionActionTitle(for permission: PermissionRequirement) -> String {
        switch permission {
        case .microphone:
            microphoneActionTitle
        case .keyboardAccess:
            keyboardAccessActionTitle
        }
    }

    private func requestPermission(_ permission: PermissionRequirement) {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        pendingPermissionReturn = nil
        shouldOfferKeyboardAccessRelaunch = false

        switch permission {
        case .microphone:
            requestMicrophonePermission {
                refreshPermissions()
                isRequestingPermissions = false
            }
        case .keyboardAccess:
            let result = requestPostEventPermission()
            if result != .granted {
                pendingPermissionReturn = .keyboardAccess
                scheduleSettingsReturnRefocus()
            }
            refreshPermissions()
            finishPermissionRequestAfterDelay()
        }
    }

    private func finishPermissionRequestAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRequestingPermissions = false
        }
    }

    private func requestMicrophonePermission(openSettings: Bool = true, completion: (() -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            hasMicrophone = true
            refocusOnboardingWindow()
            completion?()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    hasMicrophone = granted
                    if !granted && openSettings {
                        openSystemSettings("Privacy_Microphone")
                        scheduleSettingsReturnRefocus()
                    } else {
                        self.refocusOnboardingWindow()
                    }
                    completion?()
                }
            }
        case .denied, .restricted:
            hasMicrophone = false
            if openSettings {
                openSystemSettings("Privacy_Microphone")
                scheduleSettingsReturnRefocus()
            } else {
                refocusOnboardingWindow()
            }
            completion?()
        @unknown default:
            hasMicrophone = false
            refocusOnboardingWindow()
            completion?()
        }
    }

    @discardableResult
    private func requestPostEventPermission() -> PermissionRequestResult {
        let result = requestPostEventAccess()
        hasShownPostEventPrompt = true
        refreshPermissions()
        return result
    }

    private func refreshPermissions() {
        engine.refreshPermissionSnapshot()
        hasMicrophone = engine.hasMicrophone
        hasPostEvent = engine.hasPostEvent
        if hasPostEvent {
            shouldOfferKeyboardAccessRelaunch = false
        }
    }

    private func scheduleSettingsReturnRefocus() {
        settingsReturnTask?.cancel()
        settingsReturnTask = Task { @MainActor in
            var sawSystemSettings = false

            try? await Task.sleep(nanoseconds: 700_000_000)

            for _ in 0..<120 where !Task.isCancelled {
                refreshPermissions()

                let frontmostApplication = NSWorkspace.shared.frontmostApplication
                if isSystemSettingsApplication(frontmostApplication) {
                    sawSystemSettings = true
                } else if sawSystemSettings {
                    refocusOnboardingWindow()
                    pendingPermissionReturn = nil
                    settingsReturnTask = nil
                    return
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            settingsReturnTask = nil
        }
    }

    private func refocusOnboardingWindow() {
        guard step == 1, !engine.onboardingComplete else { return }
        guard let onboardingWindow else {
            openWindow(id: "onboarding")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            onboardingWindow.orderFrontRegardless()
        }
    }

    private func completeOnboardingAndCloseWindow() {
        hotkeyTester.remove()
        engine.completeOnboarding()
        if let onboardingWindow {
            onboardingWindow.close()
        } else {
            dismiss()
        }
    }

    // openSystemSettings is now a shared top-level function in SystemSettingsHelper.swift
}

private struct OnboardingWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> OnboardingWindowProbeView {
        let view = OnboardingWindowProbeView()
        view.onResolve = { resolvedWindow in
            self.window = resolvedWindow
        }
        return view
    }

    func updateNSView(_ nsView: OnboardingWindowProbeView, context: Context) {
        nsView.onResolve = { resolvedWindow in
            self.window = resolvedWindow
        }
        if window !== nsView.window {
            window = nsView.window
        }
    }
}

private final class OnboardingWindowProbeView: NSView {
    var onResolve: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve?(window)
    }
}

// MARK: - HotkeyTester

@MainActor
private final class HotkeyTester: ObservableObject {
    enum Phase {
        case waiting, holding, success
    }

    @Published var phase: Phase = .waiting

    private var hotkeyManager: HotkeyManager?

    func install(for hotkey: HotkeyManager.Hotkey) {
        remove()
        phase = .waiting

        let manager = HotkeyManager(hotkey: hotkey)
        manager.onPress = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.phase == .waiting else { return }
                self.phase = .holding
            }
        }
        manager.onRelease = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.phase == .holding else { return }
                self.phase = .success
            }
        }
        manager.start()
        hotkeyManager = manager
    }

    func remove() {
        hotkeyManager?.stop()
        hotkeyManager = nil
    }

    deinit {
        hotkeyManager?.stop()
    }
}
