#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

enum TemporaryPasteboardDisposition: Sendable, Equatable {
    case restoreSnapshot
    case preserveTranscript
    case keepCurrentClipboard
}

enum TemporaryPasteboardRestorePolicy {
    static func disposition(
        pasteWasAttempted: Bool,
        stagedTextWasConsumed: Bool,
        stagedChangeCount: Int,
        currentChangeCount: Int
    ) -> TemporaryPasteboardDisposition {
        guard stagedChangeCount == currentChangeCount else {
            return .keepCurrentClipboard
        }
        guard pasteWasAttempted, stagedTextWasConsumed else {
            return .preserveTranscript
        }
        return .restoreSnapshot
    }
}

private struct TemporaryPasteboardValue: Sendable {
    let type: String
    let data: Data?
    let string: String?
}

private struct TemporaryPasteboardItemSnapshot: Sendable {
    let values: [TemporaryPasteboardValue]
}

private struct TemporaryPasteboardSnapshot: Sendable {
    let items: [TemporaryPasteboardItemSnapshot]

    @MainActor
    init(pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            TemporaryPasteboardItemSnapshot(
                values: item.types.compactMap { type in
                    if let data = item.data(forType: type) {
                        return TemporaryPasteboardValue(type: type.rawValue, data: data, string: nil)
                    }
                    if let string = item.string(forType: type) {
                        return TemporaryPasteboardValue(type: type.rawValue, data: nil, string: string)
                    }
                    return nil
                }
            )
        } ?? []
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { snapshot in
            let item = NSPasteboardItem()
            for value in snapshot.values {
                let type = NSPasteboard.PasteboardType(value.type)
                if let data = value.data {
                    item.setData(data, forType: type)
                } else if let string = value.string {
                    item.setString(string, forType: type)
                }
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

struct TemporaryPasteboardTransaction: Sendable {
    private let snapshot: TemporaryPasteboardSnapshot
    let stagedChangeCount: Int

    @MainActor
    static func begin(
        text: String,
        provider: TemporaryPasteboardDataProvider,
        pasteboard: NSPasteboard = .general
    ) -> TemporaryPasteboardTransaction {
        let snapshot = TemporaryPasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        let providerAccepted = item.setDataProvider(provider, forTypes: [.string])
        let itemWritten = providerAccepted && pasteboard.writeObjects([item])
        if !itemWritten {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        return TemporaryPasteboardTransaction(
            snapshot: snapshot,
            stagedChangeCount: pasteboard.changeCount
        )
    }

    @MainActor
    func finish(
        pasteWasAttempted: Bool,
        stagedTextWasConsumed: Bool,
        text: String,
        pasteboard: NSPasteboard = .general
    ) -> TemporaryPasteboardDisposition {
        let disposition = TemporaryPasteboardRestorePolicy.disposition(
            pasteWasAttempted: pasteWasAttempted,
            stagedTextWasConsumed: stagedTextWasConsumed,
            stagedChangeCount: stagedChangeCount,
            currentChangeCount: pasteboard.changeCount
        )

        switch disposition {
        case .restoreSnapshot:
            snapshot.restore(to: pasteboard)
        case .preserveTranscript:
            guard pasteboard.changeCount == stagedChangeCount else {
                return .keepCurrentClipboard
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .keepCurrentClipboard:
            break
        }
        return disposition
    }
}

final class TemporaryPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let textData: Data
    private let stateLock = NSLock()
    private var consumed = false

    init(text: String) {
        textData = Data(text.utf8)
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setData(textData, forType: type)
        stateLock.lock()
        consumed = true
        stateLock.unlock()
    }

    func waitUntilConsumed() async -> Bool {
        for _ in 0..<75 {
            if wasConsumed() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return wasConsumed()
    }

    private func wasConsumed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return consumed
    }
}

private func readFocusedTextValue() -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedUIElementAttribute as CFString,
        &focusedRef
    ) == .success, let focusedRef else {
        return nil
    }
    guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
    let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
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

/// Preferred tap location for synthetic event posting.
/// Defaults to `.cgAnnotatedSessionEventTap` (avoids traversing other event taps).
/// Set `MURMUR_SYNTH_EVENT_TAP=hid` in the environment to revert to `.cghidEventTap`.
let voceSyntheticEventTapLocation: CGEventTapLocation = {
    if ProcessInfo.processInfo.environment["MURMUR_SYNTH_EVENT_TAP"]?.lowercased() == "hid" {
        return .cghidEventTap
    }
    return .cgAnnotatedSessionEventTap
}()

public enum MacInsertionError: Error, LocalizedError {
    case eventSourceUnavailable
    case accessibilityPermissionMissing
    case focusedElementUnavailable
    case unsupportedFocusedElement
    case attributeUpdateFailed

    public var errorDescription: String? {
        switch self {
        case .eventSourceUnavailable:
            return "Unable to access event source for direct typing insertion"
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for this insertion mode"
        case .focusedElementUnavailable:
            return "No focused text element was found"
        case .unsupportedFocusedElement:
            return "Focused element does not support AX text insertion"
        case .attributeUpdateFailed:
            return "Failed to update focused element text"
        }
    }
}

public struct DirectTypingInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .direct

    public init() {}

    public func insert(text: String, target: AppContext) async throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }

        await Self.activateTargetApp(target)

        let preValue = readFocusedTextValue()

        try await typeUnicode(text)

        // Only verify if we could read the pre-value (AX permission + element supports it)
        if preValue != nil {
            try await Task.sleep(nanoseconds: 150_000_000) // 150ms
            let postValue = readFocusedTextValue()
            if let postValue, postValue == preValue {
                // Positive evidence: value readable and unchanged → insertion failed
                throw MacInsertionError.attributeUpdateFailed
            }
            // postValue changed or became nil (element lost focus) → assume success
        }
        // preValue nil → can't verify, assume CGEvent delivered
    }

    private static func activateTargetApp(_ target: AppContext) async {
        guard target.bundleIdentifier != "unknown" else { return }

        for attempt in 0..<3 {
            let activationTriggered = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: target.bundleIdentifier
                ).first else {
                    return false
                }
                return app.activate()
            }

            let delay = UInt64(150_000_000 + (50_000_000 * attempt))
            try? await Task.sleep(nanoseconds: delay)

            let isFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier
            }
            if isFrontmost || !activationTriggered {
                return
            }
        }
    }

    private func typeUnicode(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw MacInsertionError.eventSourceUnavailable
        }

        let allCodeUnits = Array(text.utf16)
        guard !allCodeUnits.isEmpty else { return }

        let chunkSize = 20
        for offset in stride(from: 0, to: allCodeUnits.count, by: chunkSize) {
            let end = min(offset + chunkSize, allCodeUnits.count)
            let chunk = Array(allCodeUnits[offset..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw MacInsertionError.eventSourceUnavailable
            }

            // Some frameworks ignore event Unicode payloads and derive text from keycode/state.
            // InsertionService keeps accessibility and clipboard transports as fallbacks.
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown.post(tap: voceSyntheticEventTapLocation)
            keyUp.post(tap: voceSyntheticEventTapLocation)

            if end < allCodeUnits.count {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms between chunks
            }
        }
    }
}

public struct AccessibilityInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .accessibility

    public init() {}

    public func insert(text: String, target: AppContext) async throws {
        _ = target
        guard AXIsProcessTrusted() else {
            throw MacInsertionError.accessibilityPermissionMissing
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard focusedStatus == .success, let focusedRef else {
            throw MacInsertionError.focusedElementUnavailable
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            throw MacInsertionError.unsupportedFocusedElement
        }

        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
        let composedUpdate = try composeUpdatedValue(for: element, insertion: text)
        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            composedUpdate.text as CFTypeRef
        )

        guard setStatus == .success else {
            throw MacInsertionError.attributeUpdateFailed
        }

        // Best effort: restore caret to the end of the inserted text when possible.
        if var newSelection = composedUpdate.newSelectionRange,
           let selectionValue = AXValueCreate(.cfRange, &newSelection) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                selectionValue
            )
        }
    }

    private struct AccessibilityComposedUpdate {
        let text: String
        let newSelectionRange: CFRange?
    }

    private func composeUpdatedValue(for element: AXUIElement, insertion: String) throws -> AccessibilityComposedUpdate {
        var valueRef: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard valueStatus == .success else {
            throw MacInsertionError.unsupportedFocusedElement
        }

        let current = valueRef as? String ?? ""

        var selectedRangeRef: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )

        guard selectedStatus == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            let updated = current + insertion
            let caret = CFRange(location: updated.utf16.count, length: 0)
            return AccessibilityComposedUpdate(text: updated, newSelectionRange: caret)
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            let updated = current + insertion
            let caret = CFRange(location: updated.utf16.count, length: 0)
            return AccessibilityComposedUpdate(text: updated, newSelectionRange: caret)
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange) else {
            let updated = current + insertion
            let caret = CFRange(location: updated.utf16.count, length: 0)
            return AccessibilityComposedUpdate(text: updated, newSelectionRange: caret)
        }

        guard let swiftRange = range(from: selectedRange, in: current) else {
            let updated = current + insertion
            let caret = CFRange(location: updated.utf16.count, length: 0)
            return AccessibilityComposedUpdate(text: updated, newSelectionRange: caret)
        }

        var updated = current
        updated.replaceSubrange(swiftRange, with: insertion)
        let caret = CFRange(location: selectedRange.location + insertion.utf16.count, length: 0)
        return AccessibilityComposedUpdate(text: updated, newSelectionRange: caret)
    }

    private func range(from cfRange: CFRange, in text: String) -> Range<String.Index>? {
        guard cfRange.location >= 0, cfRange.length >= 0 else { return nil }
        guard let startUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: cfRange.location, limitedBy: text.utf16.endIndex),
              let endUTF16 = text.utf16.index(startUTF16, offsetBy: cfRange.length, limitedBy: text.utf16.endIndex),
              let start = String.Index(startUTF16, within: text),
              let end = String.Index(endUTF16, within: text) else {
            return nil
        }
        return start..<end
    }
}

public enum MacPasteHelper {
    private enum ActivationResult {
        case activated
        case appNotFound
        case focusNotAcquired
        case unknownTarget
    }

    public static func activateAndPaste(
        text: String,
        target: AppContext,
        inputTarget: FocusedInputTarget? = nil
    ) async -> AutoPasteOutcome {
        guard AXIsProcessTrusted() else {
            return .skipped(reason: "Accessibility permission is required for auto-paste.")
        }

        let activationResult = await activateTargetApp(target)
        switch activationResult {
        case .activated, .unknownTarget:
            break
        case .appNotFound:
            return .skipped(reason: "Target app was not found for auto-paste reactivation.")
        case .focusNotAcquired:
            return .skipped(reason: "Could not focus target app before auto-paste.")
        }

        guard let inputTarget = await resolveInputTarget(
            target: target,
            preferred: inputTarget
        ) else {
            return .skipped(reason: "Could not identify the editable field selected for dictation.")
        }

        guard await inputTarget.focusAndVerify() else {
            return .skipped(reason: "The editable field selected for dictation is no longer focused.")
        }

        guard let valueBeforePaste = await inputTarget.valueSnapshot() else {
            return .skipped(reason: "Could not read the editable field selected for dictation.")
        }

        guard simulateCommandV() else {
            return .skipped(reason: "Unable to synthesize Cmd+V for auto-paste.")
        }

        // A pasteboard provider being asked for data is not proof that the
        // application committed the paste. Wait for the exact captured field
        // to expose the expected value before reporting success.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 75_000_000)
            if await inputTarget.verifyInsertion(of: text, from: valueBeforePaste) {
                return .attempted
            }
        }

        return .skipped(reason: "The editable field selected for dictation did not accept the pasted transcript.")
    }

    private static func resolveInputTarget(
        target: AppContext,
        preferred: FocusedInputTarget?
    ) async -> FocusedInputTarget? {
        guard let preferred else { return nil }
        guard target.bundleIdentifier == "unknown"
            || preferred.bundleIdentifier == target.bundleIdentifier else {
            return nil
        }
        return preferred
    }

    public static func activateAndPressReturn(
        target: AppContext,
        inputTarget: FocusedInputTarget? = nil
    ) async -> AutoPasteOutcome {
        guard AXIsProcessTrusted() else {
            return .skipped(reason: "Accessibility permission is required to submit with Return.")
        }

        let activationResult = await activateTargetApp(target)
        switch activationResult {
        case .activated, .unknownTarget:
            break
        case .appNotFound:
            return .skipped(reason: "Target app was not found before submitting with Return.")
        case .focusNotAcquired:
            return .skipped(reason: "Could not focus target app before submitting with Return.")
        }

        guard let inputTarget = await resolveInputTarget(
            target: target,
            preferred: inputTarget
        ), await inputTarget.focusAndVerify() else {
            return .skipped(reason: "The editable field selected for dictation is no longer focused.")
        }

        for attempt in 0..<2 {
            if simulateReturn() {
                return .attempted
            }

            let delay = UInt64(60_000_000 * UInt64(attempt + 1))
            try? await Task.sleep(nanoseconds: delay)
        }

        return .skipped(reason: "Unable to synthesize Return for submit.")
    }

    private static func activateTargetApp(_ target: AppContext) async -> ActivationResult {
        guard target.bundleIdentifier != "unknown" else {
            return .unknownTarget
        }

        for attempt in 0..<3 {
            let didFindApp = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: target.bundleIdentifier
                ).first else {
                    return false
                }
                app.activate()
                return true
            }

            guard didFindApp else {
                return .appNotFound
            }

            let delay = UInt64(150_000_000 + (50_000_000 * attempt))
            try? await Task.sleep(nanoseconds: delay)

            let isFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier
            }
            if isFrontmost {
                return .activated
            }
        }

        return .focusNotAcquired
    }

    public static func simulateCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: voceSyntheticEventTapLocation)
        keyUp.post(tap: voceSyntheticEventTapLocation)
        return true
    }

    public static func simulateCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: voceSyntheticEventTapLocation)
        keyUp.post(tap: voceSyntheticEventTapLocation)
        return true
    }

    public static func simulateReturn() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return false }
        keyDown.post(tap: voceSyntheticEventTapLocation)
        keyUp.post(tap: voceSyntheticEventTapLocation)
        return true
    }
}
#endif
