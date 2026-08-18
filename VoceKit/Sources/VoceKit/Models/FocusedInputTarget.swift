#if os(macOS)
import ApplicationServices
import AppKit
import Foundation

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
        guard AXIsProcessTrusted(),
              let element = currentFocusedElement(),
              isEditable(element),
              let processIdentifier = processIdentifier(of: element),
              let process = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleIdentifier = process.bundleIdentifier else {
            return nil
        }

        return FocusedInputTarget(
            element: element,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            identity: identity(for: element),
            initialValue: value(of: element)
        )
    }

    func isCurrentFocus() -> Bool {
        guard let current = Self.currentFocusedElement() else { return false }
        return matches(current)
    }

    func focusAndVerify() async -> Bool {
        if isCurrentFocus() {
            return true
        }

        let focusStatus = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard focusStatus == .success else { return false }

        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if isCurrentFocus() {
                return true
            }
        }

        return false
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
        if CFEqual(element, candidate) {
            return true
        }

        guard Self.processIdentifier(of: candidate) == processIdentifier,
              Self.identity(for: candidate) == identity else {
            return false
        }

        // Descriptor fallback is useful when an app recreates its AX object,
        // but only accept a strong identifier/description so two generic text
        // fields cannot be confused with one another.
        return identity.identifier != nil || identity.description != nil
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

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue else {
            return false
        }

        return value(of: element) != nil
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
        return valueRef as? String
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
