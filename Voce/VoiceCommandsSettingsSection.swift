import SwiftUI
import VoceKit

struct VoiceCommandsSettingsSection: View {
    @Binding var preferences: AppPreferences

    private var builtInCommands: [VoiceCommand] {
        preferences.voiceCommands.filter(\.isBuiltIn)
    }

    var body: some View {
        settingsCardWithSubtitle(
            "Built-in phrases",
            subtitle: "Punctuation, spacing, and editing."
        ) {
            settingsSubcard(padding: VoceDesign.md) {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoceDesign.textSecondary)

                    Text("Custom spoken shortcuts live in Snippets.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
            }

            settingsSubcard {
                Text("Built in")
                    .font(VoceDesign.labelEmphasis())
                    .textCase(.uppercase)
                    .foregroundStyle(VoceDesign.textSecondary)

                VStack(spacing: VoceDesign.sm) {
                    ForEach(builtInCommands) { command in
                        builtInRow(command)
                    }
                }
            }
        }
    }

    private func builtInRow(_ command: VoiceCommand) -> some View {
        HStack(spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(command.trigger)
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(actionLabel(command.action))
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            Spacer(minLength: 0)

            Toggle(
                "",
                isOn: Binding(
                    get: { command.isEnabled },
                    set: { newValue in
                        if let idx = preferences.voiceCommands.firstIndex(where: { $0.id == command.id }) {
                            preferences.voiceCommands[idx].isEnabled = newValue
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
        .background(VoceDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private func actionLabel(_ action: VoiceCommand.Action) -> String {
        switch action {
        case .insertText(let text):
            let display = text
                .replacingOccurrences(of: "\n\n", with: "\\u{00B6}\\u{00B6}")
                .replacingOccurrences(of: "\n", with: "\\u{00B6}")
                .replacingOccurrences(of: "\t", with: "\\u{21E5}")
            return display.isEmpty ? "(empty)" : display
        case .deletePrevious:
            return "Delete previous sentence"
        }
    }
}
