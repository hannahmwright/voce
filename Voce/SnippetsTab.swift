import SwiftUI
import VoceKit

struct SnippetsTab: View {
    @Binding var preferences: AppPreferences
    @State private var selectedSection: SnippetSection = .custom

    private var builtInCommandCount: Int {
        preferences.voiceCommands.filter(\.isBuiltIn).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoceDesign.lg) {
                Text("Snippets")
                    .font(VoceDesign.font(size: 28, weight: .bold))
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Spoken shortcuts, shortcut ideas, and built-in dictation controls.")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)

                settingsSubcard {
                    VStack(alignment: .leading, spacing: VoceDesign.md) {
                        Text("Browse")
                            .font(VoceDesign.labelEmphasis())
                            .textCase(.uppercase)
                            .foregroundStyle(VoceDesign.textSecondary)

                        HStack(spacing: VoceDesign.sm) {
                            ForEach(SnippetSection.allCases) { section in
                                sectionButton(section)
                            }
                        }
                    }
                }

                SnippetsSettingsSection(
                    preferences: $preferences,
                    selectedSection: selectedSection
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoceDesign.lg)
        }
    }

    private func sectionButton(_ section: SnippetSection) -> some View {
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

                Text(section.detail(
                    snippetCount: preferences.snippets.count,
                    builtInCount: builtInCommandCount
                ))
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

enum SnippetSection: String, CaseIterable, Identifiable {
    case custom
    case suggestions
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom:
            return "Custom"
        case .suggestions:
            return "Suggestions"
        case .builtIn:
            return "Built-in"
        }
    }

    var systemImage: String {
        switch self {
        case .custom:
            return "text.badge.plus"
        case .suggestions:
            return "sparkles"
        case .builtIn:
            return "text.quote"
        }
    }

    func detail(snippetCount: Int, builtInCount: Int) -> String {
        switch self {
        case .custom:
            return snippetCount == 0 ? "No shortcuts yet" : "\(snippetCount) saved"
        case .suggestions:
            return "Shortcut ideas"
        case .builtIn:
            return "\(builtInCount) controls"
        }
    }
}
