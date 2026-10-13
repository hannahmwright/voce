import Foundation

/// Usage seconds that still have to be reported to the Voce backend.
///
/// Reports are coalesced per account email and feature so a run of offline
/// dictations becomes one request once the network is back. The queue is a
/// plain value so callers can persist it (it is `Codable`) and test the
/// retry policy without a network.
public struct PendingUsageReportQueue: Sendable, Codable, Equatable {
    public struct Report: Sendable, Codable, Equatable {
        public var email: String
        public var feature: String
        public var seconds: Int
        public var firstQueuedAt: Date

        public init(email: String, feature: String, seconds: Int, firstQueuedAt: Date) {
            self.email = email
            self.feature = feature
            self.seconds = seconds
            self.firstQueuedAt = firstQueuedAt
        }
    }

    /// Reports older than this are dropped instead of being charged to a
    /// later billing period.
    public static let maximumReportAge: TimeInterval = 31 * 24 * 60 * 60

    public private(set) var reports: [Report]

    public init(reports: [Report] = []) {
        self.reports = reports
    }

    public var isEmpty: Bool {
        reports.isEmpty
    }

    /// Adds `seconds` for `email`/`feature`, merging with any queued report.
    public mutating func enqueue(email: String, feature: String, seconds: Int, now: Date) {
        guard !email.isEmpty, !feature.isEmpty, seconds > 0 else { return }

        if let index = index(email: email, feature: feature) {
            reports[index].seconds += seconds
        } else {
            reports.append(Report(email: email, feature: feature, seconds: seconds, firstQueuedAt: now))
        }
    }

    /// Removes `seconds` that the backend accepted. Seconds queued while the
    /// request was in flight stay queued for the next attempt.
    public mutating func acknowledge(email: String, feature: String, seconds: Int) {
        guard let index = index(email: email, feature: feature) else { return }
        reports[index].seconds -= seconds
        if reports[index].seconds <= 0 {
            reports.remove(at: index)
        }
    }

    /// Drops a report the backend will never accept.
    public mutating func discard(email: String, feature: String) {
        guard let index = index(email: email, feature: feature) else { return }
        reports.remove(at: index)
    }

    /// Drops reports that waited longer than `maximumAge`.
    public mutating func pruneExpired(now: Date, maximumAge: TimeInterval = Self.maximumReportAge) {
        reports.removeAll { now.timeIntervalSince($0.firstQueuedAt) > maximumAge }
    }

    /// Whether a failed report should stay queued. `httpStatus` is `nil` for
    /// transport failures (offline, timeout), which are always retried, as
    /// are authentication, rate-limit and server errors. Other client errors
    /// would fail the same way forever.
    public static func shouldRetry(httpStatus: Int?) -> Bool {
        guard let httpStatus else { return true }
        switch httpStatus {
        case 401, 408, 429:
            return true
        case 400..<500:
            return false
        default:
            return true
        }
    }

    private func index(email: String, feature: String) -> Int? {
        reports.firstIndex { $0.email == email && $0.feature == feature }
    }
}
