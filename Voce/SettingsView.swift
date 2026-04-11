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
        GeometryReader { geometry in
            let isCompactHeight = geometry.size.height < 520
            let isCompactWidth = geometry.size.width < 640
            let chromePadding = isCompactHeight ? VoceDesign.md : VoceDesign.lg
            let shellPadding = isCompactWidth ? VoceDesign.md : VoceDesign.lg

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Button {
                        closeSettings()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(VoceDesign.font(size: 13, weight: .semibold))
                            .foregroundStyle(VoceDesign.textPrimary)
                            .padding(.horizontal, VoceDesign.md)
                            .padding(.vertical, VoceDesign.sm)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(VoceDesign.surface.opacity(0.58))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(Color.white.opacity(0.22), lineWidth: VoceDesign.borderThin)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Back")

                    Text("Settings")
                        .font(VoceDesign.font(size: isCompactHeight ? 20 : 22, weight: .bold))
                        .foregroundStyle(VoceDesign.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, isCompactWidth ? chromePadding : VoceDesign.xl)
                .padding(.top, chromePadding)
                .padding(.bottom, isCompactHeight ? VoceDesign.sm : VoceDesign.md)

                topTabBar(isCompactHeight: isCompactHeight)
                .padding(.horizontal, shellPadding)
                .padding(.bottom, isCompactHeight ? VoceDesign.sm : VoceDesign.md)

                contentPane(isCompactHeight: isCompactHeight)
                    .padding(.horizontal, shellPadding)
                    .padding(.bottom, chromePadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private func topTabBar(isCompactHeight: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoceDesign.sm) {
                ForEach(visibleGroups, id: \.self) { group in
                    topTabButton(for: group, isCompactHeight: isCompactHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompactHeight ? VoceDesign.xs : VoceDesign.sm)
        .padding(.vertical, isCompactHeight ? VoceDesign.xs : VoceDesign.sm)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.26))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: VoceDesign.borderThin)
        )
    }

    private func topTabButton(for group: SettingsGroup, isCompactHeight: Bool) -> some View {
        Button {
            guard selectedGroup != group else { return }
            selectedGroup = group
        } label: {
            SettingsTopTabButtonLabel(
                group: group,
                isSelected: selectedGroup == group,
                isCompactHeight: isCompactHeight
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.title)
        .accessibilityValue(selectedGroup == group ? "Selected" : "")
    }

    private func contentPane(isCompactHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            contentHeader(isCompactHeight: isCompactHeight)

            ZStack(alignment: .topLeading) {
                ForEach(visibleGroups, id: \.self) { group in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: VoceDesign.sm) {
                            groupContent(group)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, VoceDesign.xs)
                    }
                    .scrollIndicators(.visible)
                    .settingsGroupVisibility(selectedGroup == group)
                }
            }
        }
        .padding(isCompactHeight ? VoceDesign.md : VoceDesign.lg)
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

    private func contentHeader(isCompactHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text(selectedGroup.title)
                .font(VoceDesign.font(size: isCompactHeight ? 22 : 24, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)

            Text(selectedGroup.subtitle)
                .font(VoceDesign.body())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .padding(.bottom, isCompactHeight ? 0 : VoceDesign.xs)
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

private struct SettingsTopTabButtonLabel: View {
    let group: SettingsGroup
    let isSelected: Bool
    let isCompactHeight: Bool

    var body: some View {
        HStack(spacing: VoceDesign.sm) {
            Image(systemName: group.icon)
                .font(.system(size: VoceDesign.iconMD, weight: .semibold))
                .foregroundStyle(isSelected ? VoceDesign.accent : VoceDesign.textSecondary)
                .frame(width: 16)

            Text(group.title)
                .font(VoceDesign.font(size: 13, weight: .semibold))
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, isCompactHeight ? VoceDesign.md : VoceDesign.lg)
        .padding(.vertical, isCompactHeight ? VoceDesign.sm : VoceDesign.md)
        .background {
            Capsule(style: .continuous)
                .fill(isSelected ? VoceDesign.accent.opacity(0.10) : Color.clear)
                .overlay {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(.regularMaterial.opacity(0.30))
                    }
                }
        }
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    isSelected ? VoceDesign.accent.opacity(0.25) : Color.clear,
                    lineWidth: VoceDesign.borderThin
                )
        )
    }
}

private struct SettingsGroupVisibilityModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .zIndex(isVisible ? 1 : 0)
    }
}

private extension View {
    func settingsGroupVisibility(_ isVisible: Bool) -> some View {
        modifier(SettingsGroupVisibilityModifier(isVisible: isVisible))
    }
}
