import SwiftUI
import VoceKit

struct DictionaryTab: View {
    @Binding var preferences: AppPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoceDesign.lg) {
                Text("Dictionary")
                    .font(VoceDesign.font(size: 28, weight: .bold))
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Fix words Voce tends to hear wrong.")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)

                LexiconSettingsSection(preferences: $preferences)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoceDesign.lg)
        }
    }
}
