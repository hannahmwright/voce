import SwiftUI
import VoceKit

struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var preferencesDraft: AppPreferences = .default
    @State private var selectedGroup: SettingsGroup = .setup

    var body: some View {
        HStack(alignment: .top, spacing: VoceDesign.lg) {
            sidebar
            contentPane
        }
        .padding(.vertical, VoceDesign.lg)
        .toggleStyle(.switch)
        .onAppear {
            preferencesDraft = controller.preferences
        }
        .onChange(of: controller.preferences) { newValue in
            if newValue != preferencesDraft {
                preferencesDraft = newValue
            }
        }
        .onChange(of: preferencesDraft) { newValue in
            if normalizedPreferences(newValue) != controller.preferences {
                controller.applySettingsDraft(preferences: newValue, announceImmediateSave: false)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selectedGroup)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            Text("Settings")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)
                .padding(.bottom, VoceDesign.xs)

            ForEach(SettingsGroup.allCases, id: \.self) { group in
                sidebarButton(for: group)
            }

            Spacer(minLength: 0)
        }
        .padding(VoceDesign.md)
        .frame(width: 210, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.28))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous)
                .stroke(Color.white.opacity(0.32), lineWidth: VoceDesign.borderThin)
        )
        .shadowStyle(.md)
    }

    private func sidebarButton(for group: SettingsGroup) -> some View {
        Button {
            selectedGroup = group
        } label: {
            SettingsSidebarButtonLabel(
                group: group,
                isSelected: selectedGroup == group
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
        .accessibilityValue(selectedGroup == group ? "Selected" : "")
    }

    private var contentPane: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            contentHeader

            ScrollView {
                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    groupContent(selectedGroup)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, VoceDesign.xs)
            }
        }
        .padding(VoceDesign.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.48))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.34))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: VoceDesign.borderThin)
        )
        .shadowStyle(.md)
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(alignment: .center, spacing: VoceDesign.sm) {
                Text(selectedGroup.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(VoceDesign.textPrimary)

                if let badge = selectedGroup.badge {
                    Text(badge)
                        .font(VoceDesign.label())
                        .foregroundStyle(VoceDesign.accent)
                        .padding(.horizontal, VoceDesign.sm)
                        .padding(.vertical, VoceDesign.xxs)
                        .background(VoceDesign.accent.opacity(VoceDesign.opacitySubtle))
                        .clipShape(Capsule())
                }
            }

            Text(selectedGroup.description)
                .font(VoceDesign.subheadline())
                .foregroundStyle(VoceDesign.textSecondary)

            Text("Changes save automatically.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .padding(.bottom, VoceDesign.xs)
    }

    @ViewBuilder
    private func groupContent(_ group: SettingsGroup) -> some View {
        switch group {
        case .setup:
            PermissionsSettingsSection()
            RecordingSettingsSection(
                preferences: $preferencesDraft,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage
            )
            EngineSettingsSection(
                preferences: $preferencesDraft,
                controller: controller
            )
        case .behavior:
            InsertionSettingsSection(preferences: $preferencesDraft)
            MediaSettingsSection(preferences: $preferencesDraft)
            CleanupStyleSettingsSection(preferences: $preferencesDraft)
            AnchorOverrideSettingsSection(preferences: $preferencesDraft)
        case .ai:
            AISettingsSection(preferences: $preferencesDraft)
        case .vocabulary:
            LexiconSettingsSection(preferences: $preferencesDraft)
            SnippetsSettingsSection(preferences: $preferencesDraft)
            VoiceCommandsSettingsSection(preferences: $preferencesDraft)
            LearningSettingsSection()
        case .general:
            GeneralSettingsSection(
                preferences: $preferencesDraft,
                launchAtLoginWarning: controller.launchAtLoginWarning
            )
        }
    }

    private func normalizedPreferences(_ preferences: AppPreferences) -> AppPreferences {
        var snapshot = preferences
        snapshot.normalize()
        return snapshot
    }
}

private enum SettingsGroup: String, CaseIterable {
    case setup
    case behavior
    case ai
    case vocabulary
    case general

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .behavior: return "Behavior"
        case .ai: return "AI"
        case .vocabulary: return "Vocabulary"
        case .general: return "General"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return "Permissions, hotkeys, engine"
        case .behavior: return "Insertion, media, cleanup, overlay"
        case .ai: return "Workflows, phrases, Apple Intelligence"
        case .vocabulary: return "Lexicon, snippets, voice"
        case .general: return "Launch, visibility, onboarding"
        }
    }

    var description: String {
        switch self {
        case .setup:
            return "Get Voce ready to listen: system permissions, recording controls, and the live transcription model."
        case .behavior:
            return "Shape how transcripts are inserted, how media behaves during dictation, and how cleanup is applied."
        case .ai:
            return "Configure Apple Intelligence workflows, spoken AI triggers, and hands-free AI finish behavior."
        case .vocabulary:
            return "Teach Voce your preferred words, saved snippets, voice commands, and learned corrections."
        case .general:
            return "Manage app-level preferences like launch behavior, Dock visibility, and onboarding."
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gearshape"
        case .behavior: return "slider.horizontal.3"
        case .ai: return "sparkles"
        case .vocabulary: return "text.book.closed"
        case .general: return "wrench.and.screwdriver"
        }
    }

    var badge: String? {
        switch self {
        case .setup:
            return "Start here"
        case .behavior, .ai, .vocabulary, .general:
            return nil
        }
    }
}

private struct SettingsSidebarButtonLabel: View {
    let group: SettingsGroup
    let isSelected: Bool

    var body: some View {
        HStack(spacing: VoceDesign.md) {
            Image(systemName: group.icon)
                .font(.system(size: VoceDesign.iconMD, weight: .semibold))
                .foregroundStyle(isSelected ? VoceDesign.accent : VoceDesign.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(group.title)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(group.subtitle)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoceDesign.md)
        .padding(.vertical, VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(isSelected ? VoceDesign.accent.opacity(0.10) : Color.clear)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                            .fill(.regularMaterial.opacity(0.30))
                    }
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(
                    isSelected ? VoceDesign.accent.opacity(0.25) : Color.clear,
                    lineWidth: VoceDesign.borderThin
                )
        )
    }
}
