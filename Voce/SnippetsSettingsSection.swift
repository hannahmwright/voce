import SwiftUI
import VoceKit

struct SnippetsSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences
    let selectedSection: SnippetSection

    @State private var snippetSuggestions: [SnippetSuggestion] = []
    @State private var editingSnippet: SnippetEditDraft?

    private var builtInCommands: [VoiceCommand] {
        preferences.voiceCommands.filter(\.isBuiltIn)
    }

    private var groupedSnippets: [SnippetGroup] {
        let groups = Dictionary(grouping: preferences.snippets) { snippet in
            normalizedGroupName(snippet.groupName)
        }

        return groups
            .map { name, snippets in
                SnippetGroup(
                    name: name,
                    snippets: snippets.sorted {
                        if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                            return $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending
                        }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            switch selectedSection {
            case .custom:
                customSection
            case .suggestions:
                suggestionsSection
            case .builtIn:
                builtInSection
            }
        }
        .task { await refreshSnippetSuggestions() }
        .overlay {
            if let draft = editingSnippet {
                SnippetEditSheet(
                    draft: draft,
                    onCancel: {
                        editingSnippet = nil
                    },
                    onSave: { updatedDraft in
                        saveSnippet(updatedDraft)
                    },
                    onDelete: { id in
                        preferences.snippets.removeAll { $0.id == id }
                        editingSnippet = nil
                    }
                )
                .settingsModalPanel()
                .dismissOnOutsideClick {
                    editingSnippet = nil
                }
            }
        }
    }

    private var customSection: some View {
        settingsCardWithSubtitle(
            "Custom shortcuts",
            subtitle: "Your own spoken phrases."
        ) {
            settingsSubcard {
                HStack(spacing: VoceDesign.sm) {
                    Spacer(minLength: 0)

                    Button {
                        editingSnippet = SnippetEditDraft()
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
                    .help("Add shortcut")
                }

                if preferences.snippets.isEmpty {
                    Text("Nothing here yet. Try “on my way” to “On my way!”.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                } else {
                    snippetTable
                }
            }
        }
    }

    private var snippetTable: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            ForEach(groupedSnippets) { group in
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text(group.name)
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    VStack(spacing: 0) {
                        snippetTableHeader

                        ForEach(group.snippets) { snippet in
                            snippetTableRow(snippet)

                            if snippet.id != group.snippets.last?.id {
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
            }
        }
    }

    private var snippetTableHeader: some View {
        HStack(spacing: VoceDesign.md) {
            Text("Name")
                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            Text("Thing you say")
                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            Text("Text inserted")
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
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

    private func snippetTableRow(_ snippet: Snippet) -> some View {
        HStack(spacing: VoceDesign.md) {
            Button {
                editingSnippet = SnippetEditDraft(snippet: snippet)
            } label: {
                HStack(spacing: VoceDesign.md) {
                    Text(snippet.name)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)

                    Text(snippet.trigger)
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)

                    Text(snippet.expansion)
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                preferences.snippets.removeAll { $0.id == snippet.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoceDesign.textSecondary)
            .frame(width: 32)
            .help("Delete shortcut")
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
    }

    private var suggestionsSection: some View {
        settingsCardWithSubtitle(
            "Suggested shortcuts",
            subtitle: "Shorter phrases for things you say a lot."
        ) {
            settingsSubcard {
                if snippetSuggestions.isEmpty {
                    Text("Nothing useful to suggest right now.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                } else {
                    VStack(spacing: VoceDesign.sm) {
                        ForEach(snippetSuggestions.prefix(8)) { suggestion in
                            HStack(spacing: VoceDesign.sm) {
                                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                                    HStack(spacing: VoceDesign.sm) {
                                        keyboardKeyCap(suggestion.suggestedTrigger, systemImage: "text.cursor")
                                        Text("→")
                                            .font(VoceDesign.caption())
                                            .foregroundStyle(VoceDesign.textSecondary)
                                        Text("“\(suggestion.phrase)”")
                                            .font(VoceDesign.callout())
                                            .lineLimit(1)
                                    }

                                    Text("\(suggestion.occurrences)x repeated")
                                        .font(VoceDesign.caption())
                                        .foregroundStyle(VoceDesign.textSecondary)
                                }

                                Spacer(minLength: 0)

                                Button("Add") {
                                    Task {
                                        await controller.acceptSnippetSuggestion(suggestion)
                                        await refreshSnippetSuggestions()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Dismiss") {
                                    Task {
                                        await controller.dismissSnippetSuggestion(suggestion)
                                        await refreshSnippetSuggestions()
                                    }
                                }
                                .buttonStyle(.link)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, VoceDesign.sm)
                            .padding(.vertical, VoceDesign.sm)
                            .background(VoceDesign.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                            )
                        }
                    }
                }
            }
        }
    }

    private var builtInSection: some View {
        settingsCardWithSubtitle(
            "Built-in phrases",
            subtitle: "Dictation controls for punctuation, spacing, and editing."
        ) {
            settingsSubcard {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoceDesign.textSecondary)

                    Text("These work out of the box and can be turned on or off.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
            }

            settingsSubcard {
                VStack(spacing: VoceDesign.sm) {
                    ForEach(builtInCommands) { command in
                        builtInRow(command)
                    }
                }
            }
        }
    }

    private func subsectionLabel(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.labelEmphasis())
            .textCase(.uppercase)
            .foregroundStyle(VoceDesign.textSecondary)
    }

    private func builtInRow(_ command: VoiceCommand) -> some View {
        HStack(spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(command.trigger)
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(actionLabel(command.action))
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            Spacer(minLength: 0)

            Toggle(
                "",
                isOn: Binding(
                    get: { command.isEnabled },
                    set: { newValue in
                        if let idx = preferences.voiceCommands.firstIndex(where: { $0.id == command.id }) {
                            preferences.voiceCommands[idx].isEnabled = newValue
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
        .background(VoceDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }

    private func actionLabel(_ action: VoiceCommand.Action) -> String {
        switch action {
        case .insertText(let text):
            let display = text
                .replacingOccurrences(of: "\n\n", with: "\\u{00B6}\\u{00B6}")
                .replacingOccurrences(of: "\n", with: "\\u{00B6}")
                .replacingOccurrences(of: "\t", with: "\\u{21E5}")
            return display.isEmpty ? "(empty)" : display
        case .deletePrevious:
            return "Delete previous sentence"
        }
    }

    private func saveSnippet(_ draft: SnippetEditDraft) {
        let trigger = draft.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = draft.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }

        let updatedSnippet = Snippet(
            id: draft.id,
            name: draft.name,
            trigger: trigger,
            expansion: expansion,
            scope: draft.scope,
            groupName: draft.groupName
        )

        if let index = preferences.snippets.firstIndex(where: { $0.id == draft.id }) {
            preferences.snippets[index] = updatedSnippet
        } else if let existingIndex = preferences.snippets.firstIndex(where: {
            $0.trigger.caseInsensitiveCompare(updatedSnippet.trigger) == .orderedSame && $0.scope == updatedSnippet.scope
        }) {
            var replacement = updatedSnippet
            replacement.id = preferences.snippets[existingIndex].id
            preferences.snippets[existingIndex] = replacement
        } else {
            preferences.snippets.append(updatedSnippet)
        }
        editingSnippet = nil
    }

    private func refreshSnippetSuggestions() async {
        let existingTriggers = Set(controller.preferences.snippets.map(\.trigger))
        snippetSuggestions = await controller.fetchSnippetSuggestions(excluding: existingTriggers)
    }
}

private struct SnippetGroup: Identifiable {
    var id: String { name }
    let name: String
    let snippets: [Snippet]
}

private struct SnippetEditDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var name: String
    var groupName: String
    var trigger: String
    var expansion: String
    var isGlobal: Bool
    var bundleID: String

    init() {
        id = UUID()
        isNew = true
        name = ""
        groupName = Snippet.defaultGroupName
        trigger = ""
        expansion = ""
        isGlobal = true
        bundleID = ""
    }

    init(snippet: Snippet) {
        id = snippet.id
        isNew = false
        name = snippet.name
        groupName = snippet.groupName
        trigger = snippet.trigger
        expansion = snippet.expansion

        switch snippet.scope {
        case .global:
            isGlobal = true
            bundleID = ""
        case .app(let bundleID):
            isGlobal = false
            self.bundleID = bundleID
        }
    }

    var scope: Scope {
        isGlobal ? .global : .app(bundleID: bundleID)
    }
}

private struct SnippetEditSheet: View {
    @State private var draft: SnippetEditDraft
    let onCancel: () -> Void
    let onSave: (SnippetEditDraft) -> Void
    let onDelete: (UUID) -> Void

    init(
        draft: SnippetEditDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SnippetEditDraft) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        !draft.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (draft.isGlobal || !draft.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            Text(draft.isNew ? "Add shortcut" : "Edit shortcut")
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textPrimary)

            HStack(spacing: VoceDesign.sm) {
                sheetField("Name", text: $draft.name)
                sheetField("Group", text: $draft.groupName)
            }

            HStack(spacing: VoceDesign.sm) {
                sheetField("Thing you say", text: $draft.trigger)
            }

            expansionField()

            ScopePickerRow(isGlobal: $draft.isGlobal, bundleID: $draft.bundleID)

            HStack {
                if !draft.isNew {
                    Button {
                        onDelete(draft.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoceDesign.error)
                    .help("Delete shortcut")
                }

                Spacer()

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

    private func sheetField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text(title)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.textSecondary)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .settingsInputChrome()
        }
    }

    private func expansionField() -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text("Text inserted")
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.textSecondary)

            TextEditor(text: $draft.expansion)
                .font(VoceDesign.callout())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, idealHeight: 150, maxHeight: 260)
                .settingsInputChrome()
        }
    }
}

private func normalizedGroupName(_ groupName: String) -> String {
    let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Snippet.defaultGroupName : trimmed
}
