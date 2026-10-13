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
    /// Persistence is coalesced: `record` only marks the trail dirty and
    /// schedules one write per `persistenceCoalescingInterval` on the
    /// background queue, so callers (often the main actor) never encode JSON or
    /// touch the disk. Protected by `lock`.
    private let persistenceCoalescingInterval: TimeInterval
    private var hasUnpersistedEvents = false
    private var isPersistenceScheduled = false
    private var persistenceWrites = 0
    private var terminationObserver: NSObjectProtocol?

    public init(
        maximumEventCount: Int = 80,
        persistenceURL: URL? = nil,
        persistenceCoalescingInterval: TimeInterval = 1
    ) {
        self.maximumEventCount = max(1, maximumEventCount)
        self.persistenceURL = persistenceURL
        self.persistenceCoalescingInterval = max(0, persistenceCoalescingInterval)
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let storedEvents = try? JSONDecoder().decode([Event].self, from: data) {
            events = Array(storedEvents.suffix(self.maximumEventCount))
        }
        if persistenceURL != nil {
            // Flush the coalesced trail when the app quits so the last events
            // of a session are not lost. Uses the raw notification name to keep
            // this utility free of an AppKit dependency.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("NSApplicationWillTerminateNotification"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
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
        let shouldSchedulePersistence = persistenceURL != nil && !isPersistenceScheduled
        if persistenceURL != nil {
            hasUnpersistedEvents = true
        }
        if shouldSchedulePersistence {
            isPersistenceScheduled = true
        }
        lock.unlock()

        if shouldSchedulePersistence {
            persistenceQueue.asyncAfter(deadline: .now() + persistenceCoalescingInterval) { [self] in
                persistPendingEvents()
            }
        }

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

    /// Synchronously writes any events recorded since the last write. Safe to
    /// call from any thread; called automatically on app termination.
    public func flush() {
        guard persistenceURL != nil else { return }
        persistenceQueue.sync {
            persistPendingEvents()
        }
    }

    /// Number of file writes performed so far. Exposed for tests.
    var persistenceWriteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return persistenceWrites
    }

    /// Must run on `persistenceQueue`.
    private func persistPendingEvents() {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        guard let persistenceURL else { return }

        lock.lock()
        isPersistenceScheduled = false
        guard hasUnpersistedEvents else {
            lock.unlock()
            return
        }
        hasUnpersistedEvents = false
        let snapshot = events
        persistenceWrites += 1
        lock.unlock()

        do {
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            VoceKitDiagnostics.logger.error(
                "Failed to persist recent diagnostics: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
