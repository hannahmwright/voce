import SwiftUI
import VoceKit

struct AISettingsSection: View {
    private enum TriggerMode: String, CaseIterable, Identifiable {
        case hotkeyOnly
        case hotkeyAndVoice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hotkeyOnly:
                return "Hotkey only"
            case .hotkeyAndVoice:
                return "Hotkey + voice"
            }
        }
    }

    private struct WorkflowDraft {
        var title: String = ""
        var prompt: String = ""
        var triggerPhrase: String = ""
        var endKey: HandsFreeHotkey? = nil
        var isEnabled: Bool = true

        init() {}

        init(from workflow: AIWorkflow) {
            title = workflow.name
            prompt = workflow.effectivePromptTemplate ?? ""
            triggerPhrase = workflow.leadingPhrases.first ?? ""
            endKey = workflow.handsFreeFinishHotkey
            isEnabled = workflow.isEnabled
        }
    }

    private enum SheetMode: Identifiable {
        case add
        case edit(index: Int)

        var id: String {
            switch self {
            case .add:
                return "add"
            case .edit(let index):
                return "edit-\(index)"
            }
        }

        var title: String {
            switch self {
            case .add:
                return "New prompt"
            case .edit:
                return "Edit prompt"
            }
        }
    }

    @Binding var preferences: AppPreferences
    @State private var sheetMode: SheetMode?
    @State private var draft = WorkflowDraft()
    @State private var hoveredWorkflowID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            aiHeader

            Toggle(isOn: $preferences.ai.isEnabled) {
                settingInlineLabel(
                    "Use AI",
                    help: "Turns on Apple Intelligence actions."
                )
            }

            voiceTriggerRow

            workflowList
                .opacity(preferences.ai.isEnabled ? 1 : 0.48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .sheet(item: $sheetMode) { mode in
            workflowSheet(mode: mode)
        }
    }

    private var workflowList: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            Text("Actions")
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textPrimary)

            workflowSection("Built in", indices: builtInWorkflowIndices)

            if !customWorkflowIndices.isEmpty {
                workflowSection("Custom", indices: customWorkflowIndices, showsNewButton: true)
            } else {
                workflowSection("Custom", indices: [], showsNewButton: true)
            }
        }
    }

    private func workflowSection(
        _ title: String,
        indices: [Int],
        showsNewButton: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            HStack {
                Text(title)
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .textCase(.uppercase)

                Spacer()

                if showsNewButton {
                    Button {
                        draft = WorkflowDraft()
                        sheetMode = .add
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoceDesign.accent)
                    .disabled(!preferences.ai.isEnabled)
                }
            }

            if indices.isEmpty {
                Text("No custom actions")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm)
                    .background(VoceDesign.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
            } else {
                ForEach(indices, id: \.self) { index in
                    workflowRow(at: index)
                }
            }
        }
    }

    private func workflowRow(at index: Int) -> some View {
        let workflow = preferences.ai.workflows[index]
        let isHovered = hoveredWorkflowID == workflow.id

        return HStack(spacing: VoceDesign.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workflowDisplayName(for: workflow))
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .lineLimit(1)

                Text(workflowSummary(for: workflow))
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            workflowSpeechColumn(for: workflow)

            workflowKeyColumn(for: workflow)

            Toggle("", isOn: workflowEnabledBinding(at: index))
                .labelsHidden()
                .controlSize(.mini)
                .disabled(!preferences.ai.isEnabled)
                .accessibilityLabel("\(workflow.name) enabled")

            Button {
                editWorkflow(at: index)
            } label: {
                Image(systemName: "pencil")
                    .font(VoceDesign.caption())
                    .foregroundStyle(isHovered ? VoceDesign.accent : VoceDesign.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!preferences.ai.isEnabled)

            if workflow.isBuiltIn {
                Color.clear
                    .frame(width: 12, height: 1)
            } else {
                Button(role: .destructive) {
                    removeWorkflow(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(VoceDesign.caption())
                        .foregroundStyle(isHovered ? VoceDesign.error : VoceDesign.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(!preferences.ai.isEnabled)
            }
        }
        .padding(.horizontal, VoceDesign.md)
        .padding(.vertical, VoceDesign.sm)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .fill(isHovered ? VoceDesign.surface : VoceDesign.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .fill(.regularMaterial.opacity(isHovered ? 0.24 : 0.14))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .stroke(
                    isHovered ? VoceDesign.accent.opacity(0.18) : VoceDesign.border,
                    lineWidth: VoceDesign.borderThin
                )
        )
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
                hoveredWorkflowID = hovering ? workflow.id : nil
            }
        }
    }

    private func workflowSummary(for workflow: AIWorkflow) -> String {
        switch workflow.kind {
        case .ask:
            return "Answer a question"
        case .rewrite:
            return "Rewrite text"
        case .summarize:
            return "Short summary"
        case .customPrompt:
            if workflow.id == AIWorkflow.aiPromptID {
                return "Clean up a prompt"
            }
            return "Custom prompt"
        }
    }

    private func workflowDisplayName(for workflow: AIWorkflow) -> String {
        switch workflow.kind {
        case .ask:
            return "Ask"
        case .rewrite:
            return "Rewrite"
        case .summarize:
            return "Summarize"
        case .customPrompt:
            if workflow.id == AIWorkflow.aiPromptID {
                return "Better prompt"
            }
            return workflow.name
        }
    }

    private func workflowChip(_ title: String) -> some View {
        Text(title)
            .font(VoceDesign.label())
            .foregroundStyle(VoceDesign.textSecondary)
            .padding(.horizontal, VoceDesign.sm)
            .padding(.vertical, VoceDesign.xxs)
            .background(VoceDesign.surface)
            .clipShape(Capsule())
    }

    private func workflowSpeechColumn(for workflow: AIWorkflow) -> some View {
        Group {
            if let phrase = workflow.leadingPhrases.first, !phrase.isEmpty {
                workflowIconChip(systemImage: "waveform", title: phrase)
            } else {
                Color.clear
                    .frame(height: 28)
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    private func workflowKeyColumn(for workflow: AIWorkflow) -> some View {
        Group {
            if let hotkey = workflow.handsFreeFinishHotkey {
                workflowChip(hotkeyDisplayName(for: hotkey))
            } else {
                Color.clear
                    .frame(height: 28)
            }
        }
        .frame(width: 44, alignment: .leading)
    }

    private func workflowIconChip(systemImage: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(VoceDesign.label())
                .lineLimit(1)
        }
        .foregroundStyle(VoceDesign.textSecondary)
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.xxs)
        .background(VoceDesign.surface)
        .clipShape(Capsule())
    }

    private var aiHeader: some View {
        HStack(spacing: VoceDesign.sm) {
            Text("Apple Intelligence")
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textPrimary)
                .accessibilityAddTraits(.isHeader)

            miniAIBadge

            Text("Built in")
                .font(VoceDesign.label())
                .foregroundStyle(VoceDesign.warmAccentText)
                .padding(.horizontal, VoceDesign.sm)
                .padding(.vertical, VoceDesign.xxs)
                .background(VoceDesign.warmAccentFill)
                .clipShape(Capsule())

            Text("On device")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            Spacer(minLength: 0)
        }
    }

    private var miniAIBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VoceDesign.warmAccentFill)

            HStack(spacing: 3) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(VoceDesign.warmAccentText)
        }
        .frame(width: 24, height: 24)
    }

    private var voiceTriggerRow: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            settingInlineLabel(
                "Trigger mode",
                help: "Use just the hotkey, or also say rewrite, summarize, or your custom phrase first."
            )

            HStack(spacing: VoceDesign.xs) {
                ForEach(TriggerMode.allCases) { mode in
                    triggerModeButton(mode)
                }
            }
            .frame(maxWidth: 360)
            .padding(VoceDesign.xxs)
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
            .opacity(preferences.ai.isEnabled ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedTriggerMode: TriggerMode {
        preferences.ai.leadingPhraseSelectionEnabled ? .hotkeyAndVoice : .hotkeyOnly
    }

    private func triggerModeButton(_ mode: TriggerMode) -> some View {
        let isSelected = selectedTriggerMode == mode

        return Button {
            preferences.ai.leadingPhraseSelectionEnabled = mode == .hotkeyAndVoice
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode == .hotkeyOnly ? "keyboard" : "waveform")
                    .font(.system(size: 11, weight: .semibold))

                Text(mode.title)
                    .font(VoceDesign.callout())
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
            }
            .foregroundStyle(isSelected ? VoceDesign.warmAccentText : VoceDesign.textPrimary)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(VoceDesign.warmAccentFill) : AnyShapeStyle(Color.clear))
            }
        }
        .buttonStyle(.plain)
        .disabled(!preferences.ai.isEnabled)
    }

    private func workflowSheet(mode: SheetMode) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack {
                Text(mode.title)
                    .font(VoceDesign.heading2())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer()

                Button {
                    sheetMode = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            sheetField(label: "Name") {
                styledTextField("Prompt name", text: $draft.title)
            }

            sheetField(label: "Say") {
                styledTextField("Voice phrase", text: $draft.triggerPhrase)
            }

            sheetField(label: "Key") {
                HotkeyRecorderField(hotkey: $draft.endKey, allowModifierCapture: false)
            }

            sheetField(label: "Prompt") {
                TextEditor(text: $draft.prompt)
                    .font(VoceDesign.callout())
                    .scrollContentBackground(.hidden)
                    .padding(VoceDesign.sm)
                    .frame(height: 96)
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

            Toggle("On", isOn: $draft.isEnabled)

            HStack {
                Spacer()

                Button("Cancel") {
                    sheetMode = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.textSecondary)

                Button {
                    if case .edit(let index) = mode {
                        applyDraftToWorkflow(at: index)
                    } else {
                        addCustomWorkflow()
                    }
                } label: {
                    Text(primaryButtonTitle(for: mode))
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(.white)
                        .padding(.horizontal, VoceDesign.xl)
                        .padding(.vertical, VoceDesign.sm)
                        .background(
                            Capsule()
                                .fill(
                                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? VoceDesign.accent.opacity(0.4)
                                        : VoceDesign.accent
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VoceDesign.xl)
        .frame(width: 460)
        .background {
            VoceDesign.windowBackground
                .ignoresSafeArea()
        }
    }

    private func sheetField<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text(label)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(VoceDesign.textSecondary)
            content()
        }
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
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

    private func primaryButtonTitle(for mode: SheetMode) -> String {
        switch mode {
        case .add:
            return "Add"
        case .edit:
            return "Save"
        }
    }

    private var builtInWorkflowIndices: [Int] {
        preferences.ai.workflows.indices.filter { preferences.ai.workflows[$0].isBuiltIn }
    }

    private var customWorkflowIndices: [Int] {
        preferences.ai.workflows.indices.filter { !preferences.ai.workflows[$0].isBuiltIn }
    }

    private func workflowEnabledBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { preferences.ai.workflows[index].isEnabled },
            set: { preferences.ai.workflows[index].isEnabled = $0 }
        )
    }

    private func addCustomWorkflow() {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let workflow = AIWorkflow.makeCustomPrompt(
            name: trimmedTitle,
            triggerPhrase: draft.triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines),
            handsFreeFinishHotkey: draft.endKey,
            promptTemplate: draft.prompt,
            isEnabled: draft.isEnabled
        )
        preferences.ai.workflows.append(workflow)
        if preferences.ai.defaultHandsFreeWorkflowID == nil {
            preferences.ai.defaultHandsFreeWorkflowID = workflow.id
        }
        sheetMode = nil
    }

    private func editWorkflow(at index: Int) {
        draft = WorkflowDraft(from: preferences.ai.workflows[index])
        sheetMode = .edit(index: index)
    }

    private func applyDraftToWorkflow(at index: Int) {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        preferences.ai.workflows[index].name = trimmedTitle
        preferences.ai.workflows[index].promptTemplate = draft.prompt
        preferences.ai.workflows[index].isEnabled = draft.isEnabled
        preferences.ai.workflows[index].handsFreeFinishHotkey = draft.endKey

        let trimmedTrigger = draft.triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.ai.workflows[index].leadingPhrases = trimmedTrigger.isEmpty ? [] : [trimmedTrigger]

        sheetMode = nil
    }

    private func removeWorkflow(at index: Int) {
        preferences.ai.workflows.remove(at: index)
    }
}
