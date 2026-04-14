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
                        .settingsInputChrome()
                }
            }

            settingsCard("App") {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    settingInlineLabel(
                        "Appearance",
                        help: "Choose whether Voce follows macOS or stays in a fixed light or dark appearance."
                    )

                    Picker("Appearance", selection: $preferences.general.appearancePreference) {
                        ForEach(AppAppearancePreference.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

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

            settingsCard("Licenses") {
                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Portions of this software are based on steno by Ankit Cherian.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text("MIT License. Copyright (c) 2026 Ankit Cherian.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)

                    DisclosureGroup("View license notice") {
                        Text(Self.stenoMITLicense)
                            .font(VoceDesign.font(size: 11))
                            .foregroundStyle(VoceDesign.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoceDesign.sm)
                    }
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)
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

    private static let stenoMITLicense = """
    MIT License

    Copyright (c) 2026 Ankit Cherian

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
