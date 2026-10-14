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

@Test("Temporarily staged transcript is marked transient for clipboard managers")
@MainActor
func stagedTranscriptIsMarkedTransient() {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let provider = TemporaryPasteboardDataProvider(text: "staged transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "staged transcript",
        provider: provider,
        pasteboard: pasteboard
    )

    let stagedTypes = pasteboard.pasteboardItems?.first?.types ?? []
    #expect(stagedTypes.contains(.init("org.nspasteboard.TransientType")))
    #expect(stagedTypes.contains(.init("org.nspasteboard.AutoGeneratedType")))

    // When the transcript is meant to stay on the clipboard, it is a normal entry.
    let disposition = transaction.finish(
        pasteWasAttempted: false,
        stagedTextWasConsumed: false,
        text: "staged transcript",
        pasteboard: pasteboard
    )
    #expect(disposition == .preserveTranscript)
    #expect(pasteboard.string(forType: .string) == "staged transcript")
    let keptTypes = pasteboard.pasteboardItems?.first?.types ?? []
    #expect(!keptTypes.contains(.init("org.nspasteboard.TransientType")))
    #expect(!keptTypes.contains(.init("org.nspasteboard.AutoGeneratedType")))
}

@Test("Concealed clipboard contents are restored with their markers")
@MainActor
func concealedClipboardIsRestoredWithMarkers() async {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }

    let secretItem = NSPasteboardItem()
    secretItem.setString("hunter2", forType: .string)
    secretItem.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    secretItem.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
    pasteboard.clearContents()
    pasteboard.writeObjects([secretItem])

    let provider = TemporaryPasteboardDataProvider(text: "new transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "new transcript",
        provider: provider,
        pasteboard: pasteboard
    )
    let consumed = pasteboard.string(forType: .string) == "new transcript"
    let disposition = transaction.finish(
        pasteWasAttempted: true,
        stagedTextWasConsumed: consumed,
        text: "new transcript",
        pasteboard: pasteboard
    )

    #expect(disposition == .restoreSnapshot)
    #expect(pasteboard.string(forType: .string) == "hunter2", "A password manager's copy must survive dictation.")
    let restoredTypes = pasteboard.pasteboardItems?.first?.types ?? []
    #expect(restoredTypes.contains(.init("org.nspasteboard.ConcealedType")))
    #expect(restoredTypes.contains(.init("org.nspasteboard.TransientType")))
}

@Test("A clipboard over the snapshot budget is not partially restored")
@MainActor
func oversizedClipboardKeepsTranscriptInsteadOfPartialRestore() {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }

    let priorItem = NSPasteboardItem()
    priorItem.setString("previous", forType: .string)
    priorItem.setData(Data(repeating: 0xAB, count: 64), forType: .init("io.voce.tests.rich-data"))
    pasteboard.clearContents()
    pasteboard.writeObjects([priorItem])

    let provider = TemporaryPasteboardDataProvider(text: "new transcript")
    let transaction = TemporaryPasteboardTransaction.begin(
        text: "new transcript",
        provider: provider,
        pasteboard: pasteboard,
        snapshotByteLimit: 32
    )
    let disposition = transaction.finish(
        pasteWasAttempted: true,
        stagedTextWasConsumed: true,
        text: "new transcript",
        pasteboard: pasteboard
    )

    #expect(disposition == .transcriptKeptSnapshotTooLarge)
    #expect(pasteboard.string(forType: .string) == "new transcript")
    #expect(pasteboard.data(forType: .init("io.voce.tests.rich-data")) == nil)
    let types = pasteboard.pasteboardItems?.first?.types ?? []
    #expect(!types.contains(.init("org.nspasteboard.TransientType")))
}

@Test("Deferred staging snapshots and stages exactly once")
@MainActor
func deferredStagingStagesOnce() {
    let pasteboard = NSPasteboard(name: .init("io.voce.tests.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()
    pasteboard.setString("previous clipboard", forType: .string)

    let staging = TemporaryPasteStaging(
        text: "new transcript",
        provider: TemporaryPasteboardDataProvider(text: "new transcript"),
        pasteboard: pasteboard
    )
    #expect(staging.transaction == nil)
    #expect(pasteboard.string(forType: .string) == "previous clipboard", "Nothing is touched before staging.")

    staging.stageIfNeeded()
    let firstChangeCount = staging.transaction?.stagedChangeCount
    staging.stageIfNeeded()

    #expect(firstChangeCount != nil)
    #expect(staging.transaction?.stagedChangeCount == firstChangeCount)
    #expect(pasteboard.changeCount == firstChangeCount)
}

private actor NoticeRaisingClipboard: TemporaryClipboardPasteService {
    func setString(_ text: String) async throws {}

    func performTemporaryPaste(
        text: String,
        paste: @escaping @Sendable () async -> AutoPasteOutcome
    ) async throws -> AutoPasteOutcome {
        let outcome = await paste()
        InsertionNoticeContext.collector?.record("Previous clipboard was not restored.")
        return outcome
    }
}

@Test("A verified paste stays inserted and carries a clipboard notice separately")
func verifiedPasteCarriesNoticeWithoutDowngrading() async {
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(clipboard: NoticeRaisingClipboard()) { _ in .attempted }
    ])

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .inserted)
    #expect(result.errorMessage == nil)
    #expect(result.recoveryAction == nil)
    #expect(result.notice == "Previous clipboard was not restored.")
}

@Test("A copied-only result never carries a clipboard notice")
func copiedOnlyResultDropsNotice() async {
    let service = InsertionService(transports: [
        ClipboardInsertionTransport(clipboard: NoticeRaisingClipboard()) { _ in
            .unverified(reason: "Paste sent but not confirmed")
        }
    ])

    let result = await service.insert(text: "hello", target: .unknown)

    #expect(result.status == .copiedOnly)
    #expect(result.notice == nil)
}
