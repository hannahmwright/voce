import AppKit
import SwiftUI
import VoceKit

struct LexiconSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences

    @State private var showAddCorrectionPopover = false
    @State private var newTerm: String = ""
    @State private var newPreferred: String = ""
    @State private var newGlobal = true
    @State private var selectedBundleIDs: Set<String> = []
    @State private var appSearchText: String = ""

    private var visibleEntries: [LexiconEntry] {
        preferences.visibleLexiconEntries.sorted { lhs, rhs in
            lhs.term.localizedCaseInsensitiveCompare(rhs.term) == .orderedAscending
        }
    }

    private var availableAppBundleIDs: [String] {
        let seen = Set(
            controller.recentEntries
                .map(\.appBundleID)
                .filter { !$0.isEmpty && $0 != "unknown" }
        )

        return seen.sorted { lhs, rhs in
            appDisplayName(for: lhs).localizedCaseInsensitiveCompare(appDisplayName(for: rhs)) == .orderedAscending
        }
    }

    private var filteredAppBundleIDs: [String] {
        let query = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableAppBundleIDs }

        return availableAppBundleIDs.filter { bundleID in
            appDisplayName(for: bundleID).localizedCaseInsensitiveContains(query) ||
            bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: VoceDesign.md) {
                HStack(spacing: VoceDesign.xs) {
                    Text("Corrections")
                        .font(VoceDesign.heading3())
                        .foregroundStyle(VoceDesign.textPrimary)

                    HelpBubbleButton(text: "Replace words that speech gets wrong.")

                    Spacer(minLength: 0)

                    Button {
                        primeCorrectionDraft()
                        showAddCorrectionPopover = true
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
                }

                settingsSubcard {
                    if visibleEntries.isEmpty {
                        Text("Add a fix like “Chat GBT” to “ChatGPT”.")
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textSecondary)
                    } else {
                        subsectionLabel("Saved")

                        VStack(spacing: VoceDesign.sm) {
                            ForEach(visibleEntries.indices, id: \.self) { index in
                                let entry = visibleEntries[index]
                                correctionRow(entry)
                            }
                        }
                    }
                }
            }
            .cardStyle()

            if showAddCorrectionPopover {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showAddCorrectionPopover = false
                    }

                addCorrectionPopover
                    .padding(.top, 44)
                    .zIndex(1)
            }
        }
    }

    private func correctionRow(_ entry: LexiconEntry) -> some View {
        HStack(spacing: VoceDesign.sm) {
            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text("“\(entry.term)” → “\(entry.preferred)”")
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .lineLimit(1)

                scopeDescription(for: entry.scope)
            }

            Spacer(minLength: 0)

            Button("Remove", role: .destructive) {
                preferences.lexiconEntries.removeAll { $0 == entry }
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

    @ViewBuilder
    private func scopeDescription(for scope: Scope) -> some View {
        switch scope {
        case .global:
            Text("All apps")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        case .app(let bundleID):
            HStack(spacing: VoceDesign.xs) {
                appIconView(for: bundleID, size: 14)

                Text(appDisplayName(for: bundleID))
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var addCorrectionPopover: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack {
                Text("Add correction")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer(minLength: 0)

                Button("Cancel") {
                    showAddCorrectionPopover = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.textSecondary)
            }

            settingsSubcard {
                subsectionLabel("Phrase")

                VStack(spacing: VoceDesign.sm) {
                    TextField("Misheard", text: $newTerm)
                        .textFieldStyle(.roundedBorder)

                    TextField("Should be", text: $newPreferred)
                        .textFieldStyle(.roundedBorder)
                }
            }

            settingsSubcard {
                subsectionLabel("Apps")

                Picker("Scope", selection: $newGlobal) {
                    Text("All apps").tag(true)
                    Text("Specific apps").tag(false)
                }
                .pickerStyle(.segmented)
                    .onChange(of: newGlobal) { _, isGlobal in
                        if isGlobal {
                            selectedBundleIDs.removeAll()
                            appSearchText = ""
                        }
                    }

                if !newGlobal {
                    selectedAppsRow

                    TextField("Search apps", text: $appSearchText)
                        .textFieldStyle(.roundedBorder)

                    appSelectionList

                    if selectedBundleIDs.isEmpty {
                        Text(availableAppBundleIDs.isEmpty ? "No recent apps yet." : "Pick one or more apps.")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)

                Button("Save") {
                    saveCorrection()
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveDisabled)
            }
        }
        .frame(width: 560)
        .padding(VoceDesign.lg)
        .background(VoceDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private var appSelectionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                if filteredAppBundleIDs.isEmpty {
                    Text("No matching apps.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .padding(.horizontal, VoceDesign.sm)
                        .padding(.vertical, VoceDesign.sm)
                } else {
                    ForEach(filteredAppBundleIDs, id: \.self) { bundleID in
                        Button {
                            toggleBundleSelection(bundleID)
                        } label: {
                            HStack(spacing: VoceDesign.sm) {
                                Image(systemName: selectedBundleIDs.contains(bundleID) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selectedBundleIDs.contains(bundleID) ? VoceDesign.warmAccentText : VoceDesign.textSecondary)

                                appIconView(for: bundleID)

                                VStack(alignment: .leading, spacing: 1) {
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
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, VoceDesign.sm)
                            .padding(.vertical, VoceDesign.sm)
                            .background(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(selectedBundleIDs.contains(bundleID) ? VoceDesign.warmAccentFill.opacity(0.55) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(VoceDesign.sm)
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(CGFloat(max(filteredAppBundleIDs.count, 1)) * 58, 280))
        .background(VoceDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var selectedAppsWrap: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoceDesign.xs) {
                ForEach(Array(selectedBundleIDs).sorted { appDisplayName(for: $0) < appDisplayName(for: $1) }, id: \.self) { bundleID in
                    HStack(spacing: 6) {
                        appIconView(for: bundleID, size: 14)
                        Text(appDisplayName(for: bundleID))
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Button {
                            selectedBundleIDs.remove(bundleID)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(VoceDesign.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, VoceDesign.sm)
                    .padding(.vertical, VoceDesign.xs)
                    .background(VoceDesign.surfaceSecondary)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var selectedAppsRow: some View {
        Group {
            if selectedBundleIDs.isEmpty {
                Color.clear
                    .frame(height: 32)
            } else {
                selectedAppsWrap
                    .frame(height: 32)
            }
        }
    }

    private var saveDisabled: Bool {
        newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        newPreferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        (!newGlobal && selectedBundleIDs.isEmpty)
    }

    private func saveCorrection() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = newPreferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !preferred.isEmpty else { return }

        let scopes: [Scope]
        if newGlobal {
            scopes = [.global]
        } else {
            scopes = selectedBundleIDs.sorted().map { .app(bundleID: $0) }
        }

        for scope in scopes {
            let newEntry = LexiconEntry(term: term, preferred: preferred, scope: scope)
            if let existingIndex = preferences.lexiconEntries.firstIndex(where: { $0.term == newEntry.term && $0.scope == newEntry.scope }) {
                preferences.lexiconEntries[existingIndex] = newEntry
            } else {
                preferences.lexiconEntries.append(newEntry)
            }
        }

        newTerm = ""
        newPreferred = ""
        newGlobal = true
        selectedBundleIDs.removeAll()
        appSearchText = ""
        showAddCorrectionPopover = false
    }

    private func primeCorrectionDraft() {
        newTerm = ""
        newPreferred = ""
        newGlobal = true
        selectedBundleIDs.removeAll()
        appSearchText = ""
    }

    private func toggleBundleSelection(_ bundleID: String) {
        if selectedBundleIDs.contains(bundleID) {
            selectedBundleIDs.remove(bundleID)
        } else {
            selectedBundleIDs.insert(bundleID)
        }
    }

    private func subsectionLabel(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.labelEmphasis())
            .textCase(.uppercase)
            .foregroundStyle(VoceDesign.textSecondary)
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
}
