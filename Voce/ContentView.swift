import AppKit
import SwiftUI
import VoceKit

enum VoceTab: String, Hashable {
    case home = "Home"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case scratchPad = "Scratchpad"
    case settings = "Settings"

    static let navigationTabs: [VoceTab] = [.home, .dictionary, .snippets, .style, .scratchPad]

    var icon: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "text.book.closed"
        case .snippets: return "sparkles"
        case .style: return "textformat"
        case .scratchPad: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var updaterController: UpdaterController
    @State private var selectedTab: VoceTab = .home
    @State private var lastNonSettingsTab: VoceTab = .home
    @State private var settingsLaunchTarget: SettingsLaunchTarget?
    @State private var preferencesDraft: AppPreferences = .default
    @State private var accessEmailDraft = ""
    @State private var accessVerificationCodeDraft = ""
    @State private var accessVerificationCodeWasSent = false
    @State private var accessAuthIsWorking = false
    @State private var accessAuthError = ""
    @State private var accessEmailWasSubmitted = false
    @State private var accessPromptCompleted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let shellOuterPadding = proxy.size.width < 920 ? 2.0 : VoceDesign.sm
            let shellInnerPadding = proxy.size.width < 920 ? 4.0 : VoceDesign.sm
            let shellCornerRadius = proxy.size.width < 920 ? 32.0 : 38.0
            let contentCornerRadius = proxy.size.width < 920 ? 26.0 : 30.0
            let sidebarWidth = VoceDesign.sidebarWidth
            let shellContentWidth = max(0, proxy.size.width - (shellOuterPadding * 2) - (shellInnerPadding * 2))
            let shellContentHeight = max(0, proxy.size.height - (shellOuterPadding * 2) - (shellInnerPadding * 2))

            ZStack(alignment: .topLeading) {
                VoceWindowBackdrop()

                HStack(spacing: shellInnerPadding) {
                    sidebar(width: sidebarWidth, height: shellContentHeight, cornerRadius: contentCornerRadius)
                    mainContentPane(cornerRadius: contentCornerRadius)
                }
                .frame(width: shellContentWidth, height: shellContentHeight, alignment: .topLeading)
                .padding(shellInnerPadding)
                .background {
                    RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                        .fill(VoceDesign.surface.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.42))
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.12)
                                : Color.black.opacity(0.06),
                            lineWidth: VoceDesign.borderThin
                        )
                )
                .shadowStyle(.xl)
                .padding(shellOuterPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            minWidth: VoceDesign.windowMinWidth,
            idealWidth: VoceDesign.windowIdealWidth,
            minHeight: VoceDesign.windowMinHeight,
            idealHeight: VoceDesign.windowIdealHeight
        )
        .onAppear {
            preferencesDraft = controller.preferences
            accessEmailDraft = controller.preferences.billing.subscriberEmail
        }
        .onChange(of: controller.preferences) { _, newValue in
            if newValue != preferencesDraft {
                preferencesDraft = newValue
            }
            if newValue.billing.subscriberEmail != normalizedAccessEmail {
                accessEmailDraft = newValue.billing.subscriberEmail
            }
        }
        .onChange(of: preferencesDraft) { _, newValue in
            var normalized = newValue
            normalized.normalize()
            guard normalized != controller.preferences else { return }

            if normalized.requiresRuntimeRebuild(comparedTo: controller.preferences) {
                controller.applySettingsDraft(preferences: newValue, announceImmediateSave: false)
            } else {
                controller.savePreferencesQuietly(preferences: newValue)
            }
        }
        .task {
            await controller.refreshHistory()
        }
    }

    // MARK: - Sidebar

    private func sidebar(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        let isCompact = height < 700
        let railBottomInset = isCompact ? VoceDesign.sm : VoceDesign.md

        return VStack(alignment: .leading, spacing: 0) {
            sidebarBrand(isCompact: isCompact)
            sidebarNavigation(isCompact: isCompact)
            Spacer(minLength: 0)
            sidebarSettings(isCompact: isCompact)
        }
        .padding(.bottom, railBottomInset)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.30), lineWidth: VoceDesign.borderThin)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func sidebarBrand(isCompact: Bool) -> some View {
        HStack(spacing: VoceDesign.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(VoceDesign.accent)
            Text("Voce")
                .font(VoceDesign.font(size: 18, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .padding(.horizontal, VoceDesign.lg)
        .padding(.top, isCompact ? VoceDesign.md : VoceDesign.xl + VoceDesign.sm)
        .padding(.bottom, isCompact ? VoceDesign.sm : VoceDesign.xl)
    }

    private func sidebarNavigation(isCompact: Bool) -> some View {
        VStack(spacing: VoceDesign.xxs) {
            ForEach(VoceTab.navigationTabs, id: \.self) { tab in
                sidebarButton(tab, isCompact: isCompact)
            }
        }
        .padding(.horizontal, VoceDesign.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sidebarSettings(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, VoceDesign.lg)

            Button {
                openSettings()
            } label: {
                HStack(spacing: VoceDesign.md) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: selectedTab == .settings ? .semibold : .medium))
                        .foregroundStyle(selectedTab == .settings ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                        .frame(width: 20)
                    Text("Settings")
                        .font(VoceDesign.font(size: 13, weight: selectedTab == .settings ? .semibold : .medium))
                        .foregroundStyle(selectedTab == .settings ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: isCompact ? 34 : 38, alignment: .leading)
                .padding(.horizontal, VoceDesign.lg)
                .padding(.top, isCompact ? VoceDesign.xs : VoceDesign.sm)
                .padding(.bottom, isCompact ? VoceDesign.sm : VoceDesign.lg)
                .background {
                    if selectedTab == .settings {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(VoceDesign.accent.opacity(0.08))
                            .padding(.horizontal, VoceDesign.md)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(selectedTab == .settings ? .isSelected : [])
        }
        .padding(.bottom, isCompact ? VoceDesign.xs : VoceDesign.sm)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }

    private func mainContentPane(cornerRadius: CGFloat) -> some View {
        ZStack {
            VoceDesign.contentBackground

            ZStack {
                HomeTab {
                    openSettings(.handsFreeGlobalHotkey)
                }
                .tabContentVisibility(selectedTab == .home)

                DictionaryTab(preferences: $preferencesDraft)
                    .tabContentVisibility(selectedTab == .dictionary)

                SnippetsTab(preferences: $preferencesDraft)
                    .tabContentVisibility(selectedTab == .snippets)

                StyleTab(preferences: $preferencesDraft)
                    .tabContentVisibility(selectedTab == .style)

                ScratchPadTab(
                    content: $preferencesDraft.scratchPadContent,
                    isActive: selectedTab == .scratchPad
                )
                    .tabContentVisibility(selectedTab == .scratchPad)

                SettingsView(
                    initialLaunchTarget: settingsLaunchTarget,
                    accessVerificationCode: $accessVerificationCodeDraft,
                    accessVerificationCodeWasSent: accessVerificationCodeWasSent,
                    accessAuthIsWorking: accessAuthIsWorking,
                    accessAuthError: accessAuthError,
                    onRequestAccessCode: requestAccessCode(for:),
                    onVerifyAccessCode: verifyAccessCode(for:),
                    onClose: closeSettings
                )
                .environmentObject(controller)
                .environmentObject(updaterController)
                .tabContentVisibility(selectedTab == .settings)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                value: selectedTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsAccessPrompt {
                accessPrompt
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(5)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
            value: showsAccessPrompt
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04),
                    lineWidth: VoceDesign.borderThin
                )
        )
    }

    private var normalizedAccessEmail: String {
        accessEmailDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var showsAccessPrompt: Bool {
        guard selectedTab != .settings else { return false }
        switch controller.voceProEntitlementStatus {
        case .entitled:
            return accessEmailWasSubmitted && !accessPromptCompleted
        case .checking:
            return true
        case .missingEmail, .needsVerification, .notEntitled, .failed:
            return true
        }
    }

    private var accessPrompt: some View {
        AccessPromptView(
            email: $accessEmailDraft,
            verificationCode: $accessVerificationCodeDraft,
            entitlementStatus: controller.voceProEntitlementStatus,
            didSubmitEmail: accessEmailWasSubmitted,
            didSendVerificationCode: accessVerificationCodeWasSent,
            isAuthWorking: accessAuthIsWorking,
            authError: accessAuthError,
            onNext: requestAccessCode,
            onVerifyCode: verifyAccessCode,
            onResendCode: requestAccessCode,
            onChooseFree: continueWithFreeAccess,
            onSubscribe: subscribe,
            onContinue: completeAccessPrompt,
            onBackToEmail: resetAccessEmailStep
        )
    }

    private func requestAccessCode() {
        requestAccessCode(for: accessEmailDraft)
    }

    private func requestAccessCode(for rawEmail: String) {
        guard let email = saveAccessEmail(rawEmail) else { return }
        accessAuthError = ""
        accessAuthIsWorking = true
        accessPromptCompleted = false

        Task {
            do {
                try await controller.requestVoceAccessCode(email: email)
                accessVerificationCodeWasSent = true
                accessVerificationCodeDraft = ""
            } catch {
                accessAuthError = (error as? LocalizedError)?.errorDescription
                    ?? "Could not send an access code."
            }
            accessAuthIsWorking = false
        }
    }

    private func verifyAccessCode() {
        verifyAccessCode(for: accessEmailDraft)
    }

    private func verifyAccessCode(for rawEmail: String) {
        let email = rawEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let code = accessVerificationCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !code.isEmpty else { return }

        accessAuthError = ""
        accessAuthIsWorking = true

        Task {
            do {
                try await controller.verifyVoceAccessCode(email: email, code: code)
                accessEmailWasSubmitted = true
                accessVerificationCodeWasSent = false
                accessPromptCompleted = false
            } catch {
                accessAuthError = (error as? LocalizedError)?.errorDescription
                    ?? "Could not verify that code."
            }
            accessAuthIsWorking = false
        }
    }

    private func continueWithFreeAccess() {
        guard case .entitled(let entitlement) = controller.voceProEntitlementStatus,
              entitlement.source == .free
        else { return }

        accessPromptCompleted = true
    }

    private func subscribe(to plan: VoceCheckoutPlan, billingCycle: VoceCheckoutBillingCycle) {
        guard saveAccessEmail() != nil else { return }
        accessPromptCompleted = false
        controller.openVoceCheckout(plan: plan, billingCycle: billingCycle)
    }

    private func completeAccessPrompt() {
        accessPromptCompleted = true
    }

    private func resetAccessEmailStep() {
        accessEmailWasSubmitted = false
        accessVerificationCodeWasSent = false
        accessVerificationCodeDraft = ""
        accessAuthError = ""
        accessAuthIsWorking = false
        accessPromptCompleted = false
    }

    private func saveAccessEmail(_ rawEmail: String? = nil) -> String? {
        let email = (rawEmail ?? accessEmailDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return nil }

        accessEmailDraft = email
        var snapshot = preferencesDraft
        snapshot.billing.subscriberEmail = email
        snapshot.normalize()
        preferencesDraft = snapshot
        controller.applySettingsDraft(preferences: snapshot, announceImmediateSave: false)
        return email
    }

    private func sidebarButton(_ tab: VoceTab, isCompact: Bool = false) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
                lastNonSettingsTab = tab
                settingsLaunchTarget = nil
                selectedTab = tab
            }
        } label: {
            HStack(spacing: VoceDesign.md) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                    .frame(width: 20)

                Text(tab.rawValue)
                    .font(VoceDesign.font(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Spacer()
            }
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, isCompact ? VoceDesign.xs : VoceDesign.sm)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .fill(VoceDesign.accent.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(showsAccessPrompt)
        .opacity(showsAccessPrompt ? VoceDesign.opacityDisabled : 1)
        .help(showsAccessPrompt ? "Finish access setup to use Voce" : tab.rawValue)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openSettings(_ launchTarget: SettingsLaunchTarget? = nil) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationFast)) {
            if selectedTab != .settings {
                lastNonSettingsTab = selectedTab
            }
            settingsLaunchTarget = launchTarget
            selectedTab = .settings
        }
    }

    private func closeSettings() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationFast)) {
            selectedTab = lastNonSettingsTab
            settingsLaunchTarget = nil
        }
    }
}

enum SettingsLaunchTarget: Equatable {
    case handsFreeGlobalHotkey
}

private struct AccessPromptView: View {
    @Binding var email: String
    @Binding var verificationCode: String
    let entitlementStatus: VoceProEntitlementStatus
    let didSubmitEmail: Bool
    let didSendVerificationCode: Bool
    let isAuthWorking: Bool
    let authError: String
    let onNext: () -> Void
    let onVerifyCode: () -> Void
    let onResendCode: () -> Void
    let onChooseFree: () -> Void
    let onSubscribe: (VoceCheckoutPlan, VoceCheckoutBillingCycle) -> Void
    let onContinue: () -> Void
    let onBackToEmail: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heartGlowPulse = false
    @State private var selectedBillingCycle: VoceCheckoutBillingCycle = .monthly

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canGoNext: Bool {
        !normalizedEmail.isEmpty && !entitlementStatus.isChecking && !isAuthWorking
    }

    private var normalizedVerificationCode: String {
        verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canVerifyCode: Bool {
        normalizedVerificationCode.count == 6 && !isAuthWorking
    }

    private var shouldShowVerificationStep: Bool {
        didSendVerificationCode && !didSubmitEmail
    }

    private var shouldShowEmailStep: Bool {
        guard !shouldShowVerificationStep else { return false }
        switch entitlementStatus {
        case .missingEmail, .needsVerification, .failed:
            return true
        case .checking:
            return !didSubmitEmail && normalizedEmail.isEmpty
        case .entitled, .notEntitled:
            return !didSubmitEmail
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, VoceDesign.lg)
                .padding(.top, VoceDesign.lg)

            GeometryReader { _ in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(spacing: VoceDesign.md) {
                        Group {
                            if shouldShowVerificationStep {
                                verificationStep
                            } else if shouldShowEmailStep {
                                emailStep
                            } else {
                                accessStep
                            }
                        }
                        .frame(maxWidth: 860)

                        navigationBar
                    }
                    .frame(maxWidth: 860)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, VoceDesign.xl)
                .padding(.bottom, VoceDesign.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VoceWindowBackdrop()
                readabilityWash
            }
        }
    }

    private var readabilityWash: some View {
        ZStack {
            Rectangle()
                .fill(VoceDesign.contentBackground.opacity(colorScheme == .dark ? 0.62 : 0.42))

            LinearGradient(
                colors: [
                    VoceDesign.surfaceSolid.opacity(colorScheme == .dark ? 0.72 : 0.66),
                    VoceDesign.surfaceSolid.opacity(colorScheme == .dark ? 0.36 : 0.30),
                    VoceDesign.contentBackground.opacity(colorScheme == .dark ? 0.58 : 0.48)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var progressBar: some View {
        HStack(spacing: VoceDesign.xs) {
            ForEach(0..<2, id: \.self) { step in
                RoundedRectangle(cornerRadius: VoceDesign.radiusTiny)
                    .fill(step <= currentStepIndex ? warmText : VoceDesign.border)
                    .frame(height: VoceDesign.xs)
            }
        }
        .accessibilityLabel("Step \(currentStepIndex + 1) of 2")
    }

    private var emailStep: some View {
        VStack(spacing: VoceDesign.xl) {
            accessHero(
                icon: "person.crop.circle.fill",
                title: "Let's set up access",
                subtitle: "Voce uses your email to find Base or Pro access, or start your free monthly time. Pro includes 300 minutes/month of Voce Cloud."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                Text("Email")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                TextField("email@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .settingsInputChrome()
                    .onSubmit {
                        if canGoNext {
                            onNext()
                        }
                    }

                if case .failed = entitlementStatus {
                    statusLabel
                }

                if !authError.isEmpty {
                    errorLabel(authError)
                }
            }
            .frame(maxWidth: 520)
            .cardStyle(padding: VoceDesign.lg)
        }
    }

    private var verificationStep: some View {
        VStack(spacing: VoceDesign.xl) {
            accessHero(
                icon: "envelope.badge.fill",
                title: "Check your email",
                subtitle: "Enter the 6-digit code sent to \(normalizedEmail)."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                Text("Access code")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                TextField("", text: $verificationCode)
                    .textFieldStyle(.plain)
                    .settingsInputChrome()
                    .textContentType(.oneTimeCode)
                    .onChange(of: verificationCode) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        verificationCode = String(digits.prefix(6))
                    }
                    .onSubmit {
                        if canVerifyCode {
                            onVerifyCode()
                        }
                    }

                HStack(spacing: VoceDesign.sm) {
                    Text("Codes expire after 10 minutes.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)

                    Button {
                        onResendCode()
                    } label: {
                        Text("Send a new code")
                            .font(VoceDesign.captionEmphasis())
                            .foregroundStyle(isAuthWorking ? VoceDesign.textSecondary : warmText)
                            .padding(.horizontal, VoceDesign.md)
                            .padding(.vertical, VoceDesign.xs)
                            .background(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(isAuthWorking ? VoceDesign.surfaceSecondary : warmFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAuthWorking)
                }

                if !authError.isEmpty {
                    errorLabel(authError)
                }
            }
            .frame(maxWidth: 520)
            .cardStyle(padding: VoceDesign.lg)
        }
    }

    private var accessStep: some View {
        VStack(spacing: VoceDesign.xl) {
            if showsPaidActiveCard {
                paidActiveCard
            } else {
                accessHero(
                    icon: accessHeroIcon,
                    title: accessTitle,
                    subtitle: accessSubtitle
                )

                switch entitlementStatus {
                case .checking:
                    checkingCard
                case .entitled:
                    planChoiceCards
                case .notEntitled:
                    planChoiceCards
                case .failed, .missingEmail, .needsVerification:
                    emailStep
                }
            }
        }
    }

    private var checkingCard: some View {
        HStack(spacing: VoceDesign.md) {
            ProgressView()
                .controlSize(.small)
            Text("Checking access for \(normalizedEmail)...")
                .font(VoceDesign.body())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .cardStyle(padding: VoceDesign.lg)
    }

    private var warmFill: Color {
        colorScheme == .dark
            ? VoceDesign.sage.opacity(0.28)
            : VoceDesign.warmAccentFill
    }

    private var warmText: Color {
        colorScheme == .dark
            ? VoceDesign.sage
            : VoceDesign.warmAccentText
    }

    private var warmBadgeFill: Color {
        colorScheme == .dark
            ? VoceDesign.sage.opacity(0.22)
            : VoceDesign.warmAccentText
    }

    private var warmBadgeText: Color {
        colorScheme == .dark
            ? VoceDesign.sage
            : .white
    }

    private var paidActiveCard: some View {
        VStack(spacing: VoceDesign.lg) {
            HStack(spacing: VoceDesign.sm) {
                Text(activePlanBadgeTitle)
                    .font(VoceDesign.labelEmphasis())
                    .foregroundStyle(warmBadgeText)
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.xs + 1)
                    .background(
                        Capsule()
                            .fill(warmBadgeFill)
                    )

                Text("Active")
                    .font(VoceDesign.labelEmphasis())
                .foregroundStyle(colorScheme == .dark ? VoceDesign.sage : VoceDesign.success)
                .padding(.horizontal, VoceDesign.md)
                .padding(.vertical, VoceDesign.xs + 1)
                .background(
                    Capsule()
                        .fill(colorScheme == .dark ? VoceDesign.sage.opacity(0.14) : VoceDesign.successBackground)
                        .overlay(
                            Capsule()
                                .stroke(colorScheme == .dark ? VoceDesign.sage.opacity(0.2) : VoceDesign.successBorder, lineWidth: VoceDesign.borderThin)
                        )
                )
            }

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                warmFill.opacity(colorScheme == .dark ? 0.8 : 0.6),
                                warmFill.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 52
                        )
                    )
                    .frame(width: 104, height: 104)
                    .scaleEffect(heartGlowPulse ? 1.18 : 1.0)
                    .opacity(heartGlowPulse ? 0.9 : 0.45)

                Circle()
                    .fill(warmFill)
                    .frame(width: 58, height: 58)
                    .overlay(
                        Circle()
                            .stroke(warmText.opacity(0.16), lineWidth: VoceDesign.borderThin)
                    )

                Image(systemName: activePlanIconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(warmText)
            }
            .accessibilityHidden(true)

            VStack(spacing: VoceDesign.xs) {
                Text(activePlanTitle)
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(activePlanDetail)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(warmText)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, VoceDesign.xl)
        .padding(.vertical, VoceDesign.xl)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.92))
                .overlay(
                    LinearGradient(
                        colors: [
                            warmFill.opacity(colorScheme == .dark ? 0.3 : 0.5),
                            VoceDesign.wheat.opacity(colorScheme == .dark ? 0.08 : 0.22),
                            VoceDesign.roseLight.opacity(colorScheme == .dark ? 0.04 : 0.1),
                            VoceDesign.surface.opacity(0.4),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: [
                            warmFill.opacity(colorScheme == .dark ? 0.15 : 0.25),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 200
                    )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            warmText.opacity(0.22),
                            VoceDesign.wheat.opacity(colorScheme == .dark ? 0.08 : 0.16),
                            warmText.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: VoceDesign.borderThin
                )
        )
        .shadowStyle(.lg)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: VoceDesign.animationGlow)
                .repeatForever(autoreverses: true)
            ) {
                heartGlowPulse = true
            }
        }
    }

    private var planChoiceCards: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            Picker("Billing", selection: $selectedBillingCycle) {
                ForEach(VoceCheckoutBillingCycle.allCases, id: \.self) { cycle in
                    Text(cycle.title).tag(cycle)
                }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .top, spacing: VoceDesign.md) {
                basePlanCard
                proPlanCard
            }

            if canChooseFree {
                Button {
                    onChooseFree()
                } label: {
                    Text("Keep using free monthly time")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.horizontal, VoceDesign.lg)
                        .padding(.vertical, VoceDesign.sm)
                        .background(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                .fill(VoceDesign.surfaceSecondary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                        .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 680)
    }

    // MARK: - Base plan card

    private var basePlanCard: some View {
        VStack(alignment: .leading, spacing: VoceDesign.lg) {
            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                Text("Base")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(basePlanDetail)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                Text(basePriceText)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                planFeatureRow(icon: "mic.fill", text: "Unlimited local dictation", muted: false)
                planFeatureRow(icon: "sparkles", text: "Apple Intelligence actions", muted: false)
                planFeatureRow(icon: "textformat", text: "Style controls and dictionary", muted: false)
            }

            Spacer(minLength: 0)

            Button {
                onSubscribe(.base, selectedBillingCycle)
            } label: {
                Text(basePlanActionTitle)
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoceDesign.sm + 2)
                    .background(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(VoceDesign.surfaceSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(normalizedEmail.isEmpty)
            .opacity(normalizedEmail.isEmpty ? VoceDesign.opacityDisabled : 1)
        }
        .padding(VoceDesign.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.44))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    // MARK: - Pro plan card

    private var proPlanCard: some View {
        VStack(alignment: .leading, spacing: VoceDesign.lg) {
            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                HStack {
                    Text("Pro")
                        .font(VoceDesign.heading3())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Spacer(minLength: 0)

                    Text("Recommended")
                        .font(VoceDesign.label())
                        .foregroundStyle(warmText)
                        .padding(.horizontal, VoceDesign.sm)
                        .padding(.vertical, VoceDesign.xxs + 1)
                        .background(
                            Capsule()
                                .fill(warmFill)
                        )
                }

                Text("Best accuracy with 300 minutes/month of Voce Cloud.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                Text(proPriceText)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                planFeatureRow(icon: "star.fill", text: "Everything in Base", muted: false)
                planFeatureRow(icon: "cloud.fill", text: "300 minutes/month of Voce Cloud", muted: false)
                planFeatureRow(icon: "key.fill", text: "Use your OpenAI key or local dictation after that", muted: false)
                planFeatureRow(icon: "list.bullet", text: "Smarter cleanup and formatting", muted: false)
            }

            Spacer(minLength: 0)

            Button {
                onSubscribe(.pro, selectedBillingCycle)
            } label: {
                Text(proPlanActionTitle)
                    .font(VoceDesign.callout())
                    .fontWeight(.semibold)
                    .foregroundStyle(warmText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoceDesign.sm + 2)
                    .background(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(warmFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .stroke(warmText.opacity(0.14), lineWidth: VoceDesign.borderThin)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(normalizedEmail.isEmpty)
            .opacity(normalizedEmail.isEmpty ? VoceDesign.opacityDisabled : 1)
        }
        .padding(VoceDesign.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.6))
                .overlay(
                    LinearGradient(
                        colors: [
                            warmFill.opacity(colorScheme == .dark ? 0.2 : 0.32),
                            VoceDesign.wheat.opacity(colorScheme == .dark ? 0.06 : 0.12),
                            VoceDesign.surface.opacity(0.2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            warmText.opacity(0.2),
                            VoceDesign.wheat.opacity(colorScheme == .dark ? 0.06 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: VoceDesign.borderThin
                )
        )
        .shadowStyle(.md)
    }

    // MARK: - Plan feature row

    private func planFeatureRow(icon: String, text: String, muted: Bool) -> some View {
        HStack(spacing: VoceDesign.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(muted ? VoceDesign.textSecondary : warmText)
                .frame(width: 18, alignment: .center)

            Text(text)
                .font(VoceDesign.callout())
                .foregroundStyle(muted ? VoceDesign.textSecondary : VoceDesign.textPrimary)
        }
    }

    private var navigationBar: some View {
        HStack {
            if (didSubmitEmail || didSendVerificationCode) && !entitlementStatus.isChecking {
                Button {
                    onBackToEmail()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VoceDesign.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(VoceDesign.surface.opacity(0.42)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change email")
            }

            Spacer()

            if shouldShowVerificationStep {
                Button {
                    onVerifyCode()
                } label: {
                    primaryButtonLabel("Verify")
                }
                .buttonStyle(.plain)
                .disabled(!canVerifyCode)
                .opacity(canVerifyCode ? 1 : VoceDesign.opacityDisabled)
            } else if shouldShowEmailStep {
                Button {
                    onNext()
                } label: {
                    if isAuthWorking {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, VoceDesign.xl)
                            .padding(.vertical, VoceDesign.sm)
                            .background(Capsule().fill(warmFill))
                    } else {
                        primaryButtonLabel("Send code")
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canGoNext)
                .opacity(canGoNext ? 1 : VoceDesign.opacityDisabled)
            } else if canContinueToApp {
                Button {
                    onContinue()
                } label: {
                    primaryButtonLabel("Continue")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 860)
    }

    private func accessHero(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: VoceDesign.lg) {
            ZStack {
                Circle()
                    .fill(warmFill)
                    .frame(width: 88, height: 88)

                Image(systemName: icon)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(warmText)
            }
            .accessibilityHidden(true)

            VStack(spacing: VoceDesign.xs) {
                Text(title)
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
            }
            .shadow(color: heroTextShadowColor, radius: 7, x: 0, y: 1)
        }
    }

    private func primaryButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.bodyEmphasis())
            .foregroundStyle(warmText)
            .padding(.horizontal, VoceDesign.xl)
            .padding(.vertical, VoceDesign.sm)
            .background(Capsule().fill(warmFill))
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(VoceDesign.caption())
            .foregroundStyle(VoceDesign.error)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var heroTextShadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.32)
            : Color.white.opacity(0.72)
    }

    private var statusLabel: some View {
        Label(entitlementStatus.message, systemImage: statusIconName)
            .font(VoceDesign.caption())
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessHeroIcon: String {
        switch entitlementStatus {
        case .entitled(let entitlement):
            switch entitlement.source {
            case .manual:
                return "checkmark.seal.fill"
            case .free:
                return "wand.and.stars"
            default:
                return "checkmark.circle.fill"
            }
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .notEntitled:
            return "sparkles"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .missingEmail, .needsVerification:
            return "person.crop.circle.fill"
        }
    }

    private var proActiveIconName: String {
        "heart.fill"
    }

    private var activePlanBadgeTitle: String {
        guard case .entitled(let entitlement) = entitlementStatus else {
            return "Plan"
        }
        return entitlement.planTier?.title ?? "Plan"
    }

    private var activePlanIconName: String {
        guard case .entitled(let entitlement) = entitlementStatus else {
            return proActiveIconName
        }
        return entitlement.planTier == .base ? "checkmark.seal.fill" : proActiveIconName
    }

    private var activePlanTitle: String {
        guard case .entitled(let entitlement) = entitlementStatus else {
            return "Voce is active"
        }
        let planTitle = entitlement.planTier?.title ?? "Voce"
        if entitlement.source == .manual {
            return "\(planTitle) is on us"
        }
        return "Voce \(planTitle) is active"
    }

    private var activePlanDetail: String {
        guard case .entitled(let entitlement) = entitlementStatus else {
            return "You're all set."
        }
        switch entitlement.planTier {
        case .base:
            return "Local dictation and AI actions are ready to go."
        case .pro:
            return "300 minutes/month of Voce Cloud is ready, with local dictation always available."
        case .free, nil:
            return "You're all set."
        }
    }

    private var showsPaidActiveCard: Bool {
        guard case .entitled(let entitlement) = entitlementStatus else { return false }
        return (entitlement.source == .manual || entitlement.source == .stripe)
            && entitlement.planTier != .free
    }

    private var accessTitle: String {
        switch entitlementStatus {
        case .entitled(let entitlement):
            switch entitlement.planTier {
            case .base, .pro:
                return "\(entitlement.planTier?.title ?? "Voce") is ready"
            case .free:
                return "Choose your plan"
            case nil:
                return "Voce is ready"
            }
        case .checking:
            return "Checking access"
        case .notEntitled:
            return "Choose your plan"
        case .failed:
            return "Check Voce access"
        case .missingEmail, .needsVerification:
            return "Let's set up access"
        }
    }

    private var accessSubtitle: String {
        switch entitlementStatus {
        case .entitled(let entitlement):
            switch entitlement.planTier {
            case .base:
                return "We found Base for \(normalizedEmail)."
            case .pro:
                return "We found Pro for \(normalizedEmail): 300 minutes/month of Voce Cloud."
            case .free:
                return "Select Base or Pro, or keep using your free monthly time."
            case nil:
                return "Access is active for \(normalizedEmail)."
            }
        case .checking:
            return "Looking for an active subscription or free monthly time."
        case .notEntitled:
            return "Choose Base for local-only access or Pro for 300 minutes/month of Voce Cloud."
        case .failed:
            return "Try the email you used for checkout."
        case .missingEmail, .needsVerification:
            return "Voce uses your email to find Base or Pro access, or start your free monthly time. Pro includes 300 minutes/month of Voce Cloud."
        }
    }

    private var canChooseFree: Bool {
        guard case .entitled(let entitlement) = entitlementStatus else { return false }
        return entitlement.source == .free
    }

    private var canContinueToApp: Bool {
        guard case .entitled(let entitlement) = entitlementStatus else { return false }
        return entitlement.planTier == .base
            || entitlement.planTier == .pro
            || entitlement.source == nil
    }

    private var basePlanDetail: String {
        "Fast, private, and fully on-device."
    }

    private var basePlanActionTitle: String {
        selectedBillingCycle == .monthly ? "Choose Base monthly" : "Choose Base yearly"
    }

    private var proPlanActionTitle: String {
        selectedBillingCycle == .monthly ? "Choose Pro monthly" : "Choose Pro yearly"
    }

    private var basePriceText: String {
        selectedBillingCycle == .monthly ? "$7 / month" : "$70 / year"
    }

    private var proPriceText: String {
        selectedBillingCycle == .monthly ? "$10 / month" : "$108 / year"
    }

    private var currentStepIndex: Int {
        shouldShowEmailStep || shouldShowVerificationStep ? 0 : 1
    }

    private var statusIconName: String {
        switch entitlementStatus {
        case .entitled:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .missingEmail, .needsVerification, .notEntitled:
            return "info.circle.fill"
        }
    }

    private var statusColor: Color {
        switch entitlementStatus {
        case .entitled:
            return VoceDesign.accent
        case .failed:
            return VoceDesign.error
        case .missingEmail, .needsVerification, .checking, .notEntitled:
            return VoceDesign.textSecondary
        }
    }
}

// MARK: - Tab Visibility Modifier

private struct TabContentVisibilityModifier: ViewModifier {
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
    func tabContentVisibility(_ isVisible: Bool) -> some View {
        modifier(TabContentVisibilityModifier(isVisible: isVisible))
    }
}
