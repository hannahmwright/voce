import SwiftUI
import VoceKit

struct InsertionSettingsSection: View {
    @Binding var preferences: AppPreferences

    var body: some View {
        settingsCard("Text Output") {
            settingInlineLabel(
                "Priority",
                help: "Choose how Voce inserts text. Drag to set priority. Backup paste via clipboard is always kept."
            )

            List {
                ForEach(preferences.insertion.orderedMethods, id: \.rawValue) { method in
                    HStack {
                        Image(systemName: icon(for: method))
                            .foregroundStyle(VoceDesign.accent)
                        Text(label(for: method))
                        Spacer()
                    }
                    .accessibilityHint("Drag to reorder")
                }
                .onMove(perform: moveInsertionMethod)
            }
            .frame(height: VoceDesign.insertionListHeight)
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
        }
    }

    private func moveInsertionMethod(from source: IndexSet, to destination: Int) {
        preferences.insertion.orderedMethods.move(fromOffsets: source, toOffset: destination)
        if !preferences.insertion.orderedMethods.contains(.clipboardPaste) {
            preferences.insertion.orderedMethods.append(.clipboardPaste)
        }
    }

    private func label(for method: InsertionMethod) -> String {
        switch method {
        case .direct: return "Direct typing"
        case .accessibility: return "Accessibility typing"
        case .clipboardPaste: return "Clipboard fallback"
        case .none: return "None"
        }
    }

    private func icon(for method: InsertionMethod) -> String {
        switch method {
        case .direct: return "keyboard"
        case .accessibility: return "figure.wave"
        case .clipboardPaste: return "doc.on.clipboard"
        case .none: return "xmark"
        }
    }
}
