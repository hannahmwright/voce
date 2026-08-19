import Foundation
import Testing
import VoceKit
@testable import Voce

private actor SafetyTestInsertionService: InsertionServiceProtocol {
    private(set) var callCount = 0

    func insert(text: String, target: AppContext) async -> InsertResult {
        await insert(text: text, target: target, inputTarget: nil)
    }

    func insert(
        text: String,
        target: AppContext,
        inputTarget: FocusedInputTarget?
    ) async -> InsertResult {
        _ = target
        _ = inputTarget
        callCount += 1
        return InsertResult(status: .inserted, method: .clipboardPaste, insertedText: text)
    }
}

private actor SafetyTestClipboardService: ClipboardService {
    private(set) var value: String?

    func setString(_ text: String) async throws {
        value = text
    }
}

@MainActor
@Test("A stale completion is copied and never reaches automatic insertion")
func staleCompletionIsCopiedInsteadOfInserted() async throws {
    let insertion = SafetyTestInsertionService()
    let clipboard = SafetyTestClipboardService()
    let service = CompletionExecutionService(
        insertionService: insertion,
        clipboardService: clipboard,
        aiGenerationService: AppleFoundationModelsService()
    )
    let sessionID = UUID()
    let transcript = FinalizedTranscript(
        rawText: "late transcript",
        cleanText: "late transcript",
        appContext: AppContext(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
        sourceSessionID: sessionID
    )
    let routed = RoutedCompletion(
        action: .insert,
        inputText: transcript.cleanText,
        selectedBy: .defaultBehavior
    )

    let result = try await service.execute(
        routedCompletion: routed,
        finalizedTranscript: transcript,
        workflows: [],
        automaticInsertionAllowed: { false }
    )

    #expect(result.insertResult.status == .copiedOnly)
    #expect(result.insertResult.errorMessage?.contains("newer dictation") == true)
    #expect(await insertion.callCount == 0)
    #expect(await clipboard.value == "late transcript")
}
