import SwiftUI
import StenoKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    @State private var testResult: String?
    @State private var testResultIsError = false
    @State private var isTesting = false
    @StateObject private var downloader = MoonshineModelDownloader()

    var body: some View {
        settingsCard("Engine") {
            Picker("Model", selection: $preferences.dictation.modelArch) {
                ForEach(MoonshineModelPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: preferences.dictation.modelArch) { newArch in
                preferences.dictation.modelDirectoryPath = MoonshineModelPaths.defaultModelDirectoryPath(for: newArch)
            }

            if MoonshineModelDownloader.isModelReady(preset: preferences.dictation.modelArch) {
                modelReadySection
            } else {
                modelDownloadSection
            }
        }
    }

    private var modelReadySection: some View {
        HStack(spacing: StenoDesign.sm) {
            Button {
                runTestSetup()
            } label: {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
                } else {
                    Text("Test Setup")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isTesting)
            .accessibilityLabel("Test Moonshine setup")

            if let result = testResult {
                Text(result)
                    .font(StenoDesign.caption())
                    .foregroundStyle(testResultIsError ? StenoDesign.error : StenoDesign.success)
            } else {
                HStack(spacing: StenoDesign.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StenoDesign.success)
                    Text("Model ready")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.success)
                }
            }
        }
    }

    private var modelDownloadSection: some View {
        VStack(alignment: .leading, spacing: StenoDesign.sm) {
            switch downloader.status {
            case .idle, .failed:
                if case .failed(let message) = downloader.status {
                    Text(message)
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.error)
                }
                Button("Download Model") {
                    downloader.download(preset: preferences.dictation.modelArch)
                }
                .buttonStyle(.bordered)
            case .downloading:
                ProgressView(value: downloader.overallProgress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Int(downloader.overallProgress * 100))%")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.textSecondary)
                    Spacer()
                    Button("Cancel") {
                        downloader.cancel()
                    }
                    .font(StenoDesign.caption())
                    .buttonStyle(.plain)
                    .foregroundStyle(StenoDesign.textSecondary)
                }
            case .completed:
                HStack(spacing: StenoDesign.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StenoDesign.success)
                    Text("Download complete")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.success)
                }
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
                let modelDirectoryPath = preferences.dictation.modelDirectoryPath
                let modelArch = preferences.dictation.modelArch
                try await Task.detached(priority: .userInitiated) {
                    try MoonshineTranscriptionEngine.preflightCheck(
                        modelDirectoryPath: modelDirectoryPath,
                        modelArch: modelArch
                    )
                }.value

                await MainActor.run {
                    testResult = "Moonshine model is ready."
                    testResultIsError = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if testResult == "Moonshine model is ready." {
                            testResult = nil
                        }
                    }
                    isTesting = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    testResult = "Moonshine test cancelled."
                    testResultIsError = true
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Failed to load Moonshine model: \(error.localizedDescription)"
                    testResultIsError = true
                    isTesting = false
                }
            }
        }
    }
}
