import Foundation

public struct FinalizedTranscript: Sendable, Codable, Equatable {
    public var rawText: String
    public var cleanText: String
    public var removedFillers: [String]
    public var cleanupOutcome: CleanupOutcome?
    public var appContext: AppContext
    public var audioURL: URL?
    public var processingNote: String?
    public var sourceSessionID: SessionID

    public init(
        rawText: String,
        cleanText: String,
        removedFillers: [String] = [],
        cleanupOutcome: CleanupOutcome? = nil,
        appContext: AppContext,
        audioURL: URL? = nil,
        processingNote: String? = nil,
        sourceSessionID: SessionID
    ) {
        self.rawText = rawText
        self.cleanText = cleanText
        self.removedFillers = removedFillers
        self.cleanupOutcome = cleanupOutcome
        self.appContext = appContext
        self.audioURL = audioURL
        self.processingNote = processingNote
        self.sourceSessionID = sourceSessionID
    }
}

public enum AIWorkflowKind: String, Sendable, Codable, Equatable, CaseIterable {
    case ask
    case rewrite
    case summarize
    case customPrompt
    case dictationPolish
}

public struct AIWorkflow: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: AIWorkflowKind
    public var leadingPhrases: [String]
    public var handsFreeFinishHotkey: HandsFreeHotkey?
    public var promptTemplate: String?
    public var isEnabled: Bool
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: AIWorkflowKind,
        leadingPhrases: [String] = [],
        handsFreeFinishHotkey: HandsFreeHotkey? = nil,
        promptTemplate: String? = nil,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.leadingPhrases = leadingPhrases
        self.handsFreeFinishHotkey = handsFreeFinishHotkey
        self.promptTemplate = promptTemplate
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }
}

extension AIWorkflow {
    public static let askID = UUID(uuidString: "E88BCE11-3870-47E4-8A5D-5A4AB0A183C1")!
    public static let aiPromptID = UUID(uuidString: "07A82B8B-2B28-4055-834F-BA1D6FD6DA89")!
    public static let rewriteID = UUID(uuidString: "87E578D8-2BEC-4CFD-9D55-01765A8D5759")!
    public static let summarizeID = UUID(uuidString: "1AA3F135-35C4-4B6A-BD33-55E4C7034D36")!
    public static let legacyCustomPromptID = UUID(uuidString: "91204ABC-5ED0-4F31-9760-BA5F97A41630")!

    public static func defaultPromptTemplate(for kind: AIWorkflowKind) -> String? {
        switch kind {
        case .ask:
            return """
            Answer the user's request clearly and directly.

            User request:
            {{input}}
            """
        case .rewrite:
            return """
            You are rewriting text, not answering a user.
            Rewrite the following text for clarity and flow while preserving its meaning and tone.

            Output rules:
            - Return only the rewritten text
            - Do not add introductions, explanations, labels, quotation marks, or code fences
            - Do not say things like "Sure", "Here is the rewritten text", or "Rewritten text:"

            Text:
            {{input}}
            """
        case .summarize:
            return """
            You are summarizing text, not answering a user.
            Summarize the following text concisely.

            Output rules:
            - Return only the summary
            - Do not add introductions, explanations, labels, quotation marks, or code fences
            - Do not say things like "Sure", "Here is the summary", or "Summary:"

            Text:
            {{input}}
            """
        case .dictationPolish:
            return """
            Clean up this dictated text for insertion.

            Rules:
            - Preserve the user's meaning and wording as much as possible
            - Fix punctuation, capitalization, spacing, and obvious transcription artifacts
            - Use bullet points or numbered lists only when the text clearly asks for a list or sequence
            - Do not answer questions
            - Do not add new facts, examples, headings, explanations, or commentary
            - Return only the cleaned text

            Text:
            {{input}}
            """
        case .customPrompt:
            return nil
        }
    }

    public var effectivePromptTemplate: String? {
        let trimmedTemplate = promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTemplate.isEmpty {
            return trimmedTemplate
        }
        return Self.defaultPromptTemplate(for: kind)
    }

    public static let builtIns: [AIWorkflow] = [
        AIWorkflow(
            id: aiPromptID,
            name: "AI Prompt",
            kind: .customPrompt,
            leadingPhrases: ["ai prompt", "prompt for ai"],
            handsFreeFinishHotkey: .keyCode(47),
            promptTemplate: """
            Convert the following transcription into a clear and effective prompt for an AI assistant.

            - Preserve the user's intent exactly
            - Remove filler words and repetition
            - Fix grammar and phrasing
            - Make the request explicit and unambiguous

            Transcription:
            {{input}}

            Improved Prompt:
            """,
            isBuiltIn: true
        ),
        AIWorkflow(
            id: rewriteID,
            name: "Rewrite",
            kind: .rewrite,
            leadingPhrases: ["rewrite this", "rewrite"],
            isBuiltIn: true
        ),
        AIWorkflow(
            id: summarizeID,
            name: "Summarize",
            kind: .summarize,
            leadingPhrases: ["summarize this", "summarize"],
            isBuiltIn: true
        ),
    ]

    public static let builtInByID: [UUID: AIWorkflow] = Dictionary(
        uniqueKeysWithValues: builtIns.map { ($0.id, $0) }
    )

    public static let dictationPolishWorkflow = AIWorkflow(
        id: UUID(uuidString: "E81DFF9E-285B-4A08-A357-82815D2F5DAA")!,
        name: "Dictation Polish",
        kind: .dictationPolish,
        isEnabled: true,
        isBuiltIn: true
    )

    public static func makeCustomPrompt(
        name: String = "New Prompt",
        triggerPhrase: String = "",
        handsFreeFinishHotkey: HandsFreeHotkey? = nil,
        promptTemplate: String = "",
        isEnabled: Bool = true
    ) -> AIWorkflow {
        AIWorkflow(
            name: name,
            kind: .customPrompt,
            leadingPhrases: triggerPhrase.isEmpty ? [] : [triggerPhrase],
            handsFreeFinishHotkey: handsFreeFinishHotkey,
            promptTemplate: promptTemplate,
            isEnabled: isEnabled,
            isBuiltIn: false
        )
    }
}

public enum CompletionAction: Sendable, Codable, Equatable {
    case insert
    case copyToClipboard
    case insertAndSubmit
    case aiWorkflow(id: UUID)
}

public enum CompletionSelectionSource: Sendable, Codable, Equatable {
    case defaultBehavior
    case leadingPhrase(workflowID: UUID, matchedPhrase: String)
    case alternateFinishKey(workflowID: UUID)
}

public struct RoutedCompletion: Sendable, Codable, Equatable {
    public var action: CompletionAction
    public var inputText: String
    public var selectedBy: CompletionSelectionSource

    public init(
        action: CompletionAction,
        inputText: String,
        selectedBy: CompletionSelectionSource
    ) {
        self.action = action
        self.inputText = inputText
        self.selectedBy = selectedBy
    }
}

public enum AIProvider: String, Sendable, Codable, Equatable {
    case appleFoundationModels
}

public struct AIWorkflowResult: Sendable, Codable, Equatable {
    public var outputText: String
    public var provider: AIProvider
    public var modelDescription: String?
    public var latencyMS: Int?

    public init(
        outputText: String,
        provider: AIProvider,
        modelDescription: String? = nil,
        latencyMS: Int? = nil
    ) {
        self.outputText = outputText
        self.provider = provider
        self.modelDescription = modelDescription
        self.latencyMS = latencyMS
    }
}

public enum AIWorkflowError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(reason: String)
    case generationFailed(reason: String)
    case emptyOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .generationFailed(let reason):
            return reason
        case .emptyOutput:
            return "AI returned no output."
        case .cancelled:
            return "AI generation was cancelled."
        }
    }
}

public enum CompletionRoutingError: Error, LocalizedError, Sendable, Equatable {
    case workflowNotFound(UUID)
    case noContentAfterTrigger(String)

    public var errorDescription: String? {
        switch self {
        case .workflowNotFound:
            return "Selected AI workflow was not found."
        case .noContentAfterTrigger:
            return "No content after AI command."
        }
    }
}
