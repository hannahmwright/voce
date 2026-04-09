import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentStep: OnboardingStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            progressBar
                .padding(.horizontal, VoceDesign.lg)
                .padding(.top, VoceDesign.lg)

            // Step content
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .modelSetup:
                    modelSetupStep
                case .featureTour:
                    featureTourStep
                }
            }
            .id(currentStep)
            .transition(stepTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, VoceDesign.xl)

            // Navigation bar
            navigationBar
                .padding(.horizontal, VoceDesign.lg)
                .padding(.bottom, VoceDesign.lg)
        }
        .frame(
            minWidth: VoceDesign.windowMinWidth,
            idealWidth: VoceDesign.windowIdealWidth,
            minHeight: VoceDesign.windowMinHeight,
            idealHeight: VoceDesign.windowIdealHeight
        )
        .background {
            VoceWindowBackdrop()
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0),
            value: currentStep
        )
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: VoceDesign.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                RoundedRectangle(cornerRadius: VoceDesign.radiusTiny)
                    .fill(step.rawValue <= currentStep.rawValue ? VoceDesign.accent : VoceDesign.border)
                    .frame(height: VoceDesign.xs)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                        value: currentStep
                    )
            }
        }
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    // MARK: - Step Transition

    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: VoceDesign.xl) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 72))
                .foregroundStyle(VoceDesign.accentGradient)
                .accessibilityHidden(true)

            VStack(spacing: VoceDesign.sm) {
                Text("Welcome to Voce")
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Private dictation that types into your active app")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                featureRow(icon: "lock.shield", title: "Private by default", detail: "Audio and transcript cleanup stay on your Mac.")
                featureRow(icon: "bolt", title: "Fast", detail: "Apple preview appears immediately and Apple Speech handles the final transcript.")
                featureRow(icon: "text.cursor", title: "Works across apps", detail: "Types or pastes into editors, terminals, and most text fields.")
            }
            .cardStyle()

            Spacer()
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: VoceDesign.md) {
            Image(systemName: icon)
                .font(.system(size: VoceDesign.iconLG))
                .foregroundStyle(VoceDesign.accent)
                .frame(width: VoceDesign.xl)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(title)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)
                Text(detail)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: VoceDesign.lg) {
            Spacer()

            VStack(spacing: VoceDesign.sm) {
                Text("Permissions")
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Voce needs a few permissions to work properly.")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(spacing: VoceDesign.sm) {
                PermissionStatusCard(
                    title: "Microphone",
                    description: "Required to capture audio for transcription.",
                    status: controller.microphonePermissionStatus,
                    onRequest: { controller.requestMicrophonePermission() },
                    onOpenSettings: { controller.openMicrophoneSettings() }
                )

                PermissionStatusCard(
                    title: "Accessibility",
                    description: "Lets Voce type or paste into the app you're using.",
                    status: controller.accessibilityPermissionStatus,
                    onRequest: { controller.requestAccessibilityPermission() },
                    onOpenSettings: { controller.openAccessibilitySettings() }
                )

                PermissionStatusCard(
                    title: "Input Monitoring",
                    description: "Lets Voce detect global hotkeys while other apps are focused.",
                    status: controller.inputMonitoringPermissionStatus,
                    onRequest: { controller.requestInputMonitoringPermission() },
                    onOpenSettings: { controller.openInputMonitoringSettings() }
                )
            }

            if controller.microphonePermissionStatus != .granted {
                Text("Microphone access is required to continue.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.warning)
            }

            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissionStatuses()
        }
    }

    // MARK: - Step 3: Model Setup

    private var modelSetupStep: some View {
        VStack(spacing: VoceDesign.lg) {
            Spacer()

            VStack(spacing: VoceDesign.sm) {
                Text("Apple Speech")
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Voce now targets newer macOS releases and uses Apple's speech stack for final transcription.")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Locale")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                    TextField("en-US", text: localeBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("What changed")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                    Text("Voce no longer downloads a local transcription model. Apple live preview stays instant, and Apple Speech now produces the final transcript too.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textPrimary)
                    Text("Use a BCP-47 locale like `en-US` or `en-GB` if you want to override the default transcription locale.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .padding(VoceDesign.md)
                .glassBackground(cornerRadius: VoceDesign.radiusMedium)
            }
            .cardStyle()

            Spacer()
        }
    }

    private var localeBinding: Binding<String> {
        Binding(
            get: { controller.preferences.dictation.localeIdentifier },
            set: { controller.preferences.dictation.localeIdentifier = $0 }
        )
    }

    // MARK: - Step 4: Feature Tour

    private var featureTourStep: some View {
        VStack(spacing: VoceDesign.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(VoceDesign.success)
                .accessibilityHidden(true)

            VStack(spacing: VoceDesign.sm) {
                Text("You're all set!")
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Here are a few tips to get started.")
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                tipRow(number: "1", text: "Hold \(controller.preferences.hotkeys.pressToTalkHotkey.displayName) to dictate (press-to-talk)")
                tipRow(number: "2", text: handsFreeTipText)
                tipRow(number: "3", text: "Check the History tab for past transcripts")
            }
            .cardStyle()

            Spacer()
        }
    }

    private func tipRow(number: String, text: String) -> some View {
        HStack(spacing: VoceDesign.md) {
            Text(number)
                .font(VoceDesign.bodyEmphasis())
                .foregroundStyle(.white)
                .frame(width: VoceDesign.xl, height: VoceDesign.xl)
                .background(VoceDesign.accentGradient)
                .clipShape(Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(VoceDesign.body())
                .foregroundStyle(VoceDesign.textPrimary)
        }
    }

    private var handsFreeTipText: String {
        if let hotkey = controller.preferences.hotkeys.handsFreeGlobalHotkey {
            return "Press \(hotkeyDisplayName(for: hotkey)) to toggle hands-free mode"
        }

        return "Set a hands-free key in Settings when you're ready"
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    goBack()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Go to previous step")
            }

            Spacer()

            if currentStep != .welcome && currentStep != .featureTour && canSkip {
                Button("Skip") {
                    goForward()
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.textSecondary)
                .accessibilityLabel("Skip this step")
            }

            if currentStep == .featureTour {
                Button("Get Started") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .tint(VoceDesign.accent)
                .accessibilityLabel("Finish onboarding and start using Voce")
            } else {
                Button("Continue") {
                    goForward()
                }
                .buttonStyle(.borderedProminent)
                .tint(VoceDesign.accent)
                .disabled(!canContinue)
                .accessibilityLabel("Continue to next step")
            }
        }
    }

    // MARK: - Navigation Logic

    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .permissions:
            return controller.microphonePermissionStatus == .granted
        case .modelSetup:
            return !controller.preferences.dictation.localeIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        case .featureTour:
            return true
        }
    }

    private var canSkip: Bool {
        switch currentStep {
        case .welcome, .featureTour:
            return false
        case .permissions, .modelSetup:
            return true
        }
    }

    private func goForward() {
        guard let nextIndex = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextIndex
    }

    private func goBack() {
        guard let prevIndex = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevIndex
    }

    private func completeOnboarding() {
        controller.completeOnboarding()
    }
}

// MARK: - Onboarding Step Enum

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case modelSetup = 2
    case featureTour = 3
}
