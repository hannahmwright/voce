import Foundation
import Testing
@testable import VoceKit

private enum TestInsertionError: Error {
    case failed
}

private actor CallRecorder {
    private(set) var calls: [InsertionMethod] = []

    func append(_ method: InsertionMethod) {
        calls.append(method)
    }

    func snapshot() -> [InsertionMethod] {
        calls
    }
}

@Test("InsertionService falls back from direct to accessibility before clipboard")
func insertionServiceFallsBackToAccessibility() async {
    let recorder = CallRecorder()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await recorder.append(.direct)
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await recorder.append(.accessibility)
        },
        ClosureInsertionTransport(method: .clipboardPaste) { _, _ in
            await recorder.append(.clipboardPaste)
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)
    #expect(result.status == .inserted)
    #expect(result.method == .accessibility)
    #expect(await recorder.snapshot() == [.direct, .accessibility])
}

@Test("InsertionService falls back to clipboard when direct and accessibility fail")
func insertionServiceFallsBackToClipboard() async {
    let recorder = CallRecorder()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            await recorder.append(.direct)
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            await recorder.append(.accessibility)
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .clipboardPaste) { _, _ in
            await recorder.append(.clipboardPaste)
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)
    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(await recorder.snapshot() == [.direct, .accessibility, .clipboardPaste])
}

@Test("InsertionService suggests seamless refocus paste after focus-loss fallback")
func insertionServiceSuggestsRefocusPasteRecovery() async {
    let clipboard = MemoryClipboardService()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            throw MacInsertionError.attributeUpdateFailed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            throw MacInsertionError.focusedElementUnavailable
        },
        ClipboardInsertionTransport(clipboard: clipboard) { _ in
            .skipped(reason: "Unable to synthesize Cmd+V for auto-paste.")
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.recoveryAction == .refocusToPaste)
    #expect(await clipboard.latestValue == "hello")
}

@Test("InsertionService does not suggest refocus paste for permission failures")
func insertionServiceSkipsRefocusPasteRecoveryForPermissionFailures() async {
    let clipboard = MemoryClipboardService()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            throw MacInsertionError.accessibilityPermissionMissing
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            throw MacInsertionError.accessibilityPermissionMissing
        },
        ClipboardInsertionTransport(clipboard: clipboard) { _ in
            .skipped(reason: "Accessibility permission is required for auto-paste.")
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .copiedOnly)
    #expect(result.recoveryAction == nil)
    #expect(await clipboard.latestValue == "hello")
}
