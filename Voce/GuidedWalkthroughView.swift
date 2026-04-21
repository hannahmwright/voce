import AppKit
import SwiftUI
import VoceKit

struct GuidedWalkthroughView: View {
    let holdHotkeyLabel: String
    let tapHotkeyLabel: String
    let dictionaryHotkeyLabel: String
    let isRecording: Bool
    let activeRecordingStep: GuidedWalkthroughStep?
    let availableSteps: [GuidedWalkthroughStep]
    @Binding var selectedStep: GuidedWalkthroughStep

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.lg) {
            VStack(alignment: .leading, spacing: VoceDesign.lg) {
                currentStepHeader
                practiceSurface
            }
            .padding(VoceDesign.lg)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VoceDesign.contentBackground)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
            )
            .shadowStyle(.sm)
            .animation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationFast), value: selectedStep)

            walkthroughControls
        }
        .onAppear {
            if let firstStep = availableSteps.first {
                if !availableSteps.contains(selectedStep) {
                    selectedStep = firstStep
                }
            }
        }
        .onChange(of: availableSteps) { _, newSteps in
            guard let firstStep = newSteps.first else { return }
            guard !newSteps.contains(selectedStep) else { return }
            selectedStep = firstStep
        }
    }

    private var currentStepHeader: some View {
        HStack(alignment: .center, spacing: VoceDesign.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VoceDesign.warmAccentFill)
                    .frame(width: 42, height: 42)

                Image(systemName: selectedStep.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VoceDesign.warmAccentText)
            }

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text("Step \(currentStepIndex + 1) of \(availableSteps.count)")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Text(selectedStep.shortTitle)
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)
            }

            Spacer(minLength: 0)

            walkthroughHotkeyBadge(selectedStep.stepBadge)
        }
    }

    @ViewBuilder
    private var practiceSurface: some View {
        switch selectedStep {
        case .tapToRecord:
            dictationPracticeCard(
                startLabel: "Tap",
                startHotkey: tapHotkeyLabel,
                startDetail: "Tap \(tapHotkeyLabel) to start dictating.",
                sentence: "Please send the meeting notes after lunch.",
                stopLabel: "Stop",
                stopHotkey: tapHotkeyLabel,
                stopDetail: "Tap the same shortcut again."
            )
        case .holdToRecord:
            dictationPracticeCard(
                startLabel: "Hold",
                startHotkey: holdHotkeyLabel,
                startDetail: "Hold \(holdHotkeyLabel) to start dictating.",
                sentence: "I am running five minutes late, but I am on my way.",
                stopLabel: "Stop",
                stopHotkey: "Release",
                stopDetail: "Keep holding while you speak, then let go."
            )
        case .dictionaryFix:
            dictionaryPracticeCard
        }
    }

    private func dictationPracticeCard(
        startLabel: String,
        startHotkey: String,
        startDetail: String,
        sentence: String,
        stopLabel: String,
        stopHotkey: String,
        stopDetail: String
    ) -> some View {
        let isActiveLesson = isRecording && activeRecordingStep == selectedStep

        return VStack(alignment: .leading, spacing: VoceDesign.md) {
            if isActiveLesson {
                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Say this")
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.4)

                    Text(sentence)
                        .font(VoceDesign.heading2())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                lessonStepRow(
                    label: stopLabel,
                    detail: stopDetail,
                    hotkey: stopHotkey,
                    emphasized: true
                )
            } else {
                lessonStepRow(
                    label: startLabel,
                    detail: startDetail,
                    hotkey: startHotkey,
                    emphasized: true
                )
            }
        }
        .padding(VoceDesign.lg)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VoceDesign.surfaceSecondary.opacity(0.76))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var dictionaryPracticeCard: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: VoceDesign.md) {
                Text("Fix this")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                HStack(spacing: 4) {
                    Text("Please email")
                    Text("Kodex")
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(VoceDesign.skyBlue.opacity(0.42))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(VoceDesign.accent.opacity(0.34), lineWidth: VoceDesign.borderThin)
                        )
                    Text("the revised invoice today.")
                }
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textSecondary)
                .textSelection(.enabled)
            }

            lessonStepRow(
                label: "Press",
                detail: "Use the shortcut, then replace it with Codex.",
                hotkey: dictionaryHotkeyLabel,
                emphasized: true
            )
        }
        .padding(VoceDesign.lg)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VoceDesign.surfaceSecondary.opacity(0.76))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private func lessonStepRow(label: String, detail: String, hotkey: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .center, spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Text(detail)
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            walkthroughHotkeyBadge(hotkey)
        }
        .padding(.horizontal, VoceDesign.md)
        .padding(.vertical, VoceDesign.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(emphasized ? VoceDesign.warmAccentFill.opacity(0.34) : VoceDesign.surface.opacity(0.44))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(emphasized ? VoceDesign.warmAccentText.opacity(0.12) : VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private func walkthroughHotkeyBadge(_ label: String) -> some View {
        Text(label)
            .font(VoceDesign.font(size: 13, weight: .semibold))
            .foregroundStyle(VoceDesign.warmAccentText)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.xs + VoceDesign.xxs)
            .background(VoceDesign.warmAccentFill)
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
    }

    private var walkthroughControls: some View {
        HStack(spacing: VoceDesign.sm) {
            Button {
                goToPreviousStep()
            } label: {
                Label("Back", systemImage: "arrow.left")
                    .font(VoceDesign.captionEmphasis())
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoceDesign.textPrimary)
            .disabled(selectedStep == availableSteps.first)
            .opacity(selectedStep == availableSteps.first ? VoceDesign.opacityDisabled : 1)

            Spacer(minLength: 0)

            Text("\(currentStepIndex + 1) of \(availableSteps.count)")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            Button {
                goToNextStep()
            } label: {
                Label(selectedStep == availableSteps.last ? "Restart" : "Next", systemImage: "arrow.right")
                    .font(VoceDesign.captionEmphasis())
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoceDesign.warmAccentText)
        }
    }

    private var currentStepIndex: Int {
        availableSteps.firstIndex(of: selectedStep) ?? 0
    }

    private func setSelectedStep(_ step: GuidedWalkthroughStep) {
        if reduceMotion {
            selectedStep = step
        } else {
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
                selectedStep = step
            }
        }
    }

    private func goToPreviousStep() {
        let previousIndex = currentStepIndex - 1
        guard availableSteps.indices.contains(previousIndex) else { return }
        setSelectedStep(availableSteps[previousIndex])
    }

    private func goToNextStep() {
        let nextIndex = currentStepIndex + 1
        if availableSteps.indices.contains(nextIndex) {
            setSelectedStep(availableSteps[nextIndex])
        } else if let firstStep = availableSteps.first {
            setSelectedStep(firstStep)
        }
    }
}

enum GuidedWalkthroughStep: Int, CaseIterable {
    case tapToRecord = 0
    case holdToRecord = 1
    case dictionaryFix = 2

    var shortTitle: String {
        switch self {
        case .tapToRecord:
            return "Tap"
        case .holdToRecord:
            return "Hold"
        case .dictionaryFix:
            return "Fix"
        }
    }

    var stepBadge: String {
        switch self {
        case .tapToRecord:
            return "Tap to talk"
        case .holdToRecord:
            return "Hold to talk"
        case .dictionaryFix:
            return "Dictionary fix"
        }
    }

    var icon: String {
        switch self {
        case .tapToRecord:
            return "waveform"
        case .holdToRecord:
            return "keyboard"
        case .dictionaryFix:
            return "text.badge.checkmark"
        }
    }

    func primaryInstruction(
        holdHotkeyLabel: String,
        tapHotkeyLabel: String,
        dictionaryHotkeyLabel: String
    ) -> String {
        switch self {
        case .tapToRecord:
            return "Tap \(tapHotkeyLabel) to start, say the line, then tap it again."
        case .holdToRecord:
            return "Hold \(holdHotkeyLabel), say the line, then release to stop."
        case .dictionaryFix:
            return "Highlight the error, then press \(dictionaryHotkeyLabel)."
        }
    }
}

struct GuidedWalkthroughSettingsSection: View {
    let holdHotkeyLabel: String
    let tapHotkeyLabel: String
    let dictionaryHotkeyLabel: String
    let dictionaryCorrectionHotkey: VoceKeyboardShortcut
    let availableSteps: [GuidedWalkthroughStep]
    @State private var isPresentingWalkthrough = false

    var body: some View {
        settingsCardWithSubtitle(
            "Learn the basics",
            subtitle: "Open the guided practice flow again whenever you need a refresher."
        ) {
            settingsSubcard {
                VStack(alignment: .leading, spacing: VoceDesign.md) {
                    Text("Run the walkthrough in a dedicated practice view instead of inside Settings.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        isPresentingWalkthrough = true
                    } label: {
                        HStack(spacing: VoceDesign.xs) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Open walkthrough")
                                .font(VoceDesign.bodyEmphasis())
                        }
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.vertical, VoceDesign.sm)
                        .background(VoceDesign.warmAccentFill)
                        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $isPresentingWalkthrough) {
            GuidedWalkthroughModal(
                holdHotkeyLabel: holdHotkeyLabel,
                tapHotkeyLabel: tapHotkeyLabel,
                dictionaryHotkeyLabel: dictionaryHotkeyLabel,
                dictionaryCorrectionHotkey: dictionaryCorrectionHotkey,
                availableSteps: availableSteps
            )
        }
    }
}

private struct GuidedWalkthroughModal: View {
    @EnvironmentObject private var controller: DictationController
    let holdHotkeyLabel: String
    let tapHotkeyLabel: String
    let dictionaryHotkeyLabel: String
    let dictionaryCorrectionHotkey: VoceKeyboardShortcut
    let availableSteps: [GuidedWalkthroughStep]

    @Environment(\.dismiss) private var dismiss
    @FocusState private var practicePadFocused: Bool
    @State private var selectedStep: GuidedWalkthroughStep = .tapToRecord
    @State private var practiceText = ""
    @State private var lastPracticeTranscriptApplied = ""
    @State private var walkthroughShortcutMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.lg) {
            HStack(alignment: .top, spacing: VoceDesign.md) {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Learn the basics")
                        .font(VoceDesign.heading2())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text("Practice the core Voce shortcuts again without leaving Help.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer(minLength: 0)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.textPrimary)
                .padding(.horizontal, VoceDesign.md)
                .padding(.vertical, VoceDesign.sm)
                .background(
                    Capsule(style: .continuous)
                        .fill(VoceDesign.surfaceSecondary)
                )
            }

            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: VoceDesign.lg) {
                    GuidedWalkthroughView(
                        holdHotkeyLabel: holdHotkeyLabel,
                        tapHotkeyLabel: tapHotkeyLabel,
                        dictionaryHotkeyLabel: dictionaryHotkeyLabel,
                        isRecording: controller.isRecording,
                        activeRecordingStep: activeRecordingStep,
                        availableSteps: availableSteps,
                        selectedStep: $selectedStep
                    )

                    practicePadCard
                }
                .padding(.trailing, VoceDesign.xs)
            }
        }
        .padding(VoceDesign.xl)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 460, idealHeight: 620, alignment: .topLeading)
        .background(VoceDesign.windowBackground)
        .onAppear {
            practiceText = walkthroughSeedText(for: selectedStep)
            focusPracticePadSoon()
            installWalkthroughShortcutMonitorIfNeeded()
        }
        .onDisappear {
            removeWalkthroughShortcutMonitor()
        }
        .onChange(of: selectedStep) { _, step in
            practiceText = walkthroughSeedText(for: step)
            lastPracticeTranscriptApplied = ""
            focusPracticePadSoon()
        }
        .onChange(of: controller.status) { _, newStatus in
            guard newStatus.localizedCaseInsensitiveContains("copied to clipboard")
                || newStatus.localizedCaseInsensitiveContains("click the input again.") else { return }

            let transcript = controller.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, transcript != lastPracticeTranscriptApplied else { return }
            appendTranscriptToPracticePad(transcript)
        }
        .onChange(of: controller.lastTranscript) { _, newTranscript in
            guard !controller.isRecording else { return }
            let transcript = newTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, transcript != lastPracticeTranscriptApplied else { return }
            appendTranscriptToPracticePad(transcript)
        }
    }

    private var activeRecordingStep: GuidedWalkthroughStep? {
        guard controller.isRecording else { return nil }
        return controller.handsFreeOn ? .tapToRecord : .holdToRecord
    }

    private var practicePadCard: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                    Text(walkthroughScratchPadTitle)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text(walkthroughScratchPadSubtitle)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer(minLength: 0)

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
                        Text(walkthroughScratchPadPlaceholder)
                            .font(VoceDesign.body())
                            .foregroundStyle(VoceDesign.textSecondary.opacity(0.7))
                            .padding(.horizontal, VoceDesign.lg)
                            .padding(.top, VoceDesign.md + 2)
                            .allowsHitTesting(false)
                    }
                }
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

    private var walkthroughScratchPadTitle: String {
        switch selectedStep {
        case .tapToRecord:
            return "Tap to talk"
        case .holdToRecord:
            return "Hold to talk"
        case .dictionaryFix:
            return "Dictionary quick fix"
        }
    }

    private var walkthroughScratchPadSubtitle: String {
        switch selectedStep {
        case .tapToRecord:
            return "Click here, then tap \(tapHotkeyLabel) and say the line above."
        case .holdToRecord:
            return "Click here, then hold \(holdHotkeyLabel) while you say the line above."
        case .dictionaryFix:
            return "Highlight the wrong word here, then press \(dictionaryHotkeyLabel)."
        }
    }

    private var walkthroughScratchPadPlaceholder: String {
        switch selectedStep {
        case .tapToRecord:
            return "Click here, then tap \(tapHotkeyLabel)..."
        case .holdToRecord:
            return "Click here, then hold \(holdHotkeyLabel)..."
        case .dictionaryFix:
            return "Highlight Kodex, then press the quick fix shortcut..."
        }
    }

    private var practicePadStatusText: String {
        switch selectedStep {
        case .dictionaryFix:
            return practiceText.localizedCaseInsensitiveContains("codex")
                && !practiceText.localizedCaseInsensitiveContains("kodex") ? "Fixed" : "Ready"
        case .tapToRecord, .holdToRecord:
            if controller.isRecording {
                return "Listening"
            }

            return practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ready" : "Captured"
        }
    }

    private var practicePadStatusTextColor: Color {
        switch practicePadStatusText {
        case "Listening":
            return VoceDesign.warmAccentText
        case "Captured", "Fixed":
            return VoceDesign.success
        default:
            return VoceDesign.textSecondary
        }
    }

    private var practicePadStatusFill: Color {
        switch practicePadStatusText {
        case "Listening":
            return VoceDesign.warmAccentFill
        case "Captured", "Fixed":
            return VoceDesign.success.opacity(0.14)
        default:
            return VoceDesign.surfaceSecondary
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

    private func focusPracticePadSoon() {
        Task { @MainActor in
            practicePadFocused = false
            try? await Task.sleep(nanoseconds: 120_000_000)
            practicePadFocused = true
            try? await Task.sleep(nanoseconds: 180_000_000)
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
        guard practicePadFocused else { return event }
        guard selectedStep == .dictionaryFix else { return event }
        guard matches(shortcut: dictionaryCorrectionHotkey, event: event) else { return event }

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
}
