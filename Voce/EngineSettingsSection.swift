import SwiftUI
import VoceKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    @State private var testResult: String?
    @State private var testResultIsError = false
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            settingsCard("Engine") {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Apple Speech")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                    Text("Voce now uses Apple Speech for the final transcript and keeps Apple live preview for immediate feedback.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Locale")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                    TextField("en-US", text: $preferences.dictation.localeIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Use a BCP-47 locale like `en-US` or `en-GB`. This locale is used for live preview and final transcription.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                HStack(spacing: VoceDesign.sm) {
                    Button {
                        runTestSetup()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: VoceDesign.iconMD, height: VoceDesign.iconMD)
                        } else {
                            Text("Test Apple Speech")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)

                    if let result = testResult {
                        Text(result)
                            .font(VoceDesign.caption())
                            .foregroundStyle(testResultIsError ? VoceDesign.error : VoceDesign.success)
                    }
                }

                Text("Voce now targets newer macOS releases and no longer requires any bundled model download.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
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
