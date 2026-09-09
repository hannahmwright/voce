#if os(macOS)
import ApplicationServices
import AppKit
import Foundation

enum FocusedInputTargetPolicy {
    static let messagesBundleIdentifier = "com.apple.MobileSMS"

    enum InsertionEvidence: String, Sendable, Equatable {
        case textValue = "text_value"
        case selectedRange = "selected_range"
        case characterCount = "character_count"
    }

    static func acceptsTextTarget(
        role: String?,
        bundleIdentifier: String,
        hasReadableValue: Bool,
        valueIsSettable: Bool
    ) -> Bool {
        let recognizedTextRoles = Set([
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
        ])
        let hasRecognizedTextRole = role.map(recognizedTextRoles.contains) == true
        if hasReadableValue {
            return hasRecognizedTextRole || valueIsSettable
        }

        // Messages on macOS 26 can expose its focused composer as an AXTextField
        // while refusing AXValue reads. Retaining the exact live AX element still
        // lets completion prove that the same field remains focused before Cmd+V.
        return bundleIdentifier == messagesBundleIdentifier && hasRecognizedTextRole
    }

    static func insertionEvidence(
        insertedText: String,
        beforeText: String?,
        afterText: String?,
        beforeSelectedRange: CFRange?,
        afterSelectedRange: CFRange?,
        beforeCharacterCount: Int?,
        afterCharacterCount: Int?
    ) -> InsertionEvidence? {
        let insertedLength = insertedText.utf16.count
        guard insertedLength > 0 else { return nil }

        if let beforeText, let afterText, afterText != beforeText {
            if let selectedRange = beforeSelectedRange,
               let expected = valueByReplacingSelection(
                   in: beforeText,
                   selectedRange: selectedRange,
                   with: insertedText
               ),
               afterText == expected {
                return .textValue
            }

            // Some applications expose text but not a usable selection range.
            // Require the exact transcript to appear, not merely any value change.
            if afterText.contains(insertedText) {
                return .textValue
            }
        }

        if let beforeSelectedRange, let afterSelectedRange {
            let expectedLocation = beforeSelectedRange.location + insertedLength
            let rangeMatches = afterSelectedRange.location == expectedLocation
                && afterSelectedRange.length == 0
            if rangeMatches {
                if let beforeCharacterCount, let afterCharacterCount {
                    let expectedCount = beforeCharacterCount
                        - beforeSelectedRange.length
                        + insertedLength
                    if afterCharacterCount == expectedCount {
                        return .selectedRange
                    }
                } else {
                    return .selectedRange
                }
            }
        }

        // Empty or unselected composers may expose only a character count. An
        // exact increase by the inserted UTF-16 length is still positive evidence.
        if let beforeCharacterCount, let afterCharacterCount,
           afterCharacterCount != beforeCharacterCount,
           afterCharacterCount == beforeCharacterCount + insertedLength {
            return .characterCount
        }

        return nil
    }

    private static func valueByReplacingSelection(
        in text: String,
        selectedRange: CFRange,
        with insertion: String
    ) -> String? {
        guard selectedRange.location >= 0, selectedRange.length >= 0 else { return nil }
        let utf16 = text.utf16
        guard let start = utf16.index(
            utf16.startIndex,
            offsetBy: selectedRange.location,
            limitedBy: utf16.endIndex
        ),
        let end = utf16.index(
            start,
            offsetBy: selectedRange.length,
            limitedBy: utf16.endIndex
        ),
        let startIndex = String.Index(start, within: text),
        let endIndex = String.Index(end, within: text) else {
            return nil
        }

        var result = text
        result.replaceSubrange(startIndex..<endIndex, with: insertion)
        return result
    }
}

/// A live snapshot of the editable Accessibility element that was focused
/// when dictation began. It is intentionally runtime-only and is never
/// serialized with transcript history.
@MainActor
public final class FocusedInputTarget: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let identity: Identity

    public let initialValue: String?

    struct Identity: Sendable, Equatable {
        let role: String?
        let subrole: String?
        let identifier: String?
        let title: String?
        let description: String?
        let windowTitle: String?
    }

    private struct TextObservation {
        let text: String?
        let source: String
        let valueStatus: AXError
        let valueType: String
        let characterCount: Int?
        let characterCountStatus: AXError
        let rangedTextStatus: AXError?

        var diagnosticDetails: [String: String] {
            var details = [
                "value_source": source,
                "value_status": String(valueStatus.rawValue),
                "value_type": valueType,
                "character_count_status": String(characterCountStatus.rawValue),
                "has_character_count": String(characterCount != nil),
            ]
            if let rangedTextStatus {
                details["ranged_text_status"] = String(rangedTextStatus.rawValue)
            }
            return details
        }
    }

    private init(
        element: AXUIElement,
        processIdentifier: pid_t,
        bundleIdentifier: String,
        identity: Identity,
        initialValue: String?
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.identity = identity
        self.initialValue = initialValue
    }

    /// Captures the focused element only when it is an editable Accessibility
    /// value. Search fields and message composers are handled identically.
    public static func captureCurrent() -> FocusedInputTarget? {
        guard AXIsProcessTrusted() else {
            recordCaptureFailure("accessibility_not_trusted")
            return nil
        }

        guard let element = currentFocusedElement() else {
            recordCaptureFailure("focused_element_unavailable")
            return nil
        }

        guard let processIdentifier = processIdentifier(of: element) else {
            recordCaptureFailure("focused_element_pid_unavailable")
            return nil
        }

        guard let process = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleIdentifier = process.bundleIdentifier else {
            recordCaptureFailure("focused_app_bundle_unavailable")
            return nil
        }

        let identity = identity(for: element)
        let textObservation = textObservation(of: element)
        if let failureReason = editabilityFailureReason(
            for: element,
            role: identity.role,
            bundleIdentifier: bundleIdentifier,
            textObservation: textObservation
        ) {
            recordCaptureFailure(
                failureReason,
                element: element,
                additionalDetails: textObservation.diagnosticDetails
            )
            return nil
        }

        if textObservation.text == nil {
            var details = textObservation.diagnosticDetails
            details["bundle"] = bundleIdentifier
            details["role"] = identity.role ?? "unknown"
            VoceDiagnosticStore.shared.record(
                category: "input_target",
                event: "unreadable_text_target_captured",
                details: details
            )
        } else if textObservation.source != "value" {
            var details = textObservation.diagnosticDetails
            details["bundle"] = bundleIdentifier
            details["role"] = identity.role ?? "unknown"
            VoceDiagnosticStore.shared.record(
                category: "input_target",
                event: "alternate_text_value_captured",
                details: details
            )
        }

        VoceDiagnosticStore.shared.record(
            category: "input_target",
            event: "captured",
            details: [
                "bundle": bundleIdentifier,
                "role": identity.role ?? "unknown",
                "subrole": identity.subrole ?? "none",
                "has_identifier": String(identity.identifier != nil),
                "has_description": String(identity.description != nil),
                "value_source": textObservation.source,
            ]
        )

        return FocusedInputTarget(
            element: element,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            identity: identity,
            initialValue: textObservation.text
        )
    }

    func isCurrentFocus() -> Bool {
        guard let current = Self.currentFocusedElement() else { return false }
        return matches(current)
    }

    func focusAndVerify() async -> Bool {
        // Never force the captured element back into focus. A completion may
        // arrive long after the user moved to a search field or another app;
        // changing AXFocused in that situation steals the cursor and makes a
        // stale transcript eligible to paste into the wrong place.
        let isFocused = isCurrentFocus()
        VoceDiagnosticStore.shared.record(
            category: "input_target",
            event: isFocused ? "focus_verified" : "focus_changed",
            details: ["bundle": bundleIdentifier]
        )
        return isFocused
    }

    func valueSnapshot() -> ValueSnapshot? {
        guard let current = Self.currentFocusedElement(), matches(current) else {
            return nil
        }

        let textObservation = Self.textObservation(of: current)
        return ValueSnapshot(
            text: textObservation.text,
            selectedRange: Self.selectedRange(of: current),
            characterCount: textObservation.characterCount
        )
    }

    func insertionEvidence(
        for insertedText: String,
        from before: ValueSnapshot
    ) -> FocusedInputTargetPolicy.InsertionEvidence? {
        guard let after = valueSnapshot() else { return nil }
        return FocusedInputTargetPolicy.insertionEvidence(
            insertedText: insertedText,
            beforeText: before.text,
            afterText: after.text,
            beforeSelectedRange: before.selectedRange,
            afterSelectedRange: after.selectedRange,
            beforeCharacterCount: before.characterCount,
            afterCharacterCount: after.characterCount
        )
    }

    struct ValueSnapshot: @unchecked Sendable {
        let text: String?
        let selectedRange: CFRange?
        let characterCount: Int?

        var hasVerificationSignal: Bool {
            text != nil || selectedRange != nil || characterCount != nil
        }
    }

    private func matches(_ candidate: AXUIElement) -> Bool {
        // The exact Accessibility element is the only safe proof of intent.
        // Roles, descriptions, and even identifiers may be reused by a
        // message composer and an in-app search field. If an app recreates the
        // element, fall back to clipboard-only rather than guessing.
        CFEqual(element, candidate)
    }

    private static func currentFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
    }

    private static func recordCaptureFailure(
        _ reason: String,
        element: AXUIElement? = nil,
        additionalDetails: [String: String] = [:]
    ) {
        var details = additionalDetails
        details["reason"] = reason
        if let element {
            details["role"] = stringAttribute(kAXRoleAttribute as CFString, on: element) ?? "unknown"
            details["subrole"] = stringAttribute(kAXSubroleAttribute as CFString, on: element) ?? "none"
            if let processIdentifier = processIdentifier(of: element),
               let bundleIdentifier = NSRunningApplication(
                   processIdentifier: processIdentifier
               )?.bundleIdentifier {
                details["bundle"] = bundleIdentifier
            }
        }
        VoceDiagnosticStore.shared.record(
            category: "input_target",
            event: "capture_failed",
            details: details
        )
    }

    private static func editabilityFailureReason(
        for element: AXUIElement,
        role: String?,
        bundleIdentifier: String,
        textObservation: TextObservation
    ) -> String? {
        let hasReadableValue = textObservation.text != nil
        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        let valueIsSettable = settableStatus == .success && isSettable.boolValue
        guard FocusedInputTargetPolicy.acceptsTextTarget(
            role: role,
            bundleIdentifier: bundleIdentifier,
            hasReadableValue: hasReadableValue,
            valueIsSettable: valueIsSettable
        ) else {
            return hasReadableValue
                ? "focused_element_not_editable"
                : "focused_element_value_unreadable"
        }

        if !valueIsSettable, hasReadableValue {
            // Rich text composers can accept keyboard paste while reporting
            // AXValue as non-settable. We only need a readable value because
            // insertion itself uses Cmd+V and is positively verified later.
            VoceDiagnosticStore.shared.record(
                category: "input_target",
                event: "readable_text_value_not_settable",
                details: ["role": role ?? "unknown"]
            )
        }
        return nil
    }

    private static func textObservation(of element: AXUIElement) -> TextObservation {
        var valueRef: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        )
        let valueType = typeDescription(of: valueRef)
        let directText = text(from: valueRef)

        var countRef: CFTypeRef?
        let characterCountStatus = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &countRef
        )
        let characterCount = (countRef as? NSNumber)?.intValue

        if let directText {
            return TextObservation(
                text: directText,
                source: "value",
                valueStatus: valueStatus,
                valueType: valueType,
                characterCount: characterCount,
                characterCountStatus: characterCountStatus,
                rangedTextStatus: nil
            )
        }

        if characterCountStatus == .success, characterCount == 0 {
            return TextObservation(
                text: "",
                source: "character_count_empty",
                valueStatus: valueStatus,
                valueType: valueType,
                characterCount: characterCount,
                characterCountStatus: characterCountStatus,
                rangedTextStatus: nil
            )
        }

        var rangedTextRef: CFTypeRef?
        var rangedTextStatus: AXError?
        if let characterCount, characterCount > 0 {
            var fullRange = CFRange(location: 0, length: characterCount)
            if let rangeValue = AXValueCreate(.cfRange, &fullRange) {
                let status = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue,
                    &rangedTextRef
                )
                rangedTextStatus = status
                if let rangedText = text(from: rangedTextRef) {
                    return TextObservation(
                        text: rangedText,
                        source: "string_for_range",
                        valueStatus: valueStatus,
                        valueType: valueType,
                        characterCount: characterCount,
                        characterCountStatus: characterCountStatus,
                        rangedTextStatus: status
                    )
                }
            }
        }

        return TextObservation(
            text: nil,
            source: "unavailable",
            valueStatus: valueStatus,
            valueType: valueType,
            characterCount: characterCount,
            characterCountStatus: characterCountStatus,
            rangedTextStatus: rangedTextStatus
        )
    }

    private static func text(from valueRef: CFTypeRef?) -> String? {
        if let string = valueRef as? String {
            return string
        }
        if let attributedString = valueRef as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private static func typeDescription(of valueRef: CFTypeRef?) -> String {
        guard let valueRef else { return "none" }
        if valueRef is String { return "string" }
        if valueRef is NSAttributedString { return "attributed_string" }
        return "cf_type_\(CFGetTypeID(valueRef))"
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
        let rangeRef,
        CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = unsafeDowncast(rangeRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
    }

    private static func identity(for element: AXUIElement) -> Identity {
        var windowRef: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowRef
        )
        let window: AXUIElement?
        if windowStatus == .success,
           let windowRef,
           CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        } else {
            window = nil
        }

        return Identity(
            role: stringAttribute(kAXRoleAttribute as CFString, on: element),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, on: element),
            identifier: stringAttribute(kAXIdentifierAttribute as CFString, on: element),
            title: stringAttribute(kAXTitleAttribute as CFString, on: element),
            description: stringAttribute(kAXDescriptionAttribute as CFString, on: element),
            windowTitle: window.flatMap { stringAttribute(kAXTitleAttribute as CFString, on: $0) }
        )
    }

    private static func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private static func stringAttribute(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

}
#endif
