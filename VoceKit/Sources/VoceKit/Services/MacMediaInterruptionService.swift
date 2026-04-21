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

@MainActor
public final class MacMediaInterruptionService: MediaInterruptionService {
    private static let logger = VoceKitDiagnostics.logger
    private static let spotifyDisplayID = "com.spotify.client"
    private var activeTokens: Set<UUID> = []
    private var interruptedPlaybackOwner: InterruptedPlaybackOwner?
    private let playbackDetector: any MediaPlaybackStateDetector
    private let spotifyPlaybackController: any SpotifyPlaybackControlling
    private let sendPlayPauseKey: () -> Bool
    private let minimumResumeDelayNanoseconds: UInt64
    private let pauseConfirmationDelayNanoseconds: UInt64
    private let unknownResumeRetryDelayNanoseconds: UInt64
    private let maximumUnknownResumeRetryCount: Int
    private var pendingResumeTask: Task<Void, Never>?
    private var pauseSentAtUptimeNanoseconds: UInt64?

    public init() {
        let bridge = MediaRemoteBridge()
        self.playbackDetector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
        self.spotifyPlaybackController = SpotifyPlaybackController()
        self.sendPlayPauseKey = SystemMediaKeySender.sendPlayPause
        self.minimumResumeDelayNanoseconds = 300_000_000
        self.pauseConfirmationDelayNanoseconds = 120_000_000
        self.unknownResumeRetryDelayNanoseconds = 150_000_000
        self.maximumUnknownResumeRetryCount = 2
    }

    init(
        playbackDetector: any MediaPlaybackStateDetector,
        spotifyPlaybackController: any SpotifyPlaybackControlling = UnavailableSpotifyPlaybackController(),
        sendPlayPauseKey: @escaping () -> Bool,
        minimumResumeDelayNanoseconds: UInt64 = 300_000_000,
        pauseConfirmationDelayNanoseconds: UInt64 = 120_000_000,
        unknownResumeRetryDelayNanoseconds: UInt64 = 150_000_000,
        maximumUnknownResumeRetryCount: Int = 2
    ) {
        self.playbackDetector = playbackDetector
        self.spotifyPlaybackController = spotifyPlaybackController
        self.sendPlayPauseKey = sendPlayPauseKey
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
        case .playing, .likelyPlaying:
            if Task.isCancelled {
                Self.logger.debug("Skipping media interruption because task is cancelled before key send.")
                return nil
            }
            let didSend = sendPlayPauseKey()
            Self.logger.debug("Media interruption pause key send attempted: \(didSend, privacy: .public)")
            guard didSend else { return nil }

            if pauseConfirmationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pauseConfirmationDelayNanoseconds)
            }
            if Task.isCancelled {
                Self.logger.debug("Skipping media interruption because task is cancelled before pause confirmation.")
                return nil
            }

            let postPauseDetection = await playbackDetector.detect()
            Self.logger.notice(
                """
                Media interruption post-pause detection=\(postPauseDetection.logValue, privacy: .public) \
                initial=\(detection.logValue, privacy: .public)
                """
            )
            guard !Task.isCancelled else {
                Self.logger.debug("Skipping media interruption because task is cancelled after pause confirmation.")
                return nil
            }

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
            self.interruptedPlaybackOwner = interruptedPlaybackOwner
            pauseSentAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            Self.logger.notice(
                """
                Media interruption token activated. \
                Active tokens: \(self.activeTokens.count, privacy: .public) \
                interruptedApp=\(interruptedApplicationDisplayID ?? "nil", privacy: .public) \
                interruptedOwner=\(interruptedPlaybackOwner?.logValue ?? "nil", privacy: .public)
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

    private func resumePlaybackIfNeeded() async {
        defer {
            pendingResumeTask = nil
            pauseSentAtUptimeNanoseconds = nil
            interruptedPlaybackOwner = nil
        }

        guard !Task.isCancelled else {
            Self.logger.debug("Skipping media interruption resume because task was cancelled.")
            return
        }

        guard activeTokens.isEmpty else {
            Self.logger.debug("Skipping media interruption resume because a new interruption became active.")
            return
        }

        if interruptedPlaybackOwner == .spotify {
            let spotifyState = await spotifyPlaybackController.playerState()
            Self.logger.notice(
                "Media interruption Spotify state at resume=\(spotifyState.logValue, privacy: .public)"
            )
            switch spotifyState {
            case .playing:
                Self.logger.notice(
                    "Media interruption resume skipped because Spotify already resumed itself."
                )
                Self.logger.debug("Skipping media interruption resume because Spotify already resumed itself.")
                return
            case .paused:
                let didResume = await spotifyPlaybackController.play()
                Self.logger.notice("Media interruption Spotify resume attempted: \(didResume, privacy: .public)")
                Self.logger.debug("Media interruption Spotify resume attempted: \(didResume, privacy: .public)")
                return
            case .stopped:
                Self.logger.notice("Media interruption resume skipped because Spotify is stopped.")
                Self.logger.debug("Skipping media interruption resume because Spotify is stopped.")
                return
            case .unknown:
                let didResume = await spotifyPlaybackController.play()
                Self.logger.notice("Media interruption Spotify fallback resume attempted: \(didResume, privacy: .public)")
                Self.logger.debug("Media interruption Spotify fallback resume attempted: \(didResume, privacy: .public)")
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
            let didSend = sendPlayPauseKey()
            Self.logger.notice("Media interruption resume key send attempted: \(didSend, privacy: .public)")
            Self.logger.debug("Media interruption resume key send attempted: \(didSend, privacy: .public)")
        }
    }

    private func identifyInterruptedPlaybackOwner(
        detection: PlaybackDetectionResult,
        displayID: String?
    ) async -> InterruptedPlaybackOwner? {
        guard detection == .playing || detection == .likelyPlaying else { return nil }
        if displayID == Self.spotifyDisplayID {
            return .spotify
        }
        guard displayID == nil else { return nil }
        let spotifyState = await spotifyPlaybackController.playerState()
        return spotifyState == .playing ? .spotify : nil
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

enum InterruptedPlaybackOwner: Sendable, Equatable {
    case spotify

    var logValue: String {
        switch self {
        case .spotify:
            "spotify"
        }
    }
}

enum SpotifyPlaybackState: Sendable, Equatable {
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
    private static let pausedPlaybackState = 2
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

    private static func playbackStateTrust(
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

protocol SpotifyPlaybackControlling: Sendable {
    func playerState() async -> SpotifyPlaybackState
    func play() async -> Bool
}

struct UnavailableSpotifyPlaybackController: SpotifyPlaybackControlling {
    func playerState() async -> SpotifyPlaybackState { .unknown }
    func play() async -> Bool { false }
}

struct SpotifyPlaybackController: SpotifyPlaybackControlling {
    func playerState() async -> SpotifyPlaybackState {
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
        tell application id "com.spotify.client"
            play
            return player state as string
        end tell
        """
        guard let output = await runAppleScript(script) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "playing"
    }

    private func runAppleScript(_ script: String) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script]
            )
            guard result.terminationStatus == 0 else { return nil }
            return String(data: result.standardOutput, encoding: .utf8)
        } catch {
            return nil
        }
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
