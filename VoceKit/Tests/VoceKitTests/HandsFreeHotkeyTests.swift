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

#if os(macOS)
@Test("AI finish match distinguishes the default key from no match")
func aiFinishMatchDistinguishesDefaultKeyFromNoMatch() {
    let defaultKey = HandsFreeHotkey.keyCode(47)
    let workflowKey = HandsFreeHotkey.keyCode(44)

    let defaultMatch = AIFinishHotkeyMatch.match(
        keyCode: 47,
        defaultHotkey: defaultKey,
        workflowHotkeys: [workflowKey]
    )
    #expect(defaultMatch == .defaultKey)
    // nil tells the controller to use the default workflow.
    #expect(defaultMatch.callbackHotkey == nil)

    let workflowMatch = AIFinishHotkeyMatch.match(
        keyCode: 44,
        defaultHotkey: defaultKey,
        workflowHotkeys: [workflowKey]
    )
    #expect(workflowMatch == .workflow(workflowKey))
    #expect(workflowMatch.callbackHotkey == workflowKey)

    #expect(
        AIFinishHotkeyMatch.match(keyCode: 0, defaultHotkey: defaultKey, workflowHotkeys: [workflowKey])
            == .noMatch
    )
    #expect(
        AIFinishHotkeyMatch.match(keyCode: 47, defaultHotkey: nil, workflowHotkeys: [])
            == .noMatch
    )
    #expect(
        AIFinishHotkeyMatch.match(
            keyCode: 47,
            defaultHotkey: .modifier(.function),
            workflowHotkeys: [.modifier(.option)]
        ) == .noMatch
    )
}
#endif
