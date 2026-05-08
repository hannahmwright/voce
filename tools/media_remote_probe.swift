#!/usr/bin/env swift

import CoreFoundation
import Darwin
import Dispatch
import Foundation

private enum PlaybackDetectionResult: String {
    case playing
    case likelyPlaying
    case notPlaying
    case unknown
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
    let nowPlayingInfoItems: [String]?
}

private enum DetectionDecision: String {
    case playing
    case weakPositivePending
    case notPlaying
    case unknown
}

private struct DetectionPass {
    let snapshot: ProbeSnapshot
    let decision: DetectionDecision
}

private struct DetectionReport {
    let timestamp: Date
    let firstPass: DetectionPass
    let secondPass: DetectionPass?
    let finalResult: PlaybackDetectionResult
}

private struct Options {
    let watch: Bool
    let intervalSeconds: Double
    let samples: Int?
    let includeInfo: Bool

    static func parse(arguments: [String]) throws -> Options {
        var watch = false
        var intervalSeconds = 0.50
        var samples: Int?
        var includeInfo = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--watch":
                watch = true
            case "--interval":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw UsageError("`--interval` expects a positive number of seconds.")
                }
                intervalSeconds = value
            case "--samples":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw UsageError("`--samples` expects a positive integer.")
                }
                samples = value
            case "--include-info":
                includeInfo = true
            case "--help", "-h":
                throw HelpRequested()
            default:
                throw UsageError("Unknown argument: \(argument)")
            }
            index += 1
        }

        return Options(
            watch: watch,
            intervalSeconds: intervalSeconds,
            samples: samples,
            includeInfo: includeInfo
        )
    }
}

private struct UsageError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

private struct HelpRequested: Error {}

private func usageText() -> String {
    """
    Usage:
      swift tools/media_remote_probe.swift
      swift tools/media_remote_probe.swift --watch [--interval 0.25] [--samples 40] [--include-info]

    Options:
      --watch         Keep sampling until interrupted. Use `--samples` to bound it.
      --interval      Delay between reports in seconds. Default: 0.50
      --samples       Number of reports to print before exiting.
      --include-info  Print the full now-playing info dictionary for each pass.
      --help          Show this help.

    Notes:
      - This mirrors Voce's MediaRemote classifier, including the second-pass
        weak-positive confirmation that produces `.likelyPlaying`.
      - Use it while toggling Spotify play/pause or while dictation is ending.
    """
}

private extension ProbeSnapshot {
    func describe(includeInfo: Bool) -> String {
        let header = [
            "any=\(Self.describe(anyPlaying))",
            "displayID=\(displayID ?? "nil")",
            "nowPlaying=\(Self.describe(nowPlaying))",
            "state=\(Self.describe(playbackState))",
            "stateAdvancing=\(Self.describe(playbackStateIsAdvancing))",
            "rate=\(Self.describe(playbackRate))",
            "trusted=\(stateSignalTrusted)",
            "trustReason=\(stateTrustReason)",
            "strong+=\(hasStrongPositive)",
            "strong-=\(hasStrongNegative)",
            "weak+=\(hasWeakPositive)",
        ].joined(separator: " ")

        guard includeInfo else { return header }
        let formattedInfo = Self.describeInfo(nowPlayingInfoItems)
        return "\(header)\n      info=\(formattedInfo)"
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

    private static func describeInfo(_ value: [String]?) -> String {
        guard let value else { return "nil" }
        return "[\(value.joined(separator: ", "))]"
    }
}

@MainActor
private final class MediaRemoteProbe {
    private static let weakPositiveConfirmationDelayNanoseconds: UInt64 = 80_000_000
    private static let spotifyDisplayID = "com.spotify.client"
    private static let spotifyPausedPlaybackState = 2
    private let bridge = MediaRemoteBridge()
    private let includeInfo: Bool

    init(includeInfo: Bool) {
        self.includeInfo = includeInfo
    }

    func observe() async -> DetectionReport {
        bridge.activate()
        defer { bridge.deactivate() }

        let timestamp = Date()
        let firstSnapshot = await captureSnapshot()
        let firstDecision = classify(firstSnapshot)
        let firstPass = DetectionPass(snapshot: firstSnapshot, decision: firstDecision)

        switch firstDecision {
        case .playing:
            return DetectionReport(
                timestamp: timestamp,
                firstPass: firstPass,
                secondPass: nil,
                finalResult: .playing
            )
        case .notPlaying:
            return DetectionReport(
                timestamp: timestamp,
                firstPass: firstPass,
                secondPass: nil,
                finalResult: .notPlaying
            )
        case .unknown:
            return DetectionReport(
                timestamp: timestamp,
                firstPass: firstPass,
                secondPass: nil,
                finalResult: .unknown
            )
        case .weakPositivePending:
            try? await Task.sleep(nanoseconds: Self.weakPositiveConfirmationDelayNanoseconds)
            let secondSnapshot = await captureSnapshot()
            let secondDecision = classify(secondSnapshot)
            let secondPass = DetectionPass(snapshot: secondSnapshot, decision: secondDecision)

            let finalResult: PlaybackDetectionResult
            switch secondDecision {
            case .playing:
                finalResult = .playing
            case .weakPositivePending:
                finalResult = .likelyPlaying
            case .notPlaying:
                finalResult = .notPlaying
            case .unknown:
                finalResult = .unknown
            }

            return DetectionReport(
                timestamp: timestamp,
                firstPass: firstPass,
                secondPass: secondPass,
                finalResult: finalResult
            )
        }
    }

    private func captureSnapshot() async -> ProbeSnapshot {
        async let anyApplicationIsPlaying = bridge.anyApplicationIsPlaying()
        async let nowPlayingApplicationDisplayID = bridge.nowPlayingApplicationDisplayID()
        async let nowPlayingApplicationIsPlaying = bridge.nowPlayingApplicationIsPlaying()
        async let nowPlayingPlaybackState = bridge.nowPlayingPlaybackState()
        async let nowPlayingInfo = bridge.nowPlayingInfoSnapshot()

        let anyPlaying = await anyApplicationIsPlaying
        let displayID = await nowPlayingApplicationDisplayID
        let nowPlaying = await nowPlayingApplicationIsPlaying
        let playbackState = await nowPlayingPlaybackState
        let info = await nowPlayingInfo
        let playbackRate = info?.playbackRate

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
            hasWeakPositive: hasWeakPositive,
            nowPlayingInfoItems: includeInfo ? info?.formattedItems : nil
        )
    }

    private func classify(_ snapshot: ProbeSnapshot) -> DetectionDecision {
        if Self.isSpotifyPausedSignature(snapshot) {
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

    private static func isSpotifyPausedSignature(_ snapshot: ProbeSnapshot) -> Bool {
        snapshot.displayID == spotifyDisplayID
            && snapshot.anyPlaying == false
            && snapshot.nowPlaying == false
            && snapshot.playbackState == spotifyPausedPlaybackState
            && snapshot.playbackRate == nil
    }
}

@MainActor
private final class MediaRemoteBridge {
    private typealias SetWantsNowPlayingNotificationsFn = @convention(c) (Bool) -> Void
    private typealias RegisterForNowPlayingNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterForNowPlayingNotificationsFn = @convention(c) () -> Void
    private typealias BoolProbeFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias StringProbeFn = @convention(c) (DispatchQueue, @escaping (CFString?) -> Void) -> Void
    private typealias PlaybackStateProbeFn = @convention(c) (DispatchQueue, @escaping (Int) -> Void) -> Void
    private typealias PlaybackStateIsAdvancingFn = @convention(c) (Int) -> Bool
    private typealias NowPlayingInfoProbeFn = @convention(c) (DispatchQueue, @escaping ([AnyHashable: Any]?) -> Void) -> Void

    struct NowPlayingInfoSnapshot: Sendable {
        let playbackRate: Double?
        let formattedItems: [String]
    }

    private nonisolated(unsafe) let handle: UnsafeMutableRawPointer?
    private let callbackQueue = DispatchQueue(label: "Voce.MediaRemoteProbe.Callback", qos: .userInitiated)
    private let probeRunner = MediaRemoteAsyncProbeRunner()

    private let setWantsNowPlayingNotifications: SetWantsNowPlayingNotificationsFn?
    private let registerForNowPlayingNotifications: RegisterForNowPlayingNotificationsFn?
    private let unregisterForNowPlayingNotifications: UnregisterForNowPlayingNotificationsFn?
    private let getAnyApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationDisplayID: StringProbeFn?
    private let getNowPlayingApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationPlaybackState: PlaybackStateProbeFn?
    private let playbackStateIsAdvancingFn: PlaybackStateIsAdvancingFn?
    private let getNowPlayingInfoFn: NowPlayingInfoProbeFn?
    private let playbackRateInfoKey: String?
    private var activationCount = 0

    init(frameworkPath: String = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote") {
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
        self.getNowPlayingInfoFn = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingInfo",
            as: NowPlayingInfoProbeFn.self
        )
        self.playbackRateInfoKey = Self.loadCFStringConstant(
            handle: handle,
            named: "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        )
    }

    func activate() {
        activationCount += 1
        if activationCount == 1 {
            setWantsNowPlayingNotifications?(true)
            registerForNowPlayingNotifications?(callbackQueue)
        }
    }

    func deactivate() {
        guard activationCount > 0 else { return }
        activationCount -= 1
        if activationCount == 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
        }
    }

    deinit {
        if activationCount > 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
        }

        let handleAddress = UInt(bitPattern: handle)
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

    func nowPlayingInfoSnapshot() async -> NowPlayingInfoSnapshot? {
        guard let getNowPlayingInfoFn else { return nil }
        let infoResult: NowPlayingInfoSnapshot?? = await probeRunner.run { callback in
            getNowPlayingInfoFn(callbackQueue) { info in
                guard let info else {
                    callback(nil)
                    return
                }
                callback(
                    NowPlayingInfoSnapshot(
                        playbackRate: Self.extractPlaybackRate(from: info, playbackRateInfoKey: self.playbackRateInfoKey),
                        formattedItems: Self.describeInfo(info)
                    )
                )
            }
        }
        return infoResult ?? nil
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        guard let playbackStateIsAdvancingFn else { return nil }
        return playbackStateIsAdvancingFn(playbackState)
    }

    static func extractPlaybackRate(from info: [AnyHashable: Any]?, playbackRateInfoKey: String? = nil) -> Double? {
        guard let info else { return nil }

        let keys: [AnyHashable] = [
            playbackRateInfoKey as Any,
            playbackRateInfoKey.map { NSString(string: $0) } as Any,
            "kMRMediaRemoteNowPlayingInfoPlaybackRate",
            NSString(string: "kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            "PlaybackRate",
            NSString(string: "PlaybackRate"),
        ].compactMap { $0 as? AnyHashable }

        for key in keys {
            if let value = info[key] as? Double {
                return value
            }
            if let value = info[key] as? NSNumber {
                return value.doubleValue
            }
        }

        return nil
    }

    private static func describeInfo(_ value: [AnyHashable: Any]) -> [String] {
        value
            .map { key, item in
                "\(String(describing: key))=\(String(describing: item))"
            }
            .sorted()
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

private struct MediaRemoteAsyncProbeRunner {
    let timeout: DispatchTimeInterval
    let timeoutQueue: DispatchQueue

    init(
        timeout: DispatchTimeInterval = .milliseconds(250),
        timeoutQueue: DispatchQueue = DispatchQueue(label: "Voce.MediaRemoteProbe.Timeout", qos: .userInitiated)
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
        continuation.resume(returning: value)
    }
}

private func printReport(_ report: DetectionReport, includeInfo: Bool) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: report.timestamp)

    print("[\(timestamp)] result=\(report.finalResult.rawValue)")
    print("  pass1=\(report.firstPass.decision.rawValue)")
    print("    \(report.firstPass.snapshot.describe(includeInfo: includeInfo))")

    if let secondPass = report.secondPass {
        print("  pass2=\(secondPass.decision.rawValue)")
        print("    \(secondPass.snapshot.describe(includeInfo: includeInfo))")
    }

    print("")
}

private func runCLI() async -> Int32 {
    do {
        let options = try Options.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        let probe = await MediaRemoteProbe(includeInfo: options.includeInfo)

        let sampleLimit = options.samples ?? (options.watch ? nil : 1)
        var samplesTaken = 0

        while true {
            let report = await probe.observe()
            printReport(report, includeInfo: options.includeInfo)

            samplesTaken += 1
            if let sampleLimit, samplesTaken >= sampleLimit {
                break
            }
            if !options.watch && options.samples == nil {
                break
            }

            let intervalNanoseconds = UInt64(options.intervalSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }

        return EXIT_SUCCESS
    } catch is HelpRequested {
        print(usageText())
        return EXIT_SUCCESS
    } catch let error as UsageError {
        fputs("error: \(error.description)\n\n\(usageText())\n", stderr)
        return EXIT_FAILURE
    } catch {
        fputs("error: \(error)\n", stderr)
        return EXIT_FAILURE
    }
}

var exitCode: Int32 = EXIT_SUCCESS

Task {
    exitCode = await runCLI()
    CFRunLoopStop(CFRunLoopGetMain())
}

CFRunLoopRun()
Darwin.exit(exitCode)
