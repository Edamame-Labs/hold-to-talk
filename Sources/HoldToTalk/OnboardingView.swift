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
    @State private var onboardingOpenAIAPIKey = ""
    @State private var onboardingAPIKeyError: String?
    @AppStorage(openaiAPIKeySavedDefaultsKey) private var hasSavedOnboardingOpenAIKey = false
    @StateObject private var hotkeyTester = HotkeyTester()

    init(engine: DictationEngine, modelManager: ModelManager) {
        self.engine = engine
        self.modelManager = modelManager
        self.systemCompatibility = .current()
        _speechSetupMode = State(
            initialValue: engine.resolvedTranscriptionProvider == .openAI ? .openAI : .local
        )
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
            case .microphone: "Records only while you hold the shortcut."
            case .keyboardAccess: "Inserts dictated text into the app you were using."
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

    var body: some View {
        let needsInstallation = !isInstalledInApplicationsFolder()

        VStack(spacing: 0) {
            if !needsInstallation {
                HStack(spacing: 8) {
                    ForEach(0..<4) { i in
                        Capsule()
                            .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
            }

            Spacer()

            Group {
                if needsInstallation {
                    installStep
                } else {
                    switch step {
                    case 0: welcomeStep
                    case 1: permissionsStep
                    case 2: dictationStep
                    default: hotkeyStep
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer()
        }
        .frame(width: 560, height: needsInstallation ? 460 : onboardingWindowHeight)
        .animation(.easeInOut(duration: 0.3), value: step)
        .background(OnboardingWindowReader(window: $onboardingWindow))
    }

    private var onboardingWindowHeight: CGFloat {
        switch step {
        case 0:
            return 640
        case 1:
            return 690
        case 2:
            return 680
        case 3:
            return 610
        default:
            return 610
        }
    }

    // MARK: - Install

    private var installStep: some View {
        VStack(spacing: 22) {
            appIcon
                .frame(width: 88, height: 88)

            VStack(spacing: 8) {
                Text("Finish installing Hold to Talk")
                    .font(.title.bold())

                Text("Move the app to Applications so permissions, updates, and Launch at Login keep working reliably.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }

            if isInstallingToApplications {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Installing, then reopening from Applications…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Move to Applications & Continue") {
                    beginApplicationInstall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!systemCompatibility.isSupported)
            }

            if let installErrorMessage {
                VStack(spacing: 10) {
                    Label(installErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 450)

                    Button("Open Applications Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }

            if !systemCompatibility.isSupported {
                Text(systemCompatibility.statusDetailText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: onboardingContentWidth)
            }
        }
        .padding(40)
    }

    private func beginApplicationInstall() {
        installErrorMessage = nil
        isInstallingToApplications = true
        prepareOnboardingToResumeAfterAppMove()

        Task { @MainActor in
            await Task.yield()
            switch installToApplicationsAndRelaunch() {
            case .success:
                break
            case .failure(let message):
                cancelOnboardingResumeAfterFailedAppMove()
                installErrorMessage = message
                isInstallingToApplications = false
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
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

            Button(systemCompatibility.isSupported ? "Get Started" : "This Mac Is Not Supported") {
                step = 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!systemCompatibility.isSupported)
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
            ? "Local Parakeet model + on-device cleanup"
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

            if showsStaleUpdateNotice {
                staleUpdateRecoveryCard
            }

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
                        if !showsStaleUpdateNotice {
                            Text("Still pending after a relaunch? Remove Hold To Talk from the Accessibility list with the \u{2212} button, then add it again — re-enabling the existing entry does not always work.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
            startLocalModelDownloadIfNeeded(
                provider: speechSetupMode == .local ? .local : .openAI
            )
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

            if speechSetupMode == .local && modelManager.isDownloading {
                Divider()
                    .padding(.vertical, 4)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text("Preparing local dictation")
                    Spacer()
                    Text("\(Int(modelManager.downloadProgress * 100))%")
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
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

    private var showsStaleUpdateNotice: Bool {
        permissionsLikelyStaleAfterUpdate() && !hasAllPermissions
    }

    private var staleUpdateRecoveryCard: some View {
        StalePermissionRecoveryView(maxWidth: onboardingContentWidth)
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

            Text("Text cleanup and advanced provider options remain available in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                if mode == .local {
                    startLocalModelDownloadIfNeeded(provider: .local)
                } else if modelManager.isDownloading {
                    modelManager.cancelDownload()
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
                    Text("Preparing local dictation… \(Int(modelManager.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("You can continue while the model downloads.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(modelManager.downloadError == nil ? "Download Local Model" : "Try Download Again") {
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
                          prompt: Text(TranscriptionProvider.openAI.defaultModel))
                    .font(.system(.body, design: .monospaced))

                TextField("Base URL", text: $engine.openaiBaseURL,
                          prompt: Text(CloudProvider.openAI.defaultBaseURL))
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

            if let onboardingAPIKeyError {
                Text(onboardingAPIKeyError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasOnboardingOpenAIKey: Bool {
        hasSavedOnboardingOpenAIKey || !onboardingOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canContinueDictationSetup: Bool {
        guard systemCompatibility.isAppleSiliconMac else { return false }
        switch speechSetupMode {
        case .local:
            return modelManager.isDownloaded || modelManager.isDownloading
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
        startLocalModelDownloadIfNeeded(
            provider: speechSetupMode == .local ? .local : .openAI
        )
        warmUpModelIfReady()
    }

    private func finishDictationSetup() {
        switch speechSetupMode {
        case .local:
            engine.transcriptionProvider = TranscriptionProvider.local.rawValue
            warmUpModelIfReady()
        case .openAI:
            guard saveOnboardingOpenAIKeyIfNeeded() else { return }
            engine.transcriptionProvider = TranscriptionProvider.openAI.rawValue
            if engine.openaiTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.openaiTranscriptionModel = TranscriptionProvider.openAI.defaultModel
            }
            if engine.openaiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engine.openaiBaseURL = ""
            }
        }
        step = 3
    }

    // MARK: - Step 4: Hotkey

    private var resolvedHotkey: HotkeyManager.Hotkey {
        HotkeyManager.Hotkey.preferredSelection(from: engine.hotkeyChoice)
    }

    private var hotkeyStep: some View {
        VStack(spacing: 20) {
            Text("Choose Your Shortcut")
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
                        Text("Hotkey works.")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(height: 80)
                .animation(.easeInOut(duration: 0.2), value: hotkeyTester.phase)

                dictationReadinessCard

                HStack(spacing: 8) {
                    Image(systemName: "dock.rectangle")
                        .font(.caption.bold())
                    Text("Hold to Talk stays in the Dock and menu bar")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button("Back") {
                    step = 2
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Start Using Hold to Talk") {
                    completeOnboardingAndCloseWindow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canCompleteOnboarding)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: onboardingContentWidth + 64)
        .onAppear {
            warmUpModelIfReady()
            hotkeyTester.install(for: resolvedHotkey)
        }
        .onChange(of: modelManager.isDownloaded) {
            warmUpModelIfReady()
        }
        .onDisappear {
            hotkeyTester.remove()
            if engine.onboardingComplete {
                step = 0
            }
        }
    }

    @ViewBuilder
    private var dictationReadinessCard: some View {
        if engine.resolvedTranscriptionProvider == .openAI && hasSavedOnboardingOpenAIKey {
            Label("Cloud dictation is ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if engine.resolvedTranscriptionProvider == .openAI {
            Label("Return to Dictation and save an API key to continue.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if modelManager.isDownloaded {
            Label("Local dictation is ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if modelManager.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: modelManager.downloadProgress)
                Text("Preparing local dictation… \(Int(modelManager.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
        } else {
            VStack(spacing: 8) {
                if let downloadError = modelManager.downloadError {
                    Text(downloadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try Download Again") {
                    modelManager.download()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var canCompleteOnboarding: Bool {
        onboardingDictationIsReady(
            provider: engine.resolvedTranscriptionProvider,
            localModelIsDownloaded: modelManager.isDownloaded,
            hasCloudKey: hasSavedOnboardingOpenAIKey
        )
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

    private func startLocalModelDownloadIfNeeded(provider: TranscriptionProvider) {
        guard shouldAutomaticallyDownloadLocalModel(
            provider: provider,
            isDownloaded: modelManager.isDownloaded,
            isDownloading: modelManager.isDownloading
        ) else { return }
        modelManager.download()
    }

    private func saveOnboardingOpenAIKeyIfNeeded() -> Bool {
        let trimmedAPIKey = onboardingOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { return hasSavedOnboardingOpenAIKey }
        if KeychainHelper.save(provider: .openAI, key: trimmedAPIKey) {
            hasSavedOnboardingOpenAIKey = true
            onboardingOpenAIAPIKey = ""
            onboardingAPIKeyError = nil
            return true
        }
        onboardingAPIKeyError = "The API key could not be saved securely. Check Keychain access and try again."
        return false
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

    private func requestMicrophonePermission(
        openSettings: Bool = true,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
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

func shouldAutomaticallyDownloadLocalModel(
    provider: TranscriptionProvider,
    isDownloaded: Bool,
    isDownloading: Bool
) -> Bool {
    provider == .local && !isDownloaded && !isDownloading
}

func onboardingDictationIsReady(
    provider: TranscriptionProvider,
    localModelIsDownloaded: Bool,
    hasCloudKey: Bool
) -> Bool {
    switch provider {
    case .local:
        return localModelIsDownloaded
    case .openAI:
        return hasCloudKey
    }
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
}
