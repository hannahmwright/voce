#if os(macOS)
import AppKit
import IOKit.hidsystem

internal func voceMediaKeyTapLocation(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> CGEventTapLocation {
    switch environment["MURMUR_MEDIA_KEY_TAP"]?.lowercased() {
    case "annotated":
        return .cgAnnotatedSessionEventTap
    default:
        return .cghidEventTap
    }
}

public struct MediaPlaybackDiagnosticsSnapshot: Sendable, Equatable {
    public let detection: String
    public let displayID: String?
    public let anyApplicationIsPlaying: Bool?
    public let nowPlayingApplicationIsPlaying: Bool?
    public let playbackState: Int?
    public let playbackStateIsAdvancing: Bool?
    public let playbackRate: Double?
    public let stateSignalTrusted: Bool
    public let stateTrustReason: String

    public var diagnosticsText: String {
        [
            "media_detection=\(detection)",
            "media_display_id=\(displayID ?? "nil")",
            "media_any_application_is_playing=\(Self.describe(anyApplicationIsPlaying))",
            "media_now_playing_application_is_playing=\(Self.describe(nowPlayingApplicationIsPlaying))",
            "media_playback_state=\(Self.describe(playbackState))",
            "media_playback_state_is_advancing=\(Self.describe(playbackStateIsAdvancing))",
            "media_playback_rate=\(Self.describe(playbackRate))",
            "media_state_signal_trusted=\(stateSignalTrusted)",
            "media_state_trust_reason=\(stateTrustReason)"
        ].joined(separator: "\n")
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.4f", value)
    }
}

@MainActor
public final class MacMediaInterruptionService: MediaInterruptionService {
    private static let logger = VoceKitDiagnostics.logger
    private static let spotifyDisplayID = "com.spotify.client"
    private static let appleMusicDisplayID = "com.apple.Music"
    private static let applePodcastsDisplayID = "com.apple.podcasts"
    private static let appleTVDisplayID = "com.apple.TV"
    private static let quickTimeDisplayID = "com.apple.QuickTimePlayerX"
    private static let chromeDisplayID = "com.google.Chrome"
    private static let edgeDisplayID = "com.microsoft.edgemac"
    private static let braveDisplayID = "com.brave.Browser"
    private static let arcDisplayID = "company.thebrowser.Browser"
    private static let safariDisplayID = "com.apple.Safari"
    private static let firefoxDisplayID = "org.mozilla.firefox"
    private static let vlcDisplayID = "org.videolan.vlc"
    private static let iinaDisplayID = "com.colliderli.iina"
    private static let blockedMediaDisplayIDs: Set<String> = [
        "com.apple.FaceTime",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.google.meetings",
        "com.skype.skype",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
    ]
    private static let displayIDOwners: [String: InterruptedPlaybackOwner] = [
        spotifyDisplayID: .spotify,
        appleMusicDisplayID: .appleMusic,
        applePodcastsDisplayID: .applePodcasts,
        appleTVDisplayID: .appleTV,
        quickTimeDisplayID: .quickTime,
        chromeDisplayID: .chrome,
        edgeDisplayID: .edge,
        braveDisplayID: .brave,
        arcDisplayID: .arc,
        safariDisplayID: .safari,
        firefoxDisplayID: .firefox,
        vlcDisplayID: .vlc,
        iinaDisplayID: .iina,
    ]
    private static let nilDisplayIDProbeOwners: [InterruptedPlaybackOwner] = [
        .spotify,
        .appleMusic,
        .applePodcasts,
        .appleTV,
        .quickTime,
        .vlc,
    ]
    private var activeTokens: Set<UUID> = []
    private var interruptedPlaybackResumeStrategy: InterruptedPlaybackResumeStrategy?
    private let playbackDetector: any MediaPlaybackStateDetector
    private let playbackController: (InterruptedPlaybackOwner) -> any AppPlaybackControlling
    private let sendMediaCommand: (MediaInterruptionCommand) -> Bool
    /// Final fallback: synthesizes the physical play/pause media key (NX_KEYTYPE_PLAY).
    private let sendPlayPauseKey: () -> Bool
    /// When true, an unverified pause/resume (detector still reports the old state after
    /// `sendMediaCommand`) escalates to a synthetic media-key press. MediaRemote commands
    /// are fire-and-forget and silently no-op on macOS 15.4+ for non-entitled processes,
    /// so success must be confirmed by detection, never by the sender's return value.
    private let escalatesToMediaKeyOnUnverifiedCommand: Bool
    private let minimumResumeDelayNanoseconds: UInt64
    private let pauseConfirmationDelayNanoseconds: UInt64
    private let unknownResumeRetryDelayNanoseconds: UInt64
    private let maximumUnknownResumeRetryCount: Int
    private var pendingResumeTask: Task<Void, Never>?
    private var pauseSentAtUptimeNanoseconds: UInt64?

    public init() {
        let bridge = MediaRemoteBridge()
        self.playbackDetector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
        self.playbackController = { owner in
            AppPlaybackControllerFactory.controller(for: owner, sendMediaCommand: SystemMediaCommandSender.send)
        }
        self.sendMediaCommand = SystemMediaCommandSender.send
        self.sendPlayPauseKey = SystemMediaKeySender.sendPlayPause
        self.escalatesToMediaKeyOnUnverifiedCommand = true
        self.minimumResumeDelayNanoseconds = 300_000_000
        self.pauseConfirmationDelayNanoseconds = 120_000_000
        self.unknownResumeRetryDelayNanoseconds = 150_000_000
        self.maximumUnknownResumeRetryCount = 2
    }

    public static func capturePlaybackDiagnostics() async -> MediaPlaybackDiagnosticsSnapshot {
        let bridge = MediaRemoteBridge()
        bridge.activate()
        defer { bridge.deactivate() }

        async let anyApplicationIsPlaying = bridge.anyApplicationIsPlaying()
        async let nowPlayingApplicationDisplayID = bridge.nowPlayingApplicationDisplayID()
        async let nowPlayingApplicationIsPlaying = bridge.nowPlayingApplicationIsPlaying()
        async let nowPlayingPlaybackState = bridge.nowPlayingPlaybackState()
        async let nowPlayingPlaybackRate = bridge.nowPlayingPlaybackRate()

        let anyPlaying = await anyApplicationIsPlaying
        let displayID = await nowPlayingApplicationDisplayID
        let nowPlaying = await nowPlayingApplicationIsPlaying
        let playbackState = await nowPlayingPlaybackState
        let playbackRate = await nowPlayingPlaybackRate

        let trust = MultiSignalMediaPlaybackStateDetector.playbackStateTrust(
            playbackState: playbackState,
            playbackRate: playbackRate,
            nowPlaying: nowPlaying
        )

        let playbackStateIsAdvancing: Bool?
        if trust.trusted, let playbackState {
            playbackStateIsAdvancing = bridge.isPlaybackStateAdvancing(playbackState)
        } else {
            playbackStateIsAdvancing = nil
        }

        let hasStrongPositive =
            (playbackRate.map { $0 > 0 } ?? false)
            || (playbackStateIsAdvancing == true)
        let hasStrongNegative =
            (playbackRate.map { $0 == 0 } ?? false)
            || (playbackStateIsAdvancing == false)
        let hasWeakPositive = (anyPlaying == true) || (nowPlaying == true)

        let detection: String
        if anyPlaying == false,
           nowPlaying == false,
           playbackState == MultiSignalMediaPlaybackStateDetector.pausedPlaybackState,
           playbackRate == nil {
            detection = PlaybackDetectionResult.notPlaying.logValue
        } else if hasStrongPositive && !hasStrongNegative {
            detection = PlaybackDetectionResult.playing.logValue
        } else if hasStrongPositive && hasStrongNegative {
            detection = PlaybackDetectionResult.unknown.logValue
        } else if hasStrongNegative {
            detection = PlaybackDetectionResult.notPlaying.logValue
        } else if hasWeakPositive {
            detection = PlaybackDetectionResult.likelyPlaying.logValue
        } else {
            detection = PlaybackDetectionResult.unknown.logValue
        }

        return MediaPlaybackDiagnosticsSnapshot(
            detection: detection,
            displayID: displayID,
            anyApplicationIsPlaying: anyPlaying,
            nowPlayingApplicationIsPlaying: nowPlaying,
            playbackState: playbackState,
            playbackStateIsAdvancing: playbackStateIsAdvancing,
            playbackRate: playbackRate,
            stateSignalTrusted: trust.trusted,
            stateTrustReason: trust.reason
        )
    }

    init(
        playbackDetector: any MediaPlaybackStateDetector,
        spotifyPlaybackController: any SpotifyPlaybackControlling = UnavailableSpotifyPlaybackController(),
        appleMusicPlaybackController: any AppleMusicPlaybackControlling = UnavailableAppleMusicPlaybackController(),
        chromePlaybackController: any ChromePlaybackControlling = UnavailableChromePlaybackController(),
        playbackControllerOverrides: [InterruptedPlaybackOwner: any AppPlaybackControlling] = [:],
        useDefaultPlaybackControllers: Bool = false,
        sendPlayPauseKey: @escaping () -> Bool,
        sendMediaCommand: ((MediaInterruptionCommand) -> Bool)? = nil,
        minimumResumeDelayNanoseconds: UInt64 = 300_000_000,
        pauseConfirmationDelayNanoseconds: UInt64 = 120_000_000,
        unknownResumeRetryDelayNanoseconds: UInt64 = 150_000_000,
        maximumUnknownResumeRetryCount: Int = 2
    ) {
        let commandSender = sendMediaCommand ?? { _ in sendPlayPauseKey() }
        self.sendPlayPauseKey = sendPlayPauseKey
        // Escalation only makes sense when the media command sender is distinct from the
        // media-key sender; otherwise escalation would just repeat the same key press.
        self.escalatesToMediaKeyOnUnverifiedCommand = sendMediaCommand != nil
        self.playbackDetector = playbackDetector
        self.playbackController = { owner in
            if let override = playbackControllerOverrides[owner] {
                return override
            }
            switch owner {
            case .spotify:
                return spotifyPlaybackController
            case .appleMusic:
                return appleMusicPlaybackController
            case .chrome:
                return chromePlaybackController
            default:
                if useDefaultPlaybackControllers {
                    return AppPlaybackControllerFactory.controller(for: owner, sendMediaCommand: commandSender)
                }
                return UnavailableAppPlaybackController()
            }
        }
        self.sendMediaCommand = commandSender
        self.minimumResumeDelayNanoseconds = minimumResumeDelayNanoseconds
        self.pauseConfirmationDelayNanoseconds = pauseConfirmationDelayNanoseconds
        self.unknownResumeRetryDelayNanoseconds = unknownResumeRetryDelayNanoseconds
        self.maximumUnknownResumeRetryCount = maximumUnknownResumeRetryCount
    }

    public func beginInterruption() async -> MediaInterruptionToken? {
        pendingResumeTask?.cancel()
        pendingResumeTask = nil

        if Task.isCancelled {
            Self.logger.debug("Skipping media interruption because task is cancelled before detection.")
            return nil
        }

        let token = MediaInterruptionToken()
        if !activeTokens.isEmpty {
            activeTokens.insert(token.id)
            Self.logger.debug(
                "Media interruption already active. Reusing pause state. Active tokens: \(self.activeTokens.count, privacy: .public)"
            )
            return token
        }

        let detection = await playbackDetector.detect()
        let interruptedApplicationDisplayID = playbackDetector.lastDetectedDisplayID
        if let interruptedApplicationDisplayID,
           Self.blockedMediaDisplayIDs.contains(interruptedApplicationDisplayID) {
            Self.logger.notice(
                "Media interruption skipped blocked media app=\(interruptedApplicationDisplayID, privacy: .public)."
            )
            return nil
        }
        let interruptedPlaybackOwner = await identifyInterruptedPlaybackOwner(
            detection: detection,
            displayID: interruptedApplicationDisplayID
        )
        Self.logger.notice("Media interruption begin detection=\(detection.logValue, privacy: .public)")
        if Task.isCancelled {
            Self.logger.debug("Skipping media interruption because task is cancelled after detection.")
            return nil
        }

        switch detection {
        case .playing:
            if Task.isCancelled {
                Self.logger.debug("Skipping media interruption because task is cancelled before key send.")
                return nil
            }
            let pauseOutcome: AppPlaybackPauseOutcome
            let resumeStrategy: InterruptedPlaybackResumeStrategy
            if let interruptedPlaybackOwner {
                pauseOutcome = await pauseScriptablePlayback(owner: interruptedPlaybackOwner)
                Self.logger.notice(
                    "Media interruption \(interruptedPlaybackOwner.logValue, privacy: .public) pause attempted: \(pauseOutcome.logValue, privacy: .public)"
                )
                Self.logger.debug(
                    "Media interruption \(interruptedPlaybackOwner.logValue, privacy: .public) pause attempted: \(pauseOutcome.logValue, privacy: .public)"
                )
                resumeStrategy = pauseOutcome == .paused ? interruptedPlaybackOwner.resumeStrategy : .systemMediaKey
            } else {
                pauseOutcome = .failed
                resumeStrategy = .systemMediaKey
            }
            if pauseOutcome == .blocked {
                Self.logger.notice("Media interruption skipped because custom media pathway is blocked.")
                return nil
            }
            if pauseOutcome == .failed {
                let didSend = sendMediaCommand(.pause)
                Self.logger.debug("Media interruption pause command send attempted: \(didSend, privacy: .public)")
                guard didSend else { return nil }
            }

            if pauseConfirmationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pauseConfirmationDelayNanoseconds)
            }

            var postPauseDetection = await playbackDetector.detect()
            if pauseOutcome == .failed,
               postPauseDetection == .playing,
               escalatesToMediaKeyOnUnverifiedCommand {
                // The media command reported success but playback is verifiably still
                // active. MediaRemote silently no-ops on macOS 15.4+ for non-entitled
                // processes, so escalate to the synthetic play/pause media key.
                let didSendKey = sendPlayPauseKey()
                Self.logger.notice(
                    "Media interruption pause unverified after command send; media key escalation attempted: \(didSendKey, privacy: .public)"
                )
                if didSendKey {
                    if pauseConfirmationDelayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: pauseConfirmationDelayNanoseconds)
                    }
                    postPauseDetection = await playbackDetector.detect()
                }
            }
            Self.logger.notice(
                """
                Media interruption post-pause detection=\(postPauseDetection.logValue, privacy: .public) \
                initial=\(detection.logValue, privacy: .public)
                """
            )

            if postPauseDetection != .notPlaying {
                Self.logger.debug(
                    """
                    Media interruption pause was not confirmed immediately, \
                    but preserving the resume token because playback was active \
                    before the pause key send. \
                    Initial=\(detection.logValue, privacy: .public) \
                    afterPause=\(postPauseDetection.logValue, privacy: .public)
                    """
                )
            }

            activeTokens.insert(token.id)
            self.interruptedPlaybackResumeStrategy = resumeStrategy
            pauseSentAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            Self.logger.notice(
                """
                Media interruption token activated. \
                Active tokens: \(self.activeTokens.count, privacy: .public) \
                interruptedApp=\(interruptedApplicationDisplayID ?? "nil", privacy: .public) \
                interruptedOwner=\(interruptedPlaybackOwner?.logValue ?? "nil", privacy: .public) \
                resumeStrategy=\(resumeStrategy.logValue, privacy: .public)
                """
            )
            Self.logger.debug("Media interruption started. Active tokens: \(self.activeTokens.count, privacy: .public)")
            return token
        case .likelyPlaying:
            guard let interruptedPlaybackOwner else {
                Self.logger.notice("Media interruption skipped weak playback detection to avoid phantom media launch.")
                Self.logger.debug("Skipping media interruption for likelyPlaying without app-specific pause control.")
                return nil
            }
            if Task.isCancelled {
                Self.logger.debug(
                    "Skipping media interruption because task is cancelled before \(interruptedPlaybackOwner.logValue, privacy: .public) pause."
                )
                return nil
            }
            let pauseOutcome = await pauseScriptablePlayback(owner: interruptedPlaybackOwner)
            Self.logger.notice(
                "Media interruption \(interruptedPlaybackOwner.logValue, privacy: .public) pause attempted: \(pauseOutcome.logValue, privacy: .public)"
            )
            Self.logger.debug(
                "Media interruption \(interruptedPlaybackOwner.logValue, privacy: .public) pause attempted: \(pauseOutcome.logValue, privacy: .public)"
            )
            guard pauseOutcome == .paused else { return nil }

            activeTokens.insert(token.id)
            let resumeStrategy = interruptedPlaybackOwner.resumeStrategy
            interruptedPlaybackResumeStrategy = resumeStrategy
            pauseSentAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            Self.logger.notice(
                """
                Media interruption token activated. \
                Active tokens: \(self.activeTokens.count, privacy: .public) \
                interruptedApp=\(interruptedApplicationDisplayID ?? "nil", privacy: .public) \
                interruptedOwner=\(interruptedPlaybackOwner.logValue, privacy: .public) \
                resumeStrategy=\(resumeStrategy.logValue, privacy: .public)
                """
            )
            Self.logger.debug("Media interruption started. Active tokens: \(self.activeTokens.count, privacy: .public)")
            return token
        case .notPlaying, .unknown:
            Self.logger.notice("Media interruption skipped at begin because detection=\(detection.logValue, privacy: .public)")
            Self.logger.debug("Media interruption skipped. Detection: \(detection.logValue, privacy: .public)")
            return nil
        }
    }

    public func endInterruption(token: MediaInterruptionToken) {
        guard activeTokens.contains(token.id) else {
            Self.logger.debug("Ignoring endInterruption for unknown token.")
            return
        }
        activeTokens.remove(token.id)
        guard activeTokens.isEmpty else {
            Self.logger.debug(
                "Media interruption token ended but interruption remains active. Active tokens: \(self.activeTokens.count, privacy: .public)"
            )
            return
        }

        pendingResumeTask?.cancel()
        let pauseSentAtUptimeNanoseconds = self.pauseSentAtUptimeNanoseconds
        let minimumResumeDelayNanoseconds = self.minimumResumeDelayNanoseconds
        Self.logger.notice("Media interruption scheduling resume check.")
        pendingResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if let pauseSentAtUptimeNanoseconds {
                let now = DispatchTime.now().uptimeNanoseconds
                let earliestResumeTime = pauseSentAtUptimeNanoseconds &+ minimumResumeDelayNanoseconds
                if now < earliestResumeTime {
                    try? await Task.sleep(nanoseconds: earliestResumeTime - now)
                }
            }

            await self.resumePlaybackIfNeeded()
        }
        Self.logger.debug("Media interruption ended. Active tokens: 0")
    }

    private func pauseScriptablePlayback(owner: InterruptedPlaybackOwner) async -> AppPlaybackPauseOutcome {
        await playbackController(owner).pauseOutcome()
    }

    private func playScriptablePlayback(owner: InterruptedPlaybackOwner) async -> Bool {
        await playbackController(owner).play()
    }

    private func scriptablePlaybackState(owner: InterruptedPlaybackOwner) async -> AppPlaybackState {
        await playbackController(owner).playerState()
    }

    private func resumePlaybackIfNeeded() async {
        defer {
            pendingResumeTask = nil
            pauseSentAtUptimeNanoseconds = nil
            interruptedPlaybackResumeStrategy = nil
        }

        guard !Task.isCancelled else {
            Self.logger.debug("Skipping media interruption resume because task was cancelled.")
            return
        }

        guard activeTokens.isEmpty else {
            Self.logger.debug("Skipping media interruption resume because a new interruption became active.")
            return
        }

        if let scriptableOwner = interruptedPlaybackResumeStrategy?.scriptableOwner {
            let playbackState = await scriptablePlaybackState(owner: scriptableOwner)
            Self.logger.notice(
                """
                Media interruption \(scriptableOwner.logValue, privacy: .public) \
                state at resume=\(playbackState.logValue, privacy: .public)
                """
            )
            switch playbackState {
            case .playing:
                Self.logger.notice(
                    """
                    Media interruption resume skipped because \
                    \(scriptableOwner.logValue, privacy: .public) already resumed itself.
                    """
                )
                Self.logger.debug(
                    "Skipping media interruption resume because \(scriptableOwner.logValue, privacy: .public) already resumed itself."
                )
                return
            case .paused:
                let didResume = await playScriptablePlayback(owner: scriptableOwner)
                Self.logger.notice(
                    "Media interruption \(scriptableOwner.logValue, privacy: .public) resume attempted: \(didResume, privacy: .public)"
                )
                Self.logger.debug(
                    "Media interruption \(scriptableOwner.logValue, privacy: .public) resume attempted: \(didResume, privacy: .public)"
                )
                return
            case .stopped:
                Self.logger.notice(
                    "Media interruption resume skipped because \(scriptableOwner.logValue, privacy: .public) is stopped."
                )
                Self.logger.debug(
                    "Skipping media interruption resume because \(scriptableOwner.logValue, privacy: .public) is stopped."
                )
                return
            case .unknown:
                let didResume = await playScriptablePlayback(owner: scriptableOwner)
                Self.logger.notice(
                    "Media interruption \(scriptableOwner.logValue, privacy: .public) fallback resume attempted: \(didResume, privacy: .public)"
                )
                Self.logger.debug(
                    "Media interruption \(scriptableOwner.logValue, privacy: .public) fallback resume attempted: \(didResume, privacy: .public)"
                )
                return
            }
        }

        let detection = await stabilizedResumeDetection()
        Self.logger.notice("Media interruption resume detection=\(detection.logValue, privacy: .public)")
        guard !Task.isCancelled else {
            Self.logger.debug("Skipping media interruption resume because task was cancelled after detection.")
            return
        }

        guard activeTokens.isEmpty else {
            Self.logger.debug("Skipping media interruption resume because a new interruption became active after detection.")
            return
        }

        switch detection {
        case .playing, .likelyPlaying:
            Self.logger.notice(
                "Media interruption resume skipped because playback already appears active: \(detection.logValue, privacy: .public)"
            )
            Self.logger.debug(
                "Skipping media interruption resume because playback already appears active: \(detection.logValue, privacy: .public)"
            )
        case .unknown:
            Self.logger.notice("Media interruption resume skipped because playback state is unknown.")
            Self.logger.debug("Skipping media interruption resume because playback state is unknown.")
        case .notPlaying:
            let didSend = sendMediaCommand(.play)
            Self.logger.notice("Media interruption resume command send attempted: \(didSend, privacy: .public)")
            Self.logger.debug("Media interruption resume command send attempted: \(didSend, privacy: .public)")
            guard didSend, escalatesToMediaKeyOnUnverifiedCommand else { return }
            if pauseConfirmationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pauseConfirmationDelayNanoseconds)
            }
            guard !Task.isCancelled, activeTokens.isEmpty else { return }
            let postResumeDetection = await playbackDetector.detect()
            // Re-check after the detect suspension: a new interruption may have begun
            // and paused media; pressing the key now would un-pause it.
            guard !Task.isCancelled, activeTokens.isEmpty else { return }
            if postResumeDetection == .notPlaying {
                // Same MediaRemote caveat as the pause path: the command sender cannot
                // report real success, so verify and escalate to the media key.
                let didSendKey = sendPlayPauseKey()
                Self.logger.notice(
                    "Media interruption resume unverified after command send; media key escalation attempted: \(didSendKey, privacy: .public)"
                )
            }
        }
    }

    private func identifyInterruptedPlaybackOwner(
        detection: PlaybackDetectionResult,
        displayID: String?
    ) async -> InterruptedPlaybackOwner? {
        guard detection == .playing || detection == .likelyPlaying else { return nil }
        if let displayID, let owner = Self.displayIDOwners[displayID] {
            return await confirmedOwner(owner, for: detection)
        }
        guard displayID == nil else { return nil }
        for owner in Self.nilDisplayIDProbeOwners {
            if await scriptablePlaybackState(owner: owner) == .playing {
                return owner
            }
        }
        return nil
    }

    private func confirmedOwner(
        _ owner: InterruptedPlaybackOwner,
        for detection: PlaybackDetectionResult
    ) async -> InterruptedPlaybackOwner? {
        guard detection == .likelyPlaying else { return owner }
        return await scriptablePlaybackState(owner: owner) == .playing ? owner : nil
    }

    private func stabilizedResumeDetection() async -> PlaybackDetectionResult {
        var detection = await playbackDetector.detect()
        var attempt = 0

        while detection == .unknown && attempt < maximumUnknownResumeRetryCount {
            attempt += 1
            Self.logger.notice(
                "Media interruption resume detection unresolved on attempt \(attempt, privacy: .public); retrying."
            )

            if unknownResumeRetryDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: unknownResumeRetryDelayNanoseconds)
            }
            guard !Task.isCancelled else { return .unknown }

            detection = await playbackDetector.detect()
        }

        return detection
    }
}

enum PlaybackDetectionResult: Sendable, Equatable {
    case playing
    case likelyPlaying
    case notPlaying
    case unknown

    var logValue: String {
        switch self {
        case .playing:
            "playing"
        case .likelyPlaying:
            "likelyPlaying"
        case .notPlaying:
            "notPlaying"
        case .unknown:
            "unknown"
        }
    }
}

enum InterruptedPlaybackOwner: Sendable, Equatable, Hashable {
    case spotify
    case appleMusic
    case applePodcasts
    case appleTV
    case quickTime
    case chrome
    case edge
    case brave
    case arc
    case safari
    case firefox
    case vlc
    case iina

    var logValue: String {
        switch self {
        case .spotify:
            "spotify"
        case .appleMusic:
            "appleMusic"
        case .applePodcasts:
            "applePodcasts"
        case .appleTV:
            "appleTV"
        case .quickTime:
            "quickTime"
        case .chrome:
            "chrome"
        case .edge:
            "edge"
        case .brave:
            "brave"
        case .arc:
            "arc"
        case .safari:
            "safari"
        case .firefox:
            "firefox"
        case .vlc:
            "vlc"
        case .iina:
            "iina"
        }
    }

    var resumeStrategy: InterruptedPlaybackResumeStrategy {
        switch self {
        case .spotify:
            .spotify
        case .appleMusic:
            .appleMusic
        case .applePodcasts:
            .applePodcasts
        case .appleTV:
            .appleTV
        case .quickTime:
            .quickTime
        case .chrome:
            .chrome
        case .edge:
            .edge
        case .brave:
            .brave
        case .arc:
            .arc
        case .safari:
            .safari
        case .firefox:
            .firefox
        case .vlc:
            .vlc
        case .iina:
            .iina
        }
    }
}

enum InterruptedPlaybackResumeStrategy: Sendable, Equatable {
    case spotify
    case appleMusic
    case applePodcasts
    case appleTV
    case quickTime
    case chrome
    case edge
    case brave
    case arc
    case safari
    case firefox
    case vlc
    case iina
    case systemMediaKey

    var logValue: String {
        switch self {
        case .spotify:
            "spotify"
        case .appleMusic:
            "appleMusic"
        case .applePodcasts:
            "applePodcasts"
        case .appleTV:
            "appleTV"
        case .quickTime:
            "quickTime"
        case .chrome:
            "chrome"
        case .edge:
            "edge"
        case .brave:
            "brave"
        case .arc:
            "arc"
        case .safari:
            "safari"
        case .firefox:
            "firefox"
        case .vlc:
            "vlc"
        case .iina:
            "iina"
        case .systemMediaKey:
            "systemMediaKey"
        }
    }

    var scriptableOwner: InterruptedPlaybackOwner? {
        switch self {
        case .spotify:
            .spotify
        case .appleMusic:
            .appleMusic
        case .applePodcasts:
            .applePodcasts
        case .appleTV:
            .appleTV
        case .quickTime:
            .quickTime
        case .chrome:
            .chrome
        case .edge:
            .edge
        case .brave:
            .brave
        case .arc:
            .arc
        case .safari:
            .safari
        case .firefox:
            nil
        case .vlc:
            .vlc
        case .iina:
            nil
        case .systemMediaKey:
            nil
        }
    }
}

enum MediaInterruptionCommand: Sendable, Equatable {
    case pause
    case play

    var mediaRemoteCommand: Int32 {
        switch self {
        case .play:
            0
        case .pause:
            1
        }
    }
}

enum AppPlaybackState: Sendable, Equatable {
    case playing
    case paused
    case stopped
    case unknown

    var logValue: String {
        switch self {
        case .playing:
            "playing"
        case .paused:
            "paused"
        case .stopped:
            "stopped"
        case .unknown:
            "unknown"
        }
    }
}

enum AppPlaybackPauseOutcome: Sendable, Equatable {
    case paused
    case blocked
    case failed

    var logValue: String {
        switch self {
        case .paused:
            "paused"
        case .blocked:
            "blocked"
        case .failed:
            "failed"
        }
    }
}

private enum BrowserTabRiskAssessment: Sendable, Equatable {
    case safe
    case blocked
    case uninspectable
    case stopped

    init(_ rawValue: String) {
        switch rawValue.lowercased() {
        case "safe":
            self = .safe
        case "blocked":
            self = .blocked
        case "stopped":
            self = .stopped
        default:
            self = .uninspectable
        }
    }
}

enum BrowserMediaRisk: Sendable {
    static let blockedHosts: Set<String> = [
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "zoom.us",
        "webex.com",
    ]

    static func isBlockedBrowserMediaURL(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.lowercased() else { return false }
        return blockedHosts.contains { blockedHost in
            host == blockedHost || host.hasSuffix(".\(blockedHost)")
        }
    }

    static let appleScriptBlockedURLHandler = """
    on voceIsBlockedBrowserMediaURL(tabURL)
        set oldDelimiters to AppleScript's text item delimiters
        try
            set normalizedURL to tabURL as string
            set AppleScript's text item delimiters to "://"
            if (count of text items of normalizedURL) < 2 then
                set AppleScript's text item delimiters to oldDelimiters
                return false
            end if
            set urlRemainder to text item 2 of normalizedURL
            set AppleScript's text item delimiters to "/"
            set urlHostAndPort to text item 1 of urlRemainder
            set AppleScript's text item delimiters to ":"
            set urlHost to text item 1 of urlHostAndPort
            set AppleScript's text item delimiters to oldDelimiters

            if urlHost is "meet.google.com" then return true
            if urlHost ends with ".meet.google.com" then return true
            if urlHost is "teams.microsoft.com" then return true
            if urlHost ends with ".teams.microsoft.com" then return true
            if urlHost is "teams.live.com" then return true
            if urlHost ends with ".teams.live.com" then return true
            if urlHost is "zoom.us" then return true
            if urlHost ends with ".zoom.us" then return true
            if urlHost is "webex.com" then return true
            if urlHost ends with ".webex.com" then return true
            return false
        on error
            set AppleScript's text item delimiters to oldDelimiters
            return false
        end try
    end voceIsBlockedBrowserMediaURL
    """

    static let javaScriptBlockedHostExpression = """
    host === 'meet.google.com' || host.endsWith('.meet.google.com') || host === 'teams.microsoft.com' || host.endsWith('.teams.microsoft.com') || host === 'teams.live.com' || host.endsWith('.teams.live.com') || host === 'zoom.us' || host.endsWith('.zoom.us') || host === 'webex.com' || host.endsWith('.webex.com')
    """
}

@MainActor
protocol MediaPlaybackStateDetector {
    func detect() async -> PlaybackDetectionResult
    var lastDetectedDisplayID: String? { get }
}

@MainActor
protocol MediaRemoteBridging: Sendable {
    func activate()
    func deactivate()
    func anyApplicationIsPlaying() async -> Bool?
    func nowPlayingApplicationDisplayID() async -> String?
    func nowPlayingApplicationIsPlaying() async -> Bool?
    func nowPlayingPlaybackState() async -> Int?
    func nowPlayingPlaybackRate() async -> Double?
    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool?
}

final class MultiSignalMediaPlaybackStateDetector: MediaPlaybackStateDetector {
    private static let logger = VoceKitDiagnostics.logger
    private static let weakPositiveConfirmationDelayNanoseconds: UInt64 = 80_000_000
    fileprivate static let pausedPlaybackState = 2
    private let bridge: any MediaRemoteBridging
    private(set) var lastDetectedDisplayID: String?

    init(bridge: any MediaRemoteBridging = MediaRemoteBridge()) {
        self.bridge = bridge
    }

    func detect() async -> PlaybackDetectionResult {
        bridge.activate()
        defer { bridge.deactivate() }

        let firstSnapshot = await captureSnapshot()
        let firstDecision = classify(firstSnapshot)
        logSnapshot(pass: 1, snapshot: firstSnapshot, decision: firstDecision)

        let secondDecision: DetectionDecision?
        let result: PlaybackDetectionResult
        let finalDisplayID: String?

        switch firstDecision {
        case .playing:
            secondDecision = nil
            result = .playing
            finalDisplayID = firstSnapshot.displayID
        case .notPlaying:
            secondDecision = nil
            result = .notPlaying
            finalDisplayID = firstSnapshot.displayID
        case .unknown:
            secondDecision = nil
            result = .unknown
            finalDisplayID = firstSnapshot.displayID
        case .weakPositivePending:
            if Task.isCancelled {
                secondDecision = nil
                result = .unknown
                finalDisplayID = firstSnapshot.displayID
                break
            }

            try? await Task.sleep(nanoseconds: Self.weakPositiveConfirmationDelayNanoseconds)
            if Task.isCancelled {
                secondDecision = nil
                result = .unknown
                finalDisplayID = firstSnapshot.displayID
                break
            }

            let secondSnapshot = await captureSnapshot()
            let confirmedDecision = classify(secondSnapshot)
            secondDecision = confirmedDecision
            logSnapshot(pass: 2, snapshot: secondSnapshot, decision: confirmedDecision)

            switch confirmedDecision {
            case .playing:
                result = .playing
            case .weakPositivePending:
                result = .likelyPlaying
            case .notPlaying:
                result = .notPlaying
            case .unknown:
                result = .unknown
            }
            finalDisplayID = secondSnapshot.displayID ?? firstSnapshot.displayID
        }

        lastDetectedDisplayID = finalDisplayID

        Self.logger.debug(
            """
            Media detection final result=\(result.logValue, privacy: .public) \
            displayID=\(finalDisplayID ?? "nil", privacy: .public) \
            pass1=\(firstDecision.logValue, privacy: .public) \
            pass2=\(secondDecision?.logValue ?? "none", privacy: .public)
            """
        )
        return result
    }

    private func captureSnapshot() async -> ProbeSnapshot {
        async let anyApplicationIsPlaying = bridge.anyApplicationIsPlaying()
        async let nowPlayingApplicationDisplayID = bridge.nowPlayingApplicationDisplayID()
        async let nowPlayingApplicationIsPlaying = bridge.nowPlayingApplicationIsPlaying()
        async let nowPlayingPlaybackState = bridge.nowPlayingPlaybackState()
        async let nowPlayingPlaybackRate = bridge.nowPlayingPlaybackRate()

        let anyPlaying = await anyApplicationIsPlaying
        let displayID = await nowPlayingApplicationDisplayID
        let nowPlaying = await nowPlayingApplicationIsPlaying
        let playbackState = await nowPlayingPlaybackState
        let playbackRate = await nowPlayingPlaybackRate

        let trust = Self.playbackStateTrust(
            playbackState: playbackState,
            playbackRate: playbackRate,
            nowPlaying: nowPlaying
        )

        let playbackStateIsAdvancing: Bool?
        if trust.trusted, let playbackState {
            playbackStateIsAdvancing = bridge.isPlaybackStateAdvancing(playbackState)
        } else {
            playbackStateIsAdvancing = nil
        }

        let hasStrongPositive =
            (playbackRate.map { $0 > 0 } ?? false)
            || (playbackStateIsAdvancing == true)

        let hasStrongNegative =
            (playbackRate.map { $0 == 0 } ?? false)
            || (playbackStateIsAdvancing == false)

        let hasWeakPositive = (anyPlaying == true) || (nowPlaying == true)

        return ProbeSnapshot(
            anyPlaying: anyPlaying,
            displayID: displayID,
            nowPlaying: nowPlaying,
            playbackState: playbackState,
            playbackRate: playbackRate,
            playbackStateIsAdvancing: playbackStateIsAdvancing,
            stateSignalTrusted: trust.trusted,
            stateTrustReason: trust.reason,
            hasStrongPositive: hasStrongPositive,
            hasStrongNegative: hasStrongNegative,
            hasWeakPositive: hasWeakPositive
        )
    }

    private func classify(_ snapshot: ProbeSnapshot) -> DetectionDecision {
        if Self.isPausedSignature(snapshot) {
            return .notPlaying
        }
        if snapshot.hasStrongPositive && !snapshot.hasStrongNegative {
            return .playing
        }
        if snapshot.hasStrongPositive && snapshot.hasStrongNegative {
            return .unknown
        }
        if snapshot.hasStrongNegative {
            return .notPlaying
        }
        if snapshot.hasWeakPositive {
            return .weakPositivePending
        }
        return .unknown
    }

    private func logSnapshot(pass: Int, snapshot: ProbeSnapshot, decision: DetectionDecision) {
        Self.logger.debug(
            """
            Media detection pass=\(pass, privacy: .public) \
            any=\(Self.describe(snapshot.anyPlaying), privacy: .public) \
            displayID=\(snapshot.displayID ?? "nil", privacy: .public) \
            nowPlaying=\(Self.describe(snapshot.nowPlaying), privacy: .public) \
            state=\(Self.describe(snapshot.playbackState), privacy: .public) \
            stateAdvancing=\(Self.describe(snapshot.playbackStateIsAdvancing), privacy: .public) \
            rate=\(Self.describe(snapshot.playbackRate), privacy: .public) \
            stateTrusted=\(snapshot.stateSignalTrusted, privacy: .public) \
            trustReason=\(snapshot.stateTrustReason, privacy: .public) \
            decision=\(decision.logValue, privacy: .public)
            """
        )
    }

    fileprivate static func playbackStateTrust(
        playbackState: Int?,
        playbackRate: Double?,
        nowPlaying: Bool?
    ) -> (trusted: Bool, reason: String) {
        guard let playbackState else {
            return (false, "missing-state")
        }
        if playbackRate != nil {
            return (true, "trusted-with-rate")
        }
        if nowPlaying == true {
            return (true, "trusted-with-now-playing")
        }
        if playbackState == 0 {
            return (false, "error-default-state")
        }
        return (false, "uncorroborated-state")
    }

    private static func isPausedSignature(_ snapshot: ProbeSnapshot) -> Bool {
        snapshot.anyPlaying == false
            && snapshot.nowPlaying == false
            && snapshot.playbackState == pausedPlaybackState
            && snapshot.playbackRate == nil
    }

    private struct ProbeSnapshot {
        let anyPlaying: Bool?
        let displayID: String?
        let nowPlaying: Bool?
        let playbackState: Int?
        let playbackRate: Double?
        let playbackStateIsAdvancing: Bool?
        let stateSignalTrusted: Bool
        let stateTrustReason: String
        let hasStrongPositive: Bool
        let hasStrongNegative: Bool
        let hasWeakPositive: Bool
    }

    private enum DetectionDecision {
        case playing
        case weakPositivePending
        case notPlaying
        case unknown

        var logValue: String {
            switch self {
            case .playing:
                "playing"
            case .weakPositivePending:
                "weakPositivePending"
            case .notPlaying:
                "notPlaying"
            case .unknown:
                "unknown"
            }
        }
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.4f", value)
    }
}

@MainActor
final class MediaRemoteBridge: MediaRemoteBridging {
    private typealias SetWantsNowPlayingNotificationsFn = @convention(c) (Bool) -> Void
    private typealias RegisterForNowPlayingNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterForNowPlayingNotificationsFn = @convention(c) () -> Void
    private typealias BoolProbeFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias StringProbeFn = @convention(c) (DispatchQueue, @escaping (CFString?) -> Void) -> Void
    private typealias PlaybackStateProbeFn = @convention(c) (DispatchQueue, @escaping (Int) -> Void) -> Void
    private typealias PlaybackStateIsAdvancingFn = @convention(c) (Int) -> Bool
    private typealias NowPlayingInfoProbeFn = @convention(c) (DispatchQueue, @escaping ([AnyHashable: Any]?) -> Void) -> Void
    private static let logger = VoceKitDiagnostics.logger

    private nonisolated(unsafe) let handle: UnsafeMutableRawPointer?
    private let callbackQueue: DispatchQueue
    private let probeRunner: MediaRemoteAsyncProbeRunner

    private let setWantsNowPlayingNotifications: SetWantsNowPlayingNotificationsFn?
    private let registerForNowPlayingNotifications: RegisterForNowPlayingNotificationsFn?
    private let unregisterForNowPlayingNotifications: UnregisterForNowPlayingNotificationsFn?
    private let getAnyApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationDisplayID: StringProbeFn?
    private let getNowPlayingApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationPlaybackState: PlaybackStateProbeFn?
    private let playbackStateIsAdvancingFn: PlaybackStateIsAdvancingFn?
    private let getNowPlayingInfo: NowPlayingInfoProbeFn?
    private let playbackRateInfoKey: String?

    init(
        frameworkPath: String = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        callbackQueue: DispatchQueue = DispatchQueue(label: "Voce.MediaRemote.Callback", qos: .userInitiated),
        probeRunner: MediaRemoteAsyncProbeRunner = MediaRemoteAsyncProbeRunner()
    ) {
        self.callbackQueue = callbackQueue
        self.probeRunner = probeRunner

        let handle = dlopen(frameworkPath, RTLD_LAZY)
        self.handle = handle

        self.setWantsNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteSetWantsNowPlayingNotifications",
            as: SetWantsNowPlayingNotificationsFn.self
        )
        self.registerForNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteRegisterForNowPlayingNotifications",
            as: RegisterForNowPlayingNotificationsFn.self
        )
        self.unregisterForNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteUnregisterForNowPlayingNotifications",
            as: UnregisterForNowPlayingNotificationsFn.self
        )
        self.getAnyApplicationIsPlaying = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetAnyApplicationIsPlaying",
            as: BoolProbeFn.self
        )
        self.getNowPlayingApplicationDisplayID = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationDisplayID",
            as: StringProbeFn.self
        )
        self.getNowPlayingApplicationIsPlaying = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            as: BoolProbeFn.self
        )
        self.getNowPlayingApplicationPlaybackState = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationPlaybackState",
            as: PlaybackStateProbeFn.self
        )
        self.playbackStateIsAdvancingFn = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemotePlaybackStateIsAdvancing",
            as: PlaybackStateIsAdvancingFn.self
        )
        self.getNowPlayingInfo = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingInfo",
            as: NowPlayingInfoProbeFn.self
        )
        self.playbackRateInfoKey = Self.loadCFStringConstant(
            handle: handle,
            named: "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        )
    }

    private var activationCount = 0

    func activate() {
        activationCount += 1
        Self.logger.debug("MediaRemote activate. Count: \(self.activationCount, privacy: .public)")
        if activationCount == 1 {
            setWantsNowPlayingNotifications?(true)
            registerForNowPlayingNotifications?(callbackQueue)
            Self.logger.debug("MediaRemote now playing notifications enabled and registered.")
        }
    }

    func deactivate() {
        guard activationCount > 0 else {
            Self.logger.debug("MediaRemote deactivate ignored because count is already zero.")
            return
        }

        activationCount -= 1
        Self.logger.debug("MediaRemote deactivate. Count: \(self.activationCount, privacy: .public)")
        if activationCount == 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
            Self.logger.debug("MediaRemote now playing notifications unregistered and disabled.")
        }
    }

    deinit {
        if activationCount > 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
            VoceKitDiagnostics.logger.debug("MediaRemote bridge deinit forced unregister cleanup.")
        }
        // Defer dlclose to after the serial callbackQueue drains, avoiding
        // a sync-on-self deadlock if deinit runs on the callbackQueue thread.
        let handleAddress = UInt(bitPattern: self.handle)
        callbackQueue.async {
            guard handleAddress != 0,
                  let handle = UnsafeMutableRawPointer(bitPattern: handleAddress)
            else {
                return
            }
            dlclose(handle)
        }
    }

    func anyApplicationIsPlaying() async -> Bool? {
        guard let getAnyApplicationIsPlaying else { return nil }
        return await probeRunner.run { callback in
            getAnyApplicationIsPlaying(callbackQueue) { isPlaying in
                callback(isPlaying)
            }
        }
    }

    func nowPlayingApplicationDisplayID() async -> String? {
        guard let getNowPlayingApplicationDisplayID else { return nil }
        let displayIDResult: String?? = await probeRunner.run { callback in
            getNowPlayingApplicationDisplayID(callbackQueue) { displayID in
                callback(displayID as String?)
            }
        }
        return displayIDResult ?? nil
    }

    func nowPlayingApplicationIsPlaying() async -> Bool? {
        guard let getNowPlayingApplicationIsPlaying else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationIsPlaying(callbackQueue) { isPlaying in
                callback(isPlaying)
            }
        }
    }

    func nowPlayingPlaybackState() async -> Int? {
        guard let getNowPlayingApplicationPlaybackState else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationPlaybackState(callbackQueue) { playbackState in
                callback(playbackState)
            }
        }
    }

    func nowPlayingPlaybackRate() async -> Double? {
        guard let getNowPlayingInfo, let playbackRateInfoKey else { return nil }
        let playbackRateResult: Double?? = await probeRunner.run { callback in
            getNowPlayingInfo(callbackQueue) { info in
                guard let info else {
                    callback(nil)
                    return
                }
                if let rate = info[playbackRateInfoKey] as? Double {
                    callback(rate)
                    return
                }
                if let rate = info[playbackRateInfoKey] as? NSNumber {
                    callback(rate.doubleValue)
                    return
                }
                if let rate = info[NSString(string: playbackRateInfoKey)] as? NSNumber {
                    callback(rate.doubleValue)
                    return
                }
                callback(nil)
            }
        }
        return playbackRateResult ?? nil
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        guard let playbackStateIsAdvancingFn else { return nil }
        return playbackStateIsAdvancingFn(playbackState)
    }

    private static func loadSymbol<Symbol>(
        handle: UnsafeMutableRawPointer?,
        named symbolName: String,
        as _: Symbol.Type
    ) -> Symbol? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        return unsafeBitCast(symbol, to: Symbol.self)
    }

    private static func loadCFStringConstant(
        handle: UnsafeMutableRawPointer?,
        named symbolName: String
    ) -> String? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        let pointer = symbol.assumingMemoryBound(to: CFString?.self)
        guard let value = pointer.pointee else { return nil }
        return value as String
    }
}

struct MediaRemoteAsyncProbeRunner {
    let timeout: DispatchTimeInterval
    let timeoutQueue: DispatchQueue

    init(
        timeout: DispatchTimeInterval = .milliseconds(250),
        timeoutQueue: DispatchQueue = DispatchQueue(label: "Voce.MediaRemote.Timeout", qos: .userInitiated)
    ) {
        self.timeout = timeout
        self.timeoutQueue = timeoutQueue
    }

    @MainActor
    func run<Value: Sendable>(
        _ register: (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = ProbeContinuationGate(continuation: continuation)
            timeoutQueue.asyncAfter(deadline: .now() + timeout) {
                gate.resumeOnce(nil)
            }
            register { value in
                gate.resumeOnce(value)
            }
        }
    }
}

protocol AppPlaybackControlling: Sendable {
    func playerState() async -> AppPlaybackState
    func pause() async -> Bool
    func pauseOutcome() async -> AppPlaybackPauseOutcome
    func play() async -> Bool
}

extension AppPlaybackControlling {
    func pauseOutcome() async -> AppPlaybackPauseOutcome {
        await pause() ? .paused : .failed
    }
}

typealias SpotifyPlaybackControlling = AppPlaybackControlling
typealias AppleMusicPlaybackControlling = AppPlaybackControlling
typealias ChromePlaybackControlling = AppPlaybackControlling

private enum AppleScriptMediaTimeout {
    static let browser: UInt64 = 750_000_000
    static let player: UInt64 = 1_200_000_000
}

struct UnavailableSpotifyPlaybackController: SpotifyPlaybackControlling {
    func playerState() async -> AppPlaybackState { .unknown }
    func pause() async -> Bool { false }
    func play() async -> Bool { false }
}

struct UnavailableAppleMusicPlaybackController: AppleMusicPlaybackControlling {
    func playerState() async -> AppPlaybackState { .unknown }
    func pause() async -> Bool { false }
    func play() async -> Bool { false }
}

struct UnavailableChromePlaybackController: ChromePlaybackControlling {
    func playerState() async -> AppPlaybackState { .unknown }
    func pause() async -> Bool { false }
    func play() async -> Bool { false }
}

struct UnavailableAppPlaybackController: AppPlaybackControlling {
    func playerState() async -> AppPlaybackState { .unknown }
    func pause() async -> Bool { false }
    func play() async -> Bool { false }
}

private enum AppPlaybackControllerFactory {
    static func controller(
        for owner: InterruptedPlaybackOwner,
        sendMediaCommand: @escaping (MediaInterruptionCommand) -> Bool
    ) -> any AppPlaybackControlling {
        switch owner {
        case .spotify:
            SpotifyPlaybackController()
        case .appleMusic:
            AppleMusicPlaybackController()
        case .applePodcasts:
            AppleScriptPlayerPlaybackController(applicationID: "com.apple.podcasts")
        case .appleTV:
            AppleScriptPlayerPlaybackController(applicationID: "com.apple.TV")
        case .quickTime:
            QuickTimePlaybackController()
        case .chrome:
            ChromePlaybackController(applicationID: "com.google.Chrome")
        case .edge:
            ChromePlaybackController(applicationID: "com.microsoft.edgemac")
        case .brave:
            ChromePlaybackController(applicationID: "com.brave.Browser")
        case .arc:
            ChromePlaybackController(applicationID: "company.thebrowser.Browser")
        case .safari:
            SafariPlaybackController()
        case .firefox:
            MediaRemoteOnlyPlaybackController(sendMediaCommand: sendMediaCommand)
        case .vlc:
            VLCPlaybackController()
        case .iina:
            MediaRemoteOnlyPlaybackController(sendMediaCommand: sendMediaCommand)
        }
    }
}

struct MediaRemoteOnlyPlaybackController: AppPlaybackControlling, @unchecked Sendable {
    let sendMediaCommand: (MediaInterruptionCommand) -> Bool

    func playerState() async -> AppPlaybackState { .unknown }
    func pause() async -> Bool { sendMediaCommand(.pause) }
    func play() async -> Bool { sendMediaCommand(.play) }
}

struct SpotifyPlaybackController: SpotifyPlaybackControlling {
    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                return player state as string
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func play() async -> Bool {
        let script = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                play
                return player state as string
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "playing"
    }

    func pause() async -> Bool {
        let script = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                pause
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }

        // Spotify applies AppleScript playback commands asynchronously. A
        // same-script `return player state` can still report "playing" even
        // though the pause lands a fraction of a second later; poll the direct
        // Spotify state so we only keep a resume token after pause is real.
        for _ in 0..<5 {
            if await playerState() == .paused {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.player
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct AppleMusicPlaybackController: AppleMusicPlaybackControlling {
    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                return player state as string
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func play() async -> Bool {
        let script = """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                play
                return player state as string
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "playing"
    }

    func pause() async -> Bool {
        let script = """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                pause
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }

        for _ in 0..<5 {
            if await playerState() == .paused {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.player
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct AppleScriptPlayerPlaybackController: AppPlaybackControlling {
    let applicationID: String

    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                return player state as string
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func play() async -> Bool {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                play
                return player state as string
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "playing"
    }

    func pause() async -> Bool {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                pause
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }

        for _ in 0..<5 {
            if await playerState() == .paused {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.player
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct ChromePlaybackController: ChromePlaybackControlling {
    let applicationID: String

    init(applicationID: String = "com.google.Chrome") {
        self.applicationID = applicationID
    }

    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                set sawPausedMedia to false
                repeat with chromeWindow in windows
                    repeat with chromeTab in tabs of chromeWindow
                        try
                            set stateText to execute chromeTab javascript "\(Self.chromeStateJavaScript)"
                            if stateText is "playing" then
                                return "playing"
                            else if stateText is "paused" then
                                set sawPausedMedia to true
                            end if
                        end try
                    end repeat
                end repeat
                if sawPausedMedia then
                    return "paused"
                else
                    return "stopped"
                end if
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func pause() async -> Bool {
        await pauseOutcome() == .paused
    }

    func pauseOutcome() async -> AppPlaybackPauseOutcome {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                set pausedCount to 0
                set sawBlockedMedia to false
                set lastScriptError to ""
                repeat with chromeWindow in windows
                    repeat with chromeTab in tabs of chromeWindow
                        try
                            set pauseResult to execute chromeTab javascript "\(Self.chromePauseJavaScript)"
                            if pauseResult is "blocked" then
                                set sawBlockedMedia to true
                            else
                                set pausedCount to pausedCount + (pauseResult as integer)
                            end if
                        on error errorMessage
                            set lastScriptError to errorMessage
                        end try
                    end repeat
                end repeat
                if pausedCount > 0 then
                    return pausedCount as string
                else if sawBlockedMedia then
                    return "blocked"
                else if lastScriptError is not "" then
                    return "error:" & lastScriptError
                else
                    return "0"
                end if
            end tell
        else
            return "0"
        end if
        """
        guard let output = await runAppleScript(script) else {
            return .failed
        }
        let originalOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOutput = originalOutput.lowercased()
        if trimmedOutput == "blocked" {
            return .blocked
        }
        if trimmedOutput.hasPrefix("error:") {
            // Most common cause: "Allow JavaScript from Apple Events" is disabled
            // (off by default in Chrome; Arc does not expose the toggle at all).
            // Fail fast so the caller escalates to the system media key.
            VoceKitDiagnostics.logger.notice(
                """
                Browser \(self.applicationID, privacy: .public) tab JavaScript pause failed: \
                \(originalOutput, privacy: .public)
                """
            )
            return .failed
        }
        guard let pausedCount = Int(trimmedOutput), pausedCount > 0 else {
            return .failed
        }
        return .paused
    }

    private func tabRiskAssessment() async -> BrowserTabRiskAssessment {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                set sawInspectableTab to false
                repeat with chromeWindow in windows
                    repeat with chromeTab in tabs of chromeWindow
                        try
                            set sawInspectableTab to true
                            set tabURL to URL of chromeTab as string
                            if my voceIsBlockedBrowserMediaURL(tabURL) then
                                return "blocked"
                            end if
                        on error
                            return "uninspectable"
                        end try
                    end repeat
                end repeat
                if sawInspectableTab then
                    return "safe"
                else
                    return "safe"
                end if
            end tell
        else
            return "stopped"
        end if

        \(BrowserMediaRisk.appleScriptBlockedURLHandler)
        """
        guard let output = await runAppleScript(script) else { return .uninspectable }
        return BrowserTabRiskAssessment(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func play() async -> Bool {
        let script = """
        if application id "\(applicationID)" is running then
            tell application id "\(applicationID)"
                set resumedCount to 0
                repeat with chromeWindow in windows
                    repeat with chromeTab in tabs of chromeWindow
                        try
                            set resumedCount to resumedCount + ((execute chromeTab javascript "\(Self.chromePlayJavaScript)") as integer)
                        end try
                    end repeat
                end repeat
                return resumedCount as string
            end tell
        else
            return "0"
        end if
        """
        guard let output = await runAppleScript(script),
              let resumedCount = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              resumedCount > 0
        else {
            return false
        }

        for _ in 0..<5 {
            if await playerState() == .playing {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    fileprivate static let chromeStateJavaScript =
        """
        (() => { const host = location.hostname.toLowerCase(); const blocked = \(BrowserMediaRisk.javaScriptBlockedHostExpression); if (blocked) return 'none'; const media = Array.from(document.querySelectorAll('video,audio')); if (media.some((item) => !item.paused && !item.ended)) return 'playing'; if (media.length > 0) return 'paused'; return 'none'; })()
        """
        .appleScriptSingleLineLiteral

    fileprivate static let chromePauseJavaScript =
        """
        (() => { const host = location.hostname.toLowerCase(); const blocked = \(BrowserMediaRisk.javaScriptBlockedHostExpression); let count = 0; let blockedCount = 0; for (const item of Array.from(document.querySelectorAll('video,audio'))) { if (!item.paused && !item.ended) { if (blocked) { blockedCount += 1; } else { item.dataset.vocePausedForDictation = '1'; item.pause(); count += 1; } } } if (blockedCount > 0 && count === 0) return 'blocked'; return String(count); })()
        """
        .appleScriptSingleLineLiteral

    fileprivate static let chromePlayJavaScript =
        """
        (() => { const host = location.hostname.toLowerCase(); const blocked = \(BrowserMediaRisk.javaScriptBlockedHostExpression); if (blocked) return '0'; let count = 0; for (const item of Array.from(document.querySelectorAll('video,audio'))) { if (item.dataset.vocePausedForDictation === '1') { delete item.dataset.vocePausedForDictation; try { item.play(); count += 1; } catch (_) {} } } return String(count); })()
        """
        .appleScriptSingleLineLiteral

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.browser
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct SafariPlaybackController: AppPlaybackControlling {
    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "com.apple.Safari" is running then
            tell application id "com.apple.Safari"
                set sawPausedMedia to false
                repeat with safariWindow in windows
                    repeat with safariTab in tabs of safariWindow
                        try
                            set stateText to do JavaScript "\(Self.safariStateJavaScript)" in safariTab
                            if stateText is "playing" then
                                return "playing"
                            else if stateText is "paused" then
                                set sawPausedMedia to true
                            end if
                        end try
                    end repeat
                end repeat
                if sawPausedMedia then
                    return "paused"
                else
                    return "stopped"
                end if
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func pause() async -> Bool {
        await pauseOutcome() == .paused
    }

    func pauseOutcome() async -> AppPlaybackPauseOutcome {
        let script = """
        if application id "com.apple.Safari" is running then
            tell application id "com.apple.Safari"
                set pausedCount to 0
                set sawBlockedMedia to false
                repeat with safariWindow in windows
                    repeat with safariTab in tabs of safariWindow
                        try
                            set pauseResult to do JavaScript "\(Self.safariPauseJavaScript)" in safariTab
                            if pauseResult is "blocked" then
                                set sawBlockedMedia to true
                            else
                                set pausedCount to pausedCount + (pauseResult as integer)
                            end if
                        end try
                    end repeat
                end repeat
                if pausedCount > 0 then
                    return pausedCount as string
                else if sawBlockedMedia then
                    return "blocked"
                else
                    return "0"
                end if
            end tell
        else
            return "0"
        end if
        """
        guard let output = await runAppleScript(script) else {
            return .failed
        }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmedOutput == "blocked" {
            return .blocked
        }
        guard let pausedCount = Int(trimmedOutput), pausedCount > 0 else {
            return .failed
        }
        return .paused
    }

    private func tabRiskAssessment() async -> BrowserTabRiskAssessment {
        let script = """
        if application id "com.apple.Safari" is running then
            tell application id "com.apple.Safari"
                set sawInspectableTab to false
                repeat with safariWindow in windows
                    repeat with safariTab in tabs of safariWindow
                        try
                            set sawInspectableTab to true
                            set tabURL to URL of safariTab as string
                            if my voceIsBlockedBrowserMediaURL(tabURL) then
                                return "blocked"
                            end if
                        on error
                            return "uninspectable"
                        end try
                    end repeat
                end repeat
                if sawInspectableTab then
                    return "safe"
                else
                    return "safe"
                end if
            end tell
        else
            return "stopped"
        end if

        \(BrowserMediaRisk.appleScriptBlockedURLHandler)
        """
        guard let output = await runAppleScript(script) else { return .uninspectable }
        return BrowserTabRiskAssessment(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func play() async -> Bool {
        let script = """
        if application id "com.apple.Safari" is running then
            tell application id "com.apple.Safari"
                set resumedCount to 0
                repeat with safariWindow in windows
                    repeat with safariTab in tabs of safariWindow
                        try
                            set resumedCount to resumedCount + ((do JavaScript "\(Self.safariPlayJavaScript)" in safariTab) as integer)
                        end try
                    end repeat
                end repeat
                return resumedCount as string
            end tell
        else
            return "0"
        end if
        """
        guard let output = await runAppleScript(script),
              let resumedCount = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              resumedCount > 0
        else {
            return false
        }

        for _ in 0..<5 {
            if await playerState() == .playing {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static let safariStateJavaScript = ChromePlaybackController.chromeStateJavaScript
    private static let safariPauseJavaScript = ChromePlaybackController.chromePauseJavaScript
    private static let safariPlayJavaScript = ChromePlaybackController.chromePlayJavaScript

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.browser
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct QuickTimePlaybackController: AppPlaybackControlling {
    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "com.apple.QuickTimePlayerX" is running then
            tell application id "com.apple.QuickTimePlayerX"
                if not (exists document 1) then return "stopped"
                repeat with quickTimeDocument in documents
                    try
                        if playing of quickTimeDocument then return "playing"
                    end try
                end repeat
                return "paused"
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func pause() async -> Bool {
        let script = """
        if application id "com.apple.QuickTimePlayerX" is running then
            tell application id "com.apple.QuickTimePlayerX"
                repeat with quickTimeDocument in documents
                    try
                        pause quickTimeDocument
                    end try
                end repeat
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }
        for _ in 0..<5 {
            if await playerState() == .paused {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func play() async -> Bool {
        let script = """
        if application id "com.apple.QuickTimePlayerX" is running then
            tell application id "com.apple.QuickTimePlayerX"
                if exists document 1 then
                    play document 1
                end if
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }
        for _ in 0..<5 {
            if await playerState() == .playing {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.player
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

struct VLCPlaybackController: AppPlaybackControlling {
    func playerState() async -> AppPlaybackState {
        let script = """
        if application id "org.videolan.vlc" is running then
            tell application id "org.videolan.vlc"
                if playing then
                    return "playing"
                else
                    return "paused"
                end if
            end tell
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script) else { return .unknown }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        case "stopped":
            return .stopped
        default:
            return .unknown
        }
    }

    func pause() async -> Bool {
        let script = """
        if application id "org.videolan.vlc" is running then
            tell application id "org.videolan.vlc"
                pause
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }
        for _ in 0..<5 {
            if await playerState() == .paused {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func play() async -> Bool {
        let script = """
        if application id "org.videolan.vlc" is running then
            tell application id "org.videolan.vlc"
                play
            end tell
            return "ok"
        else
            return "stopped"
        end if
        """
        guard let output = await runAppleScript(script),
              output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        else { return false }
        for _ in 0..<5 {
            if await playerState() == .playing {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeoutNanoseconds: AppleScriptMediaTimeout.player
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

private extension String {
    var appleScriptSingleLineLiteral: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

private final class ProbeContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: Value?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        // Never resume while holding the lock. Cancellation handlers may run concurrently.
        continuation.resume(returning: value)
    }
}

private enum SystemMediaCommandSender {
    static func send(_ command: MediaInterruptionCommand) -> Bool {
        if MediaRemoteCommandSender.send(command) {
            return true
        }
        return SystemMediaKeySender.sendPlayPause()
    }
}

private enum MediaRemoteCommandSender {
    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Void
    private static let sendCommand: SendCommandFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommandFn.self)
    }()

    static func send(_ command: MediaInterruptionCommand) -> Bool {
        guard let sendCommand else { return false }
        sendCommand(command.mediaRemoteCommand, nil)
        return true
    }
}

private enum SystemMediaKeySender {
    static func sendPlayPause() -> Bool {
        let down = postSystemDefinedMediaEvent(key: Int32(NX_KEYTYPE_PLAY), isKeyDown: true)
        let up = postSystemDefinedMediaEvent(key: Int32(NX_KEYTYPE_PLAY), isKeyDown: false)
        return down && up
    }

    @discardableResult
    private static func postSystemDefinedMediaEvent(key: Int32, isKeyDown: Bool) -> Bool {
        // Undocumented system media event encoding used by NSEvent.systemDefined.
        // keyState 0xA = down, 0xB = up; modifierFlags 0xA00 marks media-key context.
        // Media keys intentionally use a dedicated tap policy for compatibility,
        // separate from insertion event posting.
        let keyState = isKeyDown ? 0xA : 0xB
        let data1 = Int((key << 16) | (Int32(keyState) << 8))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else {
            return false
        }

        event.cgEvent?.post(tap: voceMediaKeyTapLocation())
        return true
    }
}
#endif
