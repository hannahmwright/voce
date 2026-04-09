import SwiftUI
import VoceKit

struct CleanupStyleSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newStyleBundleID: String = ""
    @State private var newStyleProfile: StyleProfile = .init(
        name: "App Override",
        tone: .natural,
        structureMode: .paragraph,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    var body: some View {
        settingsCardWithSubtitle(
            "Cleanup Style",
            subtitle: "Deterministic local cleanup after transcription"
        ) {
            describedPicker(
                "Structure",
                description: "How the output text is formatted",
                selection: $preferences.globalStyleProfile.structureMode
            )

            describedPicker(
                "Filler removal",
                description: "How aggressively \u{201C}um\u{201D}, \u{201C}like\u{201D} are removed",
                selection: $preferences.globalStyleProfile.fillerPolicy
            )

            describedPicker(
                "IDE slash commands",
                description: "In IDEs, keep leading /commands unchanged",
                selection: $preferences.globalStyleProfile.commandPolicy
            )

            DisclosureGroup(
                "Per-app overrides (\(preferences.appStyleProfiles.count) configured)"
            ) {
                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    if preferences.appStyleProfiles.isEmpty {
                        Text("No app overrides yet. Add a bundle ID to customize cleanup per app.")
                            .foregroundStyle(VoceDesign.textSecondary)
                    } else {
                        ForEach(preferences.appStyleProfiles.keys.sorted(), id: \.self) { bundleID in
                            entryRow(
                                leading: bundleID,
                                trailing: preferences.appStyleProfiles[bundleID]?.name ?? "Profile"
                            ) {
                                preferences.appStyleProfiles.removeValue(forKey: bundleID)
                            }
                        }
                    }

                    Divider()

                    TextField("Bundle ID", text: $newStyleBundleID)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: VoceDesign.sm) {
                        enumPicker("Structure", selection: $newStyleProfile.structureMode)
                        enumPicker("Filler", selection: $newStyleProfile.fillerPolicy)
                    }
                    HStack(spacing: VoceDesign.sm) {
                        enumPicker("Slash Commands", selection: $newStyleProfile.commandPolicy)
                    }

                    HStack {
                        Spacer()
                        Button {
                            guard !newStyleBundleID.isEmpty else { return }
                            preferences.appStyleProfiles[newStyleBundleID] = newStyleProfile
                            newStyleBundleID = ""
                            newStyleProfile = .init(
                                name: "App Override",
                                tone: .natural,
                                structureMode: .paragraph,
                                fillerPolicy: .balanced,
                                commandPolicy: .transform
                            )
                        } label: {
                            Label("Add Override", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, VoceDesign.sm)
            }
        }
    }
}
