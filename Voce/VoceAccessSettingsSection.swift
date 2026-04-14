import SwiftUI

struct VoceAccessSettingsSection: View {
    @Binding var preferences: AppPreferences
    let entitlementStatus: VoceProEntitlementStatus
    let onRefreshEntitlement: () -> Void
    let onSubscribe: () -> Void
    let onManageSubscription: () -> Void

    var body: some View {
        settingsCard("Access") {
            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                settingInlineLabel(
                    "Email",
                    help: "Used to check your subscription, free access, or monthly free usage."
                )

                HStack(alignment: .center, spacing: VoceDesign.sm) {
                    TextField("email@example.com", text: $preferences.billing.subscriberEmail)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()

                    Button(entitlementStatus.isChecking ? "Checking" : "Check") {
                        onRefreshEntitlement()
                    }
                    .buttonStyle(.bordered)
                    .disabled(normalizedSubscriberEmail.isEmpty || entitlementStatus.isChecking)

                    Button("Subscribe") {
                        onSubscribe()
                    }
                    .buttonStyle(.borderedProminent)

                    if isStripeSubscriber {
                        Button("Manage") {
                            onManageSubscription()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack(spacing: VoceDesign.xs) {
                    Image(systemName: entitlementStatusIconName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(entitlementStatus.message)
                        .font(VoceDesign.caption())
                }
                .foregroundStyle(entitlementStatusColor)
            }
        }
    }

    private var normalizedSubscriberEmail: String {
        preferences.billing.subscriberEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isStripeSubscriber: Bool {
        guard case .entitled(let entitlement) = entitlementStatus else {
            return false
        }
        return entitlement.source == .stripe
    }

    private var entitlementStatusIconName: String {
        switch entitlementStatus {
        case .entitled:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .missingEmail, .notEntitled:
            return "info.circle.fill"
        }
    }

    private var entitlementStatusColor: Color {
        switch entitlementStatus {
        case .entitled:
            return VoceDesign.accent
        case .failed:
            return VoceDesign.error
        case .missingEmail, .checking, .notEntitled:
            return VoceDesign.textSecondary
        }
    }
}
