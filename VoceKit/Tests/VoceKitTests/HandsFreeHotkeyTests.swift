import Foundation
import Testing
@testable import VoceKit

@Test("HandsFreeHotkey round-trips key-code bindings")
func handsFreeHotkeyKeyCodeRoundTrip() throws {
    let hotkey = HandsFreeHotkey.keyCode(79)
    let data = try JSONEncoder().encode(hotkey)
    let decoded = try JSONDecoder().decode(HandsFreeHotkey.self, from: data)

    #expect(decoded == hotkey)
}

@Test("HandsFreeHotkey round-trips modifier bindings")
func handsFreeHotkeyModifierRoundTrip() throws {
    let hotkey = HandsFreeHotkey.modifier(.function)
    let data = try JSONEncoder().encode(hotkey)
    let decoded = try JSONDecoder().decode(HandsFreeHotkey.self, from: data)

    #expect(decoded == hotkey)
}
