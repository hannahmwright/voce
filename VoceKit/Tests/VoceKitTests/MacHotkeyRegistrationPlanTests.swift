#if os(macOS)
import Testing
@testable import VoceKit

@Test("Idle registration uses the native hands-free key without dormant selection shortcuts")
func idleRegistrationUsesOnlyEnabledKeyCodeHotkeys() {
    let registrations = IdleKeyCodeHotkeyRegistration.plan(
        globalToggleHotkey: .init(hotkey: .keyCode(79)),
        selectionCorrectionHotkey: .disabledSentinel,
        selectionSnippetHotkey: .disabledSentinel,
        hasSelectionCorrectionHandler: true,
        hasSelectionSnippetHandler: true
    )

    #expect(registrations == [
        .init(action: .handsFreeToggle, keyCode: 79, modifiers: [])
    ])
}

@Test("Idle registration preserves bound direct selection shortcuts")
func idleRegistrationIncludesBoundSelectionShortcuts() {
    let registrations = IdleKeyCodeHotkeyRegistration.plan(
        globalToggleHotkey: nil,
        selectionCorrectionHotkey: .dictionaryCorrectionDefault,
        selectionSnippetHotkey: .snippetCreationDefault,
        hasSelectionCorrectionHandler: true,
        hasSelectionSnippetHandler: true
    )

    #expect(registrations == [
        .init(
            action: .selectionCorrection,
            keyCode: 3,
            modifiers: [.control, .option]
        ),
        .init(
            action: .selectionSnippet,
            keyCode: 1,
            modifiers: [.control, .option]
        )
    ])
}

@Test("Modifier-only hands-free toggle stays on the modifier monitor")
func idleRegistrationLeavesModifierToggleToFlagsMonitor() {
    let registrations = IdleKeyCodeHotkeyRegistration.plan(
        globalToggleHotkey: .init(hotkey: .modifier(.control), triggerStyle: .doubleTap),
        selectionCorrectionHotkey: .disabledSentinel,
        selectionSnippetHotkey: .disabledSentinel,
        hasSelectionCorrectionHandler: true,
        hasSelectionSnippetHandler: true
    )

    #expect(registrations.isEmpty)
}

@Test("Idle registration does not bind selection shortcuts without handlers")
func idleRegistrationRequiresSelectionHandlers() {
    let registrations = IdleKeyCodeHotkeyRegistration.plan(
        globalToggleHotkey: nil,
        selectionCorrectionHotkey: .dictionaryCorrectionDefault,
        selectionSnippetHotkey: .snippetCreationDefault,
        hasSelectionCorrectionHandler: false,
        hasSelectionSnippetHandler: false
    )

    #expect(registrations.isEmpty)
}
#endif
