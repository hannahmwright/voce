import AppKit
import SwiftUI
import VoceKit

struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var practicePadFocused: Bool
    @FocusState private var typingTestFocused: Bool

    @State private var currentStep: OnboardingStep = .welcome
    @State private var navigationDirection: NavigationDirection = .forward
    @State private var onboardingPreferences: AppPreferences = .default
    @State private var walkthroughPracticeStep: GuidedWalkthroughStep = .tapToRecord
    @State private var typingTestText: String = ""
    @State private var typingTestStartedAt: Date?
    @State private var typingTestCompletedAt: Date?
    @State private var typingTestMeasuredWPM: Double = 0
    @State private var typingTestNow = Date()
    @State private var practiceText: String = ""
    @State private var practiceCompletedModes: Set<OnboardingPracticeMode> = []
    @State private var activePracticeMode: OnboardingPracticeMode?
    @State private var pendingPracticeMode: OnboardingPracticeMode?
    @State private var practiceStartCharacterCount: Int = 0
    @State private var accessEmailDraft = ""
    @State private var accessVerificationCodeDraft = ""
    @State private var accessVerificationCodeWasSent = false
    @State private var accessAuthIsWorking = false
    @State private var accessAuthError = ""
    @State private var lastPracticeTranscriptApplied = ""
    @State private var walkthroughShortcutMonitor: Any?

    private let onboardingModeColumnWidth: CGFloat = 214
    private let onboardingRecorderColumnWidth: CGFloat = 236
    private let onboardingReadyCardWidth: CGFloat = 560
    private static let typingSpeedPrompt = "Voce helps me write faster by turning clear speech into polished text anywhere on my Mac."

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, VoceDesign.lg)
                .padding(.top, VoceDesign.xxl + VoceDesign.xs)

            ScrollView(showsIndicators: false) {
                VStack(spacing: VoceDesign.md) {
                    Group {
                        switch currentStep {
                        case .welcome:
                            welcomeStep
                        case .typingSpeed:
                            typingSpeedStep
                        case .access:
                            accessStep
                        case .permissions:
                            permissionsStep
                        case .ready:
                            readyStep
                        case .walkthrough:
                            walkthroughStep
                        case .practice:
                            practiceStep
                        }
                    }
                    .id(currentStep)
                    .transition(stepTransition)
                    .frame(maxWidth: .infinity)

                    navigationBar
                        .padding(.top, VoceDesign.xs)
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, VoceDesign.xl)
                .padding(.top, VoceDesign.xl)
                .padding(.bottom, VoceDesign.lg)
            }
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
        .toggleStyle(.switch)
        .onAppear {
            controller.refreshPermissionStatuses()
            onboardingPreferences = controller.preferences
            onboardingPreferences.hotkeys.optionPressToTalkEnabled = false
            if onboardingPreferences.hotkeys.handsFreeGlobalHotkey == nil {
                onboardingPreferences.hotkeys.handsFreeGlobalHotkey = .init(hotkey: .keyCode(79))
            }
            normalizeOnboardingHotkeys()
            accessEmailDraft = onboardingPreferences.billing.subscriberEmail
            syncPracticeState()
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == .walkthrough || newStep == .practice {
                syncPracticeState()
                controller.applySettingsDraft(preferences: onboardingPreferences, announceImmediateSave: false)
                focusPracticePadSoon()
            } else if newStep == .typingSpeed {
                focusTypingTestSoon()
            }
        }
        .onChange(of: typingTestText) { _, newValue in
            handleTypingTestChange(newValue)
        }
        .onChange(of: controller.isRecording) { _, isRecording in
            guard currentStep == .walkthrough || currentStep == .practice else { return }

            if isRecording {
                pendingPracticeMode = nil
                activePracticeMode = controller.handsFreeOn ? .tapToTalk : .holdToTalk
                practiceStartCharacterCount = practiceText.count
            } else if let activePracticeMode {
                pendingPracticeMode = activePracticeMode
                self.activePracticeMode = nil
            }
        }
        .onChange(of: practiceText) { _, newValue in
            guard currentStep == .walkthrough || currentStep == .practice else { return }
            guard let pendingPracticeMode else { return }
            guard newValue.count > practiceStartCharacterCount else { return }
            guard enabledPracticeModes.contains(pendingPracticeMode) else { return }

            practiceCompletedModes.insert(pendingPracticeMode)
            self.pendingPracticeMode = nil
        }
        .onChange(of: walkthroughPracticeStep) { _, step in
            guard currentStep == .walkthrough else { return }
            practiceText = walkthroughSeedText(for: step)
            lastPracticeTranscriptApplied = ""
            pendingPracticeMode = nil
            practiceStartCharacterCount = 0
            focusPracticePadSoon()
        }
        .onChange(of: controller.status) { _, newStatus in
            guard currentStep == .walkthrough || currentStep == .practice else { return }
            guard newStatus.localizedCaseInsensitiveContains("copied to clipboard")
                || newStatus.localizedCaseInsensitiveContains("click the input again.") else { return }

            let transcript = controller.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, transcript != lastPracticeTranscriptApplied else { return }

            appendTranscriptToPracticePad(transcript)
        }
        .onChange(of: controller.lastTranscript) { _, newTranscript in
            guard currentStep == .walkthrough || currentStep == .practice else { return }
            guard !controller.isRecording else { return }

            let transcript = newTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, transcript != lastPracticeTranscriptApplied else { return }

            appendTranscriptToPracticePad(transcript)
        }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { now in
            guard currentStep == .typingSpeed else { return }
            typingTestNow = now
        }
        .onAppear {
            installWalkthroughShortcutMonitorIfNeeded()
        }
        .onDisappear {
            removeWalkthroughShortcutMonitor()
        }
    }

    private var progressBar: some View {
        let currentVisibleIndex = OnboardingStep.visibleCases.firstIndex(of: currentStep) ?? 0

        return HStack(spacing: VoceDesign.xs) {
            ForEach(Array(OnboardingStep.visibleCases.enumerated()), id: \.element) { index, step in
                RoundedRectangle(cornerRadius: VoceDesign.radiusTiny)
                    .fill(index <= currentVisibleIndex ? VoceDesign.warmAccentText : VoceDesign.border)
                    .frame(height: VoceDesign.xs)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                        value: currentStep
                    )
            }
        }
        .accessibilityLabel("Step \(OnboardingStep.visibleCases.firstIndex(of: currentStep).map { $0 + 1 } ?? 1) of \(OnboardingStep.visibleCases.count)")
    }

    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }

        let insertionEdge: Edge = navigationDirection == .forward ? .trailing : .leading
        let removalEdge: Edge = navigationDirection == .forward ? .leading : .trailing

        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    private var welcomeStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: "mic.fill",
                title: "Welcome to Voce",
                subtitle: "Type at the speed of voice."
            )

            HStack(spacing: VoceDesign.md) {
                welcomeHighlight(
                    icon: "lock.shield.fill",
                    title: "Private",
                    detail: "On your Mac"
                )
                welcomeHighlight(
                    icon: "bolt.fill",
                    title: "Fast",
                    detail: "Ready right away"
                )
                welcomeHighlight(
                    icon: "text.cursor",
                    title: "Across apps",
                    detail: "Types where you work"
                )
            }
            .cardStyle()
            .frame(maxWidth: 860)
        }
    }

    private var typingSpeedStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: "keyboard",
                title: "Test your typing speed",
                subtitle: "This gives Voce a baseline for time saved."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                TypingSpeedTestView(
                    bestWordsPerMinute: $onboardingPreferences.metricsBestTypingWordsPerMinute,
                    measuredWordsPerMinute: $typingTestMeasuredWPM,
                    autofocus: true
                ) { _ in
                    controller.savePreferencesQuietly(preferences: onboardingPreferences)
                }
            }
            .frame(maxWidth: 640)
            .cardStyle()
        }
    }

    private var accessStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: accessReady ? "checkmark.seal.fill" : "person.badge.key.fill",
                title: accessReady ? "Access is ready" : (accessVerificationCodeWasSent ? "Check your email" : "Set up access"),
                subtitle: accessReady
                    ? "Voce is unlocked on this Mac."
                    : (accessVerificationCodeWasSent
                       ? "Enter the 6-digit code sent to \(normalizedAccessEmail)."
                       : "Voce uses your email to find Base or Pro access, or start your free monthly time.")
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                accessStatusRow

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Email")
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)

                    TextField("email@example.com", text: $accessEmailDraft)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                        .disabled(accessAuthIsWorking || accessReady)
                        .onSubmit {
                            if canSendAccessCode {
                                requestAccessCode()
                            }
                        }
                }

                if accessVerificationCodeWasSent || needsAccessVerification {
                    VStack(alignment: .leading, spacing: VoceDesign.xs) {
                        Text("Access code")
                            .font(VoceDesign.captionEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)

                        TextField("6-digit code", text: $accessVerificationCodeDraft)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()
                            .textContentType(.oneTimeCode)
                            .disabled(accessAuthIsWorking || accessReady)
                            .onChange(of: accessVerificationCodeDraft) { _, newValue in
                                let digits = newValue.filter(\.isNumber)
                                accessVerificationCodeDraft = String(digits.prefix(6))
                            }
                            .onSubmit {
                                if canVerifyAccessCode {
                                    verifyAccessCode()
                                }
                            }

                        Text("Codes expire after 10 minutes.")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }
                }

                if !accessAuthError.isEmpty {
                    Label(accessAuthError, systemImage: "exclamationmark.triangle.fill")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: VoceDesign.sm) {
                    if accessReady {
                        Label("Verified", systemImage: "checkmark.circle.fill")
                            .font(VoceDesign.captionEmphasis())
                            .foregroundStyle(VoceDesign.success)
                    } else if accessVerificationCodeWasSent || needsAccessVerification {
                        onboardingAccessButton(
                            accessAuthIsWorking ? "Verifying..." : "Verify",
                            systemImage: nil,
                            showsSpinner: accessAuthIsWorking,
                            isEnabled: canVerifyAccessCode,
                            isProminent: true,
                            action: verifyAccessCode
                        )

                        onboardingAccessButton(
                            accessAuthIsWorking ? "Sending..." : "Send a new code",
                            systemImage: "envelope",
                            showsSpinner: accessAuthIsWorking && !canVerifyAccessCode,
                            isEnabled: canSendAccessCode,
                            isProminent: false,
                            action: requestAccessCode
                        )
                    } else {
                        onboardingAccessButton(
                            accessAuthIsWorking ? "Sending..." : "Send code",
                            systemImage: "envelope",
                            showsSpinner: accessAuthIsWorking,
                            isEnabled: canSendAccessCode,
                            isProminent: true,
                            action: requestAccessCode
                        )
                    }

                    if canSubscribeFromAccess {
                        onboardingAccessButton(
                            "Choose Base",
                            systemImage: "mic.fill",
                            isEnabled: !normalizedAccessEmail.isEmpty,
                            isProminent: false,
                            action: {
                                controller.openVoceCheckout(plan: .base, billingCycle: .monthly)
                            }
                        )

                        onboardingAccessButton(
                            "Choose Pro",
                            systemImage: "sparkles",
                            isEnabled: !normalizedAccessEmail.isEmpty,
                            isProminent: true,
                            action: {
                                controller.openVoceCheckout(plan: .pro, billingCycle: .monthly)
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: 560)
            .cardStyle(padding: VoceDesign.lg)

            if !accessReady {
                Text("Verify your email to continue setup.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.warning)
            }
        }
    }

    private var accessStatusRow: some View {
        HStack(alignment: .top, spacing: VoceDesign.sm) {
            Image(systemName: accessStatusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accessStatusTint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accessStatusTint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(accessStatusTitle)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(controller.voceProEntitlementStatus.message)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(VoceDesign.sm)
        .background(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .fill(VoceDesign.surfaceSecondary.opacity(0.62))
        )
    }

    private func onboardingAccessButton(
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
            .background(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                    .fill(isProminent ? VoceDesign.warmAccentFill : VoceDesign.surfaceSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                isProminent ? VoceDesign.warmAccentText.opacity(0.12) : VoceDesign.border,
                                lineWidth: VoceDesign.borderThin
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : VoceDesign.opacityDisabled)
    }

    private func welcomeHighlight(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoceDesign.warmAccentText)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .fill(VoceDesign.warmAccentFill)
                )

            Text(title)
                .font(VoceDesign.bodyEmphasis())
                .foregroundStyle(VoceDesign.textPrimary)

            Text(detail)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.44))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var permissionsStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: "hand.raised.fill",
                title: "Turn on access",
                subtitle: "A few quick permissions."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                permissionSectionTitle("Start here")

                PermissionStatusCard(
                    title: "Microphone",
                    description: "Lets Voce hear you.",
                    status: controller.microphonePermissionStatus,
                    onRequest: { controller.requestMicrophonePermission() },
                    onOpenSettings: { controller.openMicrophoneSettings() },
                    appearance: .onboarding
                )

                PermissionStatusCard(
                    title: "Speech",
                    description: "Lets Apple Speech transcribe while you record.",
                    status: controller.speechRecognitionPermissionStatus,
                    onRequest: { controller.requestSpeechRecognitionPermission() },
                    onOpenSettings: { controller.openSpeechRecognitionSettings() },
                    appearance: .onboarding
                )

                permissionSectionTitle("For typing and hot keys")

                PermissionStatusCard(
                    title: "Accessibility",
                    description: "Lets Voce type into other apps.",
                    status: controller.accessibilityPermissionStatus,
                    onRequest: { controller.requestAccessibilityPermission() },
                    onOpenSettings: { controller.openAccessibilitySettings() },
                    appearance: .onboarding
                )

                PermissionStatusCard(
                    title: "Input Monitoring",
                    description: "Lets Voce detect shortcuts while other apps are focused.",
                    status: controller.inputMonitoringPermissionStatus,
                    onRequest: { controller.requestInputMonitoringPermission() },
                    onOpenSettings: { controller.openInputMonitoringSettings() },
                    appearance: .onboarding
                )
            }
            .frame(maxWidth: 860)
            .cardStyle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissionStatuses()
        }
    }

    private func permissionSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.labelEmphasis())
            .foregroundStyle(VoceDesign.textSecondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private var readyStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: "keyboard.fill",
                title: "Ready to talk",
                subtitle: "Choose your hot keys."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                onboardingReadyModeRow(
                    toggle: {
                        Toggle(isOn: onboardingHoldToTalkBinding) {
                            settingInlineLabel(
                                "Hold to talk",
                                glyphStyle: .holdKey,
                                help: "Hold one or more modifier keys together to dictate, then release to stop."
                            )
                        }
                        .frame(width: onboardingModeColumnWidth, alignment: .leading)
                        .disabled(!onboardingTapToTalkEnabled)
                    },
                    recorder: {
                        PressToTalkHotkeyRecorderField(hotkey: onboardingPressToTalkBinding)
                            .frame(width: onboardingRecorderColumnWidth, alignment: .leading)
                            .disabled(!onboardingPreferences.hotkeys.optionPressToTalkEnabled)
                            .opacity(onboardingPreferences.hotkeys.optionPressToTalkEnabled ? 1 : 0.45)
                    }
                )

                onboardingReadyModeRow(
                    toggle: {
                        Toggle(isOn: onboardingTapToTalkBinding) {
                            settingInlineLabel(
                                "Tap to talk",
                                glyphStyle: .tapKey,
                                help: "Tap once to start or stop. For modifier keys, tap twice quickly to save an x2 toggle."
                            )
                        }
                        .frame(width: onboardingModeColumnWidth, alignment: .leading)
                        .disabled(!onboardingPreferences.hotkeys.optionPressToTalkEnabled)
                    },
                    recorder: {
                        HandsFreeToggleHotkeyRecorderField(hotkey: onboardingHandsFreeKeyBinding)
                            .frame(width: onboardingRecorderColumnWidth, alignment: .leading)
                            .disabled(!onboardingTapToTalkEnabled)
                            .opacity(onboardingTapToTalkEnabled ? 1 : 0.45)
                    }
                )

                onboardingReadyModeRow(
                    toggle: {
                        Toggle(isOn: $onboardingPreferences.hotkeys.voceActionsTapEnabled) {
                            settingInlineLabel(
                                "Voce actions",
                                systemImage: "command",
                                help: "Highlight text in any app, then tap Command+Option together. Voce asks whether to save the selection as a dictionary fix or a spoken snippet."
                            )
                        }
                        .frame(width: onboardingModeColumnWidth, alignment: .leading)
                    },
                    recorder: {
                        VoceActionsTapBadge(
                            isEnabled: onboardingPreferences.hotkeys.voceActionsTapEnabled
                        )
                        .frame(width: onboardingRecorderColumnWidth, alignment: .leading)
                    }
                )
            }
            .frame(maxWidth: onboardingReadyCardWidth)
            .padding(.horizontal, VoceDesign.sm)
            .padding(.vertical, VoceDesign.md)
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .fill(VoceDesign.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                            .fill(.regularMaterial.opacity(0.35))
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .stroke(Color.white.opacity(0.50), lineWidth: VoceDesign.borderThin)
            )
            .shadowStyle(.md)
        }
    }

    private var practiceStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: "square.and.pencil",
                title: "Try it out",
                subtitle: "Use your hot keys in the scratch pad."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                if !accessReady {
                    practiceAccessCallout
                }
                practiceLeadCard
                practiceProgressRow
                practicePadCard
            }
            .frame(maxWidth: 620)
            .cardStyle()
        }
    }

    private var walkthroughStep: some View {
        VStack(spacing: VoceDesign.xl) {
            onboardingHero(
                icon: "rectangle.and.hand.point.up.left.fill",
                title: "Learn the basics",
                subtitle: "Learn it and test it in the same place."
            )

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                if !accessReady {
                    practiceAccessCallout
                }

                GuidedWalkthroughView(
                    holdHotkeyLabel: onboardingHoldToTalkLabel,
                    tapHotkeyLabel: onboardingTapToTalkLabel,
                    dictionaryHotkeyLabel: keyboardShortcutDisplayName(for: onboardingPreferences.hotkeys.dictionaryCorrectionHotkey),
                    isRecording: controller.isRecording,
                    activeRecordingStep: activePracticeMode.map {
                        switch $0 {
                        case .holdToTalk:
                            return .holdToRecord
                        case .tapToTalk:
                            return .tapToRecord
                        }
                    },
                    availableSteps: availableWalkthroughSteps,
                    selectedStep: $walkthroughPracticeStep
                )
                practicePadCard
            }
            .frame(maxWidth: 760)
            .cardStyle()
        }
    }

    private func onboardingReadyModeRow<ToggleContent: View, RecorderContent: View>(
        @ViewBuilder toggle: () -> ToggleContent,
        @ViewBuilder recorder: () -> RecorderContent
    ) -> some View {
        HStack(alignment: .top, spacing: VoceDesign.md) {
            toggle()
            recorder()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoceDesign.sm + VoceDesign.xxs)
        .padding(.vertical, VoceDesign.sm)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.44))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var practiceLeadCard: some View {
        let mode = currentPracticeTarget

        return HStack(alignment: .center, spacing: VoceDesign.md) {
            ZStack {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                    .fill(VoceDesign.warmAccentFill)
                    .frame(width: 42, height: 42)

                Image(systemName: mode?.systemImage ?? "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VoceDesign.warmAccentText)
            }

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(mode == nil ? "You’re ready." : "Try this now")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.3)

                if let mode {
                    HStack(spacing: VoceDesign.sm) {
                        Text(mode.practicePrompt(hotkeyLabel: practiceHotkeyLabel(for: mode)))
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)

                        keyboardKeyCap(practiceHotkeyLabel(for: mode))
                    }
                } else {
                    Text("Both hot keys are working.")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.warmAccentFill.opacity(0.46))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.warmAccentText.opacity(0.12), lineWidth: VoceDesign.borderThin)
        )
    }

    private var practiceAccessCallout: some View {
        HStack(alignment: .top, spacing: VoceDesign.md) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VoceDesign.warmAccentText)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoceDesign.warmAccentFill)
                )

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text("Finish access setup first")
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(controller.voceProEntitlementStatus.message)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(VoceDesign.md)
        .background(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.warmAccentFill.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.warmAccentText.opacity(0.14), lineWidth: VoceDesign.borderThin)
        )
    }

    private var practiceProgressRow: some View {
        HStack(spacing: VoceDesign.sm) {
            ForEach(enabledPracticeModes, id: \.self) { mode in
                practiceModePill(mode)
            }
        }
    }

    private func practiceModePill(_ mode: OnboardingPracticeMode) -> some View {
        let isComplete = practiceCompletedModes.contains(mode)
        let isCurrent = currentPracticeTarget == mode
        let isActive = activePracticeMode == mode || pendingPracticeMode == mode

        return HStack(spacing: VoceDesign.xs) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : mode.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isComplete
                        ? VoceDesign.success
                        : (isCurrent || isActive ? VoceDesign.warmAccentText : VoceDesign.textSecondary)
                )

            Text(mode.title)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.textPrimary)
        }
        .padding(.horizontal, VoceDesign.md)
        .padding(.vertical, VoceDesign.sm)
        .background {
            Capsule()
                .fill(
                    isComplete
                        ? VoceDesign.success.opacity(0.12)
                        : ((isCurrent || isActive) ? VoceDesign.warmAccentFill.opacity(0.58) : VoceDesign.surface.opacity(0.48))
                )
        }
        .overlay(
            Capsule()
                .stroke(
                    isComplete
                        ? VoceDesign.success.opacity(0.24)
                        : ((isCurrent || isActive) ? VoceDesign.warmAccentText.opacity(0.12) : VoceDesign.border),
                    lineWidth: VoceDesign.borderThin
                )
        )
    }

    private var practicePadCard: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                    Text(currentStep == .walkthrough ? walkthroughScratchPadTitle : "Scratch pad")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text(currentStep == .walkthrough ? walkthroughScratchPadSubtitle : "Your words land here.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer(minLength: 0)

                practicePadStatus
            }

            practicePad
        }
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.44))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var practicePadStatus: some View {
        Text(practicePadStatusText)
            .font(VoceDesign.captionEmphasis())
            .foregroundStyle(practicePadStatusTextColor)
            .padding(.horizontal, VoceDesign.sm)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(practicePadStatusFill)
            }
    }

    private var practicePad: some View {
        TextEditor(text: $practiceText)
            .focused($practicePadFocused)
            .font(VoceDesign.body())
            .foregroundStyle(VoceDesign.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(VoceDesign.md)
            .frame(minHeight: 180, maxHeight: 220)
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                    .fill(VoceDesign.surfaceSecondary.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.16))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                    .stroke(
                        practicePadFocused ? VoceDesign.warmAccentText.opacity(0.22) : Color.white.opacity(0.38),
                        lineWidth: practicePadFocused ? 1.2 : VoceDesign.borderThin
                    )
            )
            .overlay(alignment: .topLeading) {
                if practiceText.isEmpty {
                    Text(currentStep == .walkthrough ? walkthroughScratchPadPlaceholder : "Click here, then try speaking...")
                        .font(VoceDesign.body())
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.7))
                        .padding(.horizontal, VoceDesign.lg)
                        .padding(.top, VoceDesign.md + 2)
                        .allowsHitTesting(false)
                }
            }
    }

    private func onboardingHero(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: VoceDesign.lg) {
            ZStack {
                Circle()
                    .fill(VoceDesign.warmAccentFill)
                    .frame(width: 88, height: 88)

                Image(systemName: icon)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(VoceDesign.warmAccentText)
            }
            .accessibilityHidden(true)

            VStack(spacing: VoceDesign.xs) {
                Text(title)
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text(subtitle)
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: VoceDesign.sm) {
            if currentStep != .welcome {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VoceDesign.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(VoceDesign.surface.opacity(0.42))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to previous step")
            }

            Spacer()

            if let skipLabel = skipButtonLabel, !canContinue {
                Button {
                    performSkip()
                } label: {
                    Text(skipLabel)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.horizontal, VoceDesign.lg)
                        .padding(.vertical, VoceDesign.sm)
                        .background(
                            Capsule()
                                .fill(VoceDesign.surface.opacity(0.55))
                        )
                        .overlay(
                            Capsule()
                                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(skipAccessibilityLabel ?? skipLabel)
            }

            if canContinue {
                Button {
                    if currentStep == .practice {
                        completeOnboarding()
                    } else {
                        goForward()
                    }
                } label: {
                    Text(currentStep == .practice ? "Start using Voce" : "Continue")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .padding(.horizontal, VoceDesign.xl)
                        .padding(.vertical, VoceDesign.sm)
                        .background(
                            Capsule()
                                .fill(VoceDesign.warmAccentFill)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(currentStep == .practice ? "Finish onboarding and start using Voce" : "Continue to next step")
            } else if skipButtonLabel == nil, let message = continueBlockedMessage {
                HStack(spacing: VoceDesign.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoceDesign.warning)

                    Text(message)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, VoceDesign.lg)
                .padding(.vertical, VoceDesign.sm)
                .background {
                    Capsule()
                        .fill(VoceDesign.contentBackground)
                        .overlay {
                            Capsule()
                                .fill(VoceDesign.warning.opacity(0.42))
                        }
                }
                .overlay(
                    Capsule()
                        .stroke(VoceDesign.warning, lineWidth: 1.4)
                )
                .accessibilityLabel(message)
            }
        }
    }

    private var skipButtonLabel: String? {
        switch currentStep {
        case .welcome, .permissions, .ready, .access:
            return nil
        case .typingSpeed:
            return "Skip"
        case .walkthrough:
            return "Skip lesson"
        case .practice:
            return "Skip test"
        }
    }

    private var skipAccessibilityLabel: String? {
        switch currentStep {
        case .typingSpeed:
            return "Skip the typing speed test"
        case .walkthrough:
            return "Skip the guided walkthrough lesson"
        case .practice:
            return "Skip the practice test and finish onboarding"
        case .welcome, .permissions, .ready, .access:
            return nil
        }
    }

    private func performSkip() {
        switch currentStep {
        case .practice:
            completeOnboarding()
        default:
            goForward()
        }
    }

    private var continueBlockedMessage: String? {
        switch currentStep {
        case .welcome, .ready:
            return nil
        case .typingSpeed:
            return "Type the prompt to measure your speed."
        case .access:
            return "Verify your email to continue."
        case .permissions:
            return "Allow Microphone and Speech to continue."
        case .walkthrough:
            return "Try the lesson to continue."
        case .practice:
            return "Practice both modes to finish."
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .typingSpeed:
            return typingTestHasResult
        case .access:
            return accessReady
        case .permissions:
            return permissionsReady
        case .ready:
            return true
        case .walkthrough:
            return currentWalkthroughLessonComplete
        case .practice:
            return practiceReady
        }
    }

    private var currentWalkthroughLessonComplete: Bool {
        switch walkthroughPracticeStep {
        case .tapToRecord:
            return practiceCompletedModes.contains(.tapToTalk)
        case .holdToRecord:
            return practiceCompletedModes.contains(.holdToTalk)
        case .dictionaryFix:
            return practiceText.localizedCaseInsensitiveContains("codex")
                && !practiceText.localizedCaseInsensitiveContains("kodex")
        }
    }

    private var practiceReady: Bool {
        accessReady && Set(enabledPracticeModes).isSubset(of: practiceCompletedModes)
    }

    private var typingTestHasResult: Bool {
        typingTestMeasuredWPM > 0
    }

    private var typingTestElapsedSeconds: Double {
        guard let startedAt = typingTestStartedAt else { return 0 }
        let end = typingTestCompletedAt ?? typingTestNow
        return max(0, end.timeIntervalSince(startedAt))
    }

    private var typingTestLiveWPM: Double {
        typingWordsPerMinute(characterCount: typingTestText.count, elapsedSeconds: typingTestElapsedSeconds)
    }

    private var typingTestProgress: Double {
        guard !Self.typingSpeedPrompt.isEmpty else { return 0 }
        return min(1, Double(typingTestText.count) / Double(Self.typingSpeedPrompt.count))
    }

    private var typingTestAccuracy: Double {
        guard !typingTestText.isEmpty else { return 1 }
        let typed = Array(typingTestText)
        let prompt = Array(Self.typingSpeedPrompt)
        let matching = typed.enumerated().reduce(0) { total, pair in
            let (index, character) = pair
            guard index < prompt.count, prompt[index] == character else { return total }
            return total + 1
        }
        return Double(matching) / Double(typed.count)
    }

    private var typingTestStatusText: String {
        if typingTestHasResult {
            return "\(formattedTypingWPM(typingTestMeasuredWPM)) WPM saved"
        }
        if typingTestStartedAt != nil {
            return "\(formattedTypingWPM(typingTestLiveWPM)) WPM"
        }
        return "Starts on first key"
    }

    private var typingTestStatusColor: Color {
        if typingTestHasResult {
            return VoceDesign.success
        }
        if typingTestStartedAt != nil {
            return VoceDesign.warmAccentText
        }
        return VoceDesign.textSecondary
    }

    private var typingSpeedStatsRow: some View {
        HStack(spacing: VoceDesign.sm) {
            typingSpeedStat(
                title: "Speed",
                value: formattedTypingWPM(typingTestHasResult ? typingTestMeasuredWPM : typingTestLiveWPM),
                unit: "WPM"
            )

            typingSpeedStat(
                title: "Accuracy",
                value: "\(Int((typingTestAccuracy * 100).rounded()))",
                unit: "%"
            )

            typingSpeedStat(
                title: "Progress",
                value: "\(Int((typingTestProgress * 100).rounded()))",
                unit: "%"
            )
        }
    }

    private func typingSpeedStat(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xxs) {
            Text(title)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .monospacedDigit()
                Text(unit)
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.44))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var accessReady: Bool {
        controller.voceProEntitlementStatus.isEntitled
    }

    private var normalizedAccessEmail: String {
        accessEmailDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var normalizedAccessCode: String {
        accessVerificationCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSendAccessCode: Bool {
        !normalizedAccessEmail.isEmpty
            && !accessAuthIsWorking
            && !controller.voceProEntitlementStatus.isChecking
    }

    private var canVerifyAccessCode: Bool {
        normalizedAccessCode.count == 6
            && !normalizedAccessEmail.isEmpty
            && !accessAuthIsWorking
    }

    private var needsAccessVerification: Bool {
        if case .needsVerification = controller.voceProEntitlementStatus {
            return true
        }
        return false
    }

    private var canSubscribeFromAccess: Bool {
        if case .notEntitled = controller.voceProEntitlementStatus {
            return true
        }
        return false
    }

    private var accessStatusTitle: String {
        switch controller.voceProEntitlementStatus {
        case .entitled:
            return "Access verified"
        case .checking:
            return "Checking access"
        case .needsVerification:
            return "Verify your email"
        case .notEntitled:
            return "Free time is used"
        case .failed:
            return "Access check failed"
        case .missingEmail:
            return "Email required"
        }
    }

    private var accessStatusIcon: String {
        switch controller.voceProEntitlementStatus {
        case .entitled:
            return "checkmark.circle.fill"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .missingEmail, .needsVerification, .notEntitled:
            return "person.badge.key.fill"
        }
    }

    private var accessStatusTint: Color {
        switch controller.voceProEntitlementStatus {
        case .entitled:
            return VoceDesign.success
        case .failed:
            return VoceDesign.error
        case .missingEmail, .needsVerification, .checking, .notEntitled:
            return VoceDesign.warmAccentText
        }
    }

    private var enabledPracticeModes: [OnboardingPracticeMode] {
        var modes: [OnboardingPracticeMode] = []
        if onboardingPreferences.hotkeys.optionPressToTalkEnabled {
            modes.append(.holdToTalk)
        }
        if onboardingTapToTalkEnabled {
            modes.append(.tapToTalk)
        }
        return modes
    }

    private var currentPracticeTarget: OnboardingPracticeMode? {
        enabledPracticeModes.first { !practiceCompletedModes.contains($0) }
    }

    private var practicePadStatusText: String {
        switch controller.recordingLifecycleState {
        case .recordingPressToTalk, .recordingHandsFree:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .idle:
            if !accessReady {
                return "Access required"
            }
            return practiceReady ? "Done" : "Ready"
        }
    }

    private var practicePadStatusFill: Color {
        switch controller.recordingLifecycleState {
        case .recordingPressToTalk, .recordingHandsFree:
            return VoceDesign.warmAccentFill
        case .transcribing:
            return VoceDesign.surfaceSecondary
        case .idle:
            if !accessReady {
                return VoceDesign.warmAccentFill.opacity(0.34)
            }
            return practiceReady ? VoceDesign.success.opacity(0.12) : VoceDesign.surfaceSecondary
        }
    }

    private var practicePadStatusTextColor: Color {
        switch controller.recordingLifecycleState {
        case .recordingPressToTalk, .recordingHandsFree:
            return VoceDesign.warmAccentText
        case .transcribing:
            return VoceDesign.textSecondary
        case .idle:
            if !accessReady {
                return VoceDesign.warmAccentText
            }
            return practiceReady ? VoceDesign.success : VoceDesign.textSecondary
        }
    }

    private func practiceHotkeyLabel(for mode: OnboardingPracticeMode) -> String {
        switch mode {
        case .holdToTalk:
            return onboardingHoldToTalkLabel
        case .tapToTalk:
            return onboardingTapToTalkLabel
        }
    }

    private var onboardingHoldToTalkLabel: String {
        hotkeyDisplayName(for: onboardingPreferences.hotkeys.pressToTalkHotkey)
    }

    private var availableWalkthroughSteps: [GuidedWalkthroughStep] {
        var steps: [GuidedWalkthroughStep] = []
        if onboardingTapToTalkEnabled {
            steps.append(.tapToRecord)
        }
        if onboardingPreferences.hotkeys.optionPressToTalkEnabled {
            steps.append(.holdToRecord)
        }
        // The dictionary practice card relies on intercepting a bound
        // single-press shortcut to swap "Kodex" -> "Codex" inside the practice
        // pad. New installs ship with the legacy direct shortcut disabled
        // (Cmd+Option tap is the primary surface), so showing the lesson
        // would leave it permanently unfinishable. Only include it when the
        // shortcut is actually bound — upgraders see it, fresh users skip it.
        if onboardingPreferences.hotkeys.dictionaryCorrectionHotkey.isBound {
            steps.append(.dictionaryFix)
        }
        return steps
    }

    private var walkthroughScratchPadTitle: String {
        switch walkthroughPracticeStep {
        case .tapToRecord:
            return "Tap to talk"
        case .holdToRecord:
            return "Hold to talk"
        case .dictionaryFix:
            return "Dictionary quick fix"
        }
    }

    private var walkthroughScratchPadSubtitle: String {
        switch walkthroughPracticeStep {
        case .tapToRecord:
            return "Click here, then tap \(onboardingTapToTalkLabel) and say the line above."
        case .holdToRecord:
            return "Click here, then hold \(onboardingHoldToTalkLabel) while you say the line above."
        case .dictionaryFix:
            return "Highlight the wrong word here, then press \(keyboardShortcutDisplayName(for: onboardingPreferences.hotkeys.dictionaryCorrectionHotkey))."
        }
    }

    private var walkthroughScratchPadPlaceholder: String {
        switch walkthroughPracticeStep {
        case .tapToRecord:
            return "Click here, then tap \(onboardingTapToTalkLabel)..."
        case .holdToRecord:
            return "Click here, then hold \(onboardingHoldToTalkLabel)..."
        case .dictionaryFix:
            return "Highlight Kodex, then press the quick fix shortcut..."
        }
    }

    private func walkthroughSeedText(for step: GuidedWalkthroughStep) -> String {
        switch step {
        case .tapToRecord, .holdToRecord:
            return ""
        case .dictionaryFix:
            return "Please email Kodex the revised invoice today."
        }
    }

    private var onboardingTapToTalkLabel: String {
        if let hotkey = onboardingPreferences.hotkeys.handsFreeGlobalHotkey {
            return handsFreeToggleDisplayName(for: hotkey)
        }
        return "your key"
    }

    private func syncPracticeState() {
        let enabledModes = Set(enabledPracticeModes)
        practiceCompletedModes = practiceCompletedModes.intersection(enabledModes)

        if let activePracticeMode, !enabledModes.contains(activePracticeMode) {
            self.activePracticeMode = nil
        }
        if let pendingPracticeMode, !enabledModes.contains(pendingPracticeMode) {
            self.pendingPracticeMode = nil
        }
    }

    private func handleTypingTestChange(_ newValue: String) {
        if newValue.isEmpty {
            typingTestStartedAt = nil
            typingTestCompletedAt = nil
            typingTestMeasuredWPM = 0
            return
        }

        if typingTestStartedAt == nil {
            let now = Date()
            typingTestStartedAt = now
            typingTestNow = now
        }

        let normalizedValue = normalizedTypingTestText(newValue)
        let normalizedPrompt = normalizedTypingTestText(Self.typingSpeedPrompt)

        if typingTestCompletedAt != nil, normalizedValue != normalizedPrompt {
            typingTestCompletedAt = nil
            typingTestMeasuredWPM = 0
        }

        guard normalizedValue == normalizedPrompt,
              typingTestCompletedAt == nil else {
            return
        }

        let completedAt = Date()
        typingTestCompletedAt = completedAt
        typingTestNow = completedAt

        let elapsedSeconds = typingTestElapsedSeconds
        let measuredWPM = typingWordsPerMinute(
            characterCount: Self.typingSpeedPrompt.count,
            elapsedSeconds: elapsedSeconds
        )
        typingTestMeasuredWPM = measuredWPM

        guard measuredWPM > onboardingPreferences.metricsBestTypingWordsPerMinute else { return }
        onboardingPreferences.metricsBestTypingWordsPerMinute = measuredWPM
        controller.savePreferencesQuietly(preferences: onboardingPreferences)
    }

    private func resetTypingTest() {
        typingTestText = ""
        typingTestStartedAt = nil
        typingTestCompletedAt = nil
        typingTestMeasuredWPM = 0
        focusTypingTestSoon()
    }

    private func typingWordsPerMinute(characterCount: Int, elapsedSeconds: Double) -> Double {
        guard characterCount > 0, elapsedSeconds > 0.5 else { return 0 }
        let standardizedWords = Double(characterCount) / 5.0
        return standardizedWords / (elapsedSeconds / 60.0)
    }

    private func normalizedTypingTestText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func formattedTypingWPM(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return "\(Int(value.rounded()))"
    }

    private func focusPracticePadSoon() {
        Task { @MainActor in
            practicePadFocused = false
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard currentStep == .walkthrough || currentStep == .practice else { return }
            practicePadFocused = true
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard currentStep == .walkthrough || currentStep == .practice else { return }
            practicePadFocused = true
        }
    }

    private func appendTranscriptToPracticePad(_ transcript: String) {
        if !practiceText.isEmpty, !practiceText.hasSuffix(" "), !practiceText.hasSuffix("\n") {
            practiceText += " "
        }
        practiceText += transcript
        lastPracticeTranscriptApplied = transcript
        practicePadFocused = true
    }

    private func focusTypingTestSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard currentStep == .typingSpeed else { return }
            typingTestFocused = true
        }
    }

    private func installWalkthroughShortcutMonitorIfNeeded() {
        guard walkthroughShortcutMonitor == nil else { return }
        walkthroughShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleWalkthroughShortcut(event)
        }
    }

    private func removeWalkthroughShortcutMonitor() {
        if let walkthroughShortcutMonitor {
            NSEvent.removeMonitor(walkthroughShortcutMonitor)
            self.walkthroughShortcutMonitor = nil
        }
    }

    private func handleWalkthroughShortcut(_ event: NSEvent) -> NSEvent? {
        guard currentStep == .walkthrough else { return event }
        guard practicePadFocused else { return event }
        guard walkthroughPracticeStep == .dictionaryFix else { return event }
        // Don't intercept anything when the legacy direct shortcut is in its
        // disabled-sentinel state (empty modifiers + keyCode 0). Without this
        // guard the matcher would accept any plain "A" keypress because
        // keyCode 0 == "A" with no modifiers required.
        let dictionaryShortcut = onboardingPreferences.hotkeys.dictionaryCorrectionHotkey
        guard dictionaryShortcut.isBound else { return event }
        guard matches(shortcut: dictionaryShortcut, event: event) else {
            return event
        }

        let term = "Kodex"
        controller.createCorrectionForSuppliedTerm(term) { replacement in
            let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReplacement.isEmpty else { return }
            practiceText = practiceText.replacingOccurrences(
                of: term,
                with: trimmedReplacement,
                options: [.caseInsensitive]
            )
            practicePadFocused = true
        }
        return nil
    }

    private func matches(shortcut: VoceKeyboardShortcut, event: NSEvent) -> Bool {
        guard event.keyCode == shortcut.keyCode else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let requiredFlags: [VoceKeyboardShortcut.Modifier: NSEvent.ModifierFlags] = [
            .control: .control,
            .option: .option,
            .command: .command,
            .shift: .shift
        ]

        for modifier in VoceKeyboardShortcut.Modifier.allCases {
            let isRequired = shortcut.modifiers.contains(modifier)
            let hasFlag = flags.contains(requiredFlags[modifier] ?? [])
            if isRequired != hasFlag {
                return false
            }
        }
        return true
    }

    private var permissionsReady: Bool {
        controller.microphonePermissionStatus == .granted
            && controller.speechRecognitionPermissionStatus == .granted
    }

    private func goForward() {
        if currentStep == .walkthrough,
           let currentIndex = availableWalkthroughSteps.firstIndex(of: walkthroughPracticeStep),
           availableWalkthroughSteps.indices.contains(currentIndex + 1) {
            walkthroughPracticeStep = availableWalkthroughSteps[currentIndex + 1]
            return
        }

        guard let currentIndex = OnboardingStep.visibleCases.firstIndex(of: currentStep) else {
            completeOnboarding()
            return
        }
        guard OnboardingStep.visibleCases.indices.contains(currentIndex + 1) else {
            completeOnboarding()
            return
        }
        navigationDirection = .forward
        animateStepChange(to: OnboardingStep.visibleCases[currentIndex + 1])
    }

    private func goBack() {
        guard let currentIndex = OnboardingStep.visibleCases.firstIndex(of: currentStep),
              currentIndex > 0 else { return }
        navigationDirection = .backward
        animateStepChange(to: OnboardingStep.visibleCases[currentIndex - 1])
    }

    private func completeOnboarding() {
        controller.savePreferencesQuietly(preferences: onboardingPreferences)
        controller.completeOnboarding()
    }

    private func requestAccessCode() {
        let email = normalizedAccessEmail
        guard !email.isEmpty else { return }

        accessAuthError = ""
        accessAuthIsWorking = true
        accessEmailDraft = email
        onboardingPreferences.billing.subscriberEmail = email
        onboardingPreferences.normalize()
        controller.applySettingsDraft(preferences: onboardingPreferences, announceImmediateSave: false)

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
        let email = normalizedAccessEmail
        let code = normalizedAccessCode
        guard !email.isEmpty, !code.isEmpty else { return }

        accessAuthError = ""
        accessAuthIsWorking = true

        Task {
            do {
                try await controller.verifyVoceAccessCode(email: email, code: code)
                accessVerificationCodeWasSent = false
                accessVerificationCodeDraft = ""
            } catch {
                accessAuthError = (error as? LocalizedError)?.errorDescription
                    ?? "Could not verify that code."
            }
            accessAuthIsWorking = false
        }
    }

    private var onboardingPressToTalkBinding: Binding<PressToTalkHotkey> {
        Binding(
            get: { onboardingPreferences.hotkeys.pressToTalkHotkey },
            set: { newValue in
                onboardingPreferences.hotkeys.pressToTalkHotkey = newValue
                saveOnboardingPreferences()
            }
        )
    }

    private var onboardingHandsFreeKeyBinding: Binding<HandsFreeToggleHotkey?> {
        Binding(
            get: { onboardingPreferences.hotkeys.handsFreeGlobalHotkey },
            set: { newValue in
                onboardingPreferences.hotkeys.handsFreeGlobalHotkey = newValue
                normalizeOnboardingHotkeys()
                saveOnboardingPreferences()
            }
        )
    }

    private var onboardingHoldToTalkBinding: Binding<Bool> {
        Binding(
            get: { onboardingPreferences.hotkeys.optionPressToTalkEnabled },
            set: { isEnabled in
                if !isEnabled && !onboardingTapToTalkEnabled { return }
                onboardingPreferences.hotkeys.optionPressToTalkEnabled = isEnabled
                normalizeOnboardingHotkeys()
                saveOnboardingPreferences()
            }
        )
    }

    private var onboardingTapToTalkBinding: Binding<Bool> {
        Binding(
            get: { onboardingTapToTalkEnabled },
            set: { isEnabled in
                if !isEnabled && !onboardingPreferences.hotkeys.optionPressToTalkEnabled { return }
                onboardingPreferences.hotkeys.handsFreeGlobalHotkey = isEnabled
                    ? (onboardingPreferences.hotkeys.handsFreeGlobalHotkey ?? .init(hotkey: .keyCode(79)))
                    : nil
                normalizeOnboardingHotkeys()
                saveOnboardingPreferences()
            }
        )
    }

    private var onboardingTapToTalkEnabled: Bool {
        onboardingPreferences.hotkeys.handsFreeGlobalHotkey != nil
    }

    private func normalizeOnboardingHotkeys() {
        if !onboardingPreferences.hotkeys.optionPressToTalkEnabled && onboardingPreferences.hotkeys.handsFreeGlobalHotkey == nil {
            onboardingPreferences.hotkeys.handsFreeGlobalHotkey = .init(hotkey: .keyCode(79))
        }
    }

    private func saveOnboardingPreferences() {
        controller.applySettingsDraft(preferences: onboardingPreferences, announceImmediateSave: false)
        syncPracticeState()
    }

    private func animateStepChange(to step: OnboardingStep) {
        if reduceMotion {
            currentStep = step
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0)) {
                currentStep = step
            }
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case typingSpeed = 1
    case access = 2
    case permissions = 3
    case ready = 4
    case walkthrough = 5
    case practice = 6

    static let visibleCases: [OnboardingStep] = [
        .welcome,
        .access,
        .permissions,
        .ready,
        .typingSpeed,
        .walkthrough
    ]
}

private enum NavigationDirection {
    case forward
    case backward
}

private enum OnboardingPracticeMode: Int, CaseIterable, Hashable {
    case holdToTalk = 1
    case tapToTalk = 2

    var title: String {
        switch self {
        case .holdToTalk:
            return "Hold to talk"
        case .tapToTalk:
            return "Tap to talk"
        }
    }

    var systemImage: String {
        switch self {
        case .holdToTalk:
            return "hand.tap.fill"
        case .tapToTalk:
            return "waveform"
        }
    }

    func practicePrompt(hotkeyLabel: String) -> String {
        switch self {
        case .holdToTalk:
            return "Hold \(hotkeyLabel), say a line, then release."
        case .tapToTalk:
            return "Tap \(hotkeyLabel), say a line, then tap again."
        }
    }

    func practiceInstruction(hotkeyLabel: String) -> String {
        switch self {
        case .holdToTalk:
            return "Hold \(hotkeyLabel) while you speak. Let go when you're done."
        case .tapToTalk:
            return "Tap \(hotkeyLabel) to start. Tap it again to stop."
        }
    }
}

/// Static "⌘ ⌥ tap" indicator. The Voce actions trigger is a modifier-only
/// tap (not a remappable keyCode), so this view replaces the recorder field
/// in the row layout — it just declares the gesture without offering edit.
struct VoceActionsTapBadge: View {
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            keycap("⌘")
            keycap("⌥")
            Text("tap")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(VoceDesign.textSecondary)
                .padding(.leading, 2)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voce actions trigger")
        .accessibilityValue(isEnabled ? "Tap Command Option" : "Disabled")
    }

    private func keycap(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(VoceDesign.textPrimary)
            .frame(minWidth: 28, minHeight: 26)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(VoceDesign.surface.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(VoceDesign.border, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 0.5, x: 0, y: 0.5)
            )
    }
}
