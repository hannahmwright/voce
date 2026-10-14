import Foundation

public enum RecordingMode: String, Sendable, Codable, Equatable {
    case pressToTalk
    case handsFree
}

public enum RecordingLifecycleState: String, Sendable, Codable, Equatable {
    case idle
    case recordingPressToTalk
    case recordingHandsFree
    case transcribing
}

public enum RecordingTransition: Sendable, Equatable {
    case start(mode: RecordingMode)
    case stop(mode: RecordingMode)
    case ignore(reason: String)
}

public struct RecordingStateMachine: Sendable, Equatable {
    public private(set) var state: RecordingLifecycleState
    /// Identifies the dictation that owns the current non-idle state. Work
    /// that finishes late (a previous dictation's transcription, a stale start)
    /// passes its own owner token, so it cannot reset a newer dictation.
    public private(set) var owner: UInt64?

    public init(initialState: RecordingLifecycleState = .idle) {
        self.state = initialState
    }

    /// Records which dictation owns the state that a start transition just
    /// entered. Ignored while idle, because there is nothing to own.
    public mutating func claim(owner: UInt64) {
        guard state != .idle else { return }
        self.owner = owner
    }

    public mutating func handlePressToTalkKeyDown() -> RecordingTransition {
        switch state {
        case .idle:
            state = .recordingPressToTalk
            owner = nil
            return .start(mode: .pressToTalk)
        case .recordingPressToTalk:
            return .ignore(reason: "Already recording with hold-to-talk.")
        case .recordingHandsFree:
            return .ignore(reason: "Hands-free recording is active.")
        case .transcribing:
            return .ignore(reason: "Still transcribing the previous session.")
        }
    }

    public mutating func handlePressToTalkKeyUp() -> RecordingTransition {
        switch state {
        case .recordingPressToTalk:
            state = .transcribing
            return .stop(mode: .pressToTalk)
        case .idle:
            return .ignore(reason: "No active hold-to-talk recording.")
        case .recordingHandsFree:
            return .ignore(reason: "Hands-free recording is active.")
        case .transcribing:
            return .ignore(reason: "Still transcribing the previous session.")
        }
    }

    public mutating func handleHandsFreeToggle() -> RecordingTransition {
        switch state {
        case .idle:
            state = .recordingHandsFree
            owner = nil
            return .start(mode: .handsFree)
        case .recordingHandsFree:
            state = .transcribing
            return .stop(mode: .handsFree)
        case .recordingPressToTalk:
            return .ignore(reason: "Hold-to-talk is active.")
        case .transcribing:
            return .ignore(reason: "Still transcribing the previous session.")
        }
    }

    /// Unconditionally returns to idle. Only use this from the same
    /// synchronous step that entered the current state; work that may run
    /// after another dictation started must use `markTranscriptionCompleted(owner:)`.
    public mutating func markTranscriptionCompleted() {
        state = .idle
        owner = nil
    }

    /// Unconditional counterpart of `markTranscriptionFailed(owner:)`.
    public mutating func markTranscriptionFailed() {
        state = .idle
        owner = nil
    }

    /// Returns to idle only if `owner` still owns the current state.
    /// - Returns: `true` when the state was reset.
    @discardableResult
    public mutating func markTranscriptionCompleted(owner: UInt64) -> Bool {
        guard state != .idle, self.owner == owner else { return false }
        state = .idle
        self.owner = nil
        return true
    }

    /// Returns to idle only if `owner` still owns the current state.
    /// - Returns: `true` when the state was reset.
    @discardableResult
    public mutating func markTranscriptionFailed(owner: UInt64) -> Bool {
        markTranscriptionCompleted(owner: owner)
    }
}
