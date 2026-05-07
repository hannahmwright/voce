import AppKit
import SwiftUI
import VoceKit

struct LexiconSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences

    @State private var editingCorrection: LexiconEditDraft?

    private var visibleCorrectionGroups: [LexiconCorrectionGroup] {
        let grouped = Dictionary(grouping: preferences.visibleLexiconEntries) { entry in
            LexiconCorrectionGroup.Key(preferred: entry.preferred, scopeID: LexiconCorrectionGroup.scopeID(for: entry.scope))
        }

        return grouped.map { key, entries in
            LexiconCorrectionGroup(
                preferred: key.preferred,
                scope: entries.first?.scope ?? .global,
                entries: entries
            )
        }
        .sorted { lhs, rhs in
            let preferredOrder = lhs.preferred.localizedCaseInsensitiveCompare(rhs.preferred)
            if preferredOrder != .orderedSame {
                return preferredOrder == .orderedAscending
            }
            return lhs.heardSummary.localizedCaseInsensitiveCompare(rhs.heardSummary) == .orderedAscending
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
            } else {
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
                    if visibleCorrectionGroups.isEmpty {
                        Text("Add a fix like “Chat GBT” to “ChatGPT”.")
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textSecondary)
                    } else {
                        correctionsTable
                    }
                }
            }
        }
        .cardStyle()
    }

    private var correctionsTable: some View {
        VStack(spacing: 0) {
            correctionsTableHeader

            ForEach(visibleCorrectionGroups.indices, id: \.self) { index in
                let group = visibleCorrectionGroups[index]
                correctionRow(group)

                if index != visibleCorrectionGroups.count - 1 {
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

    private func correctionRow(_ group: LexiconCorrectionGroup) -> some View {
        HStack(spacing: VoceDesign.md) {
            Button {
                editingCorrection = LexiconEditDraft(group: group)
            } label: {
                HStack(spacing: VoceDesign.md) {
                    Text(group.preferred)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

                    Text(group.heardSummary)
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

                    scopeDescription(for: group.scope)
                        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                preferences.lexiconEntries.removeAll { entry in
                    group.entries.contains(entry)
                }
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
        let terms = normalizedLexiconTerms(from: draft.heardTerms)
        let preferred = draft.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, !preferred.isEmpty else { return }

        let scopes: [Scope]
        if draft.isGlobal {
            scopes = [.global]
        } else {
            scopes = draft.selectedBundleIDs.sorted().map { .app(bundleID: $0) }
        }

        deleteCorrection(draft)

        for scope in scopes {
            for term in terms {
                let newEntry = LexiconEntry(term: term, preferred: preferred, scope: scope)
                if let existingIndex = preferences.lexiconEntries.firstIndex(where: {
                    $0.term.caseInsensitiveCompare(newEntry.term) == .orderedSame && $0.scope == newEntry.scope
                }) {
                    preferences.lexiconEntries[existingIndex] = newEntry
                } else {
                    preferences.lexiconEntries.append(newEntry)
                }
            }
        }

        editingCorrection = nil
    }

    private func deleteCorrection(_ draft: LexiconEditDraft) {
        if !draft.originalEntries.isEmpty {
            preferences.lexiconEntries.removeAll {
                draft.originalEntries.contains($0)
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

private struct LexiconCorrectionGroup: Identifiable {
    struct Key: Hashable {
        let preferred: String
        let scopeID: String
    }

    var id: String {
        "\(preferred.lowercased())|\(Self.scopeID(for: scope))"
    }

    let preferred: String
    let scope: Scope
    let entries: [LexiconEntry]

    var heardTerms: [String] {
        entries
            .map(\.term)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var heardSummary: String {
        heardTerms.joined(separator: ", ")
    }

    static func scopeID(for scope: Scope) -> String {
        switch scope {
        case .global:
            return "global"
        case .app(let bundleID):
            return "app:\(bundleID)"
        }
    }
}

private struct LexiconEditDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    let originalEntries: [LexiconEntry]
    var heardTerms: [String]
    var preferred: String
    var isGlobal: Bool
    var selectedBundleIDs: Set<String>

    init() {
        id = UUID()
        isNew = true
        originalEntries = []
        heardTerms = [""]
        preferred = ""
        isGlobal = true
        selectedBundleIDs = []
    }

    init(group: LexiconCorrectionGroup) {
        id = UUID()
        isNew = false
        originalEntries = group.entries
        heardTerms = group.heardTerms.isEmpty ? [""] : group.heardTerms
        preferred = group.preferred

        switch group.scope {
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
    @FocusState private var focusedHeardTermIndex: Int?

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
        !normalizedLexiconTerms(from: draft.heardTerms).isEmpty &&
        !draft.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (draft.isGlobal || !draft.selectedBundleIDs.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack(spacing: VoceDesign.sm) {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.textSecondary)
                .help("Back to corrections")

                Text(draft.isNew ? "Add correction" : "Edit correction")
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)
            }

            settingsSubcard {
                subsectionLabel("Phrase")

                VStack(spacing: VoceDesign.sm) {
                    VStack(alignment: .leading, spacing: VoceDesign.xs) {
                        Text("Voce heard")
                            .font(VoceDesign.captionEmphasis())
                            .foregroundStyle(VoceDesign.textSecondary)

                        VStack(spacing: VoceDesign.xs) {
                            ForEach(draft.heardTerms.indices, id: \.self) { index in
                                heardTermRow(at: index)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: VoceDesign.xs) {
                        Text("Use instead")
                            .font(VoceDesign.captionEmphasis())
                            .foregroundStyle(VoceDesign.textSecondary)

                        TextField("Should be", text: $draft.preferred)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()
                    }
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
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func heardTermRow(at index: Int) -> some View {
        let isLast = index == draft.heardTerms.indices.last

        return HStack(spacing: VoceDesign.xs) {
            TextField("Misheard phrase", text: bindingForHeardTerm(at: index))
                .textFieldStyle(.plain)
                .settingsInputChrome()
                .focused($focusedHeardTermIndex, equals: index)
                .submitLabel(.next)
                .onSubmit {
                    addHeardTermRow(focusNewRow: true)
                }

            Button {
                if isLast {
                    addHeardTermRow(focusNewRow: true)
                } else {
                    removeHeardTermRow(at: index)
                }
            } label: {
                Image(systemName: isLast ? "plus" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(isLast ? VoceDesign.warmAccentFill : VoceDesign.surfaceSecondary)
                    .foregroundStyle(isLast ? VoceDesign.warmAccentText : VoceDesign.textSecondary)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                    )
            }
            .buttonStyle(.plain)
            .help(isLast ? "Add another heard phrase" : "Remove heard phrase")
        }
    }

    private func bindingForHeardTerm(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard draft.heardTerms.indices.contains(index) else { return "" }
                return draft.heardTerms[index]
            },
            set: { newValue in
                guard draft.heardTerms.indices.contains(index) else { return }
                draft.heardTerms[index] = newValue
            }
        )
    }

    private func addHeardTermRow(focusNewRow: Bool = false) {
        draft.heardTerms.append("")

        if focusNewRow {
            let newIndex = draft.heardTerms.count - 1
            Task { @MainActor in
                focusedHeardTermIndex = newIndex
            }
        }
    }

    private func removeHeardTermRow(at index: Int) {
        guard draft.heardTerms.indices.contains(index), draft.heardTerms.count > 1 else { return }
        draft.heardTerms.remove(at: index)
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

private func normalizedLexiconTerms(from rawValues: [String]) -> [String] {
    var seen: Set<String> = []
    return rawValues
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { term in
            let key = term.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
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
