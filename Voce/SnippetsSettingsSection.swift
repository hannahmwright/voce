import SwiftUI
import VoceKit

struct SnippetsSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences
    let selectedSection: SnippetSection

    @State private var newTrigger: String = ""
    @State private var newExpansion: String = ""
    @State private var newBundleID: String = ""
    @State private var newGlobal = true
    @State private var snippetSuggestions: [SnippetSuggestion] = []

    private var builtInCommands: [VoiceCommand] {
        preferences.voiceCommands.filter(\.isBuiltIn)
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
    }

    private var customSection: some View {
        settingsCardWithSubtitle(
            "Custom shortcuts",
            subtitle: "Your own spoken phrases."
        ) {
            settingsSubcard {
                subsectionLabel("Saved")

                if preferences.snippets.isEmpty {
                    Text("Nothing here yet. Try “on my way” to “On my way!”.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textSecondary)
                } else {
                    VStack(spacing: VoceDesign.sm) {
                        ForEach(preferences.snippets) { snippet in
                            entryRow(
                                leading: "“\(snippet.trigger)” → \(snippet.expansion)",
                                scope: snippet.scope
                            ) {
                                preferences.snippets.removeAll { $0.id == snippet.id }
                            }
                        }
                    }
                }
            }

            settingsSubcard {
                subsectionLabel("Add shortcut")

                HStack(spacing: VoceDesign.sm) {
                    TextField("Say", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                    TextField("Insert", text: $newExpansion)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    ScopePickerRow(isGlobal: $newGlobal, bundleID: $newBundleID)
                    Spacer()
                    Button {
                        guard !newTrigger.isEmpty, !newExpansion.isEmpty else { return }
                        let scope: Scope = newGlobal ? .global : .app(bundleID: newBundleID)
                        let newSnippet = Snippet(trigger: newTrigger, expansion: newExpansion, scope: scope)
                        if let existingIndex = preferences.snippets.firstIndex(where: { $0.trigger == newSnippet.trigger && $0.scope == newSnippet.scope }) {
                            preferences.snippets[existingIndex] = newSnippet
                        } else {
                            preferences.snippets.append(newSnippet)
                        }
                        newTrigger = ""
                        newExpansion = ""
                        newBundleID = ""
                        newGlobal = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(newTrigger.isEmpty || newExpansion.isEmpty || (!newGlobal && newBundleID.isEmpty))
                }
            }
        }
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

    private func refreshSnippetSuggestions() async {
        let existingTriggers = Set(controller.preferences.snippets.map(\.trigger))
        snippetSuggestions = await controller.fetchSnippetSuggestions(excluding: existingTriggers)
    }
}
