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

@Test("InsertionService falls back from clipboard to configured secondary transports")
func insertionServiceFallsBackFromClipboardToSecondaryTransports() async {
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
            throw TestInsertionError.failed
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)
    #expect(result.status == .inserted)
    #expect(result.method == .accessibility)
    #expect(await recorder.snapshot() == [.clipboardPaste, .direct, .accessibility])
}

@Test("InsertionService returns copied-only when clipboard auto-paste is unavailable")
func insertionServiceReturnsCopiedOnlyWhenClipboardAutoPasteIsUnavailable() async {
    let recorder = CallRecorder()
    let clipboard = MemoryClipboardService()
    let service = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { _, _ in
                await recorder.append(.direct)
                throw TestInsertionError.failed
            },
            ClosureInsertionTransport(method: .accessibility) { _, _ in
                await recorder.append(.accessibility)
                throw TestInsertionError.failed
            },
            ClipboardInsertionTransport(clipboard: clipboard) { _ in
                await recorder.append(.clipboardPaste)
                return .skipped(reason: "Unable to synthesize Cmd+V for auto-paste.")
            }
        ]
    )

    let result = await service.insert(text: "hello", target: .unknown)
    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.recoveryAction == .refocusToPaste)
    #expect(await clipboard.latestValue == "hello")
    #expect(await recorder.snapshot() == [.clipboardPaste])
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

/// Clipboard double whose first `setString` throws (simulating a transient
/// pasteboard failure) while later attempts succeed.
private actor FlakyClipboardService: ClipboardService {
    private(set) var latestValue: String?
    private var attempts = 0

    func setString(_ text: String) async throws {
        attempts += 1
        guard attempts > 1 else { throw TestInsertionError.failed }
        latestValue = text
    }
}

/// Clipboard double that always throws.
private actor BrokenClipboardService: ClipboardService {
    func setString(_ text: String) async throws {
        throw TestInsertionError.failed
    }
}

@Test("InsertionService retries the clipboard copy when every transport fails")
func insertionServiceCopiesToClipboardWhenAllTransportsFail() async {
    let clipboard = FlakyClipboardService()
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            throw TestInsertionError.failed
        },
        ClosureInsertionTransport(method: .accessibility) { _, _ in
            throw TestInsertionError.failed
        },
        ClipboardInsertionTransport(clipboard: clipboard) { _ in
            .attempted
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(result.errorMessage?.contains("copied to clipboard instead") == true)
    #expect(await clipboard.latestValue == "hello")
}

@Test("InsertionService still reports failure when the clipboard copy retry also fails")
func insertionServiceReportsFailureWhenClipboardRetryFails() async {
    let service = InsertionService(transports: [
        ClosureInsertionTransport(method: .direct) { _, _ in
            throw TestInsertionError.failed
        },
        ClipboardInsertionTransport(clipboard: BrokenClipboardService()) { _ in
            .attempted
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .failed)
    #expect(result.method == InsertionMethod.none)
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
