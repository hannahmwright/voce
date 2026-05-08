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

enum AppAppearancePreference: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    case light
    case dark

    static var currentSystemDefault: AppAppearancePreference {
        .system
    }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light Mode"
        case .dark:
            return "Dark Mode"
        }
    }
}

extension OverlayBubbleAppearance {
    var title: String {
        switch self {
        case .matchApp:
            return "Match App"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .techMeter:
            return "Tech Meter"
        }
    }
}

enum DictationEngineMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case cloud

    var title: String {
        switch self {
        case .local:
            return "Local"
        case .cloud:
            return "Cloud"
        }
    }
}

enum AppDictationEnginePreference: String, Codable, Sendable, Equatable, CaseIterable {
    case followGlobal
    case local
    case cloud

    var title: String {
        switch self {
        case .followGlobal:
            return "Follow Global"
        case .local:
            return "Local"
        case .cloud:
            return "Cloud"
        }
    }

    func resolvedMode(globalMode: DictationEngineMode) -> DictationEngineMode {
        switch self {
        case .followGlobal:
            return globalMode
        case .local:
            return .local
        case .cloud:
            return .cloud
        }
    }
}

enum CloudDictationProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case openAI

    var title: String {
        switch self {
        case .openAI:
            return "OpenAI"
        }
    }
}

enum CloudAPIKeySource: String, Codable, Sendable, Equatable, CaseIterable {
    case keychain
    case environment

    var title: String {
        switch self {
        case .keychain:
            return "Keychain"
        case .environment:
            return "Environment"
        }
    }
}

struct CloudDictationPreferences: Codable, Sendable, Equatable {
    var provider: CloudDictationProvider
    var refinementEnabled: Bool
    var apiKeySource: CloudAPIKeySource

    init(
        provider: CloudDictationProvider = .openAI,
        refinementEnabled: Bool = true,
        apiKeySource: CloudAPIKeySource = .keychain
    ) {
        self.provider = provider
        self.refinementEnabled = refinementEnabled
        self.apiKeySource = apiKeySource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(CloudDictationProvider.self, forKey: .provider) ?? .openAI
        refinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .refinementEnabled) ?? true
        apiKeySource = try container.decodeIfPresent(CloudAPIKeySource.self, forKey: .apiKeySource) ?? .keychain
    }
}

struct AppPreferences: Codable, Sendable, Equatable {
    static let seededHiddenLexiconEntries: [LexiconEntry] = [
        LexiconEntry(term: "voceh", preferred: "Voce", scope: .global),
        LexiconEntry(term: "vochay", preferred: "Voce", scope: .global)
    ]

    struct General: Codable, Sendable, Equatable {
        var launchAtLoginEnabled: Bool
        var showDockIcon: Bool
        var showOnboarding: Bool
        var userName: String
        var appearancePreference: AppAppearancePreference
        var bubbleAppearance: OverlayBubbleAppearance

        init(
            launchAtLoginEnabled: Bool,
            showDockIcon: Bool,
            showOnboarding: Bool,
            userName: String = "",
            appearancePreference: AppAppearancePreference = .currentSystemDefault,
            bubbleAppearance: OverlayBubbleAppearance = .matchApp
        ) {
            self.launchAtLoginEnabled = launchAtLoginEnabled
            self.showDockIcon = showDockIcon
            self.showOnboarding = showOnboarding
            self.userName = userName
            self.appearancePreference = appearancePreference
            self.bubbleAppearance = bubbleAppearance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
            showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
            showOnboarding = try container.decodeIfPresent(Bool.self, forKey: .showOnboarding) ?? false
            userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
            appearancePreference = try container.decodeIfPresent(AppAppearancePreference.self, forKey: .appearancePreference)
                ?? .currentSystemDefault
            bubbleAppearance = try container.decodeIfPresent(OverlayBubbleAppearance.self, forKey: .bubbleAppearance) ?? .matchApp
        }
    }

    struct Hotkeys: Codable, Sendable, Equatable {
        var optionPressToTalkEnabled: Bool
        var pressToTalkHotkey: PressToTalkHotkey
        var handsFreeGlobalHotkey: HandsFreeToggleHotkey?
        var enterFinishesHandsFreeAndSubmits: Bool
        /// When true, tapping Cmd+Option (both pressed and released within
        /// ~300ms with no other key in between) opens the Voce action picker
        /// — a single discoverable entry point for dictionary fix and
        /// snippet creation. New installs ship with this on; the keyCode
        /// shortcuts below stay dormant unless the user sets them in
        /// Advanced Settings.
        var voceActionsTapEnabled: Bool
        var dictionaryCorrectionHotkey: VoceKeyboardShortcut
        var snippetCreationHotkey: VoceKeyboardShortcut

        enum CodingKeys: String, CodingKey {
            case optionPressToTalkEnabled
            case pressToTalkHotkey
            case pressToTalkModifier
            case handsFreeGlobalHotkey
            case handsFreeGlobalKeyCode
            case enterFinishesHandsFreeAndSubmits
            case voceActionsTapEnabled
            case dictionaryCorrectionHotkey
            case snippetCreationHotkey
        }

        init(
            optionPressToTalkEnabled: Bool,
            pressToTalkHotkey: PressToTalkHotkey = .default,
            handsFreeGlobalHotkey: HandsFreeToggleHotkey? = .init(hotkey: .keyCode(79)),
            enterFinishesHandsFreeAndSubmits: Bool = true,
            voceActionsTapEnabled: Bool = true,
            dictionaryCorrectionHotkey: VoceKeyboardShortcut = .disabledSentinel,
            snippetCreationHotkey: VoceKeyboardShortcut = .disabledSentinel
        ) {
            self.optionPressToTalkEnabled = optionPressToTalkEnabled
            self.pressToTalkHotkey = pressToTalkHotkey
            self.handsFreeGlobalHotkey = handsFreeGlobalHotkey
            self.enterFinishesHandsFreeAndSubmits = enterFinishesHandsFreeAndSubmits
            self.voceActionsTapEnabled = voceActionsTapEnabled
            self.dictionaryCorrectionHotkey = dictionaryCorrectionHotkey
            self.snippetCreationHotkey = snippetCreationHotkey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Preserve the historical default for upgraded installs whose stored
            // preferences predate this key, while keeping new installs default-off
            // via AppPreferences.default.
            optionPressToTalkEnabled = try container.decodeIfPresent(Bool.self, forKey: .optionPressToTalkEnabled) ?? true
            if let hotkey = try container.decodeIfPresent(PressToTalkHotkey.self, forKey: .pressToTalkHotkey) {
                pressToTalkHotkey = hotkey
            } else if let legacyModifier = try container.decodeIfPresent(PressToTalkModifier.self, forKey: .pressToTalkModifier) {
                pressToTalkHotkey = legacyModifier.asHotkey
            } else {
                pressToTalkHotkey = .default
            }
            if let hotkey = try container.decodeIfPresent(HandsFreeToggleHotkey.self, forKey: .handsFreeGlobalHotkey) {
                handsFreeGlobalHotkey = hotkey
            } else if let legacyHotkey = try container.decodeIfPresent(HandsFreeHotkey.self, forKey: .handsFreeGlobalHotkey) {
                handsFreeGlobalHotkey = .init(hotkey: legacyHotkey)
            } else if let legacyKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .handsFreeGlobalKeyCode) {
                handsFreeGlobalHotkey = .init(hotkey: .keyCode(legacyKeyCode))
            } else {
                handsFreeGlobalHotkey = .init(hotkey: .keyCode(79))
            }
            // Decoder fallback stays false so upgraded installs keep their historical
            // press-to-talk-release behaviour. New installs flip it on via the explicit
            // `Hotkeys.init(...)` default and the `.default` AppPreferences below.
            // Note: this flag is consulted in BOTH `submitActiveRecording` (hands-free
            // Enter) and `pressToTalkStop` (release-to-submit), so silently flipping it
            // for upgraders would change their press-to-talk flow, not just hands-free.
            enterFinishesHandsFreeAndSubmits = try container.decodeIfPresent(Bool.self, forKey: .enterFinishesHandsFreeAndSubmits) ?? false
            // Voce action picker: additive feature — surface to upgraders too.
            // They get the new tap-Cmd+Option entry point alongside any
            // legacy shortcut they had previously customised.
            voceActionsTapEnabled = try container.decodeIfPresent(Bool.self, forKey: .voceActionsTapEnabled) ?? true
            // Decoder fallback is `.disabledSentinel` so an upgrade from a
            // pre-shortcut version doesn't silently install global shortcuts
            // (Ctrl+Option+F/S would be swallowed system-wide). Users who
            // previously customised these shortcuts have their value encoded
            // in JSON and will keep it. Users who used the prior built-in
            // default also have it encoded (it was always written via
            // `encode(to:)` below) so they keep it too.
            dictionaryCorrectionHotkey = try container.decodeIfPresent(VoceKeyboardShortcut.self, forKey: .dictionaryCorrectionHotkey)
                ?? .disabledSentinel
            snippetCreationHotkey = try container.decodeIfPresent(VoceKeyboardShortcut.self, forKey: .snippetCreationHotkey)
                ?? .disabledSentinel
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(optionPressToTalkEnabled, forKey: .optionPressToTalkEnabled)
            try container.encode(pressToTalkHotkey, forKey: .pressToTalkHotkey)
            try container.encodeIfPresent(handsFreeGlobalHotkey, forKey: .handsFreeGlobalHotkey)
            try container.encode(enterFinishesHandsFreeAndSubmits, forKey: .enterFinishesHandsFreeAndSubmits)
            try container.encode(voceActionsTapEnabled, forKey: .voceActionsTapEnabled)
            try container.encode(dictionaryCorrectionHotkey, forKey: .dictionaryCorrectionHotkey)
            try container.encode(snippetCreationHotkey, forKey: .snippetCreationHotkey)
        }
    }

    struct Dictation: Codable, Sendable, Equatable {
        var localeIdentifier: String
        var engineMode: DictationEngineMode
        var cloud: CloudDictationPreferences

        init(
            localeIdentifier: String = "en-US",
            engineMode: DictationEngineMode = .local,
            cloud: CloudDictationPreferences = .init()
        ) {
            self.localeIdentifier = localeIdentifier
            self.engineMode = engineMode
            self.cloud = cloud
        }

        enum CodingKeys: String, CodingKey {
            case localeIdentifier
            case engineMode
            case cloud
            case modelDirectoryPath
            case modelArch
            case keepModelWarm
            case modelPath
            case whisperCLIPath
            case threadCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localeIdentifier = try container.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "en-US"
            engineMode = try container.decodeIfPresent(DictationEngineMode.self, forKey: .engineMode) ?? .local
            cloud = try container.decodeIfPresent(CloudDictationPreferences.self, forKey: .cloud) ?? .init()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(localeIdentifier, forKey: .localeIdentifier)
            try container.encode(engineMode, forKey: .engineMode)
            try container.encode(cloud, forKey: .cloud)
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
        var dictationPolishingEnabled: Bool
        var workflows: [AIWorkflow]

        init(
            isEnabled: Bool = true,
            defaultHandsFreeWorkflowID: UUID? = AIWorkflow.aiPromptID,
            handsFreeFinishHotkey: HandsFreeHotkey? = nil,
            leadingPhraseSelectionEnabled: Bool = true,
            dictationPolishingEnabled: Bool = false,
            workflows: [AIWorkflow] = AIWorkflow.builtIns
        ) {
            self.isEnabled = isEnabled
            self.defaultHandsFreeWorkflowID = defaultHandsFreeWorkflowID
            self.handsFreeFinishHotkey = handsFreeFinishHotkey
            self.leadingPhraseSelectionEnabled = leadingPhraseSelectionEnabled
            self.dictationPolishingEnabled = dictationPolishingEnabled
            self.workflows = workflows
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            defaultHandsFreeWorkflowID = try container.decodeIfPresent(UUID.self, forKey: .defaultHandsFreeWorkflowID) ?? AIWorkflow.aiPromptID
            handsFreeFinishHotkey = try container.decodeIfPresent(HandsFreeHotkey.self, forKey: .handsFreeFinishHotkey)
            leadingPhraseSelectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .leadingPhraseSelectionEnabled) ?? true
            dictationPolishingEnabled = try container.decodeIfPresent(Bool.self, forKey: .dictationPolishingEnabled) ?? false
            workflows = try container.decodeIfPresent([AIWorkflow].self, forKey: .workflows) ?? AIWorkflow.builtIns
        }
    }

    struct Billing: Codable, Sendable, Equatable {
        var subscriberEmail: String

        init(subscriberEmail: String = "") {
            self.subscriberEmail = subscriberEmail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subscriberEmail = try container.decodeIfPresent(String.self, forKey: .subscriberEmail) ?? ""
        }
    }

    var general: General
    var hotkeys: Hotkeys
    var dictation: Dictation
    var insertion: Insertion
    var media: Media
    var ai: AI
    var billing: Billing

    var lexiconEntries: [LexiconEntry]
    var globalStyleProfile: StyleProfile
    var appStyleProfiles: [String: StyleProfile]
    var appDictationEnginePreferences: [String: AppDictationEnginePreference]
    var appAnchorOverrides: [String: AppAnchorOverride]
    var snippets: [Snippet]
    var voiceCommands: [VoiceCommand]
    var scratchPadContent: String
    var metricsRecordingSecondsToday: Double
    var metricsRecordingSecondsLifetime: Double
    var metricsLifetimeTrackingStartedAt: Date?
    var metricsLastRecordingDate: String
    var metricsBestTypingWordsPerMinute: Double

    init(
        general: General,
        hotkeys: Hotkeys,
        dictation: Dictation,
        insertion: Insertion,
        media: Media,
        ai: AI,
        billing: Billing = Billing(),
        lexiconEntries: [LexiconEntry],
        globalStyleProfile: StyleProfile,
        appStyleProfiles: [String: StyleProfile],
        appDictationEnginePreferences: [String: AppDictationEnginePreference],
        appAnchorOverrides: [String: AppAnchorOverride],
        snippets: [Snippet],
        voiceCommands: [VoiceCommand],
        scratchPadContent: String = "",
        metricsRecordingSecondsToday: Double = 0,
        metricsRecordingSecondsLifetime: Double = 0,
        metricsLifetimeTrackingStartedAt: Date? = nil,
        metricsLastRecordingDate: String = "",
        metricsBestTypingWordsPerMinute: Double = 0
    ) {
        self.general = general
        self.hotkeys = hotkeys
        self.dictation = dictation
        self.insertion = insertion
        self.media = media
        self.ai = ai
        self.billing = billing
        self.lexiconEntries = lexiconEntries
        self.globalStyleProfile = globalStyleProfile
        self.appStyleProfiles = appStyleProfiles
        self.appDictationEnginePreferences = appDictationEnginePreferences
        self.appAnchorOverrides = appAnchorOverrides
        self.snippets = snippets
        self.voiceCommands = voiceCommands
        self.scratchPadContent = scratchPadContent
        self.metricsRecordingSecondsToday = metricsRecordingSecondsToday
        self.metricsRecordingSecondsLifetime = metricsRecordingSecondsLifetime
        self.metricsLifetimeTrackingStartedAt = metricsLifetimeTrackingStartedAt
        self.metricsLastRecordingDate = metricsLastRecordingDate
        self.metricsBestTypingWordsPerMinute = metricsBestTypingWordsPerMinute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general = try container.decode(General.self, forKey: .general)
        hotkeys = try container.decode(Hotkeys.self, forKey: .hotkeys)
        dictation = try container.decode(Dictation.self, forKey: .dictation)
        insertion = try container.decode(Insertion.self, forKey: .insertion)
        media = try container.decode(Media.self, forKey: .media)
        ai = try container.decodeIfPresent(AI.self, forKey: .ai) ?? AI()
        billing = try container.decodeIfPresent(Billing.self, forKey: .billing) ?? Billing()
        lexiconEntries = try container.decodeIfPresent([LexiconEntry].self, forKey: .lexiconEntries) ?? []
        globalStyleProfile = try container.decodeIfPresent(StyleProfile.self, forKey: .globalStyleProfile) ?? AppPreferences.default.globalStyleProfile
        appStyleProfiles = try container.decodeIfPresent([String: StyleProfile].self, forKey: .appStyleProfiles) ?? [:]
        appDictationEnginePreferences = try container.decodeIfPresent([String: AppDictationEnginePreference].self, forKey: .appDictationEnginePreferences) ?? [:]
        appAnchorOverrides = try container.decodeIfPresent([String: AppAnchorOverride].self, forKey: .appAnchorOverrides) ?? [:]
        snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        voiceCommands = try container.decodeIfPresent([VoiceCommand].self, forKey: .voiceCommands) ?? VoiceCommand.builtIns
        scratchPadContent = try container.decodeIfPresent(String.self, forKey: .scratchPadContent) ?? ""
        metricsRecordingSecondsToday = try container.decodeIfPresent(Double.self, forKey: .metricsRecordingSecondsToday) ?? 0
        metricsRecordingSecondsLifetime = try container.decodeIfPresent(Double.self, forKey: .metricsRecordingSecondsLifetime) ?? 0
        metricsLifetimeTrackingStartedAt = try container.decodeIfPresent(Date.self, forKey: .metricsLifetimeTrackingStartedAt)
        metricsLastRecordingDate = try container.decodeIfPresent(String.self, forKey: .metricsLastRecordingDate) ?? ""
        metricsBestTypingWordsPerMinute = try container.decodeIfPresent(Double.self, forKey: .metricsBestTypingWordsPerMinute) ?? 0
    }

    static var `default`: AppPreferences {
        return AppPreferences(
            general: .init(
                launchAtLoginEnabled: false,
                showDockIcon: true,
                showOnboarding: true,
                appearancePreference: .currentSystemDefault
            ),
            hotkeys: .init(
                optionPressToTalkEnabled: false,
                pressToTalkHotkey: .default,
                handsFreeGlobalHotkey: .init(hotkey: .keyCode(79)),
                enterFinishesHandsFreeAndSubmits: true,
                voceActionsTapEnabled: true,
                dictionaryCorrectionHotkey: .disabledSentinel,
                snippetCreationHotkey: .disabledSentinel
            ),
            dictation: .init(
                localeIdentifier: "en-US",
                engineMode: .local,
                cloud: .init(
                    provider: .openAI,
                    refinementEnabled: true,
                    apiKeySource: .keychain
                )
            ),
            insertion: .init(orderedMethods: [.direct, .accessibility, .clipboardPaste]),
            media: .init(pauseDuringHandsFree: true, pauseDuringPressToTalk: true),
            ai: .init(),
            billing: .init(),
            lexiconEntries: seededHiddenLexiconEntries,
            globalStyleProfile: .init(
                name: "Default",
                tone: .natural,
                structureMode: .paragraph,
                fillerPolicy: .balanced,
                commandPolicy: .transform
            ),
            appStyleProfiles: [:],
            appDictationEnginePreferences: [:],
            appAnchorOverrides: [:],
            snippets: [],
            voiceCommands: VoiceCommand.builtIns,
            scratchPadContent: "",
            metricsRecordingSecondsToday: 0,
            metricsRecordingSecondsLifetime: 0,
            metricsLifetimeTrackingStartedAt: nil,
            metricsLastRecordingDate: "",
            metricsBestTypingWordsPerMinute: 0
        )
    }

    mutating func normalize() {
        migrateCustomInsertTextCommandsToSnippets()

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
        if !hotkeys.optionPressToTalkEnabled && hotkeys.handsFreeGlobalHotkey == nil {
            hotkeys.handsFreeGlobalHotkey = .init(hotkey: .keyCode(79))
        }
        var existingWorkflows = ai.workflows
        existingWorkflows.removeAll { $0.id == AIWorkflow.askID }

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
            if AIWorkflow.builtInByID[updated.id] != nil {
                updated.isBuiltIn = true
            }
            if updated.id == AIWorkflow.legacyCustomPromptID {
                updated.isBuiltIn = false
            }
            if case .modifier? = updated.handsFreeFinishHotkey {
                updated.handsFreeFinishHotkey = nil
            }
            return updated
        }
        ai.workflows = existingWorkflows
        if ai.defaultHandsFreeWorkflowID == nil
            || !ai.workflows.contains(where: { $0.id == ai.defaultHandsFreeWorkflowID })
        {
            ai.defaultHandsFreeWorkflowID = AIWorkflow.aiPromptID
        }
        if case .modifier? = ai.handsFreeFinishHotkey {
            ai.handsFreeFinishHotkey = nil
        }

        dictation.localeIdentifier = dictation.localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dictation.localeIdentifier.isEmpty {
            dictation.localeIdentifier = "en-US"
        }
        appDictationEnginePreferences = appDictationEnginePreferences.reduce(into: [:]) { partialResult, entry in
            let bundleID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, entry.value != .followGlobal else {
                return
            }
            partialResult[bundleID] = entry.value
        }

        billing.subscriberEmail = billing.subscriberEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func runtimeRelevantSnapshot() -> AppPreferences {
        var snapshot = self
        snapshot.normalize()
        snapshot.scratchPadContent = ""
        snapshot.metricsRecordingSecondsToday = 0
        snapshot.metricsRecordingSecondsLifetime = 0
        snapshot.metricsLifetimeTrackingStartedAt = nil
        snapshot.metricsLastRecordingDate = ""
        snapshot.metricsBestTypingWordsPerMinute = 0
        snapshot.general.userName = ""
        snapshot.general.appearancePreference = .currentSystemDefault
        snapshot.billing.subscriberEmail = ""
        return snapshot
    }

    func requiresRuntimeRebuild(comparedTo other: AppPreferences) -> Bool {
        runtimeRelevantSnapshot() != other.runtimeRelevantSnapshot()
    }
}

extension AppPreferences {
    var usesCloudDictationConfiguration: Bool {
        dictation.engineMode == .cloud || appDictationEnginePreferences.values.contains(.cloud)
    }

    var visibleLexiconEntries: [LexiconEntry] {
        lexiconEntries.filter { entry in
            !Self.seededHiddenLexiconEntries.contains(entry)
        }
    }

    mutating func migrateCustomInsertTextCommandsToSnippets() {
        let customInsertCommands = voiceCommands.filter { command in
            !command.isBuiltIn && {
                if case .insertText = command.action { return true }
                return false
            }()
        }

        guard !customInsertCommands.isEmpty else { return }

        for command in customInsertCommands {
            guard case .insertText(let text) = command.action else { continue }
            let trigger = command.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !expansion.isEmpty else { continue }

            let alreadyExists = snippets.contains { snippet in
                snippet.scope == .global &&
                snippet.trigger.caseInsensitiveCompare(trigger) == .orderedSame
            }

            if !alreadyExists {
                snippets.append(Snippet(trigger: trigger, expansion: expansion, scope: .global))
            }
        }

        voiceCommands.removeAll { command in
            !command.isBuiltIn && {
                if case .insertText = command.action { return true }
                return false
            }()
        }
    }
}

struct DictationEngineModeResolver: Sendable, Equatable {
    var globalMode: DictationEngineMode
    var appPreferences: [String: AppDictationEnginePreference]
    var cloudModeAvailable: Bool

    func resolve(for appContext: AppContext?) -> DictationEngineMode {
        let configuredMode: DictationEngineMode
        if let bundleID = appContext?.bundleIdentifier,
           let preference = appPreferences[bundleID] {
            configuredMode = preference.resolvedMode(globalMode: globalMode)
        } else {
            configuredMode = globalMode
        }

        if configuredMode == .cloud && !cloudModeAvailable {
            return .local
        }

        return configuredMode
    }
}
