import SwiftUI
import VoceKit

struct StyleTab: View {
    @Binding var preferences: AppPreferences
    @State private var selectedSection: StyleSection = .defaultStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoceDesign.lg) {
                Text("Style")
                    .font(VoceDesign.font(size: 28, weight: .bold))
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Shape how Voce cleans up and formats what you say.")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)

                settingsSubcard {
                    VStack(alignment: .leading, spacing: VoceDesign.md) {
                        Text("Browse")
                            .font(VoceDesign.labelEmphasis())
                            .textCase(.uppercase)
                            .foregroundStyle(VoceDesign.textSecondary)

                        HStack(spacing: VoceDesign.sm) {
                            ForEach(StyleSection.allCases) { section in
                                sectionButton(section)
                            }
                        }
                    }
                }

                CleanupStyleSettingsSection(
                    preferences: $preferences,
                    selectedSection: selectedSection
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoceDesign.lg)
        }
    }

    private func sectionButton(_ section: StyleSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                HStack(spacing: VoceDesign.xs) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                    Text(section.title)
                        .font(VoceDesign.bodyEmphasis())
                }

                Text(section.detail(overrideCount: preferences.appStyleProfiles.count))
                    .font(VoceDesign.caption())
                    .foregroundStyle(selectedSection == section ? VoceDesign.warmAccentText : VoceDesign.textSecondary)
                    .lineLimit(1)
            }
            .foregroundStyle(selectedSection == section ? VoceDesign.warmAccentText : VoceDesign.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.md)
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                    .fill(selectedSection == section ? VoceDesign.warmAccentFill : VoceDesign.surfaceSecondary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                    .stroke(
                        selectedSection == section ? VoceDesign.warmAccentFill.opacity(0.95) : VoceDesign.border,
                        lineWidth: VoceDesign.borderThin
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

enum StyleSection: String, CaseIterable, Identifiable {
    case defaultStyle
    case appOverrides

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultStyle:
            return "Default"
        case .appOverrides:
            return "Apps"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultStyle:
            return "wand.and.stars"
        case .appOverrides:
            return "app.badge"
        }
    }

    func detail(overrideCount: Int) -> String {
        switch self {
        case .defaultStyle:
            return "Used everywhere"
        case .appOverrides:
            return overrideCount == 0 ? "No overrides yet" : "\(overrideCount) overrides"
        }
    }
}
