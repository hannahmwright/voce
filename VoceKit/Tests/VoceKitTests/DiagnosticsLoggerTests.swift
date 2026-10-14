import Foundation
import Testing
@testable import VoceKit

@Test("Diagnostic store keeps a bounded, single-line event trail")
func diagnosticStoreKeepsBoundedSanitizedEvents() {
    let store = VoceDiagnosticStore(maximumEventCount: 2)
    store.record(category: "input", event: "first", details: ["reason": "old"])
    store.record(category: "input", event: "second", details: ["reason": "line one\nline two"])
    store.record(category: "completion", event: "third", details: ["status": "copied_only"])

    let report = store.reportText()

    #expect(!report.contains("input.first"))
    #expect(report.contains("input.second reason=line one line two"))
    #expect(report.contains("completion.third status=copied_only"))
}

@Test("Diagnostic events survive an app restart")
func diagnosticEventsPersistAcrossStoreInstances() {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voce-diagnostics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let firstStore = VoceDiagnosticStore(maximumEventCount: 4, persistenceURL: fileURL)
    firstStore.record(
        category: "insertion",
        event: "skipped",
        details: ["reason": "focused_field_changed"]
    )
    firstStore.flush()

    let restoredStore = VoceDiagnosticStore(maximumEventCount: 4, persistenceURL: fileURL)
    #expect(restoredStore.reportText().contains("reason=focused_field_changed"))
}

@Test("Diagnostic persistence is coalesced off the recording thread")
func diagnosticPersistenceIsCoalesced() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voce-diagnostics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = VoceDiagnosticStore(
        maximumEventCount: 10,
        persistenceURL: fileURL,
        persistenceCoalescingInterval: 0.2
    )
    for index in 0..<5 {
        store.record(category: "insertion", event: "event_\(index)")
    }

    // record() never writes synchronously.
    #expect(store.persistenceWriteCount == 0)
    // The in-memory trail is immediately up to date.
    #expect(store.reportText().contains("insertion.event_4"))

    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(store.persistenceWriteCount == 1)

    let restored = VoceDiagnosticStore(maximumEventCount: 10, persistenceURL: fileURL)
    #expect(restored.reportText().contains("insertion.event_0"))
    #expect(restored.reportText().contains("insertion.event_4"))

    // A flush with nothing new recorded does not rewrite the file.
    store.flush()
    #expect(store.persistenceWriteCount == 1)
}

@Test("Diagnostic flush writes pending events immediately")
func diagnosticFlushWritesPendingEvents() {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voce-diagnostics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = VoceDiagnosticStore(
        maximumEventCount: 10,
        persistenceURL: fileURL,
        persistenceCoalescingInterval: 60
    )
    store.record(category: "input", event: "pending")
    store.flush()

    #expect(store.persistenceWriteCount == 1)
    let restored = VoceDiagnosticStore(maximumEventCount: 10, persistenceURL: fileURL)
    #expect(restored.reportText().contains("input.pending"))
}

@Test("Failure diagnostics are written without waiting for the coalescing window")
func failureDiagnosticsPersistImmediately() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voce-diagnostics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = VoceDiagnosticStore(
        maximumEventCount: 10,
        persistenceURL: fileURL,
        persistenceCoalescingInterval: 60
    )
    store.record(category: "input_target", event: "captured")
    store.record(category: "input_target", event: "capture_failed", details: ["reason": "x"])

    // Not flushed: the failure event alone triggers a background write that
    // also carries the routine event recorded before it.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(store.persistenceWriteCount == 1)
    let restored = VoceDiagnosticStore(maximumEventCount: 10, persistenceURL: fileURL)
    #expect(restored.reportText().contains("input_target.captured"))
    #expect(restored.reportText().contains("input_target.capture_failed"))
}

@Test("Failure event classification")
func failureEventClassification() {
    #expect(VoceDiagnosticStore.isFailureEvent(category: "insertion", name: "paste_unverified", details: [:]))
    #expect(VoceDiagnosticStore.isFailureEvent(category: "insertion", name: "skipped", details: [:]))
    #expect(VoceDiagnosticStore.isFailureEvent(category: "completion", name: "execution_finished", details: ["status": "failed"]))
    #expect(!VoceDiagnosticStore.isFailureEvent(category: "dictation", name: "started", details: [:]))
    #expect(!VoceDiagnosticStore.isFailureEvent(category: "insertion", name: "paste_verified", details: ["reason": "error_free"]))
}
