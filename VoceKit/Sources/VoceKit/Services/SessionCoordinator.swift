import Foundation
import OSLog

public enum SessionCoordinatorError: Error, LocalizedError {
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        }
    }
}

public struct SessionProcessingEngines: Sendable {
    public let transcriptionEngine: any TranscriptionEngine
    public let cleanupEngine: any CleanupEngine
    public let fallbackCleanupEngine: any CleanupEngine

    public init(
        transcriptionEngine: any TranscriptionEngine,
        cleanupEngine: any CleanupEngine,
        fallbackCleanupEngine: any CleanupEngine
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.cleanupEngine = cleanupEngine
        self.fallbackCleanupEngine = fallbackCleanupEngine
    }
}

public actor SessionCoordinator {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "SessionCoordinator")
    private struct ActiveSession: Sendable {
        var appContext: AppContext
        var startedAt: Date
    }

    private struct CleanupExecutionResult: Sendable {
        var transcript: CleanTranscript
        var outcome: CleanupOutcome
    }

    private let captureService: AudioCaptureService
    private let engineResolver: @Sendable (AppContext) async -> SessionProcessingEngines
    private let lexiconService: PersonalLexiconService
    private let styleProfileService: StyleProfileService
    private let snippetService: SnippetService
    private let voiceCommandService: VoiceCommandService
    private let learningEngine: LearningEngine?

    private var activeSessions: [SessionID: ActiveSession] = [:]
    private(set) var isHandsFreeEnabled: Bool = false

    public init(
        captureService: AudioCaptureService,
        transcriptionEngine: TranscriptionEngine,
        cleanupEngine: CleanupEngine,
        lexiconService: PersonalLexiconService,
        styleProfileService: StyleProfileService,
        snippetService: SnippetService = SnippetService(),
        voiceCommandService: VoiceCommandService = VoiceCommandService(),
        fallbackCleanupEngine: CleanupEngine = RuleBasedCleanupEngine(),
        learningEngine: LearningEngine? = nil
    ) {
        self.captureService = captureService
        self.engineResolver = { _ in
            SessionProcessingEngines(
                transcriptionEngine: transcriptionEngine,
                cleanupEngine: cleanupEngine,
                fallbackCleanupEngine: fallbackCleanupEngine
            )
        }
        self.lexiconService = lexiconService
        self.styleProfileService = styleProfileService
        self.snippetService = snippetService
        self.voiceCommandService = voiceCommandService
        self.learningEngine = learningEngine
    }

    public init(
        captureService: AudioCaptureService,
        engineResolver: @escaping @Sendable (AppContext) async -> SessionProcessingEngines,
        lexiconService: PersonalLexiconService,
        styleProfileService: StyleProfileService,
        snippetService: SnippetService = SnippetService(),
        voiceCommandService: VoiceCommandService = VoiceCommandService(),
        learningEngine: LearningEngine? = nil
    ) {
        self.captureService = captureService
        self.engineResolver = engineResolver
        self.lexiconService = lexiconService
        self.styleProfileService = styleProfileService
        self.snippetService = snippetService
        self.voiceCommandService = voiceCommandService
        self.learningEngine = learningEngine
    }

    @discardableResult
    public func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        let sessionID = SessionID()
        try await captureService.beginCapture(sessionID: sessionID)
        activeSessions[sessionID] = ActiveSession(appContext: appContext, startedAt: Date())
        return sessionID
    }

    /// Registers a session for streaming transcription (audio capture managed externally).
    public func registerStreamingSession(appContext: AppContext) -> SessionID {
        let sessionID = SessionID()
        activeSessions[sessionID] = ActiveSession(appContext: appContext, startedAt: Date())
        return sessionID
    }

    public func stopPressToTalk(sessionID: SessionID, languageHints: [String] = ["en-US"]) async throws -> FinalizedTranscript {
        // Remove session before the first await so actor reentrancy cannot process
        // the same session twice while transcription/cleanup are in flight.
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        let audioURL = try await captureService.endCapture(sessionID: sessionID)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let engines = await engineResolver(active.appContext)
        let rawTranscript = try await engines.transcriptionEngine.transcribe(audioURL: audioURL, languageHints: languageHints)

        return try await finaliseTranscript(rawTranscript, active: active, engines: engines, sourceSessionID: sessionID)
    }

    /// Accepts a pre-built transcript (e.g. from streaming) and runs cleanup.
    public func processStreamingTranscript(
        _ rawTranscript: RawTranscript,
        sessionID: SessionID,
        processingNote: String? = nil,
        styleOverride: StyleProfile? = nil,
        skipsCleanup: Bool = false
    ) async throws -> FinalizedTranscript {
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        let engines = await engineResolver(active.appContext)
        return try await finaliseTranscript(
            rawTranscript,
            active: active,
            engines: engines,
            processingNote: processingNote,
            styleOverride: styleOverride,
            skipsCleanup: skipsCleanup,
            sourceSessionID: sessionID
        )
    }

    /// Finalises a streaming session from captured audio written by the UI-layer
    /// preview engine.
    public func processStreamingAudio(
        audioURL: URL,
        sessionID: SessionID,
        languageHints: [String] = ["en-US"],
        processingNote: String? = nil,
        styleOverride: StyleProfile? = nil,
        skipsCleanup: Bool = false
    ) async throws -> FinalizedTranscript {
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        defer { try? FileManager.default.removeItem(at: audioURL) }
        let engines = await engineResolver(active.appContext)
        let rawTranscript = try await engines.transcriptionEngine.transcribe(audioURL: audioURL, languageHints: languageHints)
        return try await finaliseTranscript(
            rawTranscript,
            active: active,
            engines: engines,
            processingNote: processingNote,
            styleOverride: styleOverride,
            skipsCleanup: skipsCleanup,
            sourceSessionID: sessionID
        )
    }

    private func finaliseTranscript(
        _ raw: RawTranscript,
        active: ActiveSession,
        engines: SessionProcessingEngines,
        processingNote: String? = nil,
        styleOverride: StyleProfile? = nil,
        skipsCleanup: Bool = false,
        sourceSessionID: SessionID
    ) async throws -> FinalizedTranscript {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let rawTranscript = raw

        // Detect snippet triggers on the raw recognizer text and swap them for
        // opaque placeholders; expansions are inserted verbatim at the very end,
        // so cleanup, lexicon, voice commands and cloud refinement can neither
        // mangle the trigger nor rewrite the expansion.
        let snippetStartedAt = clock.now
        let protectedSnippets = await snippetService.protect(rawTranscript.text, appContext: active.appContext)
        var protectedTranscript = rawTranscript
        protectedTranscript.text = protectedSnippets.text
        Self.logger.notice(
            "Snippet detection finished in \(self.secondsSince(snippetStartedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        let profileStartedAt = clock.now
        let profile = if let styleOverride {
            styleOverride
        } else {
            await styleProfileService.resolve(for: active.appContext)
        }
        let lexicon = await lexiconService.snapshot(for: active.appContext)
        Self.logger.notice(
            "Profile + lexicon resolution finished in \(self.secondsSince(profileStartedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        let cleanupStartedAt = clock.now
        let cleanupResult: CleanupExecutionResult
        if skipsCleanup {
            cleanupResult = CleanupExecutionResult(
                transcript: CleanTranscript(text: protectedTranscript.text),
                outcome: CleanupOutcome(source: .localOnly)
            )
        } else {
            cleanupResult = try await prepareCleanTranscript(
                raw: protectedTranscript,
                protectedSnippets: protectedSnippets,
                profile: profile,
                lexicon: lexicon,
                appContext: active.appContext,
                engines: engines
            )
        }
        Self.logger.notice(
            "Cleanup finished in \(self.secondsSince(cleanupStartedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        // Apply voice commands (punctuation, whitespace, "delete that", custom) after cleanup.
        let voiceCommandsStartedAt = clock.now
        let commandedText = voiceCommandService.apply(to: cleanupResult.transcript.text)
        Self.logger.notice(
            "Voice command transform finished in \(self.secondsSince(voiceCommandsStartedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        // Expand snippets last so expansions are inserted verbatim: cleanup would
        // otherwise flatten multi-line expansions, strip "fillers" inside them,
        // apply lexicon/voice commands to them, or let the ranker reject them.
        let finalText = protectedSnippets.restore(
            in: commandedText,
            capitalizingAtTextStart: Self.capitalizesSentences(profile: profile, appContext: active.appContext)
        )

        Self.logger.notice(
            "Session finaliseTranscript total \(self.secondsSince(startedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        return FinalizedTranscript(
            // Raw text keeps the expansions (verbatim), as when snippets were
            // expanded before cleanup, so "copy transcript" copies them.
            rawText: protectedSnippets.restore(in: protectedSnippets.text),
            cleanText: finalText,
            removedFillers: cleanupResult.transcript.removedFillers,
            cleanupOutcome: cleanupResult.outcome,
            appContext: active.appContext,
            audioURL: nil,
            processingNote: processingNote,
            sourceSessionID: sourceSessionID
        )
    }

    private func secondsSince(_ start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let duration = start.duration(to: clock.now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    public func cancel(sessionID: SessionID) async {
        activeSessions.removeValue(forKey: sessionID)
        await captureService.cancelCapture(sessionID: sessionID)
    }

    public func setHandsFreeEnabled(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
    }

    private func prepareCleanTranscript(
        raw: RawTranscript,
        protectedSnippets: SnippetProtectedText,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext,
        engines: SessionProcessingEngines
    ) async throws -> CleanupExecutionResult {
        if profile.commandPolicy == .passthrough,
           appContext.isIDE,
           raw.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return CleanupExecutionResult(
                transcript: CleanTranscript(text: raw.text),
                outcome: CleanupOutcome(source: .localOnly)
            )
        }

        // Nothing but snippet triggers (e.g. the dictation is only "sig"):
        // there is nothing to clean, so don't send it anywhere.
        if protectedSnippets.hasPlaceholders, !protectedSnippets.hasContentOutsidePlaceholders {
            return CleanupExecutionResult(
                transcript: CleanTranscript(text: raw.text),
                outcome: CleanupOutcome(source: .localOnly)
            )
        }

        let cleaned: CleanTranscript
        do {
            cleaned = try await engines.cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
        } catch {
            var fallback = try await localFallbackCleanup(
                raw: raw,
                protectedSnippets: protectedSnippets,
                profile: profile,
                lexicon: lexicon,
                engines: engines
            )
            let warning = "Primary cleanup unavailable, used local fallback."
            fallback.uncertaintyFlags.append(warning)
            return CleanupExecutionResult(
                transcript: fallback,
                outcome: CleanupOutcome(source: .localFallback, warning: warning)
            )
        }

        guard protectedSnippets.placeholdersAreIntact(in: cleaned.text) else {
            // The primary engine (typically cloud refinement) duplicated or
            // altered a snippet placeholder, so its output can't receive the
            // expansions. Use local cleanup for this dictation; the primary
            // engine worked, so no "unavailable" warning is shown.
            let fallback = try await localFallbackCleanup(
                raw: raw,
                protectedSnippets: protectedSnippets,
                profile: profile,
                lexicon: lexicon,
                engines: engines
            )
            return CleanupExecutionResult(
                transcript: fallback,
                outcome: CleanupOutcome(source: .localFallback)
            )
        }

        return CleanupExecutionResult(
            transcript: cleaned,
            outcome: CleanupOutcome(source: .localSuccess)
        )
    }

    private func localFallbackCleanup(
        raw: RawTranscript,
        protectedSnippets: SnippetProtectedText,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        engines: SessionProcessingEngines
    ) async throws -> CleanTranscript {
        let fallback = try await engines.fallbackCleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
        guard protectedSnippets.placeholdersAreIntact(in: fallback.text) else {
            // Last resort: the uncleaned text, which holds every placeholder.
            return CleanTranscript(text: raw.text)
        }
        return fallback
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.mitchellh.ghostty",
        "co.zeit.hyper", "com.github.wez.wezterm",
    ]

    /// Whether an expansion at the very start of the text should be
    /// capitalized: only for sentence-capitalizing profiles, and never in
    /// IDEs, terminals or with command passthrough ("gs" → "git status").
    static func capitalizesSentences(profile: StyleProfile, appContext: AppContext) -> Bool {
        guard profile.commandPolicy != .passthrough,
              !appContext.isIDE,
              !terminalBundleIdentifiers.contains(appContext.bundleIdentifier)
        else { return false }
        switch profile.structureMode {
        case .paragraph, .email, .bullets:
            return true
        case .natural, .command:
            return false
        }
    }
}
