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

    let restoredStore = VoceDiagnosticStore(maximumEventCount: 4, persistenceURL: fileURL)
    #expect(restoredStore.reportText().contains("reason=focused_field_changed"))
}
