import SwiftUI
import VoceKit

struct LearningSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @State private var snippetSuggestions: [SnippetSuggestion] = []
    @State private var styleSuggestions: [StyleSuggestion] = []
    @State private var corrections: [Correction] = []
    @State private var correctionRaw: String = ""
    @State private var correctionFixed: String = ""

    var body: some View {
        settingsCardWithSubtitle(
            "Adaptive Learning",
            subtitle: "Voce learns from your dictation to improve over time"
        ) {
            // Quick correction entry
            correctionEntrySection

            // Snippet suggestions
            if !snippetSuggestions.isEmpty {
                Divider()
                snippetSuggestionsSection
            }

            // Style suggestions
            if !styleSuggestions.isEmpty {
                Divider()
                styleSuggestionsSection
            }

            // Correction log
            if !corrections.isEmpty {
                Divider()
                correctionLogSection
            }
        }
        .task { await refreshLearningData() }
    }

    // MARK: - Correction Entry

    private var correctionEntrySection: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text("Teach a Correction")
                .font(VoceDesign.callout())
                .foregroundStyle(VoceDesign.textSecondary)

            HStack(spacing: VoceDesign.sm) {
                TextField("Wrong word", text: $correctionRaw)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(VoceDesign.textSecondary)
                TextField("Correct word", text: $correctionFixed)
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !correctionRaw.isEmpty, !correctionFixed.isEmpty else { return }
                    Task {
                        await controller.submitCorrection(
                            rawWord: correctionRaw,
                            correctedWord: correctionFixed
                        )
                        correctionRaw = ""
                        correctionFixed = ""
                        await refreshLearningData()
                    }
                } label: {
                    Label("Teach", systemImage: "graduationcap")
                }
                .buttonStyle(.bordered)
            }

            Text("After seeing the same correction \(LearningEngine.correctionPromotionThreshold) times, it auto-adds to your lexicon.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
    }

    // MARK: - Snippet Suggestions

    private var snippetSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text("Suggested Shortcuts")
                .font(VoceDesign.callout())
                .foregroundStyle(VoceDesign.textSecondary)

            Text("You say these phrases often. Want to make them shortcuts?")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            ForEach(snippetSuggestions.prefix(5)) { suggestion in
                HStack(spacing: VoceDesign.sm) {
                    Text("\"\(suggestion.phrase)\"")
                        .font(VoceDesign.callout())
                        .lineLimit(1)
                    Spacer()
                    Text("\(suggestion.occurrences)x")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                    Button("Add") {
                        Task {
                            await controller.acceptSnippetSuggestion(suggestion)
                            await refreshLearningData()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Dismiss") {
                        Task {
                            await controller.dismissSnippetSuggestion(suggestion)
                            await refreshLearningData()
                        }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                .padding(.vertical, VoceDesign.xxs)
            }
        }
    }

    // MARK: - Style Suggestions

    private var styleSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text("App Profile Suggestions")
                .font(VoceDesign.callout())
                .foregroundStyle(VoceDesign.textSecondary)

            ForEach(styleSuggestions, id: \.bundleID) { suggestion in
                HStack(spacing: VoceDesign.sm) {
                    VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                        Text(suggestion.bundleID)
                            .font(VoceDesign.callout())
                        Text(suggestion.reason)
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }
                    Spacer()
                    Button("Apply") {
                        Task {
                            await controller.acceptStyleSuggestion(suggestion)
                            await refreshLearningData()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, VoceDesign.xxs)
                .padding(.horizontal, VoceDesign.sm)
                .background(VoceDesign.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
            }
        }
    }

    // MARK: - Correction Log

    private var correctionLogSection: some View {
        DisclosureGroup("Correction Log (\(corrections.count))") {
            ForEach(corrections.prefix(20)) { correction in
                HStack(spacing: VoceDesign.sm) {
                    Text("\"\(correction.rawWord)\" \u{2192} \"\(correction.correctedWord)\"")
                        .font(VoceDesign.callout())
                    Spacer()
                    Text("\(correction.count)x")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                    if correction.promoted {
                        Text("In Lexicon")
                            .font(VoceDesign.label())
                            .padding(.horizontal, VoceDesign.sm)
                            .padding(.vertical, VoceDesign.xxs)
                            .background(VoceDesign.accent.opacity(VoceDesign.opacitySubtle))
                            .foregroundStyle(VoceDesign.accent)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, VoceDesign.xxs)
            }
        }
    }

    // MARK: - Data Loading

    private func refreshLearningData() async {
        let existingTriggers = Set(controller.preferences.snippets.map(\.trigger))
        snippetSuggestions = await controller.fetchSnippetSuggestions(
            excluding: existingTriggers
        )
        styleSuggestions = await controller.fetchStyleSuggestions()
        corrections = await controller.fetchCorrections()
    }
}
