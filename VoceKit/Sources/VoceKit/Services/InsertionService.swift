import Foundation

public enum AutoPasteOutcome: Sendable, Equatable {
    case attempted
    /// Cmd+V was sent, but insertion could not be confirmed. Never auto-retry.
    case unverified(reason: String)
    case skipped(reason: String)

    public var skippedReason: String? {
        switch self {
        case .attempted: return nil
        case .skipped(let reason), .unverified(let reason): return reason
        }
    }
}

public struct InsertionService: InsertionServiceProtocol, Sendable {
    private let transports: [any InsertionTransport]

    private struct TransportFailure: Sendable {
        let method: InsertionMethod
        let message: String
    }

    public init(transports: [any InsertionTransport]) {
        self.transports = transports
    }

    public func insert(text: String, target: AppContext) async -> InsertResult {
        await insert(text: text, target: target, inputTarget: nil)
    }

    public func insert(
        text: String,
        target: AppContext,
        inputTarget: FocusedInputTarget?
    ) async -> InsertResult {
        await insert(
            text: text,
            target: target,
            inputTarget: inputTarget,
            exactTargetRequired: false
        )
    }

    public func insert(
        text: String,
        target: AppContext,
        inputTarget: FocusedInputTarget?,
        exactTargetRequired: Bool
    ) async -> InsertResult {
        var failures: [TransportFailure] = []

        for transport in prioritizedTransports(for: target) {
            if let clipboardTransport = transport as? ClipboardInsertionTransport {
                do {
                    let outcome = try await clipboardTransport.insertAndReturnOutcome(
                        text: text,
                        target: target,
                        inputTarget: inputTarget
                    )
                    let status: InsertionStatus
                    let errorMessage: String?
                    let recoveryAction: InsertionRecoveryAction?
                    switch outcome {
                    case .attempted:
                        status = .inserted
                        errorMessage = nil
                        recoveryAction = nil
                    case .unverified(let reason):
                        status = .copiedOnly
                        errorMessage = reason
                        recoveryAction = .checkBeforePasting
                    case .skipped(let reason):
                        status = .copiedOnly
                        errorMessage = reason
                        recoveryAction = suggestedRecoveryAction(
                            after: failures,
                            clipboardSkipReason: reason
                        )
                    }
                    return InsertResult(
                        status: status,
                        method: .clipboardPaste,
                        insertedText: text,
                        errorMessage: errorMessage,
                        recoveryAction: recoveryAction
                    )
                } catch {
                    failures.append(
                        TransportFailure(
                            method: transport.method,
                            message: error.localizedDescription
                        )
                    )
                    continue
                }
            }

            if exactTargetRequired {
                VoceDiagnosticStore.shared.record(
                    category: "insertion",
                    event: "unverified_transport_skipped",
                    details: ["method": transport.method.rawValue]
                )
                failures.append(
                    TransportFailure(
                        method: transport.method,
                        message: "Skipped because this transport cannot verify the exact dictation field."
                    )
                )
                continue
            }

            do {
                try await transport.insert(text: text, target: target)

                let status: InsertionStatus = transport.method == .clipboardPaste ? .copiedOnly : .inserted
                return InsertResult(status: status, method: transport.method, insertedText: text)
            } catch {
                failures.append(
                    TransportFailure(
                        method: transport.method,
                        message: error.localizedDescription
                    )
                )
            }
        }

        let failureSummary = failures
            .map { "\($0.method.rawValue): \($0.message)" }
            .joined(separator: " | ")

        // Last resort: every transport failed, including the clipboard
        // transport's own copy attempt. Retry a plain copy (no auto-paste) so
        // the transcript is never lost — the user can still paste manually.
        for transport in transports {
            guard let clipboardTransport = transport as? ClipboardInsertionTransport else { continue }
            if (try? await clipboardTransport.copyToClipboard(text: text)) != nil {
                return InsertResult(
                    status: .copiedOnly,
                    method: .clipboardPaste,
                    insertedText: text,
                    errorMessage: "Insertion failed; copied to clipboard instead. \(failureSummary)"
                )
            }
        }

        return InsertResult(
            status: .failed,
            method: .none,
            insertedText: text,
            errorMessage: failureSummary
        )
    }

    private func suggestedRecoveryAction(
        after failures: [TransportFailure],
        clipboardSkipReason: String
    ) -> InsertionRecoveryAction? {
        guard isRefocusPasteCandidate(skipReason: clipboardSkipReason) else {
            return nil
        }

        guard !failures.isEmpty else {
            return .refocusToPaste
        }

        let failedMethods = Set(failures.map(\.method))
        guard failedMethods.contains(.direct), failedMethods.contains(.accessibility) else {
            return nil
        }

        let relevantFailures = failures.filter { $0.method == .direct || $0.method == .accessibility }
        guard relevantFailures.contains(where: { isFocusLossCandidate(message: $0.message) }) else {
            return nil
        }

        return .refocusToPaste
    }

    private func isRefocusPasteCandidate(skipReason: String) -> Bool {
        let normalized = skipReason.lowercased()
        return normalized.contains("could not focus target app")
            || normalized.contains("unable to synthesize cmd+v")
            || normalized.contains("target app was not found")
            || normalized.contains("editable field selected for dictation")
    }

    private func isFocusLossCandidate(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("no focused text element")
            || normalized.contains("focused element does not support ax text insertion")
            || normalized.contains("failed to update focused element text")
    }

    /// Clipboard paste always runs first, by design: it is the only transport
    /// whose result is positively verified against the exact captured field,
    /// and its outcome (inserted, unverified, or skipped with the transcript
    /// left on the clipboard) is final. Direct typing and AX insertion run
    /// only when the clipboard transport throws, in their configured relative
    /// order, and never when `exactTargetRequired` is set. The app pins the
    /// configured order to `[.clipboardPaste, .accessibility, .direct]`
    /// (`AppPreferences.reliableInsertionOrder`), so there is no user-facing
    /// ordering preference to honor.
    private func prioritizedTransports(for _: AppContext) -> [any InsertionTransport] {
        var clipboard: [any InsertionTransport] = []
        var others: [any InsertionTransport] = []

        for transport in transports {
            if transport.method == .clipboardPaste {
                clipboard.append(transport)
            } else {
                others.append(transport)
            }
        }

        return clipboard + others
    }
}

public actor MemoryClipboardService: ClipboardService {
    public private(set) var latestValue: String = ""

    public init() {}

    public func setString(_ text: String) async throws {
        latestValue = text
    }
}

public struct ClipboardInsertionTransport: InsertionTransport {
    public let method: InsertionMethod = .clipboardPaste
    private let clipboard: ClipboardService
    private let autoPaste: (@Sendable (_ target: AppContext) async -> AutoPasteOutcome)?
    private let autoPasteWithInputTarget: (@Sendable (_ text: String, _ target: AppContext, _ inputTarget: FocusedInputTarget?) async -> AutoPasteOutcome)?

    public init(
        clipboard: ClipboardService,
        autoPaste: (@Sendable (_ target: AppContext) async -> AutoPasteOutcome)? = nil
    ) {
        self.clipboard = clipboard
        self.autoPaste = autoPaste
        self.autoPasteWithInputTarget = nil
    }

    public init(
        clipboard: ClipboardService,
        autoPasteWithInputTarget: @escaping @Sendable (_ text: String, _ target: AppContext, _ inputTarget: FocusedInputTarget?) async -> AutoPasteOutcome
    ) {
        self.clipboard = clipboard
        self.autoPaste = nil
        self.autoPasteWithInputTarget = autoPasteWithInputTarget
    }

    public func insert(text: String, target: AppContext) async throws {
        _ = try await insertAndReturnOutcome(text: text, target: target)
    }

    /// Copies to the clipboard without attempting auto-paste. Used by
    /// `InsertionService` as a last-resort fallback when every transport
    /// (including this one's initial copy) has failed.
    public func copyToClipboard(text: String) async throws {
        try await clipboard.setString(text)
    }

    public func insertAndReturnOutcome(text: String, target: AppContext) async throws -> AutoPasteOutcome {
        try await insertAndReturnOutcome(text: text, target: target, inputTarget: nil)
    }

    public func insertAndReturnOutcome(
        text: String,
        target: AppContext,
        inputTarget: FocusedInputTarget?
    ) async throws -> AutoPasteOutcome {
        guard autoPaste != nil || autoPasteWithInputTarget != nil else {
            try await clipboard.setString(text)
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        if let temporaryClipboard = clipboard as? any TemporaryClipboardPasteService {
            // The temporary paste service owns staging (and the settle delay
            // after it), so the transcript is only staged once the paste
            // helper's preconditions have passed.
            return try await temporaryClipboard.performTemporaryPaste(text: text) {
                await paste(text: text, target: target, inputTarget: inputTarget)
            }
        }

        try await clipboard.setString(text)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms for clipboard to settle
        return await paste(text: text, target: target, inputTarget: inputTarget)
    }

    private func paste(
        text: String,
        target: AppContext,
        inputTarget: FocusedInputTarget?
    ) async -> AutoPasteOutcome {
        if let autoPasteWithInputTarget {
            return await autoPasteWithInputTarget(text, target, inputTarget)
        }
        if let autoPaste {
            return await autoPaste(target)
        }
        return .skipped(reason: "Auto-paste callback not configured.")
    }
}

#if os(macOS)
import AppKit

public actor MacClipboardService: TemporaryClipboardPasteService {
    public init() {}

    public func setString(_ text: String) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    public func performTemporaryPaste(
        text: String,
        paste: @escaping @Sendable () async -> AutoPasteOutcome
    ) async throws -> AutoPasteOutcome {
        let provider = TemporaryPasteboardDataProvider(text: text)
        let (staging, changeCountBeforePaste) = await MainActor.run {
            (TemporaryPasteStaging(text: text, provider: provider), NSPasteboard.general.changeCount)
        }

        // `MacPasteHelper.activateAndPaste` snapshots the clipboard and stages
        // the transcript through `staging` only after its cheap preconditions
        // pass, right before Cmd+V.
        let pasteOutcome = await TemporaryPasteStagingContext.$current.withValue(staging) {
            await paste()
        }

        guard let transaction = await MainActor.run(body: { staging.transaction }) else {
            return await MainActor.run {
                Self.finishUnstagedPaste(
                    text: text,
                    pasteOutcome: pasteOutcome,
                    changeCountBeforePaste: changeCountBeforePaste
                )
            }
        }

        let didConsumeStagedText: Bool
        switch pasteOutcome {
        case .attempted:
            didConsumeStagedText = await provider.waitUntilConsumed()
        case .skipped, .unverified:
            didConsumeStagedText = false
        }

        let disposition = await MainActor.run {
            transaction.finish(
                pasteWasAttempted: pasteOutcome == .attempted,
                stagedTextWasConsumed: didConsumeStagedText,
                text: text
            )
        }

        if disposition == .keepCurrentClipboard {
            let baseReason = pasteOutcome.skippedReason
                ?? "Voce could not confirm that the target accepted the paste."
            let reason = "\(baseReason) The clipboard changed during insertion, so Voce did not overwrite the newer clipboard contents."
            if case .skipped = pasteOutcome {
                return .skipped(reason: reason)
            }
            return .unverified(reason: reason)
        }

        guard pasteOutcome == .attempted, !didConsumeStagedText else {
            return pasteOutcome
        }

        return .unverified(
            reason: "Voce could not confirm that the target accepted the paste. The transcript was kept on your clipboard."
        )
    }

    /// The paste ended without staging: the helper's preconditions failed
    /// before Cmd+V, so the user's clipboard was never snapshotted. Leave the
    /// transcript on the clipboard for manual pasting (the same end state as a
    /// staged paste that was skipped), unless the user copied something newer.
    @MainActor
    private static func finishUnstagedPaste(
        text: String,
        pasteOutcome: AutoPasteOutcome,
        changeCountBeforePaste: Int
    ) -> AutoPasteOutcome {
        let pasteboard = NSPasteboard.general
        if case .attempted = pasteOutcome {
            // Only a paste closure that does not stage through
            // `TemporaryPasteStagingContext` can get here; the paste cannot be
            // trusted to have used the transcript.
            VoceDiagnosticStore.shared.record(
                category: "insertion",
                event: "temporary_paste_not_staged"
            )
        }

        guard pasteboard.changeCount == changeCountBeforePaste else {
            let baseReason = pasteOutcome.skippedReason
                ?? "Voce could not confirm that the target accepted the paste."
            let reason = "\(baseReason) The clipboard changed during insertion, so Voce did not overwrite the newer clipboard contents."
            if case .skipped = pasteOutcome {
                return .skipped(reason: reason)
            }
            return .unverified(reason: reason)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if case .attempted = pasteOutcome {
            return .unverified(
                reason: "Voce could not confirm that the target accepted the paste. The transcript was kept on your clipboard."
            )
        }
        return pasteOutcome
    }
}
#endif
