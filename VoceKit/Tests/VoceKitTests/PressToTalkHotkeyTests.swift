import Foundation
import Testing
@testable import VoceKit

@Test("PressToTalkHotkey preserves modifier order and removes duplicates")
func pressToTalkHotkeyNormalizesModifiers() {
    let hotkey = PressToTalkHotkey(modifiers: [.control, .option, .control, .shift])

    #expect(hotkey.modifiers == [.option, .control, .shift])
    #expect(hotkey.displayName == "Option+Control+Shift")
}

@Test("PressToTalkHotkey round-trips modifier chords")
func pressToTalkHotkeyRoundTrip() throws {
    let hotkey = PressToTalkHotkey(modifiers: [.control, .option])
    let data = try JSONEncoder().encode(hotkey)
    let decoded = try JSONDecoder().decode(PressToTalkHotkey.self, from: data)

    #expect(decoded == hotkey)
}
