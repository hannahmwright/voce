#if os(macOS)
import ApplicationServices
import AppKit
import Foundation

enum FocusedInputTargetPolicy {
    static func acceptsReadableText(
        role: String?,
        hasReadableValue: Bool,
        valueIsSettable: Bool
    ) -> Bool {
        guard hasReadableValue else { return false }
        let recognizedTextRoles = Set([
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
        ])
        return role.map(recognizedTextRoles.contains) == true || valueIsSettable
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

        if let failureReason = editabilityFailureReason(for: element) {
            recordCaptureFailure(failureReason, element: element)
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
        VoceDiagnosticStore.shared.record(
            category: "input_target",
            event: "captured",
            details: [
                "bundle": bundleIdentifier,
                "role": identity.role ?? "unknown",
                "subrole": identity.subrole ?? "none",
                "has_identifier": String(identity.identifier != nil),
                "has_description": String(identity.description != nil),
            ]
        )

        return FocusedInputTarget(
            element: element,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            identity: identity,
            initialValue: value(of: element)
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

        guard let text = Self.value(of: current) else { return nil }
        return ValueSnapshot(text: text, selectedRange: Self.selectedRange(of: current))
    }

    func verifyInsertion(of insertedText: String, from before: ValueSnapshot) -> Bool {
        guard let after = valueSnapshot(), after.text != before.text else {
            return false
        }

        if let selectedRange = before.selectedRange,
           let expected = Self.valueByReplacingSelection(
               in: before.text,
               selectedRange: selectedRange,
               with: insertedText
           ),
           after.text == expected {
            return true
        }

        // Some applications expose the value but not a usable selection range.
        // In that case require the exact transcript to appear in the changed
        // value; a mere value change is not sufficient evidence.
        return after.text.contains(insertedText)
    }

    struct ValueSnapshot: @unchecked Sendable {
        let text: String
        let selectedRange: CFRange?
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
        element: AXUIElement? = nil
    ) {
        var details = ["reason": reason]
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

    private static func editabilityFailureReason(for element: AXUIElement) -> String? {
        let hasReadableValue = value(of: element) != nil
        guard hasReadableValue else {
            return "focused_element_value_unreadable"
        }

        let role = stringAttribute(kAXRoleAttribute as CFString, on: element)
        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        let valueIsSettable = settableStatus == .success && isSettable.boolValue
        guard FocusedInputTargetPolicy.acceptsReadableText(
            role: role,
            hasReadableValue: hasReadableValue,
            valueIsSettable: valueIsSettable
        ) else {
            return "focused_element_not_editable"
        }

        if !valueIsSettable {
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

    private static func value(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }
        if let string = valueRef as? String {
            return string
        }
        if let attributedString = valueRef as? NSAttributedString {
            return attributedString.string
        }
        return nil
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
#endif
