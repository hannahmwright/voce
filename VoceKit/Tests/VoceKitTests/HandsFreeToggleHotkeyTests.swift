import Foundation
import Testing
@testable import VoceKit

@Test("HandsFreeToggleHotkey round-trips single-tap bindings")
func handsFreeToggleHotkeySingleTapRoundTrip() throws {
    let hotkey = HandsFreeToggleHotkey(hotkey: .keyCode(79))
    let data = try JSONEncoder().encode(hotkey)
    let decoded = try JSONDecoder().decode(HandsFreeToggleHotkey.self, from: data)

    #expect(decoded == hotkey)
}

@Test("HandsFreeToggleHotkey round-trips double-tap bindings")
func handsFreeToggleHotkeyDoubleTapRoundTrip() throws {
    let hotkey = HandsFreeToggleHotkey(hotkey: .modifier(.control), triggerStyle: .doubleTap)
    let data = try JSONEncoder().encode(hotkey)
    let decoded = try JSONDecoder().decode(HandsFreeToggleHotkey.self, from: data)

    #expect(decoded == hotkey)
}
