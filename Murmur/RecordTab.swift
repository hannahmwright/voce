import SwiftUI
import MurmurKit

struct RecordTab: View {
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
            showErrorBanner = hasError
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Error/warning banner
            if showErrorBanner {
                errorBanner
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(errorBannerAccessibilityLabel)
                    .padding(.bottom, MurmurDesign.md)
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
                    .font(MurmurDesign.caption().monospacedDigit())
                    .foregroundStyle(MurmurDesign.accent)
                    .padding(.top, MurmurDesign.xs)
                    .transition(.opacity)
                    .accessibilityLabel("Recording time")
                    .accessibilityValue(formatElapsedTime(controller.recordingElapsed))
            }

            // Status text
            VStack(spacing: MurmurDesign.xs) {
                Text(controller.status)
                    .font(MurmurDesign.subheadline())
                    .foregroundStyle(MurmurDesign.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityLabel("Recording status")
                    .accessibilityValue(controller.status)

                if controller.recordingLifecycleState == .transcribing {
                    Text("(usually 2\u{2013}5 seconds)")
                        .font(MurmurDesign.caption())
                        .foregroundStyle(MurmurDesign.textSecondary)
                }
            }
            .padding(.top, MurmurDesign.sm)

            Spacer()

            // Last transcript card
            lastTranscriptCard
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: MurmurDesign.animationNormal),
                    value: controller.lastTranscript
                )
        }
        .padding(.vertical, MurmurDesign.lg)
    }

    private func animateErrorBannerUpdate() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: MurmurDesign.animationNormal)) {
            showErrorBanner = hasError
        }
    }

    private var hasError: Bool {
        !controller.lastError.isEmpty || !controller.hotkeyRegistrationMessage.isEmpty
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

    private var isPermissionRelated: Bool {
        let combined = (controller.lastError + controller.hotkeyRegistrationMessage).lowercased()
        return combined.contains("accessibility")
            || combined.contains("microphone")
            || combined.contains("input monitoring")
    }

    private var errorBanner: some View {
        HStack(spacing: MurmurDesign.sm) {
            RoundedRectangle(cornerRadius: MurmurDesign.radiusTiny)
                .fill(MurmurDesign.error)
                .frame(width: MurmurDesign.borderHeavy)

            VStack(alignment: .leading, spacing: MurmurDesign.xs) {
                if !controller.hotkeyRegistrationMessage.isEmpty {
                    Text(controller.hotkeyRegistrationMessage)
                        .font(MurmurDesign.caption())
                        .foregroundStyle(MurmurDesign.error)
                }
                if !controller.lastError.isEmpty {
                    Text(controller.lastError)
                        .font(MurmurDesign.caption())
                        .foregroundStyle(MurmurDesign.error)
                }
                if isPermissionRelated {
                    Button {
                        PermissionDiagnostics.openAccessibilitySettings()
                    } label: {
                        Text("Open Settings")
                            .font(MurmurDesign.caption())
                            .foregroundStyle(MurmurDesign.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open system settings for permissions")
                }
            }

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: MurmurDesign.animationNormal)) {
                    controller.clearErrors()
                    showErrorBanner = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(MurmurDesign.caption())
                    .foregroundStyle(MurmurDesign.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(MurmurDesign.md)
        .background(MurmurDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall)
                .stroke(MurmurDesign.errorBorder, lineWidth: MurmurDesign.borderNormal)
        )
    }

    private var lastTranscriptCard: some View {
        VStack(alignment: .leading, spacing: MurmurDesign.sm) {
            HStack {
                Text("Last Transcript")
                    .font(MurmurDesign.bodyEmphasis())
                    .foregroundStyle(MurmurDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !controller.lastTranscript.isEmpty {
                    CopyButtonView(action: {
                        if let entry = controller.recentEntries.first {
                            controller.copyEntry(entry)
                        }
                    }, label: "Copy last transcript")

                    Button {
                        controller.pasteLastTranscript()
                    } label: {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(MurmurDesign.caption())
                            .foregroundStyle(MurmurDesign.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Paste")
                    .accessibilityLabel("Paste last transcript")
                }
            }

            if controller.lastTranscript.isEmpty {
                Text(emptyStateHint)
                    .font(MurmurDesign.body())
                    .foregroundStyle(MurmurDesign.textSecondary)
            } else {
                Text(controller.lastTranscript)
                    .font(MurmurDesign.body())
                    .foregroundStyle(MurmurDesign.textPrimary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    private var emptyStateHint: String {
        if controller.microphonePermissionStatus == .denied {
            return "Microphone access denied. Grant access in Settings to start dictating."
        }
        if controller.microphonePermissionStatus == .unknown {
            return "Grant microphone access to start dictating."
        }

        let hotkeys = controller.preferences.hotkeys
        if hotkeys.optionPressToTalkEnabled {
            if let keyCode = hotkeys.handsFreeGlobalKeyCode {
                return "Hold Option to dictate, or press \(keyLabel(for: keyCode)) for hands-free"
            }
            return "Hold Option to start dictating"
        }
        if let keyCode = hotkeys.handsFreeGlobalKeyCode {
            return "Press \(keyLabel(for: keyCode)) to start hands-free dictation"
        }
        return "Configure a hotkey in Settings to start dictating"
    }

    private func keyLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        default: return "F\(keyCode)"
        }
    }

    private func formatElapsedTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
