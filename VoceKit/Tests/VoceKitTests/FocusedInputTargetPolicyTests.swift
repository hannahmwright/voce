#if os(macOS)
import ApplicationServices
import Testing
@testable import VoceKit

@Test("Readable text composers do not need a settable AX value")
func readableTextComposerIsAcceptedWithoutSettableValue() {
    #expect(
        FocusedInputTargetPolicy.acceptsReadableText(
            role: kAXTextAreaRole as String,
            hasReadableValue: true,
            valueIsSettable: false
        )
    )
}

@Test("Unknown controls still require a settable readable AX value")
func unknownControlRequiresSettableReadableValue() {
    #expect(
        !FocusedInputTargetPolicy.acceptsReadableText(
            role: kAXGroupRole as String,
            hasReadableValue: true,
            valueIsSettable: false
        )
    )
    #expect(
        !FocusedInputTargetPolicy.acceptsReadableText(
            role: kAXTextAreaRole as String,
            hasReadableValue: false,
            valueIsSettable: true
        )
    )
}
#endif
