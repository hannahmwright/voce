#if os(macOS)
import Dispatch
import Foundation
import Testing
@testable import VoceKit

private final class StaticPlaybackDetector: MediaPlaybackStateDetector {
    private let result: PlaybackDetectionResult
    let lastDetectedDisplayID: String?

    init(_ result: PlaybackDetectionResult, lastDetectedDisplayID: String? = nil) {
        self.result = result
        self.lastDetectedDisplayID = lastDetectedDisplayID
    }

    func detect() async -> PlaybackDetectionResult {
        result
    }
}

private final class DelayedPlaybackDetector: MediaPlaybackStateDetector {
    private let result: PlaybackDetectionResult
    private let delayNanoseconds: UInt64
    let lastDetectedDisplayID: String?

    init(_ result: PlaybackDetectionResult, delayNanoseconds: UInt64, lastDetectedDisplayID: String? = nil) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
        self.lastDetectedDisplayID = lastDetectedDisplayID
    }

    func detect() async -> PlaybackDetectionResult {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

private final class SequencedPlaybackDetector: MediaPlaybackStateDetector {
    private var results: [PlaybackDetectionResult]
    private let fallback: PlaybackDetectionResult
    private var displayIDs: [String?]
    let fallbackDisplayID: String?
    private(set) var lastDetectedDisplayID: String?
    private(set) var detectCalls = 0

    init(
        _ results: [PlaybackDetectionResult],
        fallback: PlaybackDetectionResult = .unknown,
        displayIDs: [String?] = [],
        fallbackDisplayID: String? = nil
    ) {
        self.results = results
        self.fallback = fallback
        self.displayIDs = displayIDs
        self.fallbackDisplayID = fallbackDisplayID
    }

    func detect() async -> PlaybackDetectionResult {
        detectCalls += 1
        if !displayIDs.isEmpty {
            lastDetectedDisplayID = displayIDs.removeFirst()
        } else {
            lastDetectedDisplayID = fallbackDisplayID
        }
        if !results.isEmpty {
            return results.removeFirst()
        }
        return fallback
    }
}

@MainActor
private final class FakeMediaRemoteBridge: MediaRemoteBridging {
    var activateCalls = 0
    var deactivateCalls = 0

    var anyApplicationIsPlayingValue: Bool?
    var nowPlayingApplicationDisplayIDValue: String?
    var nowPlayingApplicationIsPlayingValue: Bool?
    var nowPlayingPlaybackStateValue: Int?
    var nowPlayingPlaybackRateValue: Double?
    var playbackStateIsAdvancingValue: Bool?
    var anyApplicationIsPlayingSequence: [Bool?] = []
    var nowPlayingApplicationDisplayIDSequence: [String?] = []
    var nowPlayingApplicationIsPlayingSequence: [Bool?] = []
    var nowPlayingPlaybackStateSequence: [Int?] = []
    var nowPlayingPlaybackRateSequence: [Double?] = []
    var playbackStateIsAdvancingSequence: [Bool?] = []

    func activate() {
        activateCalls += 1
    }

    func deactivate() {
        deactivateCalls += 1
    }

    func anyApplicationIsPlaying() async -> Bool? {
        pullNext(from: &anyApplicationIsPlayingSequence, fallback: anyApplicationIsPlayingValue)
    }

    func nowPlayingApplicationDisplayID() async -> String? {
        pullNext(from: &nowPlayingApplicationDisplayIDSequence, fallback: nowPlayingApplicationDisplayIDValue)
    }

    func nowPlayingApplicationIsPlaying() async -> Bool? {
        pullNext(from: &nowPlayingApplicationIsPlayingSequence, fallback: nowPlayingApplicationIsPlayingValue)
    }

    func nowPlayingPlaybackState() async -> Int? {
        pullNext(from: &nowPlayingPlaybackStateSequence, fallback: nowPlayingPlaybackStateValue)
    }

    func nowPlayingPlaybackRate() async -> Double? {
        pullNext(from: &nowPlayingPlaybackRateSequence, fallback: nowPlayingPlaybackRateValue)
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        pullNext(from: &playbackStateIsAdvancingSequence, fallback: playbackStateIsAdvancingValue)
    }

    private func pullNext<Value>(from sequence: inout [Value?], fallback: Value?) -> Value? {
        if !sequence.isEmpty {
            return sequence.removeFirst()
        }
        return fallback
    }
}

@MainActor
private final class MediaKeySendRecorder {
    private(set) var sendCalls = 0
    var nextResult = true

    func send() -> Bool {
        sendCalls += 1
        return nextResult
    }
}

@MainActor
private final class MediaCommandRecorder {
    private(set) var commands: [MediaInterruptionCommand] = []
    var nextResult = true

    func send(_ command: MediaInterruptionCommand) -> Bool {
        commands.append(command)
        return nextResult
    }
}

private actor FakeSpotifyPlaybackController: SpotifyPlaybackControlling {
    private var states: [AppPlaybackState]
    private let fallbackState: AppPlaybackState
    private let pauseSucceeds: Bool
    private(set) var pauseCalls = 0
    private(set) var playCalls = 0

    init(
        _ states: [AppPlaybackState],
        fallbackState: AppPlaybackState = .unknown,
        pauseSucceeds: Bool = true
    ) {
        self.states = states
        self.fallbackState = fallbackState
        self.pauseSucceeds = pauseSucceeds
    }

    func playerState() async -> AppPlaybackState {
        if !states.isEmpty {
            return states.removeFirst()
        }
        return fallbackState
    }

    func pause() async -> Bool {
        pauseCalls += 1
        return pauseSucceeds
    }

    func play() async -> Bool {
        playCalls += 1
        return true
    }
}

private actor FakeAppleMusicPlaybackController: AppleMusicPlaybackControlling {
    private var states: [AppPlaybackState]
    private let fallbackState: AppPlaybackState
    private let pauseSucceeds: Bool
    private(set) var pauseCalls = 0
    private(set) var playCalls = 0

    init(
        _ states: [AppPlaybackState],
        fallbackState: AppPlaybackState = .unknown,
        pauseSucceeds: Bool = true
    ) {
        self.states = states
        self.fallbackState = fallbackState
        self.pauseSucceeds = pauseSucceeds
    }

    func playerState() async -> AppPlaybackState {
        if !states.isEmpty {
            return states.removeFirst()
        }
        return fallbackState
    }

    func pause() async -> Bool {
        pauseCalls += 1
        return pauseSucceeds
    }

    func play() async -> Bool {
        playCalls += 1
        return true
    }
}

private actor FakeChromePlaybackController: ChromePlaybackControlling {
    private var states: [AppPlaybackState]
    private let fallbackState: AppPlaybackState
    private let pauseSucceeds: Bool
    private(set) var pauseCalls = 0
    private(set) var playCalls = 0

    init(
        _ states: [AppPlaybackState],
        fallbackState: AppPlaybackState = .unknown,
        pauseSucceeds: Bool = true
    ) {
        self.states = states
        self.fallbackState = fallbackState
        self.pauseSucceeds = pauseSucceeds
    }

    func playerState() async -> AppPlaybackState {
        if !states.isEmpty {
            return states.removeFirst()
        }
        return fallbackState
    }

    func pause() async -> Bool {
        pauseCalls += 1
        return pauseSucceeds
    }

    func play() async -> Bool {
        playCalls += 1
        return true
    }
}

private actor FakeBlockedPlaybackController: AppPlaybackControlling {
    private(set) var pauseCalls = 0
    private(set) var playCalls = 0

    func playerState() async -> AppPlaybackState {
        .playing
    }

    func pause() async -> Bool {
        pauseCalls += 1
        return false
    }

    func pauseOutcome() async -> AppPlaybackPauseOutcome {
        pauseCalls += 1
        return .blocked
    }

    func play() async -> Bool {
        playCalls += 1
        return true
    }
}

private enum MediaDisplayID {
    static let chrome = "com.google.Chrome"
    static let edge = "com.microsoft.edgemac"
    static let brave = "com.brave.Browser"
    static let arc = "company.thebrowser.Browser"
    static let safari = "com.apple.Safari"
    static let firefox = "org.mozilla.firefox"
    static let appleMusic = "com.apple.Music"
    static let applePodcasts = "com.apple.podcasts"
    static let appleTV = "com.apple.TV"
    static let quickTime = "com.apple.QuickTimePlayerX"
    static let spotify = "com.spotify.client"
    static let vlc = "org.videolan.vlc"
    static let iina = "com.colliderli.iina"
    static let faceTime = "com.apple.FaceTime"
    static let zoom = "us.zoom.xos"
    static let teams = "com.microsoft.teams2"
    static let webex = "com.cisco.webexmeetingsapp"
    static let slack = "com.tinyspeck.slackmacgap"
    static let discord = "com.hnc.Discord"
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 250_000_000,
    intervalNanoseconds: UInt64 = 5_000_000,
    _ condition: @MainActor @escaping () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return await condition()
}

@MainActor
@Test("Media interruption pauses when playback is active")
func mediaInterruptionPausesWhenPlaybackIsActive() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(recorder.sendCalls == 1)
}

@Test("Media key tap location defaults to HID")
func mediaKeyTapLocationDefaultsToHID() {
    let tap = voceMediaKeyTapLocation(environment: [:])
    #expect(tap == .cghidEventTap)
}

@Test("Media key tap location honors annotated override")
func mediaKeyTapLocationHonorsAnnotatedOverride() {
    let tap = voceMediaKeyTapLocation(environment: ["MURMUR_MEDIA_KEY_TAP": "annotated"])
    #expect(tap == .cgAnnotatedSessionEventTap)
}

@Test("Media key tap location falls back to HID for invalid overrides")
func mediaKeyTapLocationFallsBackToHIDForInvalidOverride() {
    let tap = voceMediaKeyTapLocation(environment: ["MURMUR_MEDIA_KEY_TAP": "nope"])
    #expect(tap == .cghidEventTap)
}

@MainActor
@Test("Media interruption skips generic weak playback detection")
func mediaInterruptionSkipsGenericWeakPlaybackDetection() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.likelyPlaying, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(recorder.sendCalls == 0, "Weak MediaRemote evidence must not send a global media key.")
}

@MainActor
@Test("Media interruption uses app-specific pause for likely Spotify playback")
func mediaInterruptionUsesSpotifyPauseForLikelySpotifyPlayback() async {
    let recorder = MediaKeySendRecorder()
    let spotify = FakeSpotifyPlaybackController([.playing])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.likelyPlaying, .notPlaying]),
        spotifyPlaybackController: spotify,
        sendPlayPauseKey: { recorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(recorder.sendCalls == 0)
    #expect(await spotify.pauseCalls == 1)
}

@MainActor
@Test("Media interruption uses app-specific pause for likely Apple Music playback")
func mediaInterruptionUsesAppleMusicPauseForLikelyAppleMusicPlayback() async {
    let recorder = MediaKeySendRecorder()
    let appleMusic = FakeAppleMusicPlaybackController([.playing])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.likelyPlaying],
            displayIDs: [MediaDisplayID.appleMusic]
        ),
        appleMusicPlaybackController: appleMusic,
        sendPlayPauseKey: { recorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(recorder.sendCalls == 0)
    #expect(await appleMusic.pauseCalls == 1)
}

@MainActor
@Test("Confirmed unmatched playback pauses and resumes with explicit commands")
func confirmedUnmatchedPlaybackUsesExplicitPauseAndPlayCommands() async {
    let sources = [
        ("Unmatched media app", "com.example.MediaApp"),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.playing, .notPlaying, .notPlaying],
                displayIDs: [source.1, source.1, source.1]
            ),
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0
        )

        guard let token = await service.beginInterruption() else {
            Issue.record("Expected interruption token for \(source.0) playback.")
            continue
        }

        #expect(recorder.commands == [.pause], "\(source.0) should pause with an explicit pause command.")

        service.endInterruption(token: token)
        let didResume = await waitUntil {
            recorder.commands == [.pause, .play]
        }

        #expect(didResume, "\(source.0) should resume with an explicit play command.")
    }
}

@MainActor
@Test("Generic confirmed playback uses explicit pause and play commands")
func genericConfirmedPlaybackUsesExplicitPauseAndPlayCommands() async {
    let recorder = MediaCommandRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .notPlaying]),
        sendPlayPauseKey: { false },
        sendMediaCommand: { recorder.send($0) },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for confirmed generic playback.")
        return
    }

    #expect(recorder.commands == [.pause])

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        recorder.commands == [.pause, .play]
    }

    #expect(didResume)
}

@MainActor
@Test("Custom browser pathways use owner-specific controllers")
func customBrowserPathwaysUseOwnerSpecificControllers() async {
    let sources: [(String, String, InterruptedPlaybackOwner)] = [
        ("Chrome", MediaDisplayID.chrome, .chrome),
        ("Edge", MediaDisplayID.edge, .edge),
        ("Brave", MediaDisplayID.brave, .brave),
        ("Arc", MediaDisplayID.arc, .arc),
        ("Safari", MediaDisplayID.safari, .safari),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let controller = FakeSpotifyPlaybackController([.paused])
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.playing, .notPlaying, .unknown],
                displayIDs: [source.1, source.1, source.1]
            ),
            playbackControllerOverrides: [source.2: controller],
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0,
            unknownResumeRetryDelayNanoseconds: 0
        )

        guard let token = await service.beginInterruption() else {
            Issue.record("Expected interruption token for \(source.0) playback.")
            continue
        }

        #expect(await controller.pauseCalls == 1, "\(source.0) should pause through its owner controller.")
        #expect(recorder.commands.isEmpty, "\(source.0) should not use the generic command when its controller succeeds.")

        service.endInterruption(token: token)
        let didResume = await waitUntil {
            await controller.playCalls == 1
        }

        #expect(didResume, "\(source.0) should resume through its owner controller.")
        #expect(recorder.commands.isEmpty, "\(source.0) should not resume through the generic command when its controller succeeds.")
    }
}

@MainActor
@Test("Blocked custom browser pathways do not fall back or create resume tokens")
func blockedCustomBrowserPathwaysDoNotFallBackOrCreateResumeTokens() async {
    let sources: [(String, String, InterruptedPlaybackOwner)] = [
        ("Chrome", MediaDisplayID.chrome, .chrome),
        ("Safari", MediaDisplayID.safari, .safari),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let controller = FakeBlockedPlaybackController()
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.playing],
                displayIDs: [source.1]
            ),
            playbackControllerOverrides: [source.2: controller],
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0
        )

        let token = await service.beginInterruption()

        #expect(token == nil, "\(source.0) blocked media should not create a resume token.")
        #expect(await controller.pauseCalls == 1, "\(source.0) should use its custom controller before blocking.")
        #expect(await controller.playCalls == 0, "\(source.0) should not schedule custom resume for blocked media.")
        #expect(recorder.commands.isEmpty, "\(source.0) blocked media should not fall back to generic commands.")
    }
}

@MainActor
@Test("Custom browser pause success keeps browser resume strategy when global playback remains active")
func customBrowserPauseSuccessKeepsBrowserResumeStrategyWhenGlobalPlaybackRemainsActive() async {
    let recorder = MediaCommandRecorder()
    let chrome = FakeChromePlaybackController([.paused])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .playing, .unknown],
            displayIDs: [MediaDisplayID.chrome, MediaDisplayID.chrome, MediaDisplayID.chrome]
        ),
        chromePlaybackController: chrome,
        sendPlayPauseKey: { false },
        sendMediaCommand: { recorder.send($0) },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected token after Chrome-specific pause succeeded.")
        return
    }

    #expect(await chrome.pauseCalls == 1)
    #expect(recorder.commands.isEmpty, "Successful Chrome pause should not fall back even if global playback remains active.")

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        await chrome.playCalls == 1
    }

    #expect(didResume)
    #expect(recorder.commands.isEmpty)
}

@Test("Browser media risk blocks meeting URLs but allows ordinary media URLs")
func browserMediaRiskClassifiesMeetingURLs() {
    let blockedURLs = [
        "https://meet.google.com/abc-defg-hij",
        "https://teams.microsoft.com/l/meetup-join/abc",
        "https://calendar.teams.microsoft.com/meet/abc",
        "https://teams.live.com/meet/abc",
        "https://zoom.us/j/123456789",
        "https://app.zoom.us/wc/123/start",
        "https://webex.com/meet/example",
        "https://subdomain.webex.com/meet/example",
    ]

    for blockedURL in blockedURLs {
        #expect(BrowserMediaRisk.isBlockedBrowserMediaURL(blockedURL), "\(blockedURL) should be blocked.")
    }

    let allowedURLs = [
        "https://www.youtube.com/watch?v=abc",
        "https://music.youtube.com/watch?v=abc",
        "https://open.spotify.com/track/abc",
        "https://soundcloud.com/example/track",
        "https://vimeo.com/123456",
        "https://example.com/watch",
        "https://example.com/?next=https://meet.google.com/abc-defg-hij",
        "not a url",
    ]

    for allowedURL in allowedURLs {
        #expect(!BrowserMediaRisk.isBlockedBrowserMediaURL(allowedURL), "\(allowedURL) should be allowed.")
    }
}

@MainActor
@Test("Custom Apple media pathways use owner-specific controllers")
func customAppleMediaPathwaysUseOwnerSpecificControllers() async {
    let sources: [(String, String, InterruptedPlaybackOwner)] = [
        ("Apple Music", MediaDisplayID.appleMusic, .appleMusic),
        ("Apple Podcasts", MediaDisplayID.applePodcasts, .applePodcasts),
        ("Apple TV", MediaDisplayID.appleTV, .appleTV),
        ("QuickTime", MediaDisplayID.quickTime, .quickTime),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let controller = FakeSpotifyPlaybackController([.paused])
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.playing, .notPlaying, .unknown],
                displayIDs: [source.1, source.1, source.1]
            ),
            playbackControllerOverrides: [source.2: controller],
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0,
            unknownResumeRetryDelayNanoseconds: 0
        )

        guard let token = await service.beginInterruption() else {
            Issue.record("Expected interruption token for \(source.0) playback.")
            continue
        }

        #expect(await controller.pauseCalls == 1, "\(source.0) should pause through its owner controller.")
        #expect(recorder.commands.isEmpty)

        service.endInterruption(token: token)
        let didResume = await waitUntil {
            await controller.playCalls == 1
        }

        #expect(didResume, "\(source.0) should resume through its owner controller.")
        #expect(recorder.commands.isEmpty)
    }
}

@MainActor
@Test("Custom local player pathways use owner-specific controllers")
func customLocalPlayerPathwaysUseOwnerSpecificControllers() async {
    let sources: [(String, String, InterruptedPlaybackOwner)] = [
        ("VLC", MediaDisplayID.vlc, .vlc),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let controller = FakeSpotifyPlaybackController([.paused])
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.playing, .notPlaying, .unknown],
                displayIDs: [source.1, source.1, source.1]
            ),
            playbackControllerOverrides: [source.2: controller],
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0,
            unknownResumeRetryDelayNanoseconds: 0
        )

        guard let token = await service.beginInterruption() else {
            Issue.record("Expected interruption token for \(source.0) playback.")
            continue
        }

        #expect(await controller.pauseCalls == 1, "\(source.0) should pause through its owner controller.")
        #expect(recorder.commands.isEmpty)

        service.endInterruption(token: token)
        let didResume = await waitUntil {
            await controller.playCalls == 1
        }

        #expect(didResume, "\(source.0) should resume through its owner controller.")
        #expect(recorder.commands.isEmpty)
    }
}

@MainActor
@Test("Firefox and IINA default custom pathways use explicit MediaRemote commands")
func mediaRemoteOnlyCustomPathwaysUseExplicitCommands() async {
    let sources = [
        ("Firefox", MediaDisplayID.firefox),
        ("IINA", MediaDisplayID.iina),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.playing, .notPlaying, .notPlaying],
                displayIDs: [source.1, source.1, source.1]
            ),
            useDefaultPlaybackControllers: true,
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0,
            unknownResumeRetryDelayNanoseconds: 0
        )

        guard let token = await service.beginInterruption() else {
            Issue.record("Expected interruption token for \(source.0) playback.")
            continue
        }

        #expect(recorder.commands == [.pause], "\(source.0) should pause with an explicit command.")

        service.endInterruption(token: token)
        let didResume = await waitUntil {
            recorder.commands == [.pause, .play]
        }

        #expect(didResume, "\(source.0) should resume with an explicit command.")
    }
}

@MainActor
@Test("MediaRemote-only custom pathways skip resume when playback already restarted")
func mediaRemoteOnlyCustomPathwaysSkipResumeWhenPlaybackAlreadyRestarted() async {
    let sources = [
        ("Firefox", MediaDisplayID.firefox),
        ("IINA", MediaDisplayID.iina),
    ]

    for source in sources {
        let recorder = MediaCommandRecorder()
        let detector = SequencedPlaybackDetector(
            [.playing, .notPlaying, .playing],
            displayIDs: [source.1, source.1, source.1]
        )
        let service = MacMediaInterruptionService(
            playbackDetector: detector,
            useDefaultPlaybackControllers: true,
            sendPlayPauseKey: { false },
            sendMediaCommand: { recorder.send($0) },
            minimumResumeDelayNanoseconds: 0,
            pauseConfirmationDelayNanoseconds: 0,
            unknownResumeRetryDelayNanoseconds: 0
        )

        guard let token = await service.beginInterruption() else {
            Issue.record("Expected interruption token for \(source.0) playback.")
            continue
        }

        #expect(recorder.commands == [.pause], "\(source.0) should pause with an explicit command.")

        service.endInterruption(token: token)
        let didRunResumeDetection = await waitUntil {
            detector.detectCalls >= 3
        }

        #expect(didRunResumeDetection)
        #expect(recorder.commands == [.pause], "\(source.0) should not send resume when MediaRemote says playback is active.")
    }
}

@MainActor
@Test("Conference apps are custom blocked pathways")
func conferenceAppsAreCustomBlockedPathways() async {
    let sources = [
        ("FaceTime", MediaDisplayID.faceTime),
        ("Zoom", MediaDisplayID.zoom),
        ("Teams", MediaDisplayID.teams),
        ("Webex", MediaDisplayID.webex),
        ("Slack", MediaDisplayID.slack),
        ("Discord", MediaDisplayID.discord),
    ]

    for detectionResult in [PlaybackDetectionResult.playing, .likelyPlaying] {
        for source in sources {
            let recorder = MediaCommandRecorder()
            let service = MacMediaInterruptionService(
                playbackDetector: SequencedPlaybackDetector(
                    [detectionResult],
                    displayIDs: [source.1]
                ),
                sendPlayPauseKey: { false },
                sendMediaCommand: { recorder.send($0) },
                pauseConfirmationDelayNanoseconds: 0
            )

            let token = await service.beginInterruption()

            #expect(token == nil, "\(source.0) should not be interrupted for \(detectionResult).")
            #expect(recorder.commands.isEmpty, "\(source.0) should not receive media commands for \(detectionResult).")
        }
    }
}

@MainActor
@Test("Chrome confirmed playback uses Chrome-specific pause and resume")
func chromeConfirmedPlaybackUsesChromeSpecificPauseAndResume() async {
    let recorder = MediaKeySendRecorder()
    let chrome = FakeChromePlaybackController([.paused])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .unknown],
            displayIDs: [MediaDisplayID.chrome, MediaDisplayID.chrome, MediaDisplayID.chrome]
        ),
        chromePlaybackController: chrome,
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for Chrome playback.")
        return
    }

    #expect(recorder.sendCalls == 0)
    #expect(await chrome.pauseCalls == 1)

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        await chrome.playCalls == 1
    }

    #expect(didResume)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Media interruption uses Chrome-specific pause for likely Chrome playback")
func mediaInterruptionUsesChromePauseForLikelyChromePlayback() async {
    let recorder = MediaKeySendRecorder()
    let chrome = FakeChromePlaybackController([.playing])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.likelyPlaying],
            displayIDs: [MediaDisplayID.chrome]
        ),
        chromePlaybackController: chrome,
        sendPlayPauseKey: { recorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(recorder.sendCalls == 0)
    #expect(await chrome.pauseCalls == 1)
}

@MainActor
@Test("Chrome fallback uses explicit pause and play commands")
func chromeFallbackUsesExplicitPauseAndPlayCommands() async {
    let recorder = MediaCommandRecorder()
    let chrome = FakeChromePlaybackController([.unknown], pauseSucceeds: false)
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .notPlaying],
            displayIDs: [MediaDisplayID.chrome, MediaDisplayID.chrome, MediaDisplayID.chrome]
        ),
        chromePlaybackController: chrome,
        sendPlayPauseKey: { false },
        sendMediaCommand: { recorder.send($0) },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected fallback interruption token for Chrome playback.")
        return
    }

    #expect(await chrome.pauseCalls == 1)
    #expect(recorder.commands == [.pause], "Failed Chrome-specific pause should fall back to an explicit pause command.")

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        recorder.commands == [.pause, .play]
    }

    #expect(didResume, "Playback paused with an explicit fallback command must also resume with explicit play.")
    #expect(await chrome.playCalls == 0, "Fallback pause should not resume through Chrome tab scripting.")
}

@MainActor
@Test("Weak stale browser and Apple Music signals never toggle global media key")
func weakStaleBrowserAndAppleMusicSignalsDoNotToggleGlobalMediaKey() async {
    let sources: [(String, String, InterruptedPlaybackOwner)] = [
        ("Chrome", MediaDisplayID.chrome, .chrome),
        ("Safari", MediaDisplayID.safari, .safari),
        ("Apple Music", MediaDisplayID.appleMusic, .appleMusic),
    ]

    for source in sources {
        let recorder = MediaKeySendRecorder()
        let controller = FakeSpotifyPlaybackController([.paused])
        let service = MacMediaInterruptionService(
            playbackDetector: SequencedPlaybackDetector(
                [.likelyPlaying, .notPlaying],
                displayIDs: [source.1, source.1]
            ),
            playbackControllerOverrides: [source.2: controller],
            sendPlayPauseKey: { recorder.send() },
            pauseConfirmationDelayNanoseconds: 0
        )

        let token = await service.beginInterruption()

        #expect(token == nil, "\(source.0) weak playback evidence should not create a resume token.")
        #expect(await controller.pauseCalls == 0, "\(source.0) stale weak evidence should not pause.")
        #expect(recorder.sendCalls == 0, "\(source.0) weak playback evidence must not send play/pause.")
    }
}

@MainActor
@Test("Weak stale scriptable app signals do not pause or create resume tokens")
func weakStaleScriptableAppSignalsDoNotCreateResumeTokens() async {
    let spotifyRecorder = MediaKeySendRecorder()
    let spotify = FakeSpotifyPlaybackController([.paused])
    let spotifyService = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.likelyPlaying],
            displayIDs: [MediaDisplayID.spotify]
        ),
        spotifyPlaybackController: spotify,
        sendPlayPauseKey: { spotifyRecorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let spotifyToken = await spotifyService.beginInterruption()

    #expect(spotifyToken == nil)
    #expect(await spotify.pauseCalls == 0)
    #expect(spotifyRecorder.sendCalls == 0)

    let appleMusicRecorder = MediaKeySendRecorder()
    let appleMusic = FakeAppleMusicPlaybackController([.paused])
    let appleMusicService = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.likelyPlaying],
            displayIDs: [MediaDisplayID.appleMusic]
        ),
        appleMusicPlaybackController: appleMusic,
        sendPlayPauseKey: { appleMusicRecorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let appleMusicToken = await appleMusicService.beginInterruption()

    #expect(appleMusicToken == nil)
    #expect(await appleMusic.pauseCalls == 0)
    #expect(appleMusicRecorder.sendCalls == 0)

    let chromeRecorder = MediaKeySendRecorder()
    let chrome = FakeChromePlaybackController([.paused])
    let chromeService = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.likelyPlaying],
            displayIDs: [MediaDisplayID.chrome]
        ),
        chromePlaybackController: chrome,
        sendPlayPauseKey: { chromeRecorder.send() },
        pauseConfirmationDelayNanoseconds: 0
    )

    let chromeToken = await chromeService.beginInterruption()

    #expect(chromeToken == nil)
    #expect(await chrome.pauseCalls == 0)
    #expect(chromeRecorder.sendCalls == 0)
}

@MainActor
@Test("Spotify confirmed playback uses Spotify-specific pause and resume")
func spotifyConfirmedPlaybackUsesSpotifySpecificPauseAndResume() async {
    let recorder = MediaKeySendRecorder()
    let spotify = FakeSpotifyPlaybackController([.paused])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .unknown],
            displayIDs: [MediaDisplayID.spotify, MediaDisplayID.spotify, MediaDisplayID.spotify]
        ),
        spotifyPlaybackController: spotify,
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for Spotify playback.")
        return
    }

    #expect(recorder.sendCalls == 0)
    #expect(await spotify.pauseCalls == 1)

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        await spotify.playCalls == 1
    }

    #expect(didResume)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Apple Music confirmed playback uses Apple Music-specific pause and resume")
func appleMusicConfirmedPlaybackUsesAppleMusicSpecificPauseAndResume() async {
    let recorder = MediaKeySendRecorder()
    let appleMusic = FakeAppleMusicPlaybackController([.paused])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .unknown],
            displayIDs: [MediaDisplayID.appleMusic, MediaDisplayID.appleMusic, MediaDisplayID.appleMusic]
        ),
        appleMusicPlaybackController: appleMusic,
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for Apple Music playback.")
        return
    }

    #expect(recorder.sendCalls == 0)
    #expect(await appleMusic.pauseCalls == 1)

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        await appleMusic.playCalls == 1
    }

    #expect(didResume)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Spotify fallback uses explicit pause and play commands")
func spotifyFallbackUsesExplicitPauseAndPlayCommands() async {
    let recorder = MediaCommandRecorder()
    let spotify = FakeSpotifyPlaybackController([.paused], pauseSucceeds: false)
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .notPlaying],
            displayIDs: [MediaDisplayID.spotify, MediaDisplayID.spotify, MediaDisplayID.spotify]
        ),
        spotifyPlaybackController: spotify,
        sendPlayPauseKey: { false },
        sendMediaCommand: { recorder.send($0) },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected fallback interruption token for Spotify playback.")
        return
    }

    #expect(await spotify.pauseCalls == 1)
    #expect(recorder.commands == [.pause], "Failed Spotify-specific pause should fall back to an explicit pause command.")

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        recorder.commands == [.pause, .play]
    }

    #expect(didResume, "Playback paused with an explicit fallback command must also resume with explicit play.")
    #expect(await spotify.playCalls == 0, "Fallback pause should not resume through Spotify AppleScript.")
}

@MainActor
@Test("Media interruption skips pause when playback is not active")
func mediaInterruptionSkipsPauseWhenPlaybackIsNotActive() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.notPlaying),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Media interruption skips pause when playback state is unknown")
func mediaInterruptionSkipsPauseWhenPlaybackStateIsUnknown() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.unknown),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Unknown playback state must not start phantom media playback")
func unknownPlaybackStateMustNotStartPhantomMediaPlayback() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.unknown),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token == nil, "Unknown state must not produce a token — sending play/pause would start media")
    #expect(recorder.sendCalls == 0, "No media key must be sent when playback state is unknown")
}

@MainActor
@Test("Media interruption resumes only when the token was active")
func mediaInterruptionResumesOnlyForActiveToken() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for active playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Media interruption ignores invalid or duplicate tokens")
func mediaInterruptionIgnoresInvalidOrDuplicateTokens() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for active playback.")
        return
    }

    service.endInterruption(token: MediaInterruptionToken())
    #expect(recorder.sendCalls == 1)

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(recorder.sendCalls == 2)

    service.endInterruption(token: token)
    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Media interruption only resumes after the last active token ends")
func mediaInterruptionResumesAfterLastActiveToken() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    guard let first = await service.beginInterruption() else {
        Issue.record("Expected first interruption token for active playback.")
        return
    }

    guard let second = await service.beginInterruption() else {
        Issue.record("Expected second interruption token while interruption is active.")
        return
    }

    #expect(recorder.sendCalls == 1)

    service.endInterruption(token: first)
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(recorder.sendCalls == 1)

    service.endInterruption(token: second)
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Media interruption skips resume when playback already restarted")
func mediaInterruptionSkipsResumeIfPlaybackAlreadyActive() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .playing]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for active playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 1)
}

@MainActor
@Test("Media interruption keeps token when pause confirmation lags")
func mediaInterruptionKeepsTokenWhenPauseConfirmationLags() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .playing, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    let token = await service.beginInterruption()

    #expect(token != nil)

    guard let token else {
        Issue.record("Expected interruption token even when pause confirmation is delayed.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Media interruption keeps token when cancelled after pause succeeds")
func mediaInterruptionKeepsTokenWhenCancelledAfterPauseSucceeds() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 150_000_000
    )

    let task = Task { @MainActor in
        await service.beginInterruption()
    }

    let didPause = await waitUntil {
        recorder.sendCalls == 1
    }
    #expect(didPause)
    task.cancel()

    guard let token = await task.value else {
        Issue.record("Expected interruption token after pause already succeeded.")
        return
    }

    service.endInterruption(token: token)
    let didResume = await waitUntil {
        recorder.sendCalls == 2
    }

    #expect(didResume)
}

@MainActor
@Test("Media interruption still skips resume when playback never paused")
func mediaInterruptionSkipsResumeWhenPlaybackNeverPaused() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .playing, .playing]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for active playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 1)
}

@MainActor
@Test("Media interruption skips resume when playback state is unknown")
func mediaInterruptionSkipsResumeIfPlaybackStateIsUnknown() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .unknown, .unknown, .unknown]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for confirmed active playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 1)
}

@MainActor
@Test("Media interruption resumes when unknown state settles to not playing")
func mediaInterruptionResumesWhenUnknownStateSettlesToNotPlaying() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector([.playing, .notPlaying, .unknown, .notPlaying]),
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for confirmed active playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Media interruption resumes on unresolved unknown for interrupted Spotify playback")
func mediaInterruptionResumesOnUnresolvedUnknownForSpotify() async {
    let recorder = MediaKeySendRecorder()
    let spotify = FakeSpotifyPlaybackController([.playing, .paused])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .unknown, .unknown, .unknown],
            displayIDs: [nil, nil, nil, nil, nil]
        ),
        spotifyPlaybackController: spotify,
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for Spotify playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 0)
    #expect(await spotify.pauseCalls == 1)
    #expect(await spotify.playCalls == 1)
}

@MainActor
@Test("Media interruption skips Spotify resume when Spotify is already playing again")
func mediaInterruptionSkipsSpotifyResumeWhenSpotifyAlreadyPlaying() async {
    let recorder = MediaKeySendRecorder()
    let spotify = FakeSpotifyPlaybackController([.playing, .playing])
    let service = MacMediaInterruptionService(
        playbackDetector: SequencedPlaybackDetector(
            [.playing, .notPlaying, .unknown, .unknown, .unknown],
            displayIDs: [nil, nil, nil, nil, nil]
        ),
        spotifyPlaybackController: spotify,
        sendPlayPauseKey: { recorder.send() },
        minimumResumeDelayNanoseconds: 0,
        pauseConfirmationDelayNanoseconds: 0,
        unknownResumeRetryDelayNanoseconds: 0
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for Spotify playback.")
        return
    }

    service.endInterruption(token: token)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(recorder.sendCalls == 0)
    #expect(await spotify.pauseCalls == 1)
    #expect(await spotify.playCalls == 0)
}

@MainActor
@Test("Detector returns likely playing when weak positives are present")
func detectorReturnsLikelyPlayingForWeakPositives() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.anyApplicationIsPlayingValue = false

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector prefers strong-negative evidence over weak positives")
func detectorPrefersStrongNegativeOverWeakPositiveProbes() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector returns not playing for trusted strong-negative state signal")
func detectorReturnsNotPlayingForTrustedStrongNegativeStateSignal() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector treats error-default state=0 + rate=nil as weak-positive candidate")
func detectorTreatsErrorDefaultStateAsWeakPositiveCandidate() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 0
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector treats uncorroborated nonzero state + weak-positive as likely playing")
func detectorTreatsUncorroboratedNonzeroStateAsWeakPositiveCandidate() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector treats paused signature without weak positives as not playing")
func detectorTreatsPausedSignatureWithoutWeakPositiveSignalsAsNotPlaying() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = false
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector treats observed Spotify paused signature as not playing")
func detectorTreatsObservedSpotifyPausedSignatureAsNotPlaying() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = false
    bridge.nowPlayingApplicationDisplayIDValue = "com.spotify.client"
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector treats paused signatures from popular media apps as not playing")
func detectorTreatsPopularPausedSignaturesAsNotPlaying() async {
    let sources = [
        ("Chrome", MediaDisplayID.chrome),
        ("Edge", MediaDisplayID.edge),
        ("Brave", MediaDisplayID.brave),
        ("Arc", MediaDisplayID.arc),
        ("Safari", MediaDisplayID.safari),
        ("Firefox", MediaDisplayID.firefox),
        ("Apple Music", MediaDisplayID.appleMusic),
        ("Apple Podcasts", MediaDisplayID.applePodcasts),
        ("Apple TV", MediaDisplayID.appleTV),
        ("QuickTime", MediaDisplayID.quickTime),
        ("Spotify", MediaDisplayID.spotify),
        ("VLC", MediaDisplayID.vlc),
        ("IINA", MediaDisplayID.iina),
    ]

    for source in sources {
        let bridge = FakeMediaRemoteBridge()
        bridge.anyApplicationIsPlayingValue = false
        bridge.nowPlayingApplicationDisplayIDValue = source.1
        bridge.nowPlayingApplicationIsPlayingValue = false
        bridge.nowPlayingPlaybackStateValue = 2
        bridge.nowPlayingPlaybackRateValue = nil

        let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
        let result = await detector.detect()

        #expect(result == .notPlaying, "\(source.0) paused signature should be classified as not playing.")
    }
}

@MainActor
@Test("Detector treats generic paused signature as not playing without app identity")
func detectorTreatsGenericPausedSignatureAsNotPlayingWithoutAppIdentity() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = false
    bridge.nowPlayingApplicationDisplayIDValue = nil
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector returns unknown for transient weak-positive signal")
func detectorReturnsUnknownForTransientWeakPositiveSignal() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingSequence = [true, false]
    bridge.nowPlayingApplicationIsPlayingSequence = [false, false]
    bridge.nowPlayingPlaybackStateSequence = [0, 0]
    bridge.nowPlayingPlaybackRateSequence = [nil, nil]
    bridge.playbackStateIsAdvancingSequence = [false, false]

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .unknown)
}

@MainActor
@Test("Detector keeps not playing when rate=0 even if any=true")
func detectorKeepsNotPlayingWhenRateIsZeroAndAnyIsTrue() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector returns playing for strong positive signal only")
func detectorReturnsPlayingForStrongPositiveOnly() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 1.0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .playing)
}

@MainActor
@Test("Detector returns not playing for strong negative signal only")
func detectorReturnsNotPlayingForStrongNegativeOnly() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector returns unknown for mixed strong positive and strong negative signals")
func detectorReturnsUnknownForMixedStrongSignals() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 1.0
    bridge.nowPlayingPlaybackStateValue = 42
    bridge.playbackStateIsAdvancingValue = false

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .unknown)
}

@MainActor
@Test("Detector activates and deactivates bridge exactly once")
func detectorActivatesAndDeactivatesBridgeOnce() async {
    let bridge = FakeMediaRemoteBridge()
    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)

    _ = await detector.detect()

    #expect(bridge.activateCalls == 1)
    #expect(bridge.deactivateCalls == 1)
}

@MainActor
@Test("Cancelled beginInterruption does not send media key")
func cancelledBeginInterruptionDoesNotSendMediaKey() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: DelayedPlaybackDetector(.playing, delayNanoseconds: 50_000_000),
        sendPlayPauseKey: { recorder.send() }
    )

    let task = Task { @MainActor in
        await service.beginInterruption()
    }
    task.cancel()

    let token = await task.value
    #expect(token == nil)
    #expect(recorder.sendCalls == 0)
}

@Test("MediaRemote probe runner ignores callbacks after timeout")
func mediaRemoteProbeRunnerIgnoresLateCallbacks() async {
    let callbackQueue = DispatchQueue(label: "VoceTests.MediaRemote.Callback")
    callbackQueue.suspend()
    var resumedCallbackQueue = false
    defer {
        if !resumedCallbackQueue {
            callbackQueue.resume()
        }
    }

    let runner = MediaRemoteAsyncProbeRunner(
        timeout: .milliseconds(20),
        timeoutQueue: DispatchQueue(label: "VoceTests.MediaRemote.Timeout")
    )

    let value = await runner.run { callback in
        callbackQueue.async {
            callback(true)
        }
        callbackQueue.async {
            callback(false)
        }
    }

    #expect(value == nil)

    // Release queued callbacks after timeout to validate late callbacks are ignored.
    callbackQueue.resume()
    resumedCallbackQueue = true
    try? await Task.sleep(nanoseconds: 50_000_000)
}
#endif
