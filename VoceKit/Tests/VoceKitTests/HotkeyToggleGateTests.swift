import Foundation
import Testing
@testable import VoceKit

@Test("Hotkey gate toggles once for press plus release")
func hotkeyGatePressReleaseTogglesOnce() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.01)) == true)
}

@Test("Hotkey gate ignores repeated presses before one release")
func hotkeyGateIgnoresRepeatedPresses() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.02)) == false)
    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.03)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.04)) == true)
}

@Test("Hotkey gate debounces duplicate releases")
func hotkeyGateDebouncesDuplicateReleases() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.01)) == true)

    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.02)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.10)) == false)

    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.40)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.45)) == true)
}

@Test("Hotkey gate ignores release without press")
func hotkeyGateIgnoresReleaseWithoutPress() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.released, now: t0) == false)
}

@Test("Double-tap gate toggles on the second tap")
func hotkeyDoubleTapGateTogglesOnSecondTap() {
    var gate = HotkeyDoubleTapGate(activationWindowSeconds: 0.35)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.registerTap(now: t0) == false)
    #expect(gate.registerTap(now: t0.addingTimeInterval(0.2)) == true)
}

@Test("Double-tap gate requires the second tap within the activation window")
func hotkeyDoubleTapGateRequiresSecondTapWithinWindow() {
    var gate = HotkeyDoubleTapGate(activationWindowSeconds: 0.35)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.01)) == false)

    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.50)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.51)) == false)

    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.68)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.69)) == true)
}
