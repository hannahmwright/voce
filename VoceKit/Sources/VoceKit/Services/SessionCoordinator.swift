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
        var rawTranscript = raw

        let snippetStartedAt = clock.now
        rawTranscript.text = await snippetService.apply(to: rawTranscript.text, appContext: active.appContext)
        Self.logger.notice(
            "Snippet expansion finished in \(self.secondsSince(snippetStartedAt, clock: clock), format: .fixed(precision: 2))s"
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
                transcript: CleanTranscript(text: rawTranscript.text),
                outcome: CleanupOutcome(source: .localOnly)
            )
        } else {
            cleanupResult = try await prepareCleanTranscript(
                raw: rawTranscript,
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
        let finalText = voiceCommandService.apply(to: cleanupResult.transcript.text)
        Self.logger.notice(
            "Voice command transform finished in \(self.secondsSince(voiceCommandsStartedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        Self.logger.notice(
            "Session finaliseTranscript total \(self.secondsSince(startedAt, clock: clock), format: .fixed(precision: 2))s"
        )

        return FinalizedTranscript(
            rawText: rawTranscript.text,
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

        do {
            let cleaned = try await engines.cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            return CleanupExecutionResult(
                transcript: cleaned,
                outcome: CleanupOutcome(source: .localSuccess)
            )
        } catch {
            var fallback = try await engines.fallbackCleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            let warning = "Primary cleanup unavailable, used local fallback."
            fallback.uncertaintyFlags.append(warning)
            return CleanupExecutionResult(
                transcript: fallback,
                outcome: CleanupOutcome(source: .localFallback, warning: warning)
            )
        }
    }
}
