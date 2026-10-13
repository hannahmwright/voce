import Testing
@testable import VoceKit

@Test("RecordingStateMachine enforces hands-free toggle start/stop semantics")
func recordingStateMachineHandsFreeToggle() {
    var machine = RecordingStateMachine()

    let first = machine.handleHandsFreeToggle()
    #expect(first == .start(mode: .handsFree))
    #expect(machine.state == .recordingHandsFree)

    let second = machine.handleHandsFreeToggle()
    #expect(second == .stop(mode: .handsFree))
    #expect(machine.state == .transcribing)

    let blocked = machine.handleHandsFreeToggle()
    switch blocked {
    case .ignore(let reason):
        #expect(!reason.isEmpty)
    default:
        Issue.record("Expected toggle to be ignored during transcribing")
    }

    machine.markTranscriptionCompleted()
    #expect(machine.state == .idle)
}

@Test("RecordingStateMachine keeps hold-to-talk independent")
func recordingStateMachinePressToTalkFlow() {
    var machine = RecordingStateMachine()

    let start = machine.handlePressToTalkKeyDown()
    #expect(start == .start(mode: .pressToTalk))
    #expect(machine.state == .recordingPressToTalk)

    let ignoreToggle = machine.handleHandsFreeToggle()
    switch ignoreToggle {
    case .ignore(let reason):
        #expect(!reason.isEmpty)
    default:
        Issue.record("Expected hands-free toggle to be ignored during hold-to-talk recording")
    }

    let stop = machine.handlePressToTalkKeyUp()
    #expect(stop == .stop(mode: .pressToTalk))
    #expect(machine.state == .transcribing)

    machine.markTranscriptionFailed()
    #expect(machine.state == .idle)
}

@Test("A late completion from a previous dictation does not reset the next one")
func recordingStateMachineIgnoresStaleOwnerCompletion() {
    var machine = RecordingStateMachine()

    let transition1 = machine.handlePressToTalkKeyDown()
    #expect(transition1 == .start(mode: .pressToTalk))
    machine.claim(owner: 1)
    let transition2 = machine.handlePressToTalkKeyUp()
    #expect(transition2 == .stop(mode: .pressToTalk))
    let reset1 = machine.markTranscriptionCompleted(owner: 1)
    #expect(reset1)
    #expect(machine.state == .idle)
    #expect(machine.owner == nil)

    // Dictation 2 starts while dictation 1 is still transcribing in the background.
    let transition3 = machine.handlePressToTalkKeyDown()
    #expect(transition3 == .start(mode: .pressToTalk))
    machine.claim(owner: 2)

    // Dictation 1's processing then fails or finishes.
    let reset2 = machine.markTranscriptionFailed(owner: 1)
    #expect(!reset2)
    let reset3 = machine.markTranscriptionCompleted(owner: 1)
    #expect(!reset3)
    #expect(machine.state == .recordingPressToTalk)
    #expect(machine.owner == 2)

    // The key release for dictation 2 is still honoured.
    let transition4 = machine.handlePressToTalkKeyUp()
    #expect(transition4 == .stop(mode: .pressToTalk))
    #expect(machine.state == .transcribing)
    let reset4 = machine.markTranscriptionCompleted(owner: 2)
    #expect(reset4)
    #expect(machine.state == .idle)
}

@Test("A start transition drops the previous owner until the new dictation claims it")
func recordingStateMachineStartClearsOwner() {
    var machine = RecordingStateMachine()

    let transition1 = machine.handleHandsFreeToggle()
    #expect(transition1 == .start(mode: .handsFree))
    machine.claim(owner: 7)
    #expect(machine.owner == 7)
    machine.markTranscriptionFailed()
    #expect(machine.owner == nil)

    let transition2 = machine.handleHandsFreeToggle()
    #expect(transition2 == .start(mode: .handsFree))
    #expect(machine.owner == nil)
    let reset1 = machine.markTranscriptionCompleted(owner: 7)
    #expect(!reset1)
    #expect(machine.state == .recordingHandsFree)
}

@Test("Owner-scoped completion is a no-op when idle and claims are ignored while idle")
func recordingStateMachineOwnerScopedNoOpsWhenIdle() {
    var machine = RecordingStateMachine()

    machine.claim(owner: 3)
    #expect(machine.owner == nil)
    let reset1 = machine.markTranscriptionCompleted(owner: 3)
    #expect(!reset1)
    #expect(machine.state == .idle)

    let transition1 = machine.handleHandsFreeToggle()
    #expect(transition1 == .start(mode: .handsFree))
    machine.claim(owner: 3)
    let transition2 = machine.handleHandsFreeToggle()
    #expect(transition2 == .stop(mode: .handsFree))
    #expect(machine.owner == 3)
    let reset2 = machine.markTranscriptionFailed(owner: 3)
    #expect(reset2)
    #expect(machine.state == .idle)
    let reset3 = machine.markTranscriptionFailed(owner: 3)
    #expect(!reset3)
}
