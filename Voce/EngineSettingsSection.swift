import AppKit
import SwiftUI
import VoceKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController

    @State private var localTestResult: String?
    @State private var localTestResultIsError = false
    @State private var isTestingLocal = false

    @State private var cloudTestResult: String?
    @State private var cloudTestResultIsError = false
    @State private var isTestingCloud = false
    @State private var apiKeyDraft = ""
    @State private var isEditingStoredAPIKey = false
    @State private var cloudStatusRefreshID = UUID()
    @State private var showAddAppOverrideSheet = false
    @State private var newAppOverrideBundleID = ""
    @State private var newAppOverridePreference: AppDictationEnginePreference = .cloud

    var body: some View {
        settingsCard("Speech") {
            engineRow

            if usesCloudConfiguration {
                cloudConfiguration
            }

            if cloudControlsUnlocked {
                appOverrideSection
            }

            diagnosticsRow
        }
    }

    // MARK: - Engine row

    private var engineRow: some View {
        HStack(alignment: .center, spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                HStack(spacing: VoceDesign.xs) {
                    Text("Dictation Engine")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)

                    if controller.isDevBuildWithCloudOptions {
                        Text("Dev")
                            .font(VoceDesign.label())
                            .foregroundStyle(VoceDesign.error)
                            .padding(.horizontal, VoceDesign.sm)
                            .padding(.vertical, VoceDesign.xxs)
                            .background(VoceDesign.errorBackground)
                            .clipShape(Capsule())
                    }
                }

                if !cloudControlsUnlocked {
                    Text("Apple Speech only. Cloud transcription is part of Voce Pro.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if cloudControlsUnlocked {
                Picker("Dictation Engine", selection: $preferences.dictation.engineMode) {
                    ForEach(DictationEngineMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                upgradeToProButton
            }
        }
    }

    private var upgradeToProButton: some View {
        Button {
            controller.openVoceCheckout(plan: .pro, billingCycle: .monthly)
        } label: {
            HStack(spacing: VoceDesign.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("Upgrade to Pro")
                    .font(VoceDesign.captionEmphasis())
            }
            .foregroundStyle(VoceDesign.warmAccentText)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.xs)
            .background(
                Capsule().fill(VoceDesign.warmAccentFill)
            )
        }
        .buttonStyle(.plain)
        .help("Open the Voce Pro checkout to enable cloud transcription.")
    }

    // MARK: - Cloud configuration

    private var cloudConfiguration: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            Toggle("Cloud refinement", isOn: $preferences.dictation.cloud.refinementEnabled)
                .tint(VoceDesign.warmAccentText)
                .disabled(!cloudControlsUnlocked)

            if controller.usesDirectCloudCredentials {
                Picker("API Key Source", selection: $preferences.dictation.cloud.apiKeySource) {
                    ForEach(CloudAPIKeySource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: preferences.dictation.cloud.apiKeySource) { _, _ in
                    isEditingStoredAPIKey = false
                    apiKeyDraft = ""
                }

                if preferences.dictation.cloud.apiKeySource == .keychain {
                    keychainKeyControls
                } else {
                    Text("Using `\(controller.cloudCredentialEnvironmentVariableName)` from environment.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
            } else {
                Text("Authenticated through your Voce account.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            resultBanner(cloudStatus.message, isError: cloudStatus.isError)
        }
    }

    @ViewBuilder
    private var keychainKeyControls: some View {
        if controller.hasStoredCloudAPIKey && !isEditingStoredAPIKey && apiKeyDraft.isEmpty {
            HStack(spacing: VoceDesign.sm) {
                Button("Replace key") {
                    isEditingStoredAPIKey = true
                }
                .buttonStyle(.borderedProminent)

                Button("Clear key", role: .destructive) {
                    clearCloudAPIKey()
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                SecureField("OpenAI API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: VoceDesign.sm) {
                    Button("Save key") {
                        saveCloudAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if controller.hasStoredCloudAPIKey {
                        Button("Cancel") {
                            apiKeyDraft = ""
                            isEditingStoredAPIKey = false
                        }
                        .buttonStyle(.bordered)

                        Button("Clear key", role: .destructive) {
                            clearCloudAPIKey()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsRow: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(spacing: VoceDesign.lg) {
                diagnosticButton(
                    label: isTestingLocal ? "Testing Apple Speech…" : "Test Apple Speech",
                    isWorking: isTestingLocal,
                    action: runLocalTestSetup
                )
                .disabled(isTestingLocal)

                if cloudControlsUnlocked && usesCloudConfiguration {
                    diagnosticButton(
                        label: isTestingCloud ? "Testing cloud…" : "Test cloud setup",
                        isWorking: isTestingCloud,
                        action: runCloudTestSetup
                    )
                    .disabled(isTestingCloud)
                }

                Spacer(minLength: 0)
            }

            if let result = localTestResult {
                resultBanner(result, isError: localTestResultIsError)
            }

            if let result = cloudTestResult {
                resultBanner(result, isError: cloudTestResultIsError)
            }
        }
    }

    private func diagnosticButton(
        label: String,
        isWorking: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: VoceDesign.xs) {
                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(VoceDesign.warmAccentText)
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(VoceDesign.caption())
            }
            .foregroundStyle(VoceDesign.warmAccentText)
        }
        .buttonStyle(.plain)
        .opacity(isWorking ? 0.7 : 1)
    }

    private var cloudStatus: CloudDictationAvailabilityStatus {
        _ = cloudStatusRefreshID
        return controller.cloudDictationStatus
    }

    private var usesCloudConfiguration: Bool {
        cloudControlsUnlocked && preferences.usesCloudDictationConfiguration
    }

    private var cloudControlsUnlocked: Bool {
        controller.canUseCloudDictation
    }

    private var appOverrideSection: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            HStack(spacing: VoceDesign.sm) {
                Text("App overrides")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer(minLength: 0)

                Button {
                    primeNewAppOverrideDraft()
                    showAddAppOverrideSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(VoceDesign.warmAccentFill)
                        )
                }
                .buttonStyle(.plain)
                .disabled(availableAppBundleIDs.isEmpty)
                .opacity(availableAppBundleIDs.isEmpty ? 0.45 : 1)
                .popover(isPresented: $showAddAppOverrideSheet, arrowEdge: .top) {
                    addAppOverrideSheet
                }
            }

            if preferences.appDictationEnginePreferences.isEmpty {
                Text("Pin specific apps to Local or Cloud.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            } else {
                VStack(spacing: VoceDesign.xs) {
                    ForEach(preferences.appDictationEnginePreferences.keys.sorted(), id: \.self) { bundleID in
                        appOverrideRow(bundleID: bundleID)
                    }
                }
            }
        }
    }

    private func appOverrideRow(bundleID: String) -> some View {
        HStack(spacing: VoceDesign.sm) {
            appIconView(for: bundleID, size: 18)

            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(appDisplayName(for: bundleID))
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .lineLimit(1)

                Text(bundleID)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Picker("", selection: appOverrideBinding(for: bundleID)) {
                ForEach(AppDictationEnginePreference.allCases, id: \.self) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Button("Remove", role: .destructive) {
                preferences.appDictationEnginePreferences.removeValue(forKey: bundleID)
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, VoceDesign.xs)
        .padding(.horizontal, VoceDesign.sm)
        .background(VoceDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private func resultBanner(_ result: String, isError: Bool) -> some View {
        HStack(spacing: VoceDesign.sm) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? VoceDesign.error : VoceDesign.success)

            Text(result)
                .font(VoceDesign.caption())
                .foregroundStyle(isError ? VoceDesign.error : VoceDesign.success)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
        .background(isError ? VoceDesign.errorBackground : VoceDesign.successBackground)
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .stroke(isError ? VoceDesign.errorBorder : VoceDesign.successBorder, lineWidth: VoceDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
    }

    private func appOverrideBinding(for bundleID: String) -> Binding<AppDictationEnginePreference> {
        Binding(
            get: {
                preferences.appDictationEnginePreferences[bundleID] ?? .followGlobal
            },
            set: { newValue in
                if newValue == .followGlobal {
                    preferences.appDictationEnginePreferences.removeValue(forKey: bundleID)
                } else {
                    preferences.appDictationEnginePreferences[bundleID] = newValue
                }
            }
        )
    }

    private var currentFrontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private var availableAppBundleIDs: [String] {
        var bundleIDs = recentAppBundleIDs

        if let currentFrontmostBundleID,
           !currentFrontmostBundleID.isEmpty,
           currentFrontmostBundleID != "unknown",
           !bundleIDs.contains(currentFrontmostBundleID) {
            bundleIDs.insert(currentFrontmostBundleID, at: 0)
        }

        return bundleIDs
    }

    private var recentAppBundleIDs: [String] {
        let seen = Set(
            controller.recentEntries
                .map(\.appBundleID)
                .filter { !$0.isEmpty && $0 != "unknown" }
        )

        return seen.sorted { lhs, rhs in
            appDisplayName(for: lhs).localizedCaseInsensitiveCompare(appDisplayName(for: rhs)) == .orderedAscending
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    @ViewBuilder
    private func appIconView(for bundleID: String, size: CGFloat = 16) -> some View {
        if let icon = appIcon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
        } else {
            Image(systemName: "app")
                .font(.system(size: max(11, size * 0.72), weight: .medium))
                .foregroundStyle(VoceDesign.textSecondary.opacity(0.75))
                .frame(width: size, height: size)
        }
    }

    private func primeNewAppOverrideDraft() {
        newAppOverrideBundleID = currentFrontmostBundleID ?? availableAppBundleIDs.first ?? ""
        newAppOverridePreference = preferences.dictation.engineMode == .cloud ? .local : .cloud
    }

    private func addAppOverride() {
        let bundleID = newAppOverrideBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }

        if newAppOverridePreference == .followGlobal {
            preferences.appDictationEnginePreferences.removeValue(forKey: bundleID)
        } else {
            preferences.appDictationEnginePreferences[bundleID] = newAppOverridePreference
        }

        showAddAppOverrideSheet = false
        newAppOverrideBundleID = ""
        newAppOverridePreference = .cloud
    }

    private var addAppOverrideSheet: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack {
                Text("Add engine override")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer(minLength: 0)

                Button("Cancel") {
                    showAddAppOverrideSheet = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.textSecondary)
            }

            settingsSubcard {
                Text("App")
                    .font(VoceDesign.labelEmphasis())
                    .textCase(.uppercase)
                    .foregroundStyle(VoceDesign.textSecondary)

                HStack(spacing: VoceDesign.sm) {
                    Menu {
                        ForEach(availableAppBundleIDs, id: \.self) { bundleID in
                            Button {
                                newAppOverrideBundleID = bundleID
                            } label: {
                                HStack(spacing: VoceDesign.sm) {
                                    appIconView(for: bundleID)
                                    Text(appDisplayName(for: bundleID))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: VoceDesign.sm) {
                            if !newAppOverrideBundleID.isEmpty {
                                appIconView(for: newAppOverrideBundleID)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                if newAppOverrideBundleID.isEmpty {
                                    Text("Select app")
                                        .font(VoceDesign.callout())
                                        .foregroundStyle(VoceDesign.textPrimary)
                                } else {
                                    Text(appDisplayName(for: newAppOverrideBundleID))
                                        .font(VoceDesign.callout())
                                        .foregroundStyle(VoceDesign.textPrimary)
                                        .lineLimit(1)

                                    Text("Recent apps")
                                        .font(VoceDesign.caption())
                                        .foregroundStyle(VoceDesign.textSecondary)
                                }
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(VoceDesign.textSecondary.opacity(0.9))
                                .frame(width: 22, height: 22)
                                .background(
                                    Circle()
                                        .fill(VoceDesign.surfaceSecondary)
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.vertical, 12)
                        .background(VoceDesign.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2)
                                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .disabled(availableAppBundleIDs.isEmpty)

                    Button {
                        newAppOverrideBundleID = currentFrontmostBundleID ?? newAppOverrideBundleID
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VoceDesign.warmAccentText)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(VoceDesign.warmAccentFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(currentFrontmostBundleID == nil)
                    .opacity(currentFrontmostBundleID == nil ? 0.45 : 1)
                    .help("Use current app")
                }

                if !newAppOverrideBundleID.isEmpty {
                    Text(newAppOverrideBundleID)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(availableAppBundleIDs.isEmpty ? "No recent apps yet." : "Pick an app you have already dictated into.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
            }

            settingsSubcard {
                Text("Engine")
                    .font(VoceDesign.labelEmphasis())
                    .textCase(.uppercase)
                    .foregroundStyle(VoceDesign.textSecondary)

                Picker("App engine", selection: $newAppOverridePreference) {
                    ForEach(AppDictationEnginePreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Spacer(minLength: 0)

                Button("Add") {
                    addAppOverride()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAppOverrideBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 560)
        .padding(VoceDesign.lg)
        .background(VoceDesign.surface)
    }

    private func runLocalTestSetup() {
        isTestingLocal = true
        localTestResult = nil

        Task {
            let micStatus = PermissionDiagnostics.microphoneStatus()
            guard micStatus == .granted else {
                await MainActor.run {
                    localTestResult = "Microphone permission not granted."
                    localTestResultIsError = true
                    isTestingLocal = false
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
                    localTestResult = "Apple Speech is ready."
                    localTestResultIsError = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if localTestResult == "Apple Speech is ready." {
                            localTestResult = nil
                        }
                    }
                    isTestingLocal = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    localTestResult = "Apple Speech test cancelled."
                    localTestResultIsError = true
                    isTestingLocal = false
                }
            } catch {
                await MainActor.run {
                    localTestResult = "Apple Speech setup failed: \(error.localizedDescription)"
                    localTestResultIsError = true
                    isTestingLocal = false
                }
            }
        }
    }

    private func runCloudTestSetup() {
        isTestingCloud = true
        cloudTestResult = nil

        Task {
            do {
                let result = try await controller.runCloudDictationTest()
                await MainActor.run {
                    cloudTestResult = result
                    cloudTestResultIsError = false
                    cloudStatusRefreshID = UUID()
                    isTestingCloud = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    cloudTestResult = "Cloud dictation test cancelled."
                    cloudTestResultIsError = true
                    isTestingCloud = false
                }
            } catch {
                await MainActor.run {
                    cloudTestResult = error.localizedDescription
                    cloudTestResultIsError = true
                    cloudStatusRefreshID = UUID()
                    isTestingCloud = false
                }
            }
        }
    }

    private func saveCloudAPIKey() {
        do {
            try controller.saveCloudAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            isEditingStoredAPIKey = false
            cloudTestResult = "OpenAI API key saved."
            cloudTestResultIsError = false
            cloudStatusRefreshID = UUID()
        } catch {
            cloudTestResult = error.localizedDescription
            cloudTestResultIsError = true
        }
    }

    private func clearCloudAPIKey() {
        do {
            try controller.clearCloudAPIKey()
            apiKeyDraft = ""
            isEditingStoredAPIKey = false
            cloudTestResult = "OpenAI API key cleared."
            cloudTestResultIsError = false
            cloudStatusRefreshID = UUID()
        } catch {
            cloudTestResult = error.localizedDescription
            cloudTestResultIsError = true
        }
    }
}
