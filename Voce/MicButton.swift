import SwiftUI

struct MicButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let handsFreeOn: Bool
    let onTap: () -> Void

    @State private var glowAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                micButton
                    .onChange(of: isRecording) { _, recording in
                        glowAnimating = recording
                    }
            } else {
                micButton
                    .onChange(of: isRecording) { recording in
                        glowAnimating = recording
                    }
            }
        }
        .onAppear {
            if isRecording {
                glowAnimating = true
            }
        }
    }

    private var micButton: some View {
        Button(action: onTap) {
            ZStack {
                // Glow ring (visible only when recording)
                if isRecording {
                    Circle()
                        .stroke(VoceDesign.accent, lineWidth: VoceDesign.borderHeavy)
                        .frame(width: VoceDesign.micButtonGlowSize, height: VoceDesign.micButtonGlowSize)
                        .opacity(reduceMotion ? VoceDesign.opacityDisabled : (glowAnimating ? VoceDesign.opacityGlowMax : VoceDesign.opacityMuted))
                        .scaleEffect(reduceMotion ? 1.0 : (glowAnimating ? VoceDesign.micButtonGlowScale : 1.0))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationGlow).repeatForever(autoreverses: true),
                            value: glowAnimating
                        )
                }

                // Main circle
                Circle()
                    .fill(isRecording ? VoceDesign.accent : VoceDesign.surface)
                    .frame(width: VoceDesign.micButtonSize, height: VoceDesign.micButtonSize)
                    .shadowStyle(isRecording ? .recording : .idle)
                    .overlay(
                        Circle()
                            .stroke(
                                isRecording ? Color.clear : VoceDesign.border,
                                lineWidth: VoceDesign.borderNormal
                            )
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: VoceDesign.animationNormal, dampingFraction: 0.8),
                        value: isRecording
                    )

                // Icon / progress overlay
                ZStack {
                    if isTranscribing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                            .tint(.white)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: VoceDesign.iconXL, weight: .medium))
                            .foregroundStyle(isRecording ? .white : VoceDesign.accent)
                            .transition(reduceMotion ? .opacity : .scale(scale: 1.1).combined(with: .opacity))
                    }
                }
                .animation(
                    reduceMotion ? nil : .spring(response: VoceDesign.animationNormal, dampingFraction: 0.8),
                    value: isTranscribing
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
        .accessibilityValue(micAccessibilityValue)
    }

    private var micAccessibilityLabel: String {
        if isRecording { return "Microphone, recording" }
        if isTranscribing { return "Microphone, transcribing" }
        return "Microphone"
    }

    private var micAccessibilityHint: String {
        if isTranscribing { return "Transcription in progress" }
        if isRecording { return "Tap to stop recording" }
        return "Tap to start hands-free recording"
    }

    private var micAccessibilityValue: String {
        if isRecording { return "Recording" }
        if isTranscribing { return "Transcribing" }
        if handsFreeOn { return "Hands-free active" }
        return "Idle"
    }
}
