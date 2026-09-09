import AppKit
import Testing
@testable import VoceKit

private actor TransactionalMemoryClipboard: TemporaryClipboardPasteService {
    private(set) var value: String
    private(set) var snapshotCount = 0
    private(set) var restoreCount = 0

    init(value: String) {
        self.value = value
    }

    func setString(_ text: String) async throws {
        value = text
    }

    func performTemporaryPaste(
        text: String,
        paste: @escaping @Sendable () async -> AutoPasteOutcome
    ) async throws -> AutoPasteOutcome {
        snapshotCount += 1
        let snapshot = value
        value = text
        let outcome = await paste()
        if outcome == .attempted {
            value = snapshot
            restoreCount += 1
        }
        return outcome
    }
}

@Test("Successful auto-paste uses one snapshot and restores the previous clipboard")
func successfulAutoPasteRestoresPreviousClipboard() async {
    let clipboard = TransactionalMemoryClipboard(value: "previous clipboard")
    let transport = ClipboardInsertionTransport(clipboard: clipboard) { _ in .attempted }

    let outcome = try? await transport.insertAndReturnOutcome(text: "new transcript", target: .unknown)

    #expect(outcome == .attempted)
    #expect(await clipboard.value == "previous clipboard")
    #expect(await clipboard.snapshotCount == 1)
    #expect(await clipboard.restoreCount == 1)
}

@Test("Unsuccessful auto-paste leaves the transcript on the clipboard")
func unsuccessfulAutoPastePreservesTranscript() async {
    let clipboard = TransactionalMemoryClipboard(value: "previous clipboard")
    let transport = ClipboardInsertionTransport(clipboard: clipboard) { _ in
        .skipped(reason: "Could not focus target app before auto-paste.")
    }

    let outcome = try? await transport.insertAndReturnOutcome(text: "recovery transcript", target: .unknown)

    #expect(outcome?.skippedReason == "Could not focus target app before auto-paste.")
    #expect(await clipboard.value == "recovery transcript")
    #expect(await clipboard.snapshotCount == 1)
    #expect(await clipboard.restoreCount == 0)
}

@Test("Explicit clipboard copy remains persistent")
func explicitClipboardCopyRemainsPersistent() async {
    let clipboard = TransactionalMemoryClipboard(value: "previous clipboard")
    let transport = ClipboardInsertionTransport(clipboard: clipboard) { _ in .attempted }

    try? await transport.copyToClipboard(text: "explicit copy")

    #expect(await clipboard.value == "explicit copy")
    #expect(await clipboard.snapshotCount == 0)
    #expect(await clipboard.restoreCount == 0)
}

@Test("Consumed staged paste restores rich previous pasteboard contents")
@MainActor
func consumedTemporaryPasteRestoresPreviousPasteboard() async {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }

    let priorItem = NSPasteboardItem()
    priorItem.setString("previous clipboard", forType: .string)
    priorItem.setData(Data([0x01, 0x02, 0x03]), forType: .init("io.voce.tests.rich-data"))
    pasteboard.clearContents()
    pasteboard.writeObjects([priorItem])

    let provider = TemporaryPasteboardDataProvider(text: "new transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "new transcript",
        provider: provider,
        pasteboard: pasteboard
    )

    #expect(pasteboard.string(forType: .string) == "new transcript")
    let consumed = await provider.waitUntilConsumed()
    let disposition = transaction.finish(
        pasteWasAttempted: true,
        stagedTextWasConsumed: consumed,
        text: "new transcript",
        pasteboard: pasteboard
    )

    #expect(disposition == .restoreSnapshot)
    #expect(pasteboard.string(forType: .string) == "previous clipboard")
    #expect(pasteboard.data(forType: .init("io.voce.tests.rich-data")) == Data([0x01, 0x02, 0x03]))
}

@Test("Unconsumed staged paste remains available for recovery")
@MainActor
func unconsumedTemporaryPastePreservesTranscript() {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let provider = TemporaryPasteboardDataProvider(text: "recovery transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "recovery transcript",
        provider: provider,
        pasteboard: pasteboard
    )
    let disposition = transaction.finish(
        pasteWasAttempted: true,
        stagedTextWasConsumed: false,
        text: "recovery transcript",
        pasteboard: pasteboard
    )

    #expect(disposition == .preserveTranscript)
    #expect(pasteboard.string(forType: .string) == "recovery transcript")
}

@Test("A paste that was not positively verified preserves the transcript")
@MainActor
func unverifiedTemporaryPastePreservesTranscriptEvenIfDataWasRequested() {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let provider = TemporaryPasteboardDataProvider(text: "unverified transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "unverified transcript",
        provider: provider,
        pasteboard: pasteboard
    )

    let disposition = transaction.finish(
        pasteWasAttempted: false,
        stagedTextWasConsumed: true,
        text: "unverified transcript",
        pasteboard: pasteboard
    )

    #expect(disposition == .preserveTranscript)
    #expect(pasteboard.string(forType: .string) == "unverified transcript")
}

@Test("A newer clipboard change is never overwritten by snapshot restoration")
@MainActor
func externalClipboardChangeWinsDuringTemporaryPaste() {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let provider = TemporaryPasteboardDataProvider(text: "new transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "new transcript",
        provider: provider,
        pasteboard: pasteboard
    )

    pasteboard.clearContents()
    pasteboard.setString("newer user copy", forType: .string)
    let disposition = transaction.finish(
        pasteWasAttempted: true,
        stagedTextWasConsumed: true,
        text: "new transcript",
        pasteboard: pasteboard
    )

    #expect(disposition == .keepCurrentClipboard)
    #expect(pasteboard.string(forType: .string) == "newer user copy")
}

@Test("Unverified auto-paste preserves the transcript and its no-retry outcome")
func unverifiedAutoPastePreservesTranscript() async throws {
    let clipboard = TransactionalMemoryClipboard(value: "previous clipboard")
    let expected = AutoPasteOutcome.unverified(reason: "Paste sent but not confirmed")
    let transport = ClipboardInsertionTransport(clipboard: clipboard) { _ in expected }
    let outcome = try await transport.insertAndReturnOutcome(text: "recovery transcript", target: .unknown)
    #expect(outcome == expected)
    #expect(await clipboard.value == "recovery transcript")
    #expect(await clipboard.restoreCount == 0)
}
