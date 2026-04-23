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
        .contentShape(Rectangle())
        .accessibilityLabel(group.title)
        .accessibilityValue(selectedGroup == group ? "Selected" : "")
    }

    private func contentPane(isCompactHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            contentHeader(isCompactHeight: isCompactHeight)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: VoceDesign.sm) {
                    groupContent(selectedGroup)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, VoceDesign.xs)
            }
            .id(selectedGroup)
            .scrollIndicators(.visible)
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
                onSubscribeBase: { cycle in
                    controller.openVoceCheckout(plan: .base, billingCycle: cycle)
                },
                onSubscribePro: { cycle in
                    controller.openVoceCheckout(plan: .pro, billingCycle: cycle)
                },
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
                onSubscribeBase: { cycle in
                    controller.openVoceCheckout(plan: .base, billingCycle: cycle)
                },
                onSubscribePro: { cycle in
                    controller.openVoceCheckout(plan: .pro, billingCycle: cycle)
                },
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
            HelpSupportSection(
                subscriberEmail: preferencesDraft.billing.subscriberEmail,
                appearancePreference: preferencesDraft.general.appearancePreference,
                launchAtLoginEnabled: preferencesDraft.general.launchAtLoginEnabled,
                showDockIcon: preferencesDraft.general.showDockIcon,
                tapHotkeyLabel: settingsTapToTalkLabel,
                holdHotkeyLabel: settingsHoldToTalkLabel,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage,
                aiAvailable: controller.aiAvailabilityIsAvailable
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
        case .help: return "Walkthrough, support"
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
            return "Replay the core teaching flow, get quick answers, and contact support when something goes wrong."
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

private struct HelpSupportSection: View {
    @EnvironmentObject private var controller: DictationController
    let subscriberEmail: String
    let appearancePreference: AppAppearancePreference
    let launchAtLoginEnabled: Bool
    let showDockIcon: Bool
    let tapHotkeyLabel: String
    let holdHotkeyLabel: String
    let hotkeyRegistrationMessage: String
    let aiAvailable: Bool

    @State private var selectedCategory: VoceSupportRequestCategory?
    @State private var feedbackMessage = ""
    @State private var feedbackIsError = false

    var body: some View {
        settingsCardWithSubtitle(
            "Support",
            subtitle: "Send a question, bug report, or feature request without leaving Voce."
        ) {
            if !feedbackMessage.isEmpty {
                Text(feedbackMessage)
                    .font(VoceDesign.caption())
                    .foregroundStyle(feedbackIsError ? VoceDesign.error : VoceDesign.textPrimary)
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(feedbackIsError ? VoceDesign.errorBackground : VoceDesign.surfaceSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                feedbackIsError ? VoceDesign.errorBorder : VoceDesign.border,
                                lineWidth: VoceDesign.borderThin
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
            }

            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                ForEach(VoceSupportRequestCategory.allCases) { category in
                    settingsSubcard {
                        HStack(alignment: .top, spacing: VoceDesign.md) {
                            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                                Text(category.title)
                                    .font(VoceDesign.bodyEmphasis())
                                    .foregroundStyle(VoceDesign.textPrimary)

                                Text(category.subtitle)
                                    .font(VoceDesign.caption())
                                    .foregroundStyle(VoceDesign.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)

                            Button("Open") {
                                selectedCategory = category
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            Text("Bug reports can include lightweight diagnostics like app version, macOS version, and current shortcut settings only when you explicitly enable that option.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $selectedCategory) { category in
            SupportRequestFormSheet(
                category: category,
                initialEmail: subscriberEmail,
                diagnostics: diagnosticsText,
                onSubmitted: { confirmation in
                    feedbackMessage = confirmation
                    feedbackIsError = false
                    selectedCategory = nil
                }
            )
            .environmentObject(controller)
        }
    }

    private var diagnosticsText: String {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let values = [
            "app_version=\(appVersion)",
            "build=\(buildNumber)",
            "macos=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "tap_hotkey=\(tapHotkeyLabel)",
            "hold_hotkey=\(holdHotkeyLabel)",
            "appearance=\(appearancePreference.title)",
            "launch_at_login=\(launchAtLoginEnabled)",
            "show_dock_icon=\(showDockIcon)",
            "ai_available=\(aiAvailable)",
            "hotkey_registration=\(hotkeyRegistrationMessage.isEmpty ? "ok" : hotkeyRegistrationMessage)"
        ]
        return values.joined(separator: "\n")
    }
}

private struct SupportRequestFormSheet: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.dismiss) private var dismiss

    let category: VoceSupportRequestCategory
    let initialEmail: String
    let diagnostics: String
    let onSubmitted: (String) -> Void

    @State private var email = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var includeDiagnostics = true
    @State private var isSubmitting = false
    @State private var errorMessage = ""

    private let supportService = VoceSupportRequestService()

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text(category.title)
                        .font(VoceDesign.heading2())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text(category.subtitle)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.plain)
            }

            settingsSubcard {
                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Reply email")
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    TextField("email@example.com", text: $email)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()

                    Text("Subject")
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    TextField("Short summary", text: $subject)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()

                    Text("Message")
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    TextEditor(text: $message)
                        .font(VoceDesign.body())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .frame(minHeight: 150)
                        .padding(.horizontal, VoceDesign.sm)
                        .padding(.vertical, VoceDesign.xs)
                        .background(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                .fill(VoceDesign.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                        .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                                )
                        )

                    Toggle("Include lightweight diagnostics", isOn: $includeDiagnostics)
                        .font(VoceDesign.callout())

                    Text("Voce always includes app version and macOS version. This toggle adds non-sensitive context like shortcut labels and display settings.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.error)
            }

            HStack {
                Text(appMetadataLine)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)

                Spacer()

                Button("Send") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }
        }
        .padding(VoceDesign.lg)
        .frame(width: 560)
        .settingsModalPanel()
        .onAppear {
            email = initialEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            subject = category.defaultSubject
        }
    }

    private var appMetadataLine: String {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Voce \(appVersion) (\(buildNumber)) on \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private func submit() {
        guard !isSubmitting else { return }
        errorMessage = ""
        isSubmitting = true

        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let payload = VoceSupportRequestPayload(
            category: category.rawValue,
            email: email,
            subject: subject,
            message: message,
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            includeDiagnostics: includeDiagnostics,
            diagnostics: includeDiagnostics ? diagnostics : nil
        )

        Task {
            do {
                try await supportService.submit(payload)
                await MainActor.run {
                    isSubmitting = false
                    onSubmitted("\(category.title) sent. We will reply to \(email.trimmingCharacters(in: .whitespacesAndNewlines)).")
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                }
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
