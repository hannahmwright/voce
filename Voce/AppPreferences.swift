import Foundation
import VoceKit

/// A fixed screen-space anchor for apps where accessibility can't detect the input area.
/// The overlay positions itself relative to this rect instead of querying AX APIs.
struct AppAnchorOverride: Codable, Sendable, Equatable {
    /// Screen-space origin X.
    var x: Double
    /// Screen-space origin Y.
    var y: Double
    /// Width of the input region.
    var width: Double
    /// Height of the input region.
    var height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct AppPreferences: Codable, Sendable, Equatable {
    struct General: Codable, Sendable, Equatable {
        var launchAtLoginEnabled: Bool
        var showDockIcon: Bool
        var showOnboarding: Bool

        init(launchAtLoginEnabled: Bool, showDockIcon: Bool, showOnboarding: Bool) {
            self.launchAtLoginEnabled = launchAtLoginEnabled
            self.showDockIcon = showDockIcon
            self.showOnboarding = showOnboarding
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
            showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
            showOnboarding = try container.decodeIfPresent(Bool.self, forKey: .showOnboarding) ?? false
        }
    }

    struct Hotkeys: Codable, Sendable, Equatable {
        var optionPressToTalkEnabled: Bool
        var pressToTalkHotkey: PressToTalkHotkey
        var handsFreeGlobalHotkey: HandsFreeHotkey?
        var enterFinishesHandsFreeAndSubmits: Bool

        enum CodingKeys: String, CodingKey {
            case optionPressToTalkEnabled
            case pressToTalkHotkey
            case pressToTalkModifier
            case handsFreeGlobalHotkey
            case handsFreeGlobalKeyCode
            case enterFinishesHandsFreeAndSubmits
        }

        init(
            optionPressToTalkEnabled: Bool,
            pressToTalkHotkey: PressToTalkHotkey = .default,
            handsFreeGlobalHotkey: HandsFreeHotkey? = .keyCode(79),
            enterFinishesHandsFreeAndSubmits: Bool = false
        ) {
            self.optionPressToTalkEnabled = optionPressToTalkEnabled
            self.pressToTalkHotkey = pressToTalkHotkey
            self.handsFreeGlobalHotkey = handsFreeGlobalHotkey
            self.enterFinishesHandsFreeAndSubmits = enterFinishesHandsFreeAndSubmits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            optionPressToTalkEnabled = try container.decodeIfPresent(Bool.self, forKey: .optionPressToTalkEnabled) ?? true
            if let hotkey = try container.decodeIfPresent(PressToTalkHotkey.self, forKey: .pressToTalkHotkey) {
                pressToTalkHotkey = hotkey
            } else if let legacyModifier = try container.decodeIfPresent(PressToTalkModifier.self, forKey: .pressToTalkModifier) {
                pressToTalkHotkey = legacyModifier.asHotkey
            } else {
                pressToTalkHotkey = .default
            }
            if let hotkey = try container.decodeIfPresent(HandsFreeHotkey.self, forKey: .handsFreeGlobalHotkey) {
                handsFreeGlobalHotkey = hotkey
            } else if let legacyKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .handsFreeGlobalKeyCode) {
                handsFreeGlobalHotkey = .keyCode(legacyKeyCode)
            } else {
                handsFreeGlobalHotkey = .keyCode(79)
            }
            enterFinishesHandsFreeAndSubmits = try container.decodeIfPresent(Bool.self, forKey: .enterFinishesHandsFreeAndSubmits) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(optionPressToTalkEnabled, forKey: .optionPressToTalkEnabled)
            try container.encode(pressToTalkHotkey, forKey: .pressToTalkHotkey)
            try container.encodeIfPresent(handsFreeGlobalHotkey, forKey: .handsFreeGlobalHotkey)
            try container.encode(enterFinishesHandsFreeAndSubmits, forKey: .enterFinishesHandsFreeAndSubmits)
        }
    }

    struct Dictation: Codable, Sendable, Equatable {
        var modelDirectoryPath: String
        var modelArch: MoonshineModelPreset
        var keepModelWarm: Bool

        init(
            modelDirectoryPath: String,
            modelArch: MoonshineModelPreset = .smallStreaming,
            keepModelWarm: Bool = true
        ) {
            self.modelDirectoryPath = modelDirectoryPath
            self.modelArch = modelArch
            self.keepModelWarm = keepModelWarm
        }

        enum CodingKeys: String, CodingKey {
            case modelDirectoryPath
            case modelArch
            case keepModelWarm
            case modelPath
            case whisperCLIPath
            case threadCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaultModelArch: MoonshineModelPreset = .smallStreaming
            let defaultPath = MoonshineModelPaths.defaultModelDirectoryPath(for: defaultModelArch)

            let decodedPath = try container.decodeIfPresent(String.self, forKey: .modelDirectoryPath)
            let legacyPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
            let resolvedPath: String

            if let decodedPath, !decodedPath.isEmpty {
                resolvedPath = decodedPath
            } else if let legacyPath, !legacyPath.isEmpty {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: legacyPath, isDirectory: &isDirectory), isDirectory.boolValue {
                    resolvedPath = legacyPath
                } else {
                    resolvedPath = defaultPath
                }
            } else {
                resolvedPath = defaultPath
            }

            modelDirectoryPath = resolvedPath
            modelArch = try container.decodeIfPresent(MoonshineModelPreset.self, forKey: .modelArch) ?? defaultModelArch
            keepModelWarm = try container.decodeIfPresent(Bool.self, forKey: .keepModelWarm) ?? true
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(modelDirectoryPath, forKey: .modelDirectoryPath)
            try container.encode(modelArch, forKey: .modelArch)
            try container.encode(keepModelWarm, forKey: .keepModelWarm)
        }
    }

    struct Insertion: Codable, Sendable, Equatable {
        var orderedMethods: [InsertionMethod]

        init(orderedMethods: [InsertionMethod]) {
            self.orderedMethods = orderedMethods
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            orderedMethods = try container.decodeIfPresent([InsertionMethod].self, forKey: .orderedMethods) ?? [.direct, .accessibility, .clipboardPaste]
        }
    }

    struct Media: Codable, Sendable, Equatable {
        var pauseDuringHandsFree: Bool
        var pauseDuringPressToTalk: Bool

        init(pauseDuringHandsFree: Bool = true, pauseDuringPressToTalk: Bool = true) {
            self.pauseDuringHandsFree = pauseDuringHandsFree
            self.pauseDuringPressToTalk = pauseDuringPressToTalk
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pauseDuringHandsFree = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringHandsFree) ?? true
            pauseDuringPressToTalk = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringPressToTalk) ?? true
        }
    }

    struct AI: Codable, Sendable, Equatable {
        var isEnabled: Bool
        var defaultHandsFreeWorkflowID: UUID?
        var handsFreeFinishHotkey: HandsFreeHotkey?
        var leadingPhraseSelectionEnabled: Bool
        var workflows: [AIWorkflow]

        init(
            isEnabled: Bool = false,
            defaultHandsFreeWorkflowID: UUID? = AIWorkflow.askID,
            handsFreeFinishHotkey: HandsFreeHotkey? = nil,
            leadingPhraseSelectionEnabled: Bool = true,
            workflows: [AIWorkflow] = AIWorkflow.builtIns
        ) {
            self.isEnabled = isEnabled
            self.defaultHandsFreeWorkflowID = defaultHandsFreeWorkflowID
            self.handsFreeFinishHotkey = handsFreeFinishHotkey
            self.leadingPhraseSelectionEnabled = leadingPhraseSelectionEnabled
            self.workflows = workflows
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            defaultHandsFreeWorkflowID = try container.decodeIfPresent(UUID.self, forKey: .defaultHandsFreeWorkflowID) ?? AIWorkflow.askID
            handsFreeFinishHotkey = try container.decodeIfPresent(HandsFreeHotkey.self, forKey: .handsFreeFinishHotkey)
            leadingPhraseSelectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .leadingPhraseSelectionEnabled) ?? true
            workflows = try container.decodeIfPresent([AIWorkflow].self, forKey: .workflows) ?? AIWorkflow.builtIns
        }
    }

    var general: General
    var hotkeys: Hotkeys
    var dictation: Dictation
    var insertion: Insertion
    var media: Media
    var ai: AI

    var lexiconEntries: [LexiconEntry]
    var globalStyleProfile: StyleProfile
    var appStyleProfiles: [String: StyleProfile]
    var appAnchorOverrides: [String: AppAnchorOverride]
    var snippets: [Snippet]
    var voiceCommands: [VoiceCommand]

    init(
        general: General,
        hotkeys: Hotkeys,
        dictation: Dictation,
        insertion: Insertion,
        media: Media,
        ai: AI,
        lexiconEntries: [LexiconEntry],
        globalStyleProfile: StyleProfile,
        appStyleProfiles: [String: StyleProfile],
        appAnchorOverrides: [String: AppAnchorOverride],
        snippets: [Snippet],
        voiceCommands: [VoiceCommand]
    ) {
        self.general = general
        self.hotkeys = hotkeys
        self.dictation = dictation
        self.insertion = insertion
        self.media = media
        self.ai = ai
        self.lexiconEntries = lexiconEntries
        self.globalStyleProfile = globalStyleProfile
        self.appStyleProfiles = appStyleProfiles
        self.appAnchorOverrides = appAnchorOverrides
        self.snippets = snippets
        self.voiceCommands = voiceCommands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general = try container.decode(General.self, forKey: .general)
        hotkeys = try container.decode(Hotkeys.self, forKey: .hotkeys)
        dictation = try container.decode(Dictation.self, forKey: .dictation)
        insertion = try container.decode(Insertion.self, forKey: .insertion)
        media = try container.decode(Media.self, forKey: .media)
        ai = try container.decodeIfPresent(AI.self, forKey: .ai) ?? AI()
        lexiconEntries = try container.decodeIfPresent([LexiconEntry].self, forKey: .lexiconEntries) ?? []
        globalStyleProfile = try container.decodeIfPresent(StyleProfile.self, forKey: .globalStyleProfile) ?? AppPreferences.default.globalStyleProfile
        appStyleProfiles = try container.decodeIfPresent([String: StyleProfile].self, forKey: .appStyleProfiles) ?? [:]
        appAnchorOverrides = try container.decodeIfPresent([String: AppAnchorOverride].self, forKey: .appAnchorOverrides) ?? [:]
        snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        voiceCommands = try container.decodeIfPresent([VoiceCommand].self, forKey: .voiceCommands) ?? VoiceCommand.builtIns
    }

    static var `default`: AppPreferences {
        return AppPreferences(
            general: .init(
                launchAtLoginEnabled: false,
                showDockIcon: true,
                showOnboarding: true
            ),
            hotkeys: .init(
                optionPressToTalkEnabled: true,
                pressToTalkHotkey: .default,
                handsFreeGlobalHotkey: .keyCode(79),
                enterFinishesHandsFreeAndSubmits: false
            ),
            dictation: .init(
                modelDirectoryPath: MoonshineModelPaths.defaultModelDirectoryPath(for: .smallStreaming),
                modelArch: .smallStreaming,
                keepModelWarm: true
            ),
            insertion: .init(orderedMethods: [.direct, .accessibility, .clipboardPaste]),
            media: .init(pauseDuringHandsFree: true, pauseDuringPressToTalk: true),
            ai: .init(),
            lexiconEntries: [
                LexiconEntry(term: "voceh", preferred: "Voce", scope: .global),
                LexiconEntry(term: "voce kit", preferred: "VoceKit", scope: .global)
            ],
            globalStyleProfile: .init(
                name: "Default",
                tone: .natural,
                structureMode: .paragraph,
                fillerPolicy: .balanced,
                commandPolicy: .transform
            ),
            appStyleProfiles: [:],
            appAnchorOverrides: [:],
            snippets: [],
            voiceCommands: VoiceCommand.builtIns
        )
    }

    mutating func normalize() {
        let supported: Set<InsertionMethod> = [.direct, .accessibility, .clipboardPaste]
        var seen: Set<InsertionMethod> = []
        var normalized: [InsertionMethod] = []

        for method in insertion.orderedMethods where supported.contains(method) && !seen.contains(method) {
            normalized.append(method)
            seen.insert(method)
        }

        if !seen.contains(.clipboardPaste) {
            normalized.append(.clipboardPaste)
        }

        insertion.orderedMethods = normalized
        var existingWorkflows = ai.workflows

        if let legacyIndex = existingWorkflows.firstIndex(where: { $0.id == AIWorkflow.legacyCustomPromptID }) {
            existingWorkflows[legacyIndex].isBuiltIn = false
            if existingWorkflows[legacyIndex].name == "Custom Prompt" {
                existingWorkflows[legacyIndex].name = "Custom Prompt"
            }
        }

        let mergedBuiltIns = AIWorkflow.builtIns.reduce(into: [AIWorkflow]()) { partialResult, workflow in
            if !partialResult.contains(where: { $0.id == workflow.id }) {
                partialResult.append(workflow)
            }
        }
        for builtIn in mergedBuiltIns where !existingWorkflows.contains(where: { $0.id == builtIn.id }) {
            existingWorkflows.append(builtIn)
        }
        existingWorkflows = existingWorkflows.map { workflow in
            var updated = workflow
            if case .modifier? = updated.handsFreeFinishHotkey {
                updated.handsFreeFinishHotkey = nil
            }
            return updated
        }
        ai.workflows = existingWorkflows
        if ai.defaultHandsFreeWorkflowID == nil
            || !ai.workflows.contains(where: { $0.id == ai.defaultHandsFreeWorkflowID })
        {
            ai.defaultHandsFreeWorkflowID = AIWorkflow.askID
        }
        if case .modifier? = ai.handsFreeFinishHotkey {
            ai.handsFreeFinishHotkey = nil
        }
        let originalArch = dictation.modelArch
        let normalizedArch = originalArch.normalizedForVoce
        if normalizedArch != originalArch {
            dictation.modelArch = normalizedArch
            dictation.modelDirectoryPath = MoonshineModelPaths.defaultModelDirectoryPath(for: normalizedArch)
            return
        }

        if dictation.modelDirectoryPath.isEmpty {
            dictation.modelDirectoryPath = MoonshineModelPaths.defaultModelDirectoryPath(for: normalizedArch)
        }
    }
}
