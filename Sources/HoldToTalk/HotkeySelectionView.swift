import SwiftUI

struct HotkeySelectionView: View {
    @Binding var selection: String

    var keyLabel: String = "Key"
    var maxWidth: CGFloat?
    var onChange: () -> Void = {}

    private var hotkey: HotkeyManager.Hotkey {
        HotkeyManager.Hotkey.preferredSelection(from: selection)
    }

    private var selectedKind: HotkeyManager.Hotkey.Kind {
        hotkey.kind
    }

    private var selectedSide: HotkeyManager.Hotkey.ModifierSide {
        hotkey.modifierSide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(keyLabel, selection: kindBinding) {
                ForEach(HotkeyManager.Hotkey.selectableKinds) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if selectedKind.supportsSideSelection {
                Picker("Side", selection: sideBinding) {
                    ForEach(HotkeyManager.Hotkey.ModifierSide.allCases) { side in
                        Text(side.displayName).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .onChange(of: selection) {
            onChange()
        }
    }

    private var kindBinding: Binding<HotkeyManager.Hotkey.Kind> {
        Binding(
            get: { selectedKind },
            set: { kind in
                let side = kind.supportsSideSelection ? selectedSide : .either
                selection = HotkeyManager.Hotkey.selection(kind: kind, side: side).rawValue
            }
        )
    }

    private var sideBinding: Binding<HotkeyManager.Hotkey.ModifierSide> {
        Binding(
            get: { selectedSide },
            set: { side in
                selection = HotkeyManager.Hotkey.selection(kind: selectedKind, side: side).rawValue
            }
        )
    }
}
