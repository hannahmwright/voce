import AppKit
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

@Suite(.serialized)
@MainActor
struct ClipboardRecoveryPromptTests {
    @Test("Unverified recovery hides the popup and repeated clicks cannot paste again")
    func unverifiedRecoveryIsOneShot() async {
        let presenter = ClipboardRecoveryPromptPresenter()
        defer { presenter.hide() }
        var pastes = 0
        presenter.show(onCopy: {}, onPasteAfterRefocus: {
            pastes += 1
            #expect(!presenter.isVisible)
            return false
        })
        presenter.recoverAfterRefocusClick()
        presenter.recoverAfterRefocusClick()
        await presenter.pendingPasteTask?.value
        presenter.recoverAfterRefocusClick()
        await presenter.pendingPasteTask?.value
        #expect(pastes == 1)
        #expect(!presenter.isVisible)
    }

    @Test("Dismiss and Copy cancel a queued recovery paste")
    func dismissAndCopyCancelPaste() async {
        let presenter = ClipboardRecoveryPromptPresenter()
        defer { presenter.hide() }
        var pastes = 0
        var copies = 0
        for copy in [false, true] {
            presenter.show(onCopy: { copies += 1 }, onPasteAfterRefocus: {
                pastes += 1
                return true
            })
            presenter.recoverAfterRefocusClick()
            let pending = presenter.pendingPasteTask
            if copy { presenter.handleCopyButton() }
            else { presenter.handleDismissButton() }
            await pending?.value
            presenter.recoverAfterRefocusClick()
            #expect(!presenter.isVisible)
        }
        #expect(pastes == 0)
        #expect(copies == 1)
    }

    @Test("Escape dismisses the native popup and cancels a queued paste")
    func escapeCancelsPaste() async throws {
        let presenter = ClipboardRecoveryPromptPresenter()
        defer { presenter.hide() }
        var pastes = 0
        presenter.show(onCopy: {}, onPasteAfterRefocus: { pastes += 1; return true })
        presenter.recoverAfterRefocusClick()
        let pending = presenter.pendingPasteTask
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        NSApplication.shared.sendEvent(event)
        await pending?.value
        #expect(!presenter.isVisible)
        #expect(pastes == 0)
    }

    @Test("An old in-flight recovery cannot dismiss or clear a replacement prompt")
    func staleRecoveryCannotAffectNewPrompt() async {
        let presenter = ClipboardRecoveryPromptPresenter()
        defer { presenter.hide() }
        var continuation: CheckedContinuation<Bool, Never>?
        presenter.show(onCopy: {}, onPasteAfterRefocus: {
            await withCheckedContinuation { continuation = $0 }
        })
        presenter.recoverAfterRefocusClick()
        let oldTask = presenter.pendingPasteTask
        // Wait for the actual callback rather than assuming scheduler timing.
        for _ in 0..<200 {
            if continuation != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(continuation != nil)
        guard continuation != nil else { return }
        var newPastes = 0
        presenter.show(onCopy: {}, onPasteAfterRefocus: {
            newPastes += 1
            return true
        })
        continuation?.resume(returning: false)
        await oldTask?.value
        #expect(presenter.isVisible)
        presenter.recoverAfterRefocusClick()
        await presenter.pendingPasteTask?.value
        #expect(newPastes == 1)
        #expect(!presenter.isVisible)
    }
}
