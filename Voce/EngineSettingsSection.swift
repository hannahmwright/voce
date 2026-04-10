import SwiftUI
import VoceKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    @State private var testResult: String?
    @State private var testResultIsError = false
    @State private var isTesting = false

    var body: some View {
        settingsCard("Speech") {
            HStack(alignment: .center, spacing: VoceDesign.md) {
                speechBrandTile

                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                    HStack(spacing: VoceDesign.xs) {
                        Text("Apple Speech")
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Text("Built in")
                            .font(VoceDesign.label())
                            .foregroundStyle(VoceDesign.warmAccentText)
                            .padding(.horizontal, VoceDesign.sm)
                            .padding(.vertical, VoceDesign.xxs)
                            .background(VoceDesign.warmAccentFill)
                            .clipShape(Capsule())
                    }

                    Text("Uses Apple's speech stack for live transcription.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer()

                Button {
                    runTestSetup()
                } label: {
                    HStack(spacing: VoceDesign.sm) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                        }

                        Text(isTesting ? "Testing..." : "Run test")
                            .font(VoceDesign.captionEmphasis())
                    }
                    .foregroundStyle(VoceDesign.warmAccentText)
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm)
                    .background(
                        Capsule()
                            .fill(VoceDesign.warmAccentFill)
                    )
                    .shadowStyle(.sm)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
                .opacity(isTesting ? 0.9 : 1)
            }
            .padding(VoceDesign.md)
            .glassBackground(cornerRadius: VoceDesign.radiusMedium)

            if let result = testResult {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: testResultIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(testResultIsError ? VoceDesign.error : VoceDesign.success)

                    Text(result)
                        .font(VoceDesign.caption())
                        .foregroundStyle(testResultIsError ? VoceDesign.error : VoceDesign.success)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, VoceDesign.sm)
                .padding(.vertical, VoceDesign.sm)
                .background(testResultIsError ? VoceDesign.errorBackground : VoceDesign.successBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .stroke(testResultIsError ? VoceDesign.errorBorder : VoceDesign.successBorder, lineWidth: VoceDesign.borderThin)
                )
                .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
            }
        }
    }

    private var speechBrandTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.warmAccentFill)

            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(VoceDesign.warmAccentText)
        }
        .frame(width: 52, height: 52)
        .shadowStyle(.sm)
    }

    private func runTestSetup() {
        isTesting = true
        testResult = nil

        Task {
            let micStatus = PermissionDiagnostics.microphoneStatus()
            guard micStatus == .granted else {
                await MainActor.run {
                    testResult = "Microphone permission not granted."
                    testResultIsError = true
                    isTesting = false
                }
                return
            }

            do {
                let localeIdentifier = preferences.dictation.localeIdentifier
                try await Task.detached(priority: .userInitiated) {
                    try await AppleSpeechTranscriptionEngine.preflightCheck(
                        localeIdentifier: localeIdentifier
                    )
                }.value

                await MainActor.run {
                    testResult = "Apple Speech is ready."
                    testResultIsError = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if testResult == "Apple Speech is ready." {
                            testResult = nil
                        }
                    }
                    isTesting = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    testResult = "Apple Speech test cancelled."
                    testResultIsError = true
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Apple Speech setup failed: \(error.localizedDescription)"
                    testResultIsError = true
                    isTesting = false
                }
            }
        }
    }
}
