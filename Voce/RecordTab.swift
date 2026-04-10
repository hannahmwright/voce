import SwiftUI
import VoceKit

struct RecordTab: View {
    private enum PermissionCalloutKind {
        case accessibility
        case microphone
        case inputMonitoring

        var icon: String {
            switch self {
            case .accessibility: return "hand.raised.fill"
            case .microphone: return "mic.fill"
            case .inputMonitoring: return "keyboard.fill"
            }
        }

        var title: String {
            switch self {
            case .accessibility: return "Enable Accessibility"
            case .microphone: return "Allow Microphone Access"
            case .inputMonitoring: return "Enable Input Monitoring"
            }
        }
    }

    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showErrorBanner = false

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                content
                    .onChange(of: controller.lastError) { _, _ in
                        animateErrorBannerUpdate()
                    }
                    .onChange(of: controller.hotkeyRegistrationMessage) { _, _ in
                        animateErrorBannerUpdate()
                    }
            } else {
                content
                    .onChange(of: controller.lastError) { _ in
                        animateErrorBannerUpdate()
                    }
                    .onChange(of: controller.hotkeyRegistrationMessage) { _ in
                        animateErrorBannerUpdate()
                    }
            }
        }
        .onAppear {
            controller.refreshPermissionStatuses()
            showErrorBanner = hasError
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Error/warning banner
            if showErrorBanner {
                HStack {
                    errorBanner
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(errorBannerAccessibilityLabel)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, VoceDesign.md)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity)
                )
            }

            Spacer()

            // Mic button
            MicButton(
                isRecording: controller.isRecording,
                isTranscribing: controller.recordingLifecycleState == .transcribing,
                handsFreeOn: controller.handsFreeOn,
                onTap: { controller.toggleHandsFree() }
            )

            // Recording elapsed time
            if controller.isRecording {
                Text(formatElapsedTime(controller.recordingElapsed))
                    .font(VoceDesign.caption().monospacedDigit())
                    .foregroundStyle(VoceDesign.accent)
                    .padding(.top, VoceDesign.xs)
                    .transition(.opacity)
                    .accessibilityLabel("Recording time")
                    .accessibilityValue(formatElapsedTime(controller.recordingElapsed))
            }

            // Status text
            VStack(spacing: VoceDesign.xs) {
                Text(controller.status)
                    .font(VoceDesign.subheadline())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityLabel("Recording status")
                    .accessibilityValue(controller.status)

                if controller.recordingLifecycleState == .transcribing {
                    Text("(usually 2\u{2013}5 seconds)")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
            }
            .padding(.top, VoceDesign.sm)

            Spacer()

            // Last transcript card or empty hint
            if controller.lastTranscript.isEmpty {
                emptyHintView
            } else {
                lastTranscriptCard
            }
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, VoceDesign.xl)
        .padding(.vertical, VoceDesign.xxl)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.44))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: VoceDesign.borderThin)
                )
                .shadowStyle(.lg)
        }
        .padding(VoceDesign.lg)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
            value: controller.lastTranscript
        )
    }

    private func animateErrorBannerUpdate() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal)) {
            showErrorBanner = hasError
        }
    }

    private var hasError: Bool {
        permissionCalloutKind != nil || !activeErrorMessage.isEmpty
    }

    private var errorBannerAccessibilityLabel: String {
        var parts: [String] = []
        if !controller.hotkeyRegistrationMessage.isEmpty {
            parts.append(controller.hotkeyRegistrationMessage)
        }
        if !controller.lastError.isEmpty {
            parts.append(controller.lastError)
        }
        return parts.joined(separator: ". ")
    }

    private var activeErrorMessage: String {
        let parts = [controller.hotkeyRegistrationMessage, controller.lastError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !isResolvedPermissionMessage($0) }
        return parts.joined(separator: " ")
    }

    private var permissionCalloutKind: PermissionCalloutKind? {
        let combined = activeErrorMessage.lowercased()

        if controller.accessibilityPermissionStatus == .denied
            || (combined.contains("accessibility") && controller.accessibilityPermissionStatus != .granted)
        {
            return .accessibility
        }

        if controller.inputMonitoringPermissionStatus == .denied
            || (combined.contains("input monitoring") && controller.inputMonitoringPermissionStatus != .granted)
        {
            return .inputMonitoring
        }

        if controller.microphonePermissionStatus == .denied
            || (
                controller.microphonePermissionStatus != .granted
                && (combined.contains("microphone") || combined.contains("allow microphone"))
            )
        {
            return .microphone
        }

        return nil
    }

    private func isResolvedPermissionMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()

        if controller.microphonePermissionStatus == .granted,
           (normalized.contains("microphone permission") || normalized == "microphone permission denied") {
            return true
        }

        if controller.accessibilityPermissionStatus == .granted,
           normalized.contains("accessibility") && normalized.contains("permission") {
            return true
        }

        if controller.inputMonitoringPermissionStatus == .granted,
           normalized.contains("input monitoring") {
            return true
        }

        return false
    }

    private var permissionCalloutMessage: String {
        guard let kind = permissionCalloutKind else { return "" }

        switch kind {
        case .accessibility:
            return "Voce needs Accessibility access to type into other apps."
        case .microphone:
            return "Voce needs microphone access before it can start live dictation."
        case .inputMonitoring:
            return "Input Monitoring lets Voce detect shortcuts while other apps are focused."
        }
    }

    private var permissionButtonTitle: String {
        guard let kind = permissionCalloutKind else { return "Open Settings" }

        switch kind {
        case .microphone:
            return controller.microphonePermissionStatus == .unknown ? "Allow Microphone" : "Open Settings"
        case .accessibility, .inputMonitoring:
            return "Open Settings"
        }
    }

    // MARK: - Error Banner

    private var errorBanner: some View {
        Group {
            if let kind = permissionCalloutKind {
                permissionBanner(kind)
            } else {
                genericErrorBanner
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func permissionBanner(_ kind: PermissionCalloutKind) -> some View {
        HStack(alignment: .top, spacing: VoceDesign.md) {
            Image(systemName: kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoceDesign.accent)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.55))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                Text(kind.title)
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(permissionCalloutMessage)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(permissionButtonTitle) {
                    handlePermissionAction(kind)
                }
                .buttonStyle(.plain)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.accent)
                .padding(.top, VoceDesign.xxs)
            }

            Spacer(minLength: 0)

            dismissErrorButton
        }
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surfaceSecondary.opacity(0.66))
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(.regularMaterial.opacity(0.34))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: VoceDesign.borderThin)
        )
    }

    private var genericErrorBanner: some View {
        HStack(alignment: .top, spacing: VoceDesign.md) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoceDesign.error)

            Text(activeErrorMessage)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            dismissErrorButton
        }
        .padding(VoceDesign.md)
        .glassBackground(cornerRadius: VoceDesign.radiusMedium)
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                .stroke(VoceDesign.errorBorder, lineWidth: VoceDesign.borderThin)
        )
    }

    private var dismissErrorButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal)) {
                controller.clearErrors()
                showErrorBanner = false
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss error")
    }

    private func handlePermissionAction(_ kind: PermissionCalloutKind) {
        switch kind {
        case .accessibility:
            controller.openAccessibilitySettings()
        case .microphone:
            if controller.microphonePermissionStatus == .unknown {
                controller.requestMicrophonePermission()
            } else {
                controller.openMicrophoneSettings()
            }
        case .inputMonitoring:
            controller.openInputMonitoringSettings()
        }
    }

    // MARK: - Empty Hint

    private var emptyHintView: some View {
        VStack(spacing: VoceDesign.sm) {
            if controller.microphonePermissionStatus == .denied {
                Label("Microphone access denied", systemImage: "mic.slash")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            } else if controller.microphonePermissionStatus == .unknown {
                Label("Grant microphone access to start", systemImage: "mic.badge.plus")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            } else {
                hotkeyHint
            }
        }
        .frame(maxWidth: .infinity)
        .padding(VoceDesign.md)
        .glassBackground(cornerRadius: VoceDesign.radiusMedium)
    }

    private var hotkeyHint: some View {
        HStack(spacing: VoceDesign.sm) {
            let hotkeys = controller.preferences.hotkeys
            if hotkeys.optionPressToTalkEnabled {
                keyBadge(hotkeys.pressToTalkHotkey.displayName)
                Text("hold to dictate")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
            if hotkeys.optionPressToTalkEnabled, hotkeys.handsFreeGlobalHotkey != nil {
                Text("or")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.6))
            }
            if let hotkey = hotkeys.handsFreeGlobalHotkey {
                keyBadge(keyLabel(for: hotkey))
                Text("hands-free")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
            if !hotkeys.optionPressToTalkEnabled && hotkeys.handsFreeGlobalHotkey == nil {
                Text("Set up a hotkey in Settings")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
    }

    private func keyBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(VoceDesign.textPrimary)
            .padding(.horizontal, VoceDesign.sm)
            .padding(.vertical, VoceDesign.xs)
            .background(VoceDesign.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2))
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2)
                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
            )
    }

    // MARK: - Transcript Card

    private var lastTranscriptCard: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            Text(controller.lastTranscript)
                .font(VoceDesign.body())
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Action row
            HStack(spacing: VoceDesign.md) {
                Text("Last transcript")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)

                Spacer()

                Button {
                    controller.copyCurrentTranscript()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy last transcript")

                Button {
                    controller.pasteCurrentTranscript()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste last transcript")
            }
        }
        .cardStyle()
    }

    // MARK: - Helpers

    private func keyLabel(for hotkey: HandsFreeToggleHotkey) -> String {
        handsFreeToggleDisplayName(for: hotkey)
    }

    private func formatElapsedTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
