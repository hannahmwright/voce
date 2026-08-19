import Foundation
import OSLog

enum VoceKitDiagnostics {
    // VoceKit uses its own subsystem so package logs can be filtered separately
    // from app-layer logs (which use io.voceapp.voce).
    static let logger = Logger(subsystem: "io.voceapp.vocekit", category: "Diagnostics")
}

/// A bounded, persistent trail of non-sensitive runtime decisions that can
/// be attached to a support request. Callers must never include transcript
/// text, clipboard contents, credentials, or field values in `details`.
public final class VoceDiagnosticStore: @unchecked Sendable {
    public static let shared = VoceDiagnosticStore(
        persistenceURL: VoceRuntimeConfiguration.applicationSupportDirectory(
            fileName: "recent-diagnostics.json"
        )
    )

    private struct Event: Sendable, Codable {
        let date: Date
        let category: String
        let name: String
        let details: [String: String]
    }

    private let lock = NSLock()
    private let maximumEventCount: Int
    private let persistenceURL: URL?
    private let persistenceQueue = DispatchQueue(
        label: "io.voceapp.vocekit.diagnostics-persistence",
        qos: .utility
    )
    private var events: [Event] = []

    public init(
        maximumEventCount: Int = 80,
        persistenceURL: URL? = nil
    ) {
        self.maximumEventCount = max(1, maximumEventCount)
        self.persistenceURL = persistenceURL
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let storedEvents = try? JSONDecoder().decode([Event].self, from: data) {
            events = Array(storedEvents.suffix(self.maximumEventCount))
        }
    }

    public func record(
        category: String,
        event name: String,
        details: [String: String] = [:]
    ) {
        let event = Event(
            date: Date(),
            category: Self.sanitized(category),
            name: Self.sanitized(name),
            details: details.reduce(into: [:]) { result, pair in
                result[Self.sanitized(pair.key)] = Self.sanitized(pair.value)
            }
        )

        lock.lock()
        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        let persistenceSnapshot = events
        lock.unlock()

        persist(persistenceSnapshot)

        let detailText = Self.renderDetails(event.details)
        if detailText.isEmpty {
            VoceKitDiagnostics.logger.info(
                "\(event.category, privacy: .public).\(event.name, privacy: .public)"
            )
        } else {
            VoceKitDiagnostics.logger.info(
                "\(event.category, privacy: .public).\(event.name, privacy: .public) \(detailText, privacy: .public)"
            )
        }
    }

    public func reportText() -> String {
        lock.lock()
        let snapshot = events
        lock.unlock()

        guard !snapshot.isEmpty else {
            return "recent_runtime_events=none"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = snapshot.map { event in
            let details = Self.renderDetails(event.details)
            let suffix = details.isEmpty ? "" : " \(details)"
            return "\(formatter.string(from: event.date)) \(event.category).\(event.name)\(suffix)"
        }
        return (["recent_runtime_events="] + lines).joined(separator: "\n")
    }

    private static func renderDetails(_ details: [String: String]) -> String {
        details.keys.sorted().map { key in
            "\(key)=\(details[key] ?? "unknown")"
        }.joined(separator: " ")
    }

    private static func sanitized(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(240))
    }

    private func persist(_ events: [Event]) {
        guard let persistenceURL else { return }
        persistenceQueue.sync {
            do {
                let directory = persistenceURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(events)
                try data.write(to: persistenceURL, options: .atomic)
            } catch {
                VoceKitDiagnostics.logger.error(
                    "Failed to persist recent diagnostics: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
