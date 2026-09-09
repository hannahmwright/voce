#if os(macOS)
import ApplicationServices
import Testing
@testable import VoceKit

@Test("Readable text composers do not need a settable AX value")
func readableTextComposerIsAcceptedWithoutSettableValue() {
    #expect(
        FocusedInputTargetPolicy.acceptsTextTarget(
            role: kAXTextAreaRole as String,
            bundleIdentifier: "com.example.editor",
            hasReadableValue: true,
            valueIsSettable: false
        )
    )
}

@Test("Unknown controls still require a settable readable AX value")
func unknownControlRequiresSettableReadableValue() {
    #expect(
        !FocusedInputTargetPolicy.acceptsTextTarget(
            role: kAXGroupRole as String,
            bundleIdentifier: "com.example.editor",
            hasReadableValue: true,
            valueIsSettable: false
        )
    )
    #expect(
        !FocusedInputTargetPolicy.acceptsTextTarget(
            role: kAXTextAreaRole as String,
            bundleIdentifier: "com.example.editor",
            hasReadableValue: false,
            valueIsSettable: true
        )
    )
}

@Test("Messages keeps its exact focused text field when AXValue is unreadable")
func messagesAcceptsUnreadableFocusedTextField() {
    #expect(
        FocusedInputTargetPolicy.acceptsTextTarget(
            role: kAXTextFieldRole as String,
            bundleIdentifier: FocusedInputTargetPolicy.messagesBundleIdentifier,
            hasReadableValue: false,
            valueIsSettable: false
        )
    )
}

@Test("Messages does not accept an unreadable non-text accessibility group")
func messagesRejectsUnreadableFocusedGroup() {
    #expect(
        !FocusedInputTargetPolicy.acceptsTextTarget(
            role: kAXGroupRole as String,
            bundleIdentifier: FocusedInputTargetPolicy.messagesBundleIdentifier,
            hasReadableValue: false,
            valueIsSettable: false
        )
    )
}

@Test("Unreadable text fields remain rejected outside Messages")
func otherAppsRejectUnreadableFocusedTextField() {
    #expect(
        !FocusedInputTargetPolicy.acceptsTextTarget(
            role: kAXTextFieldRole as String,
            bundleIdentifier: "com.example.editor",
            hasReadableValue: false,
            valueIsSettable: false
        )
    )
}

@Test("Selection movement verifies insertion when text values remain unreadable")
func selectionMovementVerifiesUnreadableInsertion() {
    let evidence = FocusedInputTargetPolicy.insertionEvidence(
        insertedText: "hello",
        beforeText: nil,
        afterText: nil,
        beforeSelectedRange: CFRange(location: 0, length: 0),
        afterSelectedRange: CFRange(location: 5, length: 0),
        beforeCharacterCount: 0,
        afterCharacterCount: 5
    )

    #expect(evidence == .selectedRange)
}

@Test("Readable text replacement remains positively verified")
func readableTextReplacementRemainsVerified() {
    let evidence = FocusedInputTargetPolicy.insertionEvidence(
        insertedText: "Voce",
        beforeText: "hello world",
        afterText: "hello Voce",
        beforeSelectedRange: CFRange(location: 6, length: 5),
        afterSelectedRange: CFRange(location: 10, length: 0),
        beforeCharacterCount: 11,
        afterCharacterCount: 10
    )

    #expect(evidence == .textValue)
}

@Test("A changed readable value without the transcript is not accepted")
func unrelatedReadableTextChangeIsNotVerified() {
    let evidence = FocusedInputTargetPolicy.insertionEvidence(
        insertedText: "Voce",
        beforeText: "hello",
        afterText: "hello!",
        beforeSelectedRange: nil,
        afterSelectedRange: nil,
        beforeCharacterCount: nil,
        afterCharacterCount: nil
    )

    #expect(evidence == nil)
}

@Test("Character-count fallback verifies an empty unreadable composer")
func characterCountVerifiesUnreadableInsertion() {
    let evidence = FocusedInputTargetPolicy.insertionEvidence(
        insertedText: "hello",
        beforeText: nil,
        afterText: nil,
        beforeSelectedRange: nil,
        afterSelectedRange: nil,
        beforeCharacterCount: 0,
        afterCharacterCount: 5
    )

    #expect(evidence == .characterCount)
}

@Test("Unrelated Accessibility changes do not verify insertion")
func unrelatedAccessibilityChangesDoNotVerifyInsertion() {
    let evidence = FocusedInputTargetPolicy.insertionEvidence(
        insertedText: "hello",
        beforeText: nil,
        afterText: nil,
        beforeSelectedRange: CFRange(location: 0, length: 0),
        afterSelectedRange: CFRange(location: 1, length: 0),
        beforeCharacterCount: 0,
        afterCharacterCount: 1
    )

    #expect(evidence == nil)
}
#endif
