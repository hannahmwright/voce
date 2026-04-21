import SwiftUI

struct VoceAccessSettingsSection: View {
    @Binding var preferences: AppPreferences
    @Binding var verificationCode: String
    let entitlementStatus: VoceProEntitlementStatus
    let didSendVerificationCode: Bool
    let isAuthWorking: Bool
    let authError: String
    let onRefreshEntitlement: () -> Void
    let onRequestAccessCode: () -> Void
    let onVerifyAccessCode: () -> Void
    let onSubscribe: () -> Void
    let onManageSubscription: () -> Void
    #if DEBUG
    let onResetAccessSession: () -> Void
    #endif

    var body: some View {
        settingsCard("Access") {
            VStack(alignment: .leading, spacing: VoceDesign.lg) {
                accessStatusCard

                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    settingInlineLabel(
                        "Email",
                        help: "Used to check your subscription, free access, or monthly free usage."
                    )

                    HStack(alignment: .center, spacing: VoceDesign.sm) {
                        TextField("email@example.com", text: $preferences.billing.subscriberEmail)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()
                            .frame(maxWidth: 460)

                        accessButton(
                            primaryAccessButtonTitle,
                            systemImage: primaryAccessButtonIcon,
                            showsSpinner: entitlementStatus.isChecking || isAuthWorking,
                            isEnabled: !normalizedSubscriberEmail.isEmpty
                                && !entitlementStatus.isChecking
                                && !isAuthWorking,
                            isProminent: false,
                            action: primaryAccessButtonAction
                        )

                        if !isEntitled {
                            accessButton(
                                "Subscribe",
                                systemImage: "sparkles",
                                isEnabled: !normalizedSubscriberEmail.isEmpty,
                                isProminent: true,
                                action: onSubscribe
                            )
                        }

                        if isStripeSubscriber {
                            accessButton(
                                "Manage",
                                systemImage: "creditcard",
                                isEnabled: true,
                                isProminent: false,
                                action: onManageSubscription
                            )
                        }
                    }
                }

                if showsVerificationCodeEntry {
                    verificationCodeEntry
                }

                #if DEBUG
                debugSection
                #endif
            }
        }
    }

    private var accessStatusCard: some View {
        let presentation = statusPresentation

        return HStack(alignment: .center, spacing: VoceDesign.md) {
            ZStack {
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                    .fill(presentation.tint.opacity(0.16))

                Image(systemName: presentation.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(presentation.tint)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                HStack(spacing: VoceDesign.sm) {
                    Text(presentation.title)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)

                    if let badge = presentation.badge {
                        Text(badge)
                            .font(VoceDesign.label())
                            .foregroundStyle(presentation.tint)
                            .padding(.horizontal, VoceDesign.sm)
                            .padding(.vertical, VoceDesign.xxs)
                            .background(presentation.tint.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusTiny + 4, style: .continuous))
                    }
                }

                Text(presentation.detail)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.58))
                .overlay(
                    LinearGradient(
                        colors: [
                            presentation.tint.opacity(0.10),
                            VoceDesign.surface.opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .stroke(presentation.tint.opacity(0.16), lineWidth: VoceDesign.borderThin)
                )
        }
    }

    private func accessButton(
        _ title: String,
        systemImage: String?,
        showsSpinner: Bool = false,
        isEnabled: Bool,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: VoceDesign.xs) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }

                Text(title)
                    .font(VoceDesign.captionEmphasis())
            }
            .foregroundStyle(isProminent ? VoceDesign.warmAccentText : VoceDesign.textPrimary)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm)
            .frame(minWidth: isProminent ? 116 : 88)
            .background(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                    .fill(isProminent ? VoceDesign.warmAccentFill : VoceDesign.surfaceSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(isProminent ? VoceDesign.warmAccentText.opacity(0.12) : VoceDesign.border, lineWidth: VoceDesign.borderThin)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : VoceDesign.opacityDisabled)
    }

    private var verificationCodeEntry: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                Text(didSendVerificationCode ? "Enter your access code" : "Verify this email")
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(verificationCodeDetail)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: VoceDesign.sm) {
                TextField("6-digit code", text: $verificationCode)
                    .textFieldStyle(.plain)
                    .settingsInputChrome()
                    .textContentType(.oneTimeCode)
                    .frame(maxWidth: 180)
                    .onChange(of: verificationCode) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        verificationCode = String(digits.prefix(6))
                    }
                    .onSubmit {
                        if canVerifyCode {
                            onVerifyAccessCode()
                        }
                    }

                accessButton(
                    isAuthWorking ? "Verifying..." : "Verify",
                    systemImage: nil,
                    showsSpinner: isAuthWorking,
                    isEnabled: canVerifyCode,
                    isProminent: true,
                    action: onVerifyAccessCode
                )

                Button {
                    onRequestAccessCode()
                } label: {
                    Text(didSendVerificationCode ? "Send a new code" : "Send code")
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(isAuthWorking ? VoceDesign.textSecondary : VoceDesign.warmAccentText)
                }
                .buttonStyle(.plain)
                .disabled(normalizedSubscriberEmail.isEmpty || isAuthWorking)
            }

            Text("Codes expire after 10 minutes.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            if !authError.isEmpty {
                Label(authError, systemImage: "exclamationmark.triangle.fill")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VoceDesign.md)
        .background(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .stroke(VoceDesign.warmAccentText.opacity(0.16), lineWidth: VoceDesign.borderThin)
                )
        )
    }

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(spacing: VoceDesign.sm) {
                Text("Testing tools")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)

                Spacer(minLength: 0)

                Button("Reset code login") {
                    onResetAccessSession()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.textSecondary)
                .disabled(normalizedSubscriberEmail.isEmpty)
            }

            Text("Clears the saved verification for the current email.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .padding(VoceDesign.sm)
        .background(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .fill(VoceDesign.surfaceSecondary.opacity(0.50))
        )
    }
    #endif

    // MARK: - Helpers

    private var normalizedSubscriberEmail: String {
        preferences.billing.subscriberEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isEntitled: Bool {
        if case .entitled = entitlementStatus { return true }
        return false
    }

    private var isStripeSubscriber: Bool {
        guard case .entitled(let entitlement) = entitlementStatus else {
            return false
        }
        return entitlement.source == .stripe
    }

    private var primaryAccessButtonTitle: String {
        if entitlementStatus.isChecking {
            return "Checking..."
        }
        if isAuthWorking {
            return didSendVerificationCode ? "Sending..." : "Working..."
        }
        return shouldSendCodeFromPrimaryButton ? "Send code" : "Check"
    }

    private var primaryAccessButtonIcon: String? {
        if entitlementStatus.isChecking || isAuthWorking {
            return nil
        }
        return shouldSendCodeFromPrimaryButton ? "envelope" : "arrow.clockwise"
    }

    private var shouldSendCodeFromPrimaryButton: Bool {
        switch entitlementStatus {
        case .entitled, .checking:
            return false
        case .missingEmail, .needsVerification, .notEntitled, .failed:
            return true
        }
    }

    private func primaryAccessButtonAction() {
        if shouldSendCodeFromPrimaryButton {
            onRequestAccessCode()
        } else {
            onRefreshEntitlement()
        }
    }

    private var showsVerificationCodeEntry: Bool {
        didSendVerificationCode || needsVerification
    }

    private var needsVerification: Bool {
        if case .needsVerification = entitlementStatus {
            return true
        }
        return false
    }

    private var canVerifyCode: Bool {
        verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).count == 6
            && !isAuthWorking
    }

    private var verificationCodeDetail: String {
        if didSendVerificationCode {
            return "We sent a 6-digit code to \(normalizedSubscriberEmail). Enter it here to finish setup."
        }
        return "Send a code to \(normalizedSubscriberEmail), then enter it here to unlock Voce on this Mac."
    }

    private var statusPresentation: (title: String, detail: String, badge: String?, icon: String, tint: Color) {
        switch entitlementStatus {
        case .missingEmail:
            return (
                "Start with your email",
                "We will find Pro access or start your free monthly dictation time.",
                nil,
                "person.crop.circle",
                VoceDesign.warmAccentText
            )
        case .needsVerification:
            return (
                "Verify your email",
                "Send yourself a code to unlock Voce on this Mac.",
                nil,
                "envelope.badge",
                VoceDesign.warmAccentText
            )
        case .checking:
            return (
                "Checking access",
                "Looking for Pro or free monthly time.",
                nil,
                "arrow.triangle.2.circlepath",
                VoceDesign.textSecondary
            )
        case .entitled(let entitlement):
            switch entitlement.source {
            case .manual:
                return (
                    "Voce Pro is on us",
                    "Unlimited dictation and AI polish are ready for you.",
                    "Pro",
                    "heart.fill",
                    VoceDesign.warmAccentText
                )
            case .stripe:
                return (
                    "Voce Pro is active",
                    "Unlimited dictation and AI polish are ready to go.",
                    "Subscribed",
                    "sparkles",
                    VoceDesign.warmAccentText
                )
            case .free:
                let remaining = entitlement.freeRemainingMinutesText ?? "Free time"
                return (
                    "Free access is active",
                    "\(remaining) included this month so you can put Voce through its paces.",
                    "Free",
                    "timer",
                    VoceDesign.success
                )
            case nil:
                return (
                    "Voce is ready",
                    "Your access is active on this Mac.",
                    nil,
                    "checkmark.seal",
                    VoceDesign.success
                )
            }
        case .notEntitled:
            return (
                "Your free time is used",
                "Upgrade to keep dictating with unlimited time and AI polish.",
                nil,
                "sparkles",
                VoceDesign.warmAccentText
            )
        case .failed(_, let message):
            return (
                "Access check needs another try",
                message,
                nil,
                "exclamationmark.triangle",
                VoceDesign.error
            )
        }
    }
}
