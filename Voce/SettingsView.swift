import SwiftUI
import VoceKit

struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.dismiss) private var dismiss
    private let initialLaunchTarget: SettingsLaunchTarget?
    @Binding private var accessVerificationCode: String
    private let accessVerificationCodeWasSent: Bool
    private let accessAuthIsWorking: Bool
    private let accessAuthError: String
    private let onRequestAccessCode: (String) -> Void
    private let onVerifyAccessCode: (String) -> Void
    private let onClose: (() -> Void)?
    @State private var preferencesDraft: AppPreferences = .default
    @State private var selectedGroup: SettingsGroup = .setup

    init(
        initialLaunchTarget: SettingsLaunchTarget? = nil,
        accessVerificationCode: Binding<String> = .constant(""),
        accessVerificationCodeWasSent: Bool = false,
        accessAuthIsWorking: Bool = false,
        accessAuthError: String = "",
        onRequestAccessCode: @escaping (String) -> Void = { _ in },
        onVerifyAccessCode: @escaping (String) -> Void = { _ in },
        onClose: (() -> Void)? = nil
    ) {
        self.initialLaunchTarget = initialLaunchTarget
        _accessVerificationCode = accessVerificationCode
        self.accessVerificationCodeWasSent = accessVerificationCodeWasSent
        self.accessAuthIsWorking = accessAuthIsWorking
        self.accessAuthError = accessAuthError
        self.onRequestAccessCode = onRequestAccessCode
        self.onVerifyAccessCode = onVerifyAccessCode
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
        HStack(spacing: isCompactHeight ? VoceDesign.xs : VoceDesign.sm) {
            ForEach(visibleGroups, id: \.self) { group in
                topTabButton(for: group, isCompactHeight: isCompactHeight)
            }
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            #if DEBUG
            VoceAccessSettingsSection(
                preferences: $preferencesDraft,
                verificationCode: $accessVerificationCode,
                entitlementStatus: controller.voceProEntitlementStatus,
                didSendVerificationCode: accessVerificationCodeWasSent,
                isAuthWorking: accessAuthIsWorking,
                authError: accessAuthError,
                onRefreshEntitlement: controller.refreshVoceProEntitlement,
                onRequestAccessCode: requestAccessCodeForSettingsEmail,
                onVerifyAccessCode: verifyAccessCodeForSettingsEmail,
                onSubscribe: controller.openVoceProCheckout,
                onManageSubscription: controller.openVoceProPortal,
                onResetAccessSession: controller.resetVoceAccessSessionForTesting
            )
            #else
            VoceAccessSettingsSection(
                preferences: $preferencesDraft,
                verificationCode: $accessVerificationCode,
                entitlementStatus: controller.voceProEntitlementStatus,
                didSendVerificationCode: accessVerificationCodeWasSent,
                isAuthWorking: accessAuthIsWorking,
                authError: accessAuthError,
                onRefreshEntitlement: controller.refreshVoceProEntitlement,
                onRequestAccessCode: requestAccessCodeForSettingsEmail,
                onVerifyAccessCode: verifyAccessCodeForSettingsEmail,
                onSubscribe: controller.openVoceProCheckout,
                onManageSubscription: controller.openVoceProPortal
            )
            #endif
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
        case .ai:
            AISettingsSection(
                preferences: $preferencesDraft,
                entitlementStatus: controller.voceProEntitlementStatus
            )
        case .general:
            GeneralSettingsSection(
                preferences: $preferencesDraft,
                launchAtLoginWarning: controller.launchAtLoginWarning
            )
        case .help:
            GuidedWalkthroughSettingsSection(
                holdHotkeyLabel: settingsHoldToTalkLabel,
                tapHotkeyLabel: settingsTapToTalkLabel,
                dictionaryHotkeyLabel: keyboardShortcutDisplayName(for: preferencesDraft.hotkeys.dictionaryCorrectionHotkey),
                dictionaryCorrectionHotkey: preferencesDraft.hotkeys.dictionaryCorrectionHotkey,
                availableSteps: {
                    var steps: [GuidedWalkthroughStep] = []
                    if preferencesDraft.hotkeys.handsFreeGlobalHotkey != nil {
                        steps.append(.tapToRecord)
                    }
                    if preferencesDraft.hotkeys.optionPressToTalkEnabled {
                        steps.append(.holdToRecord)
                    }
                    steps.append(.dictionaryFix)
                    return steps
                }()
            )
            HelpFAQSection(
                tapHotkeyLabel: settingsTapToTalkLabel,
                holdHotkeyLabel: settingsHoldToTalkLabel,
                dictionaryHotkeyLabel: keyboardShortcutDisplayName(for: preferencesDraft.hotkeys.dictionaryCorrectionHotkey)
            )
        }
    }

    private func normalizedPreferences(_ preferences: AppPreferences) -> AppPreferences {
        var snapshot = preferences
        snapshot.normalize()
        return snapshot
    }

    private func requestAccessCodeForSettingsEmail() {
        onRequestAccessCode(preferencesDraft.billing.subscriberEmail)
    }

    private func verifyAccessCodeForSettingsEmail() {
        onVerifyAccessCode(preferencesDraft.billing.subscriberEmail)
    }

    private var settingsHoldToTalkLabel: String {
        hotkeyDisplayName(for: preferencesDraft.hotkeys.pressToTalkHotkey)
    }

    private var settingsTapToTalkLabel: String {
        if let hotkey = preferencesDraft.hotkeys.handsFreeGlobalHotkey {
            return handsFreeToggleDisplayName(for: hotkey)
        }
        return "your key"
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
    case help

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .behavior: return "Behavior"
        case .ai: return "AI"
        case .general: return "General"
        case .help: return "Help"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return "Access, keys, speech"
        case .behavior: return "Text and media"
        case .ai: return "Workflows, triggers"
        case .general: return "Profile, launch, app"
        case .help: return "Walkthrough, answers"
        }
    }

    var description: String {
        switch self {
        case .setup:
            return "Get Voce ready to listen: system permissions, recording controls, and the live transcription model."
        case .behavior:
            return "Shape how transcripts are inserted and how media behaves during dictation."
        case .ai:
            return "Configure Apple Intelligence workflows, spoken AI triggers, and hands-free AI finish behavior."
        case .general:
            return "Manage app-level preferences like your display name, launch behavior, and Dock visibility."
        case .help:
            return "Replay the core teaching flow and get quick answers about dictation, shortcuts, and fixes."
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gearshape"
        case .behavior: return "slider.horizontal.3"
        case .ai: return "sparkles"
        case .general: return "wrench.and.screwdriver"
        case .help: return "questionmark.circle"
        }
    }

    var badge: String? {
        switch self {
        case .setup:
            return "Start here"
        case .help:
            return "Need a refresher?"
        case .behavior, .ai, .general:
            return nil
        }
    }
}

private struct HelpFAQSection: View {
    let tapHotkeyLabel: String
    let holdHotkeyLabel: String
    let dictionaryHotkeyLabel: String

    var body: some View {
        settingsCardWithSubtitle(
            "FAQ",
            subtitle: "Short answers for the things people look for first."
        ) {
            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                faqRow(
                    question: "How do I start dictating?",
                    answer: "Click into the app you want to type in, then use Tap to Talk or Hold to Talk. Tap uses \(tapHotkeyLabel). Hold uses \(holdHotkeyLabel)."
                )
                faqRow(
                    question: "How do I fix a word Voce gets wrong?",
                    answer: "Highlight the wrong word, press \(dictionaryHotkeyLabel), then enter the correct replacement in the Teach Voce popover."
                )
                faqRow(
                    question: "Why did my transcript copy instead of pasting?",
                    answer: "That happens when Voce cannot safely insert text into the target app. The transcript is copied to your clipboard so you can paste it manually."
                )
                faqRow(
                    question: "Can I replay the teaching flow?",
                    answer: "Yes. Use Open walkthrough in Help any time you want to run through the practice flow again."
                )
            }
        }
    }

    private func faqRow(question: String, answer: String) -> some View {
        settingsSubcard {
            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                Text(question)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(answer)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isCompactHeight ? VoceDesign.sm : VoceDesign.md)
        .padding(.vertical, isCompactHeight ? VoceDesign.xs : VoceDesign.sm)
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
