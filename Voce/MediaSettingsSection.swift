import SwiftUI

struct MediaSettingsSection: View {
    private let modeColumnWidth: CGFloat = 248

    @Binding var preferences: AppPreferences

    var body: some View {
        settingsCard("Media") {
            HStack(spacing: VoceDesign.md) {
                Spacer()
                    .frame(width: modeColumnWidth)

                Text("Pause Media")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: VoceDesign.md) {
                mediaModeLabel(
                    "Hold to talk",
                    glyphStyle: .holdKey,
                    help: "Voce only sends play/pause when playback is clearly active."
                )
                .frame(width: modeColumnWidth, alignment: .leading)

                Toggle("", isOn: $preferences.media.pauseDuringPressToTalk)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Pause media for hold to talk")
            }

            HStack(alignment: .center, spacing: VoceDesign.md) {
                mediaModeLabel(
                    "Tap to talk",
                    glyphStyle: .tapKey,
                    help: "Voce only sends play/pause when playback is clearly active."
                )
                .frame(width: modeColumnWidth, alignment: .leading)

                Toggle("", isOn: $preferences.media.pauseDuringHandsFree)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Pause media for tap to talk")
            }
        }
    }

    @MainActor
    private func mediaModeLabel(
        _ title: String,
        glyphStyle: SettingGlyphStyle,
        help: String
    ) -> some View {
        HStack(spacing: VoceDesign.xs) {
            SettingGlyph(style: glyphStyle)

            Text(title)
                .font(VoceDesign.callout())
                .foregroundStyle(VoceDesign.textPrimary)

            HelpBubbleButton(text: help)

            Spacer(minLength: 0)
        }
    }
}
