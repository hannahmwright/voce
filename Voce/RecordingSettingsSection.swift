import SwiftUI
import VoceKit

struct RecordingSettingsSection: View {
    @Binding var preferences: AppPreferences
    let hotkeyRegistrationMessage: String

    var body: some View {
        settingsCard("Recording") {
            Toggle("Enable hold-to-talk", isOn: $preferences.hotkeys.optionPressToTalkEnabled)

            if preferences.hotkeys.optionPressToTalkEnabled {
                Picker("Hold-to-talk key", selection: $preferences.hotkeys.pressToTalkModifier) {
                    ForEach(PressToTalkModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)

                Text("Choose a modifier key you do not already use for other shortcuts.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                Text("Global hands-free key")
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)

                HotkeyRecorderField(hotkey: handsFreeKeyBinding)
            }

            Text("Click the field, then press the key or modifier you want. This works well for unknown mic or Globe/Fn keys too.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            if !hotkeyRegistrationMessage.isEmpty {
                Text(hotkeyRegistrationMessage)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.error)
            }
        }
    }

    private var handsFreeKeyBinding: Binding<HandsFreeHotkey?> {
        Binding(
            get: { preferences.hotkeys.handsFreeGlobalHotkey },
            set: { preferences.hotkeys.handsFreeGlobalHotkey = $0 }
        )
    }
}
