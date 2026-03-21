import SwiftUI

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String
    @EnvironmentObject private var updaterController: UpdaterController

    var body: some View {
        Group {
            settingsCard("General") {
                Toggle("Launch at login", isOn: $preferences.general.launchAtLoginEnabled)
                Toggle("Show Dock icon", isOn: $preferences.general.showDockIcon)
                Toggle("Show onboarding on next launch", isOn: $preferences.general.showOnboarding)
                if !launchAtLoginWarning.isEmpty {
                    Text(launchAtLoginWarning)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.error)
                }
                Button("Re-run onboarding wizard") {
                    preferences.general.showOnboarding = true
                }
                .buttonStyle(.bordered)
            }

            settingsCardWithSubtitle(
                "Updates",
                subtitle: "Check for new Voce releases and install them through Sparkle."
            ) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!updaterController.canCheckForUpdates)
            }
        }
    }
}
