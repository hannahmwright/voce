import SwiftUI
import VoceKit

struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var practicePadFocused: Bool

    @State private var currentStep: OnboardingStep = .welcome
    @State private var navigationDirection: NavigationDirection = .forward
    @State private var onboardingPreferences: AppPreferences = .default
    @State private var practiceText: String = ""
    @State private var practiceCompletedModes: Set<OnboardingPracticeMode> = []
    @State private var activePracticeMode: OnboardingPracticeMode?
    @State private var pendingPracticeMode: OnboardingPracticeMode?
    @State private var practiceStartCharacterCount: Int = 0

    private let onboardingModeColumnWidth: CGFloat = 214
    private let onboardingRecorderColumnWidth: CGFloat = 236
    private let onboardingReadyCardWidth: CGFloat = 560

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
                            switch currentStep {
                            case .welcome:
                                welcomeStep
                            case .permissions:
                                permissionsStep
                            case .ready:
                                readyStep
                            case .practice:
                                practiceStep
                            }
                        }
                        .id(currentStep)
                        .transition(stepTransition)

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
            syncPracticeState()
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == .practice {
                syncPracticeState()
                controller.applySettingsDraft(preferences: onboardingPreferences, announceImmediateSave: false)
                focusPracticePadSoon()
            }
        }
        .onChange(of: controller.isRecording) { _, isRecording in
            guard currentStep == .practice else { return }

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
            guard currentStep == .practice else { return }
            guard let pendingPracticeMode else { return }
            guard newValue.count > practiceStartCharacterCount else { return }
            guard enabledPracticeModes.contains(pendingPracticeMode) else { return }

            practiceCompletedModes.insert(pendingPracticeMode)
            self.pendingPracticeMode = nil
        }
    }

    private var progressBar: some View {
        HStack(spacing: VoceDesign.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                RoundedRectangle(cornerRadius: VoceDesign.radiusTiny)
                    .fill(step.rawValue <= currentStep.rawValue ? VoceDesign.warmAccentText : VoceDesign.border)
                    .frame(height: VoceDesign.xs)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                        value: currentStep
                    )
            }
        }
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
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

            if !permissionsReady {
                Text("Allow Microphone and Speech to continue.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.warning)
            }
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
                practiceLeadCard
                practiceProgressRow
                practicePadCard
            }
            .frame(maxWidth: 620)
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
                    Text("Scratch pad")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text("Your words land here.")
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
                    Text("Click here, then try speaking...")
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
        HStack {
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

            if currentStep == .practice {
                Button {
                    completeOnboarding()
                } label: {
                    Text("Skip test")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.vertical, VoceDesign.sm)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip the practice test and finish onboarding")
            }

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
            .disabled(!canContinue)
            .opacity(canContinue ? 1 : VoceDesign.opacityDisabled)
            .accessibilityLabel(currentStep == .practice ? "Finish onboarding and start using Voce" : "Continue to next step")
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .permissions:
            return permissionsReady
        case .ready:
            return true
        case .practice:
            return practiceReady
        }
    }

    private var practiceReady: Bool {
        Set(enabledPracticeModes).isSubset(of: practiceCompletedModes)
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
            return practiceReady ? VoceDesign.success : VoceDesign.textSecondary
        }
    }

    private func practiceHotkeyLabel(for mode: OnboardingPracticeMode) -> String {
        switch mode {
        case .holdToTalk:
            return hotkeyDisplayName(for: onboardingPreferences.hotkeys.pressToTalkHotkey)
        case .tapToTalk:
            if let hotkey = onboardingPreferences.hotkeys.handsFreeGlobalHotkey {
                return handsFreeToggleDisplayName(for: hotkey)
            }
            return "your key"
        }
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

    private func focusPracticePadSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard currentStep == .practice else { return }
            practicePadFocused = true
        }
    }

    private var permissionsReady: Bool {
        controller.microphonePermissionStatus == .granted
            && controller.speechRecognitionPermissionStatus == .granted
    }

    private func goForward() {
        guard let nextIndex = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        navigationDirection = .forward
        animateStepChange(to: nextIndex)
    }

    private func goBack() {
        guard let previousIndex = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        navigationDirection = .backward
        animateStepChange(to: previousIndex)
    }

    private func completeOnboarding() {
        controller.savePreferencesQuietly(preferences: onboardingPreferences)
        controller.completeOnboarding()
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
    case permissions = 1
    case ready = 2
    case practice = 3
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
