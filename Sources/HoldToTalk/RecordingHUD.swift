import SwiftUI
import AppKit

func recordingHUDRestingOrigin(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    panelSize: CGSize,
    shadowInset: CGFloat
) -> CGPoint {
    CGPoint(
        x: screenFrame.midX - panelSize.width / 2,
        y: visibleFrame.minY + 20 - shadowInset
    )
}

// MARK: - Non-activating Panel

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// NSHostingView subclass that disables the default opaque background
/// so the SwiftUI content composites correctly over the desktop.
private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Belt-and-suspenders: ensure the backing layer is non-opaque
        // after AppKit sets it up during window attachment.
        if let layer {
            layer.isOpaque = false
            layer.backgroundColor = .clear
        }
    }
}

@MainActor
private final class HUDModel: ObservableObject {
    @Published var state: DictationEngine.State = .idle
    @Published var recordingLevels: [CGFloat] = Array(repeating: 0, count: 11)

    func pushRecordingLevel(_ level: CGFloat) {
        var updated = recordingLevels
        updated.removeFirst()
        updated.append(level)
        recordingLevels = updated
    }

    func resetRecordingLevels() {
        recordingLevels = Array(repeating: 0, count: recordingLevels.count)
    }
}

// MARK: - Recording HUD

@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()

    private struct ScreenPanel {
        let screen: NSScreen
        let panel: HUDPanel
    }

    private var screenPanels: [ScreenPanel] = []
    private let model = HUDModel()
    /// Extra inset around the capsule so the drop shadow is not clipped by the panel edge.
    static let shadowInset: CGFloat = 20
    private static let size = CGSize(width: 292 + shadowInset * 2, height: 68 + shadowInset * 2)
    /// True while an animateOut() is in flight; cleared on completion or when interrupted by a new show request.
    private var isAnimatingOut = false

    private init() {}

    func update(_ state: DictationEngine.State, level: CGFloat = 0) {
        let wasVisible = model.state != .idle
        model.state = state
        if state == .recording {
            model.pushRecordingLevel(level)
        } else {
            model.resetRecordingLevels()
        }

        if state == .idle {
            animateOut()
        } else if isAnimatingOut {
            // Interrupted: a new active state arrived while the dismiss animation is running.
            // Cancel the out-animation by snapping alpha back and restarting from current position.
            isAnimatingOut = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                for screenPanel in screenPanels {
                    let panel = screenPanel.panel
                    panel.animator().alphaValue = 1
                }
            }
            ensurePanels()
            animateIn()
        } else if !wasVisible {
            ensurePanels()
            animateIn()
        }
    }

    // MARK: - Panels

    private func ensurePanels() {
        guard screenPanels.isEmpty else { return }
        screenPanels = NSScreen.screens.map { screen in
            ScreenPanel(screen: screen, panel: makePanel())
        }
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary,
            .ignoresCycle, .fullScreenAuxiliary,
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        let hosting = TransparentHostingView(rootView: HUDContentView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    // MARK: - Positioning

    private func restingOrigin(for screen: NSScreen) -> NSPoint {
        recordingHUDRestingOrigin(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            panelSize: Self.size,
            shadowInset: Self.shadowInset
        )
    }

    // MARK: - Animations

    private func animateIn() {
        guard !screenPanels.isEmpty else { return }
        for screenPanel in screenPanels {
            let destination = restingOrigin(for: screenPanel.screen)
            screenPanel.panel.setFrameOrigin(
                NSPoint(x: destination.x, y: destination.y - 14)
            )
            screenPanel.panel.alphaValue = 0
            screenPanel.panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for screenPanel in screenPanels {
                let destination = restingOrigin(for: screenPanel.screen)
                screenPanel.panel.animator().alphaValue = 1
                screenPanel.panel.animator().setFrameOrigin(destination)
            }
        }
    }

    private func animateOut() {
        let visiblePanels = screenPanels.filter { $0.panel.isVisible }
        guard !visiblePanels.isEmpty else { return }
        isAnimatingOut = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for screenPanel in visiblePanels {
                let panel = screenPanel.panel
                let origin = panel.frame.origin
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 8))
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Only clear the panels if the animation wasn't interrupted by a new show request.
                guard let self, self.isAnimatingOut else { return }
                for screenPanel in self.screenPanels {
                    screenPanel.panel.orderOut(nil)
                }
                self.isAnimatingOut = false
                self.screenPanels.removeAll()
            }
        })
    }
}

// MARK: - SwiftUI Content

private struct HUDContentView: View {
    @ObservedObject var model: HUDModel

    private var accentColor: Color {
        model.state == .recording ? .red : .accentColor
    }

    private var title: String {
        model.state == .recording ? "Listening" : "Transcribing"
    }

    private var subtitle: String {
        model.state == .recording ? "Release to transcribe" : "Turning speech into text"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 42, height: 42)

                if model.state == .recording {
                    RecordingWaveView(levels: model.recordingLevels)
                        .frame(width: 28, height: 22)
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .symbolEffect(.pulse)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if model.state == .recording {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.18))
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(accentColor)
                        .frame(width: 7, height: 7)
                }
                .symbolEffect(.pulse)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.14),
                                    accentColor.opacity(0.08),
                                    .clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.55),
                            accentColor.opacity(0.28),
                            .white.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: accentColor.opacity(0.14), radius: 18, y: 7)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .padding(RecordingHUD.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.state)
    }
}

private struct RecordingWaveView: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.red, .orange],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2, height: barHeight(level: level, index: index))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.spring(response: 0.15, dampingFraction: 0.68), value: levels)
    }

    private func barHeight(level: CGFloat, index: Int) -> CGFloat {
        let minimumHeight: CGFloat = 4
        let maximumHeight: CGFloat = 22
        // Amplify low levels so quiet speech still shows visible movement
        let amplified = pow(max(level, 0), 0.5)
        // Stagger neighboring bars slightly for a more organic wave shape
        let center = Double(levels.count) / 2.0
        let distance = abs(Double(index) - center) / center
        let taper = 1.0 - 0.25 * distance
        let visibleLevel = max(amplified * taper, 0.08)
        return minimumHeight + (maximumHeight - minimumHeight) * min(visibleLevel, 1.0)
    }
}
