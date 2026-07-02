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
    @State private var settingsSearchText = ""
    @FocusState private var settingsSearchIsFocused: Bool
    /// Card title to scroll to after a search result switches the group; consumed
    /// once the pane has laid out.
    @State private var pendingSearchScrollAnchor: String?
    /// Card title currently glowing after a search jump; cleared after a beat.
    @State private var highlightedSettingsCard: String?

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

	                    settingsSearchField
	                        .frame(width: isCompactWidth ? 210 : 260)
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
        .onExitCommand {
            if isSearchingSettings {
                settingsSearchText = ""
            } else {
                closeSettings()
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

    private var settingsSearchField: some View {
        HStack(spacing: VoceDesign.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoceDesign.textSecondary)

            TextField("Find setting", text: $settingsSearchText)
                .textFieldStyle(.plain)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textPrimary)
                .focused($settingsSearchIsFocused)

            if !settingsSearchText.isEmpty {
                Button {
                    settingsSearchText = ""
                    settingsSearchIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear settings search")
            } else if !settingsSearchIsFocused {
                Text("⌘F")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.xs)
        .background(
            // Invisible ⌘F target: focuses the search field from anywhere in Settings.
            Button("") { settingsSearchIsFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .background(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .stroke(
                            settingsSearchIsFocused ? VoceDesign.accent.opacity(0.42) : Color.white.opacity(0.24),
                            lineWidth: VoceDesign.borderThin
                        )
                )
        )
        .accessibilityElement(children: .contain)
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

            ScrollViewReader { scrollProxy in
                ScrollView {
                    // Eager VStack, not LazyVStack: scroll anchors must exist for
                    // `scrollTo` to land on cards below the fold, and panes are
                    // small enough that laziness buys nothing.
                    VStack(alignment: .leading, spacing: VoceDesign.sm) {
                        if isSearchingSettings {
                            searchResultsContent
                        } else {
                            groupContent(selectedGroup)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, VoceDesign.xs)
                    .environment(\.highlightedSettingsCard, highlightedSettingsCard)
                }
                .id(isSearchingSettings ? "settings-search" : selectedGroup.rawValue)
                .scrollIndicators(.visible)
                // task(id:) rather than onChange: the ScrollView is recreated when
                // the group swaps (its .id changes), and the new instance must still
                // consume the pending anchor.
                .task(id: pendingSearchScrollAnchor) {
                    guard let anchor = pendingSearchScrollAnchor else { return }
                    // Let the freshly selected group lay out before scrolling.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo(anchor, anchor: .top)
                    }
                    highlightedSettingsCard = anchor
                    pendingSearchScrollAnchor = nil
                }
                .task(id: highlightedSettingsCard) {
                    guard highlightedSettingsCard != nil else { return }
                    try? await Task.sleep(nanoseconds: 1_700_000_000)
                    guard !Task.isCancelled else { return }
                    highlightedSettingsCard = nil
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
            Text(isSearchingSettings ? "Search Results" : selectedGroup.title)
                .font(VoceDesign.font(size: isCompactHeight ? 22 : 24, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)

            Text(isSearchingSettings ? searchSummaryText : selectedGroup.subtitle)
                .font(VoceDesign.body())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .padding(.bottom, isCompactHeight ? 0 : VoceDesign.xs)
    }

    private var isSearchingSettings: Bool {
        !normalizedSettingsSearchText.isEmpty
    }

    private var normalizedSettingsSearchText: String {
        settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchSummaryText: String {
        let count = visibleSearchResults.count
        if count == 1 {
            return "1 match for \"\(normalizedSettingsSearchText)\""
        }
        return "\(count) matches for \"\(normalizedSettingsSearchText)\""
    }

    private var visibleSearchResults: [SettingsSearchResult] {
        SettingsSearchResult.matches(
            query: normalizedSettingsSearchText,
            visibleGroups: visibleGroups
        )
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        if visibleSearchResults.isEmpty {
            settingsSubcard {
                HStack(spacing: VoceDesign.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: VoceDesign.iconMD, weight: .semibold))
                        .foregroundStyle(VoceDesign.textSecondary)

                    VStack(alignment: .leading, spacing: VoceDesign.xs) {
                        Text("No matching settings")
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Text("Try words like hotkey, cloud, media, bubble, launch, updates, AI, support, or microphone.")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            ForEach(visibleSearchResults) { result in
                Button {
                    selectedGroup = result.group
                    settingsSearchText = ""
                    settingsSearchIsFocused = false
                    pendingSearchScrollAnchor = result.anchor
                } label: {
                    SettingsSearchResultRow(result: result)
                }
                .buttonStyle(.plain)
            }
        }
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
        case .behavior:
            RecordingSettingsSection(
                preferences: $preferencesDraft,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage,
                autoStartHandsFreeCapture: initialLaunchTarget == .handsFreeGlobalHotkey
            )
            MediaSettingsSection(preferences: $preferencesDraft)
        case .speech:
            EngineSettingsSection(
                preferences: $preferencesDraft,
                controller: controller
            )
        case .ai:
            AISettingsSection(
                preferences: $preferencesDraft,
                entitlementStatus: controller.voceProEntitlementStatus
            )
            // The AI section builds its own card chrome, so it doesn't get an
            // anchor from settingsCard; tag it here so search can jump to it.
            .settingsCardAnchor("AI workflows")
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
                    // Only surface the dictionary lesson when the legacy
                    // direct shortcut is bound. New installs use the
                    // Cmd+Option Voce-actions tap (taught in Recording
                    // Settings) and showing the lesson would leave it
                    // unfinishable since the tap path doesn't route through
                    // the practice pad's intercept.
                    if preferencesDraft.hotkeys.dictionaryCorrectionHotkey.isBound {
                        steps.append(.dictionaryFix)
                    }
                    return steps
                }()
            )
            HelpSupportSection(
                subscriberEmail: preferencesDraft.billing.subscriberEmail,
                appearancePreference: preferencesDraft.general.appearancePreference,
                launchAtLoginEnabled: preferencesDraft.general.launchAtLoginEnabled,
                showDockIcon: preferencesDraft.general.showDockIcon,
                pauseDuringHandsFree: preferencesDraft.media.pauseDuringHandsFree,
                pauseDuringPressToTalk: preferencesDraft.media.pauseDuringPressToTalk,
                tapHotkeyLabel: settingsTapToTalkLabel,
                holdHotkeyLabel: settingsHoldToTalkLabel,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage,
                aiAvailable: controller.aiAvailabilityIsAvailable
            )
            HelpFAQSection(
                tapHotkeyLabel: settingsTapToTalkLabel,
                holdHotkeyLabel: settingsHoldToTalkLabel,
                dictionaryHotkeyLabel: keyboardShortcutDisplayName(for: preferencesDraft.hotkeys.dictionaryCorrectionHotkey),
                dictionaryShortcutIsBound: preferencesDraft.hotkeys.dictionaryCorrectionHotkey.isBound,
                voceActionsTapEnabled: preferencesDraft.hotkeys.voceActionsTapEnabled
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
            return .behavior
        case nil:
            return .setup
        }
    }
}

private enum SettingsGroup: String, CaseIterable {
    case setup
    case behavior
    case speech
    case ai
    case general
    case help

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .behavior: return "Behavior"
        case .speech: return "Speech"
        case .ai: return "AI"
        case .general: return "General"
        case .help: return "Help"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return "Access and permissions"
        case .behavior: return "Shortcuts and media"
        case .speech: return "Dictation engine"
        case .ai: return "Workflows, triggers"
        case .general: return "Profile, app, updates"
        case .help: return "Walkthrough, support"
        }
    }

    var description: String {
        switch self {
        case .setup:
            return "Connect your account and grant the macOS permissions Voce needs before dictation starts."
        case .behavior:
            return "Choose how recording starts and how music or video behaves while you dictate."
        case .speech:
            return "Choose local or cloud transcription, language, per-app overrides, and model diagnostics."
        case .ai:
            return "Configure Apple Intelligence workflows, spoken AI triggers, and hands-free AI finish behavior."
        case .general:
            return "Manage profile, appearance, launch behavior, update checks, and license notices."
        case .help:
            return "Replay the core teaching flow, get quick answers, and contact support when something goes wrong."
        }
    }

    var icon: String {
        switch self {
        case .setup: return "gearshape"
        case .behavior: return "slider.horizontal.3"
        case .speech: return "waveform"
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
        case .behavior, .speech, .ai, .general:
            return nil
        }
    }
}

private struct SettingsSearchResult: Identifiable {
    let id: String
    let title: String
    let detail: String
    let group: SettingsGroup
    let keywords: [String]

    var anchor: String {
        switch id {
        case "walkthrough":
            return "Learn the basics"
        default:
            return title
        }
    }

    static func matches(query: String, visibleGroups: [SettingsGroup]) -> [SettingsSearchResult] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        guard !terms.isEmpty else { return [] }

        let visibleGroupSet = Set(visibleGroups)
        let scored = all
            .filter { visibleGroupSet.contains($0.group) }
            .enumerated()
            .compactMap { index, result -> (score: Int, index: Int, result: SettingsSearchResult)? in
                var total = 0
                for term in terms {
                    // Every term must match somewhere (AND semantics), but each term
                    // may match a different field.
                    guard let score = result.score(for: term) else { return nil }
                    total += score
                }
                return (total, index, result)
            }

        // Best matches first (title > keyword > detail); index keeps ties stable.
        return scored
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.result)
    }

    /// Field-weighted match score for a single query term, or nil when the term
    /// matches nothing. Title hits outrank keyword hits outrank detail/group hits.
    private func score(for term: String) -> Int? {
        if Self.fieldMatches(term: term, text: title) { return 3 }
        if keywords.contains(where: { Self.fieldMatches(term: term, text: $0) }) { return 2 }
        let context = "\(detail) \(group.title) \(group.subtitle)"
        if Self.fieldMatches(term: term, text: context) { return 1 }
        return nil
    }

    /// A term matches a field when it appears as a substring (terms of 4+ characters),
    /// shares a meaningful prefix with a word ("updates" ↔ "update", "updating" ↔
    /// "update"), or is one typo away from a word ("permisions" → "permissions").
    /// Plain substring search alone made the search feel broken: singular/plural and
    /// small typos found nothing. Short terms (1-3 characters) only match word
    /// prefixes so "pin" finds engine pinning, not the middle of "typing".
    private static func fieldMatches(term: String, text: String) -> Bool {
        let lowered = text.lowercased()
        if term.count >= 4, lowered.contains(term) { return true }
        return words(in: lowered).contains { word in
            if word.hasPrefix(term) { return true }
            if term.hasPrefix(word), word.count >= 4 { return true }
            if term.count >= 5, word.count >= 5, abs(term.count - word.count) <= 1,
               isWithinOneEdit(term, word) {
                return true
            }
            return false
        }
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Damerau-Levenshtein distance ≤ 1: one insertion, deletion, replacement, or
    /// adjacent transposition.
    private static func isWithinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let first = Array(a)
        let second = Array(b)
        let (short, long) = first.count <= second.count ? (first, second) : (second, first)
        guard long.count - short.count <= 1 else { return false }

        if short.count == long.count {
            var mismatches: [Int] = []
            for index in short.indices where short[index] != long[index] {
                mismatches.append(index)
                if mismatches.count > 2 { return false }
            }
            if mismatches.count <= 1 { return true }
            let firstIndex = mismatches[0]
            let secondIndex = mismatches[1]
            return secondIndex == firstIndex + 1
                && short[firstIndex] == long[secondIndex]
                && short[secondIndex] == long[firstIndex]
        }

        var shortIndex = 0
        var longIndex = 0
        var skippedOne = false
        while shortIndex < short.count, longIndex < long.count {
            if short[shortIndex] == long[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else if skippedOne {
                return false
            } else {
                skippedOne = true
                longIndex += 1
            }
        }
        return true
    }

    // Every card shown by `groupContent(_:)` must have an entry here, or it is
    // unfindable. When adding a settings card, add its entry (title, detail, and the
    // words a user would actually type — including synonyms not shown in the UI).
    private static let all: [SettingsSearchResult] = [
        .init(
            id: "access",
            title: "Access",
            detail: "Subscription email, verification code, entitlement, and account access.",
            group: .setup,
            keywords: [
                "login", "sign in", "email", "code", "base", "pro", "billing",
                "subscription", "account", "upgrade", "plan", "checkout", "portal",
                "manage subscription", "verify", "entitlement"
            ]
        ),
        .init(
            id: "permissions",
            title: "Permissions",
            detail: "Microphone, speech recognition, accessibility, and input monitoring access.",
            group: .setup,
            keywords: [
                "privacy", "system settings", "input", "monitoring", "mic",
                "microphone", "speech", "accessibility", "access", "grant", "allow"
            ]
        ),
        .init(
            id: "recording-shortcuts",
            title: "Recording shortcuts",
            detail: "Tap to Talk, Hold to Talk, global hotkeys, Return to submit, dictionary quick fix, and snippet creation.",
            group: .behavior,
            keywords: [
                "shortcut", "key", "hotkey", "keyboard", "option", "hold", "tap",
                "press", "return", "submit", "record", "hands free", "push to talk",
                "voce actions", "fn", "transcribing"
            ]
        ),
        .init(
            id: "dictation-engine",
            title: "Speech",
            detail: "Choose local or cloud transcription, language, per-app overrides, and cloud model behavior.",
            group: .speech,
            keywords: [
                "cloud", "local", "model", "transcription", "speech", "openai",
                "language", "locale", "whisper", "override", "pin", "per app",
                "on device", "offline", "engine"
            ]
        ),
        .init(
            id: "media",
            title: "Media",
            detail: "Pause and resume music or video while dictating.",
            group: .behavior,
            keywords: [
                "spotify", "youtube", "music", "pause", "resume", "playback",
                "sound", "audio", "video", "browser", "chrome", "arc", "play",
                "interrupt", "volume"
            ]
        ),
        .init(
            id: "ai-workflows",
            title: "AI workflows",
            detail: "Configure AI cleanup, finish keys, workflow shortcuts, and spoken triggers.",
            group: .ai,
            keywords: [
                "cleanup", "refinement", "refine", "apple intelligence", "trigger",
                "workflow", "prompt", "finish", "cloud refinement", "rewrite",
                "polish", "formatting"
            ]
        ),
        .init(
            id: "appearance",
            title: "Appearance",
            detail: "Choose app theme, light or dark mode behavior, and the dictation bubble style.",
            group: .general,
            keywords: [
                "theme", "dark", "light", "bubble", "tech", "meter", "visual",
                "mode", "style", "color", "system"
            ]
        ),
        .init(
            id: "profile",
            title: "Profile",
            detail: "Set the name Voce uses in the main recording prompt.",
            group: .general,
            keywords: ["name", "username", "display", "greeting", "prompt"]
        ),
        .init(
            id: "app-behavior",
            title: "App behavior",
            detail: "Launch at login, Dock icon visibility, welcome replay, and app-level behavior.",
            group: .general,
            keywords: [
                "startup", "login", "dock", "window", "menu bar", "launch",
                "welcome", "onboarding", "icon", "autostart", "boot", "hide"
            ]
        ),
        .init(
            id: "typing-speed",
            title: "Typing speed",
            detail: "Measure your typing baseline; Voce uses your best score for time-saved estimates.",
            group: .general,
            keywords: [
                "wpm", "words per minute", "typing", "speed", "test", "baseline",
                "measure", "time saved", "benchmark", "stats"
            ]
        ),
        .init(
            id: "updates",
            title: "Updates",
            detail: "Check for a new version of Voce and install the latest release.",
            group: .general,
            keywords: [
                "update", "updates", "upgrade", "version", "latest", "release",
                "check for updates", "check now", "new version", "software update",
                "install", "changelog", "what's new"
            ]
        ),
        .init(
            id: "licenses",
            title: "Licenses",
            detail: "Open-source license notices and acknowledgements.",
            group: .general,
            keywords: [
                "license", "mit", "open source", "acknowledgements", "credits",
                "legal", "copyright", "notice", "attribution"
            ]
        ),
        .init(
            id: "walkthrough",
            title: "Walkthrough",
            detail: "Replay the teaching flow for dictation, shortcuts, and dictionary fixes.",
            group: .help,
            keywords: [
                "tutorial", "guide", "practice", "learn", "training", "onboarding",
                "lesson", "replay", "how to"
            ]
        ),
        .init(
            id: "support",
            title: "Support",
            detail: "Report a bug, send feedback, request a feature, and include diagnostics.",
            group: .help,
            keywords: [
                "bug", "feedback", "feature", "diagnostics", "email", "help",
                "contact", "report", "issue", "problem", "crash"
            ]
        ),
        .init(
            id: "faq",
            title: "FAQ",
            detail: "Quick answers for starting dictation, fixing words, and pasted transcripts.",
            group: .help,
            keywords: [
                "question", "answer", "fix word", "clipboard", "paste", "dictating",
                "troubleshooting", "not working"
            ]
        )
    ]
}

private struct SettingsSearchResultRow: View {
    let result: SettingsSearchResult

    var body: some View {
        settingsSubcard {
            HStack(alignment: .top, spacing: VoceDesign.md) {
                Image(systemName: result.group.icon)
                    .font(.system(size: VoceDesign.iconMD, weight: .semibold))
                    .foregroundStyle(VoceDesign.accent)
                    .frame(width: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    HStack(spacing: VoceDesign.sm) {
                        Text(result.title)
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Text(result.group.title)
                            .font(VoceDesign.captionEmphasis())
                            .foregroundStyle(VoceDesign.textSecondary)
                            .padding(.horizontal, VoceDesign.xs)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(VoceDesign.surfaceSecondary.opacity(0.78))
                            )
                    }

                    Text(result.detail)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VoceDesign.textSecondary)
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct HelpFAQSection: View {
    let tapHotkeyLabel: String
    let holdHotkeyLabel: String
    let dictionaryHotkeyLabel: String
    let dictionaryShortcutIsBound: Bool
    let voceActionsTapEnabled: Bool

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
                    answer: dictionaryFixAnswer
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

    /// Compose the dictionary-fix answer based on which surface(s) are
    /// available. New installs use the Cmd+Option tap; upgraders may still
    /// have the legacy direct shortcut bound. If both are off the legacy
    /// "press Unassigned" string would be nonsense, so steer the user to
    /// re-enable the tap.
    private var dictionaryFixAnswer: String {
        switch (voceActionsTapEnabled, dictionaryShortcutIsBound) {
        case (true, true):
            return "Highlight the wrong word, then either tap \u{2318}\u{2325} together (Voce actions) or press \(dictionaryHotkeyLabel) for a direct fix."
        case (true, false):
            return "Highlight the wrong word, tap \u{2318}\u{2325} together, and pick Dictionary fix in the action picker."
        case (false, true):
            return "Highlight the wrong word, press \(dictionaryHotkeyLabel), then enter the correct replacement in the Teach Voce popover."
        case (false, false):
            return "Turn on Voce actions in Recording shortcuts, then highlight the wrong word and tap \u{2318}\u{2325} together to fix it."
        }
    }
}

private struct HelpSupportSection: View {
    @EnvironmentObject private var controller: DictationController
    let subscriberEmail: String
    let appearancePreference: AppAppearancePreference
    let launchAtLoginEnabled: Bool
    let showDockIcon: Bool
    let pauseDuringHandsFree: Bool
    let pauseDuringPressToTalk: Bool
    let tapHotkeyLabel: String
    let holdHotkeyLabel: String
    let hotkeyRegistrationMessage: String
    let aiAvailable: Bool

    @State private var selectedCategory: VoceSupportRequestCategory?
    @State private var feedbackMessage = ""
    @State private var feedbackIsError = false
    @State private var mediaDiagnosticsText = "media_diagnostics_status=pending"

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
        .task {
            await refreshMediaDiagnostics()
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
            "pause_media_for_tap_to_talk=\(pauseDuringHandsFree)",
            "pause_media_for_hold_to_talk=\(pauseDuringPressToTalk)",
            "ai_available=\(aiAvailable)",
            "hotkey_registration=\(hotkeyRegistrationMessage.isEmpty ? "ok" : hotkeyRegistrationMessage)",
            mediaDiagnosticsText
        ]
        return values.joined(separator: "\n")
    }

    private func refreshMediaDiagnostics() async {
        let snapshot = await MacMediaInterruptionService.capturePlaybackDiagnostics()
        mediaDiagnosticsText = snapshot.diagnosticsText
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
