import AppKit
import SwiftUI

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String
    @EnvironmentObject private var updaterController: UpdaterController

    var body: some View {
        Group {
            settingsCard("Profile") {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    settingInlineLabel(
                        "Name",
                        help: "Shown in the Home greeting. Defaults to your Mac name."
                    )

                    TextField("Your name", text: displayNameBinding)
                        .textFieldStyle(.plain)
                        .font(VoceDesign.callout())
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.vertical, VoceDesign.sm)
                        .background {
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                .fill(VoceDesign.surfaceSecondary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                        .fill(.regularMaterial.opacity(0.18))
                                )
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                        )
                }
            }

            settingsCard("App") {
                Toggle(isOn: $preferences.general.launchAtLoginEnabled) {
                    settingInlineLabel(
                        "Launch on login",
                        help: "Open Voce automatically when you sign in."
                    )
                }

                if !launchAtLoginWarning.isEmpty {
                    Text(launchAtLoginWarning)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.error)
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.vertical, VoceDesign.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(VoceDesign.errorBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                .stroke(VoceDesign.errorBorder, lineWidth: VoceDesign.borderThin)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
                }

                Toggle(isOn: $preferences.general.showDockIcon) {
                    settingInlineLabel(
                        "Show in Dock",
                        help: "Keep Voce visible in the Dock."
                    )
                }

                Button {
                    preferences.general.showOnboarding = true
                } label: {
                    HStack(spacing: VoceDesign.xs) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 15, weight: .semibold))

                        Text("Show welcome")
                            .font(VoceDesign.callout())
                    }
                    .foregroundStyle(VoceDesign.warmAccentText)
                    .padding(.horizontal, VoceDesign.lg)
                    .padding(.vertical, VoceDesign.sm + 1)
                    .background(
                        Capsule()
                            .fill(VoceDesign.warmAccentFill)
                    )
                }
                .buttonStyle(.plain)
            }

            settingsCard("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates")
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Text("Get the latest version of Voce.")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }

                    Spacer()

                    Button("Check now") {
                        updaterController.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updaterController.canCheckForUpdates)
                }
            }
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: {
                let current = preferences.general.userName.trimmingCharacters(in: .whitespacesAndNewlines)
                return current.isEmpty ? macOSFirstName : current
            },
            set: { newValue in
                preferences.general.userName = newValue
            }
        )
    }

    private var macOSFirstName: String {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        return firstName.isEmpty ? "" : firstName
    }
}
