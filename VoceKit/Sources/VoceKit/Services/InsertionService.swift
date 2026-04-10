import Foundation

public enum AutoPasteOutcome: Sendable, Equatable {
    case attempted
    case skipped(reason: String)

    public var skippedReason: String? {
        guard case .skipped(let reason) = self else { return nil }
        return reason
    }
}

public struct InsertionService: InsertionServiceProtocol, Sendable {
    private static let terminalClipboardFirstBundleIDs: Set<String> = [
        "dev.warp.warp-stable",
        "com.openai.codex",
        "com.apple.terminal",
        "com.googlecode.iterm2"
    ]

    private let transports: [any InsertionTransport]

    private struct TransportFailure: Sendable {
        let method: InsertionMethod
        let message: String
    }

    public init(transports: [any InsertionTransport]) {
        self.transports = transports
    }

    public func insert(text: String, target: AppContext) async -> InsertResult {
        var failures: [TransportFailure] = []

        for transport in prioritizedTransports(for: target) {
            if let clipboardTransport = transport as? ClipboardInsertionTransport {
                do {
                    let outcome = try await clipboardTransport.insertAndReturnOutcome(text: text, target: target)
                    let status: InsertionStatus
                    let errorMessage: String?
                    let recoveryAction: InsertionRecoveryAction?
                    switch outcome {
                    case .attempted:
                        status = .inserted
                        errorMessage = nil
                        recoveryAction = nil
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

        return InsertResult(
            status: .failed,
            method: .none,
            insertedText: text,
            errorMessage: failures
                .map { "\($0.method.rawValue): \($0.message)" }
                .joined(separator: " | ")
        )
    }

    private func suggestedRecoveryAction(
        after failures: [TransportFailure],
        clipboardSkipReason: String
    ) -> InsertionRecoveryAction? {
        guard isRefocusPasteCandidate(skipReason: clipboardSkipReason) else {
            return nil
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
    }

    private func isFocusLossCandidate(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("no focused text element")
            || normalized.contains("focused element does not support ax text insertion")
            || normalized.contains("failed to update focused element text")
    }

    private func prioritizedTransports(for target: AppContext) -> [any InsertionTransport] {
        guard Self.terminalClipboardFirstBundleIDs.contains(target.bundleIdentifier.lowercased()) else {
            return transports
        }

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

    public init(
        clipboard: ClipboardService,
        autoPaste: (@Sendable (_ target: AppContext) async -> AutoPasteOutcome)? = nil
    ) {
        self.clipboard = clipboard
        self.autoPaste = autoPaste
    }

    public func insert(text: String, target: AppContext) async throws {
        _ = try await insertAndReturnOutcome(text: text, target: target)
    }

    public func insertAndReturnOutcome(text: String, target: AppContext) async throws -> AutoPasteOutcome {
        try await clipboard.setString(text)

        guard let autoPaste else {
            return .skipped(reason: "Auto-paste callback not configured.")
        }

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms for clipboard to settle
        return await autoPaste(target)
    }
}

#if os(macOS)
import AppKit

public actor MacClipboardService: ClipboardService {
    public init() {}

    public func setString(_ text: String) async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
