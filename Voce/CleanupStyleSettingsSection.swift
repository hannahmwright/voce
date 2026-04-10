import AppKit
import SwiftUI
import VoceKit

struct CleanupStyleSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences
    let selectedSection: StyleSection
    @State private var showAddOverrideSheet = false
    @State private var newStyleBundleID: String = ""
    @State private var newStyleProfile: StyleProfile = .init(
        name: "App Override",
        tone: .natural,
        structureMode: .paragraph,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    var body: some View {
        Group {
            switch selectedSection {
            case .defaultStyle:
                defaultStyleSection
            case .appOverrides:
                appOverridesSection
            }
        }
    }

    private var defaultStyleSection: some View {
        settingsCardWithSubtitle(
            "Default style",
            subtitle: "How Voce cleans up text unless an app override takes over."
        ) {
            styleMenuRow(
                "Format",
                description: "How dictated text is shaped by default.",
                value: $preferences.globalStyleProfile.structureMode
            )

            styleMenuRow(
                "Cleanup",
                description: "How aggressively Voce removes filler words like um and like.",
                value: $preferences.globalStyleProfile.fillerPolicy
            )

            styleMenuRow(
                "Slash commands",
                description: "Whether leading slash commands stay raw in coding tools.",
                value: $preferences.globalStyleProfile.commandPolicy
            )
        }
    }

    private var appOverridesSection: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack(spacing: VoceDesign.xs) {
                Text("App overrides")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)

                HelpBubbleButton(text: "Give one app a different cleanup style.")

                Spacer(minLength: 0)

                Button {
                    primeOverrideDraft()
                    showAddOverrideSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(VoceDesign.warmAccentFill)
                        )
                }
                .buttonStyle(.plain)
                .disabled(availableAppBundleIDs.isEmpty)
                .opacity(availableAppBundleIDs.isEmpty ? 0.45 : 1)
                .popover(isPresented: $showAddOverrideSheet, arrowEdge: .top) {
                    addOverrideSheet
                }
            }

            settingsSubcard {
                subsectionLabel("Saved")

                if preferences.appStyleProfiles.isEmpty {
                    Text("No app overrides yet.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                } else {
                    VStack(spacing: VoceDesign.sm) {
                        ForEach(preferences.appStyleProfiles.keys.sorted(), id: \.self) { bundleID in
                            overrideRow(bundleID: bundleID, profile: preferences.appStyleProfiles[bundleID])
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private func styleMenuRow<T: Hashable & CaseIterable & RawRepresentable>(
        _ title: String,
        description: String,
        value: Binding<T>
    ) -> some View where T.RawValue == String {
        settingsSubcard {
            HStack(spacing: VoceDesign.md) {
                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                    settingInlineLabel(title, help: description)
                    Text(readableValue(value.wrappedValue))
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer(minLength: 0)

                Picker("", selection: value) {
                    ForEach(Array(T.allCases), id: \.self) { option in
                        Text(readableValue(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func menuTile<T: Hashable & CaseIterable & RawRepresentable>(
        title: String,
        selection: Binding<T>,
        label: String
    ) -> some View where T.RawValue == String {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text(title)
                .font(VoceDesign.labelEmphasis())
                .textCase(.uppercase)
                .foregroundStyle(VoceDesign.textSecondary)

            Menu {
                ForEach(Array(T.allCases), id: \.self) { option in
                    Button(readableValue(option)) {
                        selection.wrappedValue = option
                    }
                }
            } label: {
                HStack(spacing: VoceDesign.sm) {
                    Text(label)
                        .font(VoceDesign.font(size: 19, weight: .medium))
                        .lineLimit(1)
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
                .foregroundStyle(VoceDesign.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2, style: .continuous)
                    .fill(VoceDesign.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2, style: .continuous)
                            .fill(.regularMaterial.opacity(0.12))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2)
                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2))
            .accessibilityLabel(title)
            .accessibilityValue(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
        .background(VoceDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private func overrideSummary(for profile: StyleProfile?) -> String {
        guard let profile else { return "Style" }
        return [
            structureLabel(profile.structureMode),
            fillerLabel(profile.fillerPolicy),
            commandLabel(profile.commandPolicy)
        ].joined(separator: " · ")
    }

    private func overrideRow(bundleID: String, profile: StyleProfile?) -> some View {
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

            Text(overrideSummary(for: profile))
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
                .lineLimit(1)

            Button("Remove", role: .destructive) {
                preferences.appStyleProfiles.removeValue(forKey: bundleID)
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

    private func readableValue<T: RawRepresentable>(_ value: T) -> String where T.RawValue == String {
        switch value.rawValue {
        case "passthrough":
            return "Keep raw"
        case "transform":
            return "Format"
        default:
            return value.rawValue.capitalized
        }
    }

    private func structureLabel(_ mode: StructureMode) -> String {
        readableValue(mode)
    }

    private func fillerLabel(_ policy: FillerPolicy) -> String {
        readableValue(policy)
    }

    private func commandLabel(_ policy: CommandPolicy) -> String {
        readableValue(policy)
    }

    private func subsectionLabel(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.labelEmphasis())
            .textCase(.uppercase)
            .foregroundStyle(VoceDesign.textSecondary)
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

    private func primeOverrideDraft() {
        newStyleBundleID = currentFrontmostBundleID ?? availableAppBundleIDs.first ?? ""
        newStyleProfile = .init(
            name: "App Override",
            tone: .natural,
            structureMode: .paragraph,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        )
    }

    private func addOverride() {
        let bundleID = newStyleBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        preferences.appStyleProfiles[bundleID] = newStyleProfile
        showAddOverrideSheet = false
        newStyleBundleID = ""
        newStyleProfile = .init(
            name: "App Override",
            tone: .natural,
            structureMode: .paragraph,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        )
    }

    private var addOverrideSheet: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack {
                Text("Add override")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer(minLength: 0)

                Button("Cancel") {
                    showAddOverrideSheet = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.textSecondary)
            }

            settingsSubcard {
                subsectionLabel("App")

                HStack(spacing: VoceDesign.sm) {
                    Menu {
                        ForEach(availableAppBundleIDs, id: \.self) { bundleID in
                            Button {
                                newStyleBundleID = bundleID
                            } label: {
                                HStack(spacing: VoceDesign.sm) {
                                    appIconView(for: bundleID)
                                    Text(appDisplayName(for: bundleID))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: VoceDesign.sm) {
                            if !newStyleBundleID.isEmpty {
                                appIconView(for: newStyleBundleID)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                if newStyleBundleID.isEmpty {
                                    Text("Select app")
                                        .font(VoceDesign.callout())
                                        .foregroundStyle(VoceDesign.textPrimary)
                                } else {
                                    Text(appDisplayName(for: newStyleBundleID))
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
                        newStyleBundleID = currentFrontmostBundleID ?? newStyleBundleID
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

                if !newStyleBundleID.isEmpty {
                    Text(newStyleBundleID)
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
                subsectionLabel("Style")

                HStack(spacing: VoceDesign.sm) {
                    menuTile(
                        title: "Format",
                        selection: $newStyleProfile.structureMode,
                        label: structureLabel(newStyleProfile.structureMode)
                    )

                    menuTile(
                        title: "Cleanup",
                        selection: $newStyleProfile.fillerPolicy,
                        label: fillerLabel(newStyleProfile.fillerPolicy)
                    )

                    menuTile(
                        title: "Slash",
                        selection: $newStyleProfile.commandPolicy,
                        label: commandLabel(newStyleProfile.commandPolicy)
                    )
                }
            }

            HStack {
                Spacer(minLength: 0)

                Button("Add") {
                    addOverride()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newStyleBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 620)
        .padding(VoceDesign.lg)
        .background(VoceDesign.surface)
    }
}
