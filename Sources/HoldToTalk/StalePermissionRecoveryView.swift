import AppKit
import SwiftUI

/// Guidance for permissions that broke because the app was updated or moved.
///
/// macOS binds Accessibility and Input Monitoring to an app's code identity. On
/// an update it commonly keeps the previous entry listed *and switched on* while
/// the grant no longer applies, so the usual "turn this on" instruction sends
/// the user to a pane where everything already looks correct. Removing the entry
/// and adding it back is what actually clears it.
///
/// The app cannot fix this itself: macOS exposes no API for an app to reset its
/// own TCC records, which is why the fallback is a command the user runs.
struct StalePermissionRecoveryView: View {
    var maxWidth: CGFloat?

    @State private var didCopyCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Permissions need re-granting after this update",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.orange)

            Text("macOS ties these permissions to each version of an app. After an update it often still shows Hold To Talk as enabled while the grant itself no longer applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("1. Open the Privacy pane.")
                Text("2. Select Hold To Talk and remove it with the \u{2212} button.")
                Text("3. Add it back with \u{002B}, or use the permission buttons again.")
            }
            .font(.caption)

            HStack(spacing: 8) {
                Button("Open Accessibility") {
                    openSystemSettings("Privacy_Accessibility")
                }
                .controlSize(.small)

                Button("Open Input Monitoring") {
                    openSystemSettings("Privacy_ListenEvent")
                }
                .controlSize(.small)
            }

            DisclosureGroup("Still not working?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run this in Terminal to clear the old entries, then grant them again. Hold to Talk cannot do this for you — macOS gives an app no way to reset its own permissions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 6) {
                        Text(tccResetCommand())
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tccResetCommand(), forType: .string)
                            didCopyCommand = true
                        } label: {
                            Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy command")
                    }

                    Text("Quit Hold to Talk before running it, then open it again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.35))
        )
    }
}
