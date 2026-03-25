import SwiftUI
import VoceKit

struct AISettingsSection: View {
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
            case .add: return "add"
            case .edit(let i): return "edit-\(i)"
            }
        }

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    @EnvironmentObject private var controller: DictationController
    @Binding var preferences: AppPreferences
    @State private var sheetMode: SheetMode?
    @State private var draft = WorkflowDraft()
    @State private var hoveredWorkflowID: UUID?

    var body: some View {
        settingsCardWithSubtitle(
            "AI Workflows",
            subtitle: "Route finished dictation through Apple Intelligence when you want rewritten or summarized output."
        ) {
            Toggle("Enable AI workflows", isOn: $preferences.ai.isEnabled)

            availabilityRow

            Toggle("Allow spoken leading phrases", isOn: $preferences.ai.leadingPhraseSelectionEnabled)
                .disabled(!preferences.ai.isEnabled)

            workflowTable
        }
        .sheet(item: $sheetMode) { mode in
            workflowSheet(mode: mode)
        }
    }

    // MARK: - Availability

    private var availabilityRow: some View {
        HStack(spacing: VoceDesign.sm) {
            Circle()
                .fill(controller.aiAvailabilityIsAvailable ? VoceDesign.success : VoceDesign.warning)
                .frame(width: 8, height: 8)

            Text(controller.appleIntelligenceAvailabilityText)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
    }

    // MARK: - Unified Workflow Table

    private var workflowTable: some View {
        VStack(alignment: .leading, spacing: VoceDesign.sm) {
            HStack {
                Text("Workflows")
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer()

                Button {
                    draft = WorkflowDraft()
                    sheetMode = .add
                } label: {
                    Label("Add Workflow", systemImage: "plus")
                        .font(VoceDesign.label())
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoceDesign.accent)
                .disabled(!preferences.ai.isEnabled)
            }

            // Table header
            HStack(spacing: 0) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Trigger")
                    .frame(width: 90, alignment: .leading)
                Text("Finish Key")
                    .frame(width: 72, alignment: .leading)
                Text("Enabled")
                    .frame(width: 60, alignment: .center)
                Spacer()
                    .frame(width: 52)
            }
            .font(VoceDesign.label())
            .foregroundStyle(VoceDesign.textSecondary)
            .padding(.horizontal, VoceDesign.sm)

            // All workflow rows
            ForEach(Array(preferences.ai.workflows.indices), id: \.self) { index in
                workflowRow(at: index)
            }
        }
    }

    private func workflowRow(at index: Int) -> some View {
        let workflow = preferences.ai.workflows[index]
        let isHovered = hoveredWorkflowID == workflow.id

        return HStack(spacing: 0) {
            // Name + built-in badge
            HStack(spacing: VoceDesign.xs) {
                Text(workflow.name)
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .lineLimit(1)

                if workflow.isBuiltIn {
                    Text("Default")
                        .font(VoceDesign.label())
                        .padding(.horizontal, VoceDesign.xs + VoceDesign.xxs)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(VoceDesign.accent.opacity(VoceDesign.opacitySubtle))
                        )
                        .foregroundStyle(VoceDesign.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trigger phrase
            Text(workflow.leadingPhrases.first ?? "--")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)

            // Finish key
            Group {
                if let key = workflow.handsFreeFinishHotkey {
                    Text(hotkeyDisplayName(for: key))
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                } else {
                    Text("--")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.5))
                }
            }
            .lineLimit(1)
            .frame(width: 72, alignment: .leading)

            Toggle("", isOn: workflowEnabledBinding(at: index))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .disabled(!preferences.ai.isEnabled)
                .accessibilityLabel("\(workflow.name) enabled")
                .frame(width: 60, alignment: .center)

            HStack(spacing: 0) {
                Button {
                    editWorkflow(at: index)
                } label: {
                    Image(systemName: "pencil")
                        .font(VoceDesign.caption())
                        .foregroundStyle(isHovered ? VoceDesign.accent : VoceDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Edit workflow")
                .accessibilityLabel("Edit \(workflow.name)")
                .frame(width: 26, alignment: .center)

                if workflow.isBuiltIn {
                    Color.clear
                        .frame(width: 26, height: 1)
                } else {
                    Button(role: .destructive) {
                        removeWorkflow(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(VoceDesign.caption())
                            .foregroundStyle(isHovered ? VoceDesign.error : VoceDesign.textSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Delete workflow")
                    .accessibilityLabel("Delete \(workflow.name)")
                    .disabled(!preferences.ai.isEnabled)
                    .frame(width: 26, alignment: .center)
                }
            }
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, VoceDesign.sm)
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
                hoveredWorkflowID = hovering ? workflow.id : nil
            }
        }
    }

    // MARK: - Workflow Sheet (Add / Edit)

    private func workflowSheet(mode: SheetMode) -> some View {
        let isEditing = mode.isEditing
        let sheetTitle = isEditing ? "Edit Workflow" : "New Workflow"

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                    Text(sheetTitle)
                        .font(VoceDesign.heading2())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text(isEditing
                         ? "Update your workflow settings."
                         : "Create a workflow that processes dictation through a custom prompt.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                Spacer()
                Button {
                    sheetMode = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, VoceDesign.xl)
            .padding(.top, VoceDesign.lg)
            .padding(.bottom, VoceDesign.md)

            Divider()
                .overlay(VoceDesign.border)

            // Form fields — compact layout, no scroll needed
            VStack(alignment: .leading, spacing: VoceDesign.md) {
                // Title
                sheetField(label: "Title") {
                    styledTextField("e.g. Client-ready log", text: $draft.title)
                }

                // Trigger phrase
                sheetField(label: "Trigger Phrase") {
                    styledTextField("e.g. billable log", text: $draft.triggerPhrase)
                }

                // Prompt template
                sheetField(label: "Prompt") {
                    TextEditor(text: $draft.prompt)
                        .font(VoceDesign.callout())
                        .scrollContentBackground(.hidden)
                        .padding(VoceDesign.sm)
                        .frame(height: 80)
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

                Text("Use {{input}} where the dictated text should appear.")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .padding(.top, -VoceDesign.sm)

                // End key
                sheetField(label: "Finish Key") {
                    HotkeyRecorderField(
                        hotkey: $draft.endKey,
                        allowModifierCapture: false
                    )
                }

                // Enabled toggle
                HStack {
                    Text("Enabled")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)
                    Spacer()
                    Toggle("", isOn: $draft.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, VoceDesign.xl)
            .padding(.vertical, VoceDesign.lg)

            Divider()
                .overlay(VoceDesign.border)

            // Footer
            HStack {
                Spacer()

                Button("Cancel") {
                    sheetMode = nil
                }
                .buttonStyle(.plain)
                .font(VoceDesign.callout())
                .foregroundStyle(VoceDesign.textSecondary)
                .padding(.horizontal, VoceDesign.md)

                Button {
                    if case .edit(let index) = mode {
                        applyDraftToWorkflow(at: index)
                    } else {
                        addCustomWorkflow()
                    }
                } label: {
                    Text(isEditing ? "Save" : "Add Workflow")
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(.white)
                        .padding(.horizontal, VoceDesign.xl)
                        .padding(.vertical, VoceDesign.sm)
                        .background {
                            Capsule()
                                .fill(
                                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? VoceDesign.accent.opacity(0.4)
                                        : VoceDesign.accent
                                )
                        }
                }
                .buttonStyle(.plain)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, VoceDesign.xl)
            .padding(.vertical, VoceDesign.md)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            VoceDesign.windowBackground
                .ignoresSafeArea()
        }
    }

    // MARK: - Sheet Helpers

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

    // MARK: - Bindings

    private func workflowEnabledBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { preferences.ai.workflows[index].isEnabled },
            set: { preferences.ai.workflows[index].isEnabled = $0 }
        )
    }

    // MARK: - Actions

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
