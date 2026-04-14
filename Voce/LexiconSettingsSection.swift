import AppKit
import SwiftUI
import VoceKit

struct LexiconSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences

    @State private var editingCorrection: LexiconEditDraft?

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
            lexiconAppDisplayName(for: lhs).localizedCaseInsensitiveCompare(lexiconAppDisplayName(for: rhs)) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack(spacing: VoceDesign.xs) {
                Text("Corrections")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)

                HelpBubbleButton(text: "Replace words that speech gets wrong.")

                Spacer(minLength: 0)

                Button {
                    editingCorrection = LexiconEditDraft()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(VoceDesign.warmAccentFill)
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                        )
                }
                .buttonStyle(.plain)
                .help("Add correction")
            }

            settingsSubcard {
                if visibleEntries.isEmpty {
                        Text("Add a fix like “Chat GBT” to “ChatGPT”.")
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textSecondary)
                    } else {
                        correctionsTable
                    }
                }
        }
        .cardStyle()
        .overlay {
            if let draft = editingCorrection {
                LexiconEditSheet(
                    draft: draft,
                    availableAppBundleIDs: availableAppBundleIDs,
                    onCancel: {
                        editingCorrection = nil
                    },
                    onSave: { updatedDraft in
                        saveCorrection(updatedDraft)
                    },
                    onDelete: { draft in
                        deleteCorrection(draft)
                        editingCorrection = nil
                    }
                )
                .settingsModalPanel()
                .dismissOnOutsideClick {
                    editingCorrection = nil
                }
            }
        }
    }

    private var correctionsTable: some View {
        VStack(spacing: 0) {
            correctionsTableHeader

            ForEach(visibleEntries.indices, id: \.self) { index in
                let entry = visibleEntries[index]
                correctionRow(entry)

                if index != visibleEntries.count - 1 {
                    Divider()
                        .padding(.leading, VoceDesign.sm)
                }
            }
        }
        .background(VoceDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private var correctionsTableHeader: some View {
        HStack(spacing: VoceDesign.md) {
            Text("Use instead")
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text("Voce heard")
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text("Scope")
                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            Text("")
                .frame(width: 32)
        }
        .font(VoceDesign.labelEmphasis())
        .textCase(.uppercase)
        .foregroundStyle(VoceDesign.textPrimary)
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
        .background(VoceDesign.surface)
    }

    private func correctionRow(_ entry: LexiconEntry) -> some View {
        HStack(spacing: VoceDesign.md) {
            Button {
                editingCorrection = LexiconEditDraft(entry: entry)
            } label: {
                HStack(spacing: VoceDesign.md) {
                    Text(entry.preferred)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

                    Text(entry.term)
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

                    scopeDescription(for: entry.scope)
                        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                preferences.lexiconEntries.removeAll { $0 == entry }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoceDesign.textSecondary)
            .frame(width: 32)
            .help("Delete correction")
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
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
                lexiconAppIconView(for: bundleID, size: 14)

                Text(lexiconAppDisplayName(for: bundleID))
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func saveCorrection(_ draft: LexiconEditDraft) {
        let term = draft.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = draft.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !preferred.isEmpty else { return }

        let scopes: [Scope]
        if draft.isGlobal {
            scopes = [.global]
        } else {
            scopes = draft.selectedBundleIDs.sorted().map { .app(bundleID: $0) }
        }

        deleteCorrection(draft)

        for scope in scopes {
            let newEntry = LexiconEntry(term: term, preferred: preferred, scope: scope)
            if let existingIndex = preferences.lexiconEntries.firstIndex(where: {
                $0.term.caseInsensitiveCompare(newEntry.term) == .orderedSame && $0.scope == newEntry.scope
            }) {
                preferences.lexiconEntries[existingIndex] = newEntry
            } else {
                preferences.lexiconEntries.append(newEntry)
            }
        }

        editingCorrection = nil
    }

    private func deleteCorrection(_ draft: LexiconEditDraft) {
        if let originalTerm = draft.originalTerm,
           let originalScope = draft.originalScope {
            preferences.lexiconEntries.removeAll {
                $0.term == originalTerm && $0.scope == originalScope
            }
        }
    }

    private func subsectionLabel(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.labelEmphasis())
            .textCase(.uppercase)
            .foregroundStyle(VoceDesign.textSecondary)
    }

}

private struct LexiconEditDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    let originalTerm: String?
    let originalScope: Scope?
    var term: String
    var preferred: String
    var isGlobal: Bool
    var selectedBundleIDs: Set<String>

    init() {
        id = UUID()
        isNew = true
        originalTerm = nil
        originalScope = nil
        term = ""
        preferred = ""
        isGlobal = true
        selectedBundleIDs = []
    }

    init(entry: LexiconEntry) {
        id = UUID()
        isNew = false
        originalTerm = entry.term
        originalScope = entry.scope
        term = entry.term
        preferred = entry.preferred

        switch entry.scope {
        case .global:
            isGlobal = true
            selectedBundleIDs = []
        case .app(let bundleID):
            isGlobal = false
            selectedBundleIDs = [bundleID]
        }
    }
}

private struct LexiconEditSheet: View {
    @State private var draft: LexiconEditDraft
    @State private var appSearchText = ""

    let availableAppBundleIDs: [String]
    let onCancel: () -> Void
    let onSave: (LexiconEditDraft) -> Void
    let onDelete: (LexiconEditDraft) -> Void

    init(
        draft: LexiconEditDraft,
        availableAppBundleIDs: [String],
        onCancel: @escaping () -> Void,
        onSave: @escaping (LexiconEditDraft) -> Void,
        onDelete: @escaping (LexiconEditDraft) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.availableAppBundleIDs = availableAppBundleIDs
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var filteredAppBundleIDs: [String] {
        let query = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableAppBundleIDs }

        return availableAppBundleIDs.filter { bundleID in
            lexiconAppDisplayName(for: bundleID).localizedCaseInsensitiveContains(query) ||
            bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    private var canSave: Bool {
        !draft.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (draft.isGlobal || !draft.selectedBundleIDs.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            Text(draft.isNew ? "Add correction" : "Edit correction")
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textPrimary)

            settingsSubcard {
                subsectionLabel("Phrase")

                VStack(spacing: VoceDesign.sm) {
                    TextField("Misheard", text: $draft.term)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()

                    TextField("Should be", text: $draft.preferred)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }
            }

            settingsSubcard {
                subsectionLabel("Apps")

                Picker("Scope", selection: $draft.isGlobal) {
                    Text("All apps").tag(true)
                    Text("Specific apps").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.isGlobal) { _, isGlobal in
                    if isGlobal {
                        draft.selectedBundleIDs.removeAll()
                        appSearchText = ""
                    }
                }

                if !draft.isGlobal {
                    selectedAppsRow

                    TextField("Search apps", text: $appSearchText)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()

                    appSelectionList

                    if draft.selectedBundleIDs.isEmpty {
                        Text(availableAppBundleIDs.isEmpty ? "No recent apps yet." : "Pick one or more apps.")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }
                }
            }

            HStack {
                if !draft.isNew {
                    Button {
                        onDelete(draft)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoceDesign.error)
                    .help("Delete correction")
                }

                Spacer(minLength: 0)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(VoceDesign.textSecondary)

                Button(draft.isNew ? "Add" : "Save") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(VoceDesign.xl)
        .frame(width: 560)
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
                                Image(systemName: draft.selectedBundleIDs.contains(bundleID) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(draft.selectedBundleIDs.contains(bundleID) ? VoceDesign.warmAccentText : VoceDesign.textSecondary)

                                lexiconAppIconView(for: bundleID)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lexiconAppDisplayName(for: bundleID))
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
                                    .fill(draft.selectedBundleIDs.contains(bundleID) ? VoceDesign.warmAccentFill.opacity(0.55) : Color.clear)
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

    private var selectedAppsRow: some View {
        Group {
            if draft.selectedBundleIDs.isEmpty {
                Color.clear
                    .frame(height: 32)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VoceDesign.xs) {
                        ForEach(Array(draft.selectedBundleIDs).sorted { lexiconAppDisplayName(for: $0) < lexiconAppDisplayName(for: $1) }, id: \.self) { bundleID in
                            HStack(spacing: 6) {
                                lexiconAppIconView(for: bundleID, size: 14)
                                Text(lexiconAppDisplayName(for: bundleID))
                                    .font(VoceDesign.caption())
                                    .foregroundStyle(VoceDesign.textPrimary)

                                Button {
                                    draft.selectedBundleIDs.remove(bundleID)
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
                .frame(height: 32)
            }
        }
    }

    private func toggleBundleSelection(_ bundleID: String) {
        if draft.selectedBundleIDs.contains(bundleID) {
            draft.selectedBundleIDs.remove(bundleID)
        } else {
            draft.selectedBundleIDs.insert(bundleID)
        }
    }

    private func subsectionLabel(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.labelEmphasis())
            .textCase(.uppercase)
            .foregroundStyle(VoceDesign.textSecondary)
    }
}

private func lexiconAppDisplayName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
       let bundle = Bundle(url: url),
       let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
        return name
    }
    return bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
}

private func lexiconAppIcon(for bundleID: String) -> NSImage? {
    guard !bundleID.isEmpty,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
    }

    let icon = NSWorkspace.shared.icon(forFile: url.path)
    icon.size = NSSize(width: 18, height: 18)
    return icon
}

@ViewBuilder
private func lexiconAppIconView(for bundleID: String, size: CGFloat = 16) -> some View {
    if let icon = lexiconAppIcon(for: bundleID) {
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
