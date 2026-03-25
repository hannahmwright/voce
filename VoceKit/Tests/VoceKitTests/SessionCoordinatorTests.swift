import Foundation
import Testing
import VoceKitTestSupport
@testable import VoceKit

@Test("SessionCoordinator marks localSuccess when primary cleanup succeeds")
func sessionCoordinatorLocalSuccessOutcome() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "local success test")
    }

    let cleanupCounter = CleanupCounter()
    let cleanupEngine = CountingCleanupEngine(counter: cleanupCounter)

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: cleanupEngine,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.cleanupOutcome?.source == .localSuccess)
    #expect(result.cleanupOutcome?.warning == nil)
    #expect(await cleanupCounter.value() == 1)
    #expect(result.cleanText == "local success test cleaned")
}

@Test("SessionCoordinator falls back locally when primary cleanup fails")
func sessionCoordinatorLocalFallbackOnPrimaryFailure() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "um voceh can you clean this up")
    }

    let lexicon = PersonalLexiconService()
    await lexicon.upsert(term: "voceh", preferred: "Voce", scope: .global)

    let styles = StyleProfileService(
        globalProfile: StyleProfile(
            name: "Default",
            tone: .natural,
            structureMode: .paragraph,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        )
    )

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: FailingCleanupEngine(),
        lexiconService: lexicon,
        styleProfileService: styles,
        fallbackCleanupEngine: RuleBasedCleanupEngine()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"))
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.cleanupOutcome?.source == .localFallback)
    #expect(result.cleanupOutcome?.warning == "Primary cleanup unavailable, used local fallback.")
    #expect(result.cleanText.contains("Voce"))
    #expect(!result.cleanText.localizedCaseInsensitiveContains("um "))
}

@Test("SessionCoordinator keeps slash commands raw for IDE passthrough profile")
func sessionCoordinatorCommandPassthroughStaysLocalOnly() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "/build target")
    }

    let style = StyleProfile(
        name: "IDE",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .minimal,
        commandPolicy: .passthrough
    )

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(globalProfile: style)
    )

    let ideContext = AppContext(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", isIDE: true)
    let sessionID = try await coordinator.startPressToTalk(appContext: ideContext)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.cleanupOutcome?.source == .localOnly)
    #expect(result.cleanText == "/build target")
}

@Test("SessionCoordinator hands-free state uses explicit setter")
func sessionCoordinatorExplicitHandsFreeSetter() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: "test") },
        cleanupEngine: RuleBasedCleanupEngine(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    #expect(await coordinator.isHandsFreeEnabled == false)
    await coordinator.setHandsFreeEnabled(true)
    #expect(await coordinator.isHandsFreeEnabled == true)
    await coordinator.setHandsFreeEnabled(false)
    #expect(await coordinator.isHandsFreeEnabled == false)
}
