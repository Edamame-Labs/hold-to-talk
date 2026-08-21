import SwiftUI
import AppKit

/// Where the recording overlay sits.
enum RecordingHUDPosition: String, CaseIterable, Identifiable, Sendable {
    case bottom
    case top
    /// Near the mouse pointer, which is usually where the user is looking.
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .top:    return "Top"
        case .cursor: return "Follow Pointer"
        }
    }

    var summary: String {
        switch self {
        case .bottom:
            return "Along the bottom edge, above the Dock."
        case .top:
            return "Along the top edge, below the menu bar."
        case .cursor:
            return "Next to the mouse pointer, on that screen only."
        }
    }
}

/// Gap between the overlay and the screen edge it hugs.
let recordingHUDEdgeMargin: CGFloat = 20
/// Gap between the overlay and the pointer, so it never sits under the cursor.
let recordingHUDCursorOffset: CGFloat = 18

func recordingHUDRestingOrigin(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    panelSize: CGSize,
    shadowInset: CGFloat
) -> CGPoint {
    recordingHUDOrigin(
        position: .bottom,
        screenFrame: screenFrame,
        visibleFrame: visibleFrame,
        panelSize: panelSize,
        shadowInset: shadowInset,
        cursorPoint: nil
    )
}

/// Placement for one screen.
///
/// `shadowInset` is transparent padding baked into the panel so the drop shadow
/// is not clipped, so every edge calculation has to subtract it — otherwise the
/// overlay looks like it is floating a shadow's width away from the edge.
///
/// Cursor placement is clamped to the visible frame, so the overlay stays fully
/// on screen even when the pointer is in a corner.
func recordingHUDOrigin(
    position: RecordingHUDPosition,
    screenFrame: CGRect,
    visibleFrame: CGRect,
    panelSize: CGSize,
    shadowInset: CGFloat,
    cursorPoint: CGPoint?
) -> CGPoint {
    switch position {
    case .bottom:
        return CGPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + recordingHUDEdgeMargin - shadowInset
        )
    case .top:
        return CGPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - recordingHUDEdgeMargin + shadowInset
        )
    case .cursor:
        guard let cursorPoint else {
            return recordingHUDOrigin(
                position: .bottom,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                panelSize: panelSize,
                shadowInset: shadowInset,
                cursorPoint: nil
            )
        }
        // Below the pointer by default; the clamp lifts it back up near the
        // bottom edge rather than letting it hang off screen.
        let desired = CGPoint(
            x: cursorPoint.x - panelSize.width / 2,
            y: cursorPoint.y - panelSize.height + shadowInset - recordingHUDCursorOffset
        )
        let minX = visibleFrame.minX - shadowInset
        let maxX = visibleFrame.maxX - panelSize.width + shadowInset
        let minY = visibleFrame.minY - shadowInset
        let maxY = visibleFrame.maxY - panelSize.height + shadowInset
        return CGPoint(
            x: min(max(desired.x, minX), max(minX, maxX)),
            y: min(max(desired.y, minY), max(minY, maxY))
        )
    }
}

/// Makes the HUD purely visual.
///
/// The overlay shows state and a waveform and has nothing to click, but a
/// borderless panel still swallows every click inside its frame — a 332x108
/// area at the bottom of *each* screen, over whatever the user was trying to
/// reach while dictating. Not activating is not enough on its own; the panel
/// has to opt out of hit-testing entirely.
///
/// If the HUD ever gains a control, this has to go and the panel needs real
/// hit-testing instead.
func configureHUDPanelForPassthrough(_ panel: NSPanel) {
    panel.ignoresMouseEvents = true
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
    private static let size = CGSize(width: 184 + shadowInset * 2, height: 44 + shadowInset * 2)
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

    /// The user's chosen placement, read fresh so a Settings change applies to
    /// the next dictation without restarting.
    private var position: RecordingHUDPosition {
        RecordingHUDPosition(
            rawValue: UserDefaults.standard.string(forKey: recordingHUDPositionDefaultsKey) ?? ""
        ) ?? .bottom
    }

    /// Pointer location in screen coordinates, and the screen it is on.
    private func cursorPlacement() -> (point: CGPoint, screen: NSScreen)? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
        guard let screen else { return nil }
        return (point, screen)
    }

    private func ensurePanels() {
        guard screenPanels.isEmpty else { return }
        // Following the pointer means one overlay on the screen the pointer is
        // on; showing it on every display would put copies where nobody looks.
        if position == .cursor, let placement = cursorPlacement() {
            screenPanels = [ScreenPanel(screen: placement.screen, panel: makePanel())]
            return
        }
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
        configureHUDPanelForPassthrough(panel)

        let hosting = TransparentHostingView(rootView: HUDContentView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    // MARK: - Positioning

    private func restingOrigin(for screen: NSScreen) -> NSPoint {
        let chosen = position
        let cursorPoint: CGPoint? = chosen == .cursor ? cursorPlacement()?.point : nil
        return recordingHUDOrigin(
            position: chosen,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            panelSize: Self.size,
            shadowInset: Self.shadowInset,
            cursorPoint: cursorPoint
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

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 28, height: 28)

                if model.state == .recording {
                    RecordingWaveView(levels: model.recordingLevels)
                        .frame(width: 19, height: 15)
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .symbolEffect(.pulse)
                }
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if model.state == .recording {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.18))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                }
                .symbolEffect(.pulse)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentColor)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
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
