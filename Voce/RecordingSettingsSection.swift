import SwiftUI
import VoceKit

struct RecordingSettingsSection: View {
    private let modeColumnWidth: CGFloat = 248

    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences
    let hotkeyRegistrationMessage: String
    var autoStartHandsFreeCapture: Bool = false

    var body: some View {
        settingsCard("Transcribing") {
            if controller.inputMonitoringPermissionStatus != .granted {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(VoceDesign.error)

                    Text("Hot Keys will not work until Input Monitoring is granted.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.error)

                    Spacer(minLength: 0)
                }
                .padding(VoceDesign.md)
                .glassBackground(cornerRadius: VoceDesign.radiusSmall)
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                        .stroke(VoceDesign.errorBorder, lineWidth: VoceDesign.borderThin)
                )
            }

            HStack(spacing: VoceDesign.md) {
                Spacer()
                    .frame(width: modeColumnWidth)

                Text("Mapping")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: VoceDesign.md) {
                Toggle(isOn: holdToTalkBinding) {
                    settingInlineLabel(
                        "Hold to talk",
                        glyphStyle: .holdKey,
                        help: "Hold one or more modifier keys together to dictate, then release to stop."
                    )
                }
                .frame(width: modeColumnWidth, alignment: .leading)
                .disabled(!tapToTalkEnabled)

                PressToTalkHotkeyRecorderField(hotkey: $preferences.hotkeys.pressToTalkHotkey)
                    .disabled(!preferences.hotkeys.optionPressToTalkEnabled)
                    .opacity(preferences.hotkeys.optionPressToTalkEnabled ? 1 : 0.45)
            }

            HStack(alignment: .top, spacing: VoceDesign.md) {
                Toggle(isOn: tapToTalkBinding) {
                    settingInlineLabel(
                        "Tap to talk",
                        glyphStyle: .tapKey,
                        help: "Tap once to start or stop. For modifier keys, tap twice quickly to save an x2 toggle."
                    )
                }
                .frame(width: modeColumnWidth, alignment: .leading)
                .disabled(!preferences.hotkeys.optionPressToTalkEnabled)

                HandsFreeToggleHotkeyRecorderField(
                    hotkey: handsFreeKeyBinding,
                    autoStartCapture: autoStartCaptureForTapToTalk
                )
                .disabled(!tapToTalkEnabled)
                .opacity(tapToTalkEnabled ? 1 : 0.45)
            }

            HStack(alignment: .top, spacing: VoceDesign.md) {
                HStack(spacing: VoceDesign.sm) {
                    HStack(spacing: VoceDesign.xs) {
                        keyboardKeyCap("return", systemImage: "arrow.turn.down.left")
                        Text("to send")
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textPrimary)
                            .lineLimit(1)
                        HelpBubbleButton(text: "When tap-to-talk is active, Return stops recording, inserts the transcript, then sends one final Return to the current app. Best for chat boxes and command bars.")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)

                    Toggle("", isOn: $preferences.hotkeys.enterFinishesHandsFreeAndSubmits)
                        .labelsHidden()
                        .accessibilityLabel("Return to send")
                }
                .frame(width: modeColumnWidth, alignment: .leading)
                .disabled(!tapToTalkEnabled)
                .opacity(tapToTalkEnabled ? 1 : 0.55)

                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: VoceDesign.md) {
                settingInlineLabel(
                    "Dictionary quick fix",
                    systemImage: "text.badge.checkmark",
                    help: "Highlight text in any app, press this shortcut, then add a dictionary correction from the menu bar."
                )
                .frame(width: modeColumnWidth, alignment: .leading)

                KeyboardShortcutRecorderField(
                    shortcut: $preferences.hotkeys.dictionaryCorrectionHotkey,
                    defaultShortcut: .dictionaryCorrectionDefault,
                    accessibilityLabel: "Dictionary quick fix hotkey"
                )
            }

            HStack(alignment: .top, spacing: VoceDesign.md) {
                settingInlineLabel(
                    "Create shortcut",
                    systemImage: "text.quote",
                    help: "Highlight text in any app, press this shortcut, then save it as a spoken shortcut from the menu bar."
                )
                .frame(width: modeColumnWidth, alignment: .leading)

                KeyboardShortcutRecorderField(
                    shortcut: $preferences.hotkeys.snippetCreationHotkey,
                    defaultShortcut: .snippetCreationDefault,
                    accessibilityLabel: "Create shortcut hotkey"
                )
            }

            if shouldShowHotkeyRegistrationMessage {
                Text(hotkeyRegistrationMessage)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.error)
            }
        }
        .onAppear {
            ensureAtLeastOneModeEnabled()
        }
    }

    private var handsFreeKeyBinding: Binding<HandsFreeToggleHotkey?> {
        Binding(
            get: { preferences.hotkeys.handsFreeGlobalHotkey },
            set: { preferences.hotkeys.handsFreeGlobalHotkey = $0 }
        )
    }

    private var holdToTalkBinding: Binding<Bool> {
        Binding(
            get: { preferences.hotkeys.optionPressToTalkEnabled },
            set: { isEnabled in
                if !isEnabled && !tapToTalkEnabled { return }
                preferences.hotkeys.optionPressToTalkEnabled = isEnabled
                ensureAtLeastOneModeEnabled()
            }
        )
    }

    private var tapToTalkBinding: Binding<Bool> {
        Binding(
            get: { tapToTalkEnabled },
            set: { isEnabled in
                if !isEnabled && !preferences.hotkeys.optionPressToTalkEnabled { return }
                preferences.hotkeys.handsFreeGlobalHotkey = isEnabled
                    ? (preferences.hotkeys.handsFreeGlobalHotkey ?? .init(hotkey: .keyCode(79)))
                    : nil
                ensureAtLeastOneModeEnabled()
            }
        )
    }

    private var tapToTalkEnabled: Bool {
        preferences.hotkeys.handsFreeGlobalHotkey != nil
    }

    private var autoStartCaptureForTapToTalk: Bool {
        autoStartHandsFreeCapture && tapToTalkEnabled
    }

    private func ensureAtLeastOneModeEnabled() {
        if !preferences.hotkeys.optionPressToTalkEnabled && preferences.hotkeys.handsFreeGlobalHotkey == nil {
            preferences.hotkeys.handsFreeGlobalHotkey = .init(hotkey: .keyCode(79))
        }
    }

    private var shouldShowHotkeyRegistrationMessage: Bool {
        guard !hotkeyRegistrationMessage.isEmpty else { return false }
        return hotkeyRegistrationMessage != "Input Monitoring permission required for shortcuts."
    }
}
