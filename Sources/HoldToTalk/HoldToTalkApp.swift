import SwiftUI
import AVFoundation
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openOnboardingHandler: (() -> Void)?
    private var pendingInitialOnboardingOpen = false
    private var hasOpenedInitialOnboarding = false
    private var onboardingRecoveryObservers: [NSObjectProtocol] = []
    private var onboardingRecoveryGeneration = 0
    private let onboardingWindowTitle = "Welcome to Hold to Talk"
    private let onboardingWindowIdentifier = NSUserInterfaceItemIdentifier("com.holdtotalk.onboarding")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isDiagnosticLoggingEnabled() {
            truncateDebugLogIfNeeded()
        } else {
            clearDebugLog()
        }

        // Re-register login item so the current binary owns the entry.
        // SMAppService tracks registrations by code signature; after a Sparkle
        // update the old version's entry becomes a ghost that the new binary
        // cannot manage.  We persist the user's intent in UserDefaults so we
        // can always re-register on launch, even though SMAppService.mainApp.status
        // returns .notRegistered for the fresh binary.
        migrateAndReregisterLoginItem()

        if shouldOpenInitialOnboarding {
            pendingInitialOnboardingOpen = true
            flushPendingInitialOnboardingOpen()
        }
        installOnboardingRecoveryObservers()

        if shouldShowLaunchInstallPrompt(
            installedInApplications: isInstalledInApplicationsFolder(),
            installPromptDismissed: UserDefaults.standard.bool(forKey: dismissedInstallPromptDefaultsKey),
            openingInitialOnboarding: shouldOpenInitialOnboarding
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    self.showInstallPrompt()
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleOnboardingWindowRecovery(delay: 0.2)
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOnboardingRecoveryObservers()
    }

    @MainActor
    private func showInstallPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        let compatibility = SystemCompatibility.current()
        let alert = makeInstallAlert(icon: HoldToTalkApp.appIcon, compatibility: compatibility)
        alert.showsSuppressionButton = compatibility.isSupported
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()

        if compatibility.isSupported, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: dismissedInstallPromptDefaultsKey)
        }

        guard compatibility.isSupported else { return }

        if response == .alertFirstButtonReturn {
            switch installToApplicationsAndRelaunch() {
            case .success:
                break
            case .failure(let message):
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could Not Move App"
                errorAlert.informativeText = message
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
            }
        }
    }

    /// Migrate existing SMAppService registrations to UserDefaults-tracked intent,
    /// then unconditionally re-register so the current binary owns the login item.
    private func migrateAndReregisterLoginItem() {
        let defaults = UserDefaults.standard

        // One-time migration: if the UserDefaults key doesn't exist yet,
        // seed it from the current SMAppService status so existing users
        // who enabled launch-at-login before this change keep it on.
        if defaults.object(forKey: launchAtLoginDefaultsKey) == nil {
            defaults.set(SMAppService.mainApp.status == .enabled, forKey: launchAtLoginDefaultsKey)
        }

        if defaults.bool(forKey: launchAtLoginDefaultsKey) {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        } else {
            // User doesn't want launch-at-login.  Clean up any ghost entry
            // left behind by a previous version.
            try? SMAppService.mainApp.unregister()
        }
    }

    func setOpenOnboardingHandler(_ handler: @escaping () -> Void) {
        openOnboardingHandler = handler
        flushPendingInitialOnboardingOpen()
    }

    private var shouldOpenInitialOnboarding: Bool {
        #if DEBUG
        if DebugFlags.forceOnboarding { return true }
        #endif
        return !UserDefaults.standard.bool(forKey: onboardingCompleteDefaultsKey)
    }

    private func flushPendingInitialOnboardingOpen() {
        guard pendingInitialOnboardingOpen,
              !hasOpenedInitialOnboarding,
              let openOnboardingHandler else { return }
        pendingInitialOnboardingOpen = false
        hasOpenedInitialOnboarding = true
        DispatchQueue.main.async {
            openOnboardingHandler()
        }
    }

    private func installOnboardingRecoveryObservers() {
        guard onboardingRecoveryObservers.isEmpty else { return }

        onboardingRecoveryObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      self.shouldOpenInitialOnboarding,
                      let window = notification.object as? NSWindow,
                      self.isOnboardingWindow(window)
                else { return }
                self.scheduleOnboardingWindowRecovery(delay: 0.4)
            }
        )

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        onboardingRecoveryObservers.append(
            workspaceNotifications.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      self.shouldOpenInitialOnboarding,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      isSystemSettingsApplication(application)
                else { return }
                self.scheduleOnboardingWindowRecovery(delay: 0.8)
            }
        )

        onboardingRecoveryObservers.append(
            workspaceNotifications.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      self.shouldOpenInitialOnboarding,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      isSystemSettingsApplication(application)
                else { return }
                self.scheduleOnboardingWindowRecovery(delay: 0.4)
            }
        )
    }

    private func removeOnboardingRecoveryObservers() {
        for observer in onboardingRecoveryObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        onboardingRecoveryObservers.removeAll()
    }

    private func scheduleOnboardingWindowRecovery(delay: TimeInterval) {
        guard shouldOpenInitialOnboarding else { return }

        onboardingRecoveryGeneration += 1
        let generation = onboardingRecoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == self.onboardingRecoveryGeneration,
                  self.shouldOpenInitialOnboarding
            else { return }
            self.recoverOnboardingWindow()
        }
    }

    private func recoverOnboardingWindow() {
        guard shouldOpenInitialOnboarding else { return }

        if focusExistingOnboardingWindow() {
            return
        }

        if let openOnboardingHandler {
            openOnboardingHandler()
        } else {
            pendingInitialOnboardingOpen = true
            hasOpenedInitialOnboarding = false
        }
    }

    private func focusExistingOnboardingWindow() -> Bool {
        guard let window = NSApp.windows.first(where: isOnboardingWindow) else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    private func isOnboardingWindow(_ window: NSWindow) -> Bool {
        window.identifier == onboardingWindowIdentifier || window.title == onboardingWindowTitle
    }
}

@main
struct HoldToTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine: DictationEngine
    @Environment(\.openWindow) private var openWindow
    #if canImport(Sparkle)
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    init() {
        let launchPreparation = onboardingLaunchPreparation()
        switch launchPreparation {
        case .fullReset:
            resetPersistedAppStateForFreshOnboarding()
        case .reopenAfterAppMove:
            reopenOnboardingForCurrentInstall()
        case .none:
            break
        }
        _engine = StateObject(wrappedValue: DictationEngine())
    }

    private var shouldShowOnboarding: Bool {
        #if DEBUG
        if DebugFlags.forceOnboarding { return true }
        #endif
        return !engine.onboardingComplete
    }

    private var hotkeyDisplayName: String {
        HotkeyManager.Hotkey.preferredSelection(from: engine.hotkeyChoice).displayName
    }

    private var appUpdater: (any AppUpdateDriver)? {
        #if canImport(Sparkle)
        guard appHasStableCodeIdentity() else { return nil }
        return SparkleUpdateDriver(updater: updaterController.updater)
        #else
        return nil
        #endif
    }

    var body: some Scene {
        let _ = configureAppDelegate()

        MenuBarExtra {
            if shouldShowOnboarding {
                onboardingMenu
            } else {
                mainMenu
            }
        } label: {
            Label("Hold to Talk", systemImage: engine.state.icon)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Hold to Talk", id: "onboarding") {
            OnboardingView(engine: engine, modelManager: engine.modelManager)
                .background(OnboardingWindowConfigurator(isBlocking: shouldShowOnboarding))
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        Window("Hold to Talk Settings", id: "settings") {
            SettingsView(engine: engine, modelManager: engine.modelManager, updater: appUpdater)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }

    private var label: some View {
        Label(
            engine.state == .idle
                ? "Ready - hold \(hotkeyDisplayName)"
                : engine.state.label,
            systemImage: engine.state.icon
        )
        .font(.headline)
    }

    private var onboardingMenu: some View {
        menuPanel(
            title: "Finish Setup",
            subtitle: "A few steps are needed before dictation is ready.",
            icon: "wand.and.sparkles"
        ) {
            Button {
                openOnboardingWindow()
            } label: {
                Label("Continue Setup", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var mainMenu: some View {
        menuPanel(
            title: menuStatusTitle,
            subtitle: menuStatusSubtitle,
            icon: engine.state.icon
        ) {
            if !isInstalledInApplicationsFolder() {
                Button {
                    showInstallAlert()
                } label: {
                    Label("Move to Applications", systemImage: "arrow.down.app.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !engine.hasMicrophone || !engine.hasPostEvent {
                setupStatusBlock
            }

            if let error = engine.lastError {
                menuMessage(error, icon: "exclamationmark.triangle.fill", color: .orange)
            }

            if !engine.lastCleanText.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.lastCleanText, forType: .string)
                } label: {
                    Label("Copy Last Transcription", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var setupStatusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Setup Checklist", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(missingSetupCount) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !engine.hasMicrophone {
                setupActionRow(
                    title: "Microphone",
                    subtitle: "Records your voice.",
                    icon: "mic",
                    actionTitle: "Enable"
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in
                            engine.refreshPermissionSnapshot()
                            if !granted {
                                openSystemSettings("Privacy_Microphone")
                            }
                        }
                    }
                }
            }

            if !engine.hasPostEvent {
                setupActionRow(
                    title: "Keyboard Access",
                    subtitle: "Types dictated text into other apps.",
                    icon: "keyboard",
                    actionTitle: "Enable"
                ) {
                    _ = requestPostEventAccess()
                }
            }

            Button {
                openOnboardingWindow()
            } label: {
                Label("Open Full Setup", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.22))
        )
    }

    private var menuStatusTitle: String {
        if !engine.hasMicrophone || !engine.hasPostEvent {
            return "Setup Required"
        }
        return engine.state == .idle ? "Ready" : engine.state.label
    }

    private var menuStatusSubtitle: String {
        if !engine.hasMicrophone && !engine.hasPostEvent {
            return "Microphone and Keyboard Access are missing."
        }
        if !engine.hasMicrophone {
            return "Microphone access is missing."
        }
        if !engine.hasPostEvent {
            return "Keyboard Access is missing."
        }
        return engine.state == .idle ? "Hold \(hotkeyDisplayName) to dictate." : "Release the hold key to finish."
    }

    private var missingSetupCount: Int {
        [!engine.hasMicrophone, !engine.hasPostEvent].filter { $0 }.count
    }

    private func menuPanel<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            menuHeader(title: title, subtitle: subtitle, icon: icon)
            content()
            Divider()
            menuFooter
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var menuFooter: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(",")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("q")
        }
    }

    private func menuHeader(title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func setupActionRow(
        title: String,
        subtitle: String,
        icon: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(actionTitle, action: action)
                .controlSize(.small)
        }
    }

    private func menuMessage(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.10))
            )
    }

    @MainActor
    private func showInstallAlert() {
        let compatibility = SystemCompatibility.current()
        let alert = makeInstallAlert(icon: Self.appIcon, compatibility: compatibility)

        let response = alert.runModal()
        guard compatibility.isSupported else { return }

        if response == .alertFirstButtonReturn {
            switch installToApplicationsAndRelaunch() {
            case .success:
                break
            case .failure(let message):
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could Not Move App"
                errorAlert.informativeText = message
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
            }
        }
    }

    @MainActor
    private func openOnboardingWindow() {
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureAppDelegate() {
        appDelegate.setOpenOnboardingHandler {
            openOnboardingWindow()
        }
    }

    /// Loads the app icon from the .app bundle or from the source tree for debug runs.
    static let appIcon: NSImage? = {
        if let bundled = Bundle.main.image(forResource: "HoldToTalk") { return bundled }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()  // Sources/HoldToTalk/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // project root
        let url = projectRoot.appendingPathComponent("Resources/HoldToTalk.icns")
        if let img = NSImage(contentsOf: url), img.isValid { return img }
        return nil
    }()
}

private func makeInstallAlert(
    icon: NSImage?,
    compatibility: SystemCompatibility
) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = compatibility.isSupported ? "Move to Applications?" : "This Mac is not supported"
    alert.informativeText = compatibility.installPromptText
    alert.alertStyle = compatibility.isSupported ? .informational : .warning
    alert.icon = icon

    if compatibility.isSupported {
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
    } else {
        alert.addButton(withTitle: "OK")
    }

    return alert
}

func shouldShowLaunchInstallPrompt(
    installedInApplications: Bool,
    installPromptDismissed: Bool,
    openingInitialOnboarding: Bool
) -> Bool {
    !installedInApplications && !installPromptDismissed && !openingInitialOnboarding
}

private struct OnboardingWindowConfigurator: NSViewRepresentable {
    let isBlocking: Bool

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onResolve = { window in
            context.coordinator.configure(window: window, isBlocking: isBlocking)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onResolve = { window in
            context.coordinator.configure(window: window, isBlocking: isBlocking)
        }
        context.coordinator.configure(window: nsView.window, isBlocking: isBlocking)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        func configure(window: NSWindow?, isBlocking: Bool) {
            guard let window else { return }

            window.identifier = NSUserInterfaceItemIdentifier("com.holdtotalk.onboarding")
            window.title = "Welcome to Hold to Talk"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false

            var styleMask = window.styleMask
            if isBlocking {
                styleMask.remove([.closable, .miniaturizable])
            } else {
                styleMask.insert([.closable, .miniaturizable])
            }
            window.styleMask = styleMask

            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for button in buttons {
                window.standardWindowButton(button)?.isHidden = isBlocking
                window.standardWindowButton(button)?.isEnabled = !isBlocking
            }
        }
    }
}

private final class WindowProbeView: NSView {
    var onResolve: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve?(window)
    }
}
