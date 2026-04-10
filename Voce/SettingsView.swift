import SwiftUI
import VoceKit

struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.dismiss) private var dismiss
    private let initialLaunchTarget: SettingsLaunchTarget?
    private let onClose: (() -> Void)?
    @State private var preferencesDraft: AppPreferences = .default
    @State private var selectedGroup: SettingsGroup = .setup

    init(initialLaunchTarget: SettingsLaunchTarget? = nil, onClose: (() -> Void)? = nil) {
        self.initialLaunchTarget = initialLaunchTarget
        self.onClose = onClose
        _selectedGroup = State(initialValue: Self.group(for: initialLaunchTarget))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(alignment: .center) {
                Text("Settings")
                    .font(VoceDesign.font(size: 22, weight: .bold))
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer()

                Button {
                    closeSettings()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, VoceDesign.xl)
            .padding(.top, VoceDesign.lg)
            .padding(.bottom, VoceDesign.md)

            // Two-pane layout
            HStack(alignment: .top, spacing: VoceDesign.lg) {
                sidebar
                contentPane
            }
            .padding(.horizontal, VoceDesign.lg)
            .padding(.bottom, VoceDesign.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoceDesign.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: VoceDesign.borderThin)
        )
        .toggleStyle(.switch)
        .onAppear {
            if !visibleGroups.contains(selectedGroup) {
                selectedGroup = .setup
            }
            preferencesDraft = controller.preferences
        }
        .onChange(of: controller.preferences) { _, newValue in
            if newValue != preferencesDraft {
                preferencesDraft = newValue
            }
        }
        .onChange(of: controller.aiAvailabilityIsAvailable) { _, isAvailable in
            if !isAvailable && selectedGroup == .ai {
                selectedGroup = .setup
            }
        }
        .onChange(of: preferencesDraft) { _, newValue in
            let normalized = normalizedPreferences(newValue)
            guard normalized != controller.preferences else { return }

            if normalized.requiresRuntimeRebuild(comparedTo: controller.preferences) {
                controller.applySettingsDraft(preferences: newValue, announceImmediateSave: false)
            } else {
                controller.savePreferencesQuietly(preferences: newValue)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            ForEach(visibleGroups, id: \.self) { group in
                sidebarButton(for: group)
            }

            Spacer(minLength: 0)
        }
        .padding(VoceDesign.md)
        .frame(width: 200, alignment: .topLeading)
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
            Text(selectedGroup.title)
                .font(VoceDesign.font(size: 24, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)
        }
        .padding(.bottom, VoceDesign.xs)
    }

    private var visibleGroups: [SettingsGroup] {
        SettingsGroup.allCases.filter { group in
            if group == .ai {
                return controller.aiAvailabilityIsAvailable
            }
            return true
        }
    }

    @ViewBuilder
    private func groupContent(_ group: SettingsGroup) -> some View {
        switch group {
        case .setup:
            PermissionsSettingsSection()
            RecordingSettingsSection(
                preferences: $preferencesDraft,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage,
                autoStartHandsFreeCapture: initialLaunchTarget == .handsFreeGlobalHotkey
            )
            EngineSettingsSection(
                preferences: $preferencesDraft,
                controller: controller
            )
        case .behavior:
            MediaSettingsSection(preferences: $preferencesDraft)
            AnchorOverrideSettingsSection(preferences: $preferencesDraft)
        case .ai:
            AISettingsSection(preferences: $preferencesDraft)
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

    private func closeSettings() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private static func group(for launchTarget: SettingsLaunchTarget?) -> SettingsGroup {
        switch launchTarget {
        case .handsFreeGlobalHotkey:
            return .setup
        case nil:
            return .setup
        }
    }
}

private enum SettingsGroup: String, CaseIterable {
    case setup
    case behavior
    case ai
    case general

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .behavior: return "Behavior"
        case .ai: return "AI"
        case .general: return "General"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return "Access, keys, speech"
        case .behavior: return "Text, media, overlay"
        case .ai: return "Workflows, triggers"
        case .general: return "Profile, launch, app"
        }
    }

    var description: String {
        switch self {
        case .setup:
            return "Get Voce ready to listen: system permissions, recording controls, and the live transcription model."
        case .behavior:
            return "Shape how transcripts are inserted, how media behaves during dictation, and overlay positioning."
        case .ai:
            return "Configure Apple Intelligence workflows, spoken AI triggers, and hands-free AI finish behavior."
        case .general:
            return "Manage app-level preferences like your display name, launch behavior, and Dock visibility."
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gearshape"
        case .behavior: return "slider.horizontal.3"
        case .ai: return "sparkles"
        case .general: return "wrench.and.screwdriver"
        }
    }

    var badge: String? {
        switch self {
        case .setup:
            return "Start here"
        case .behavior, .ai, .general:
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
                    .font(VoceDesign.font(size: 14, weight: .semibold))
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
