import Foundation

/// Usage seconds that still have to be reported to the Voce backend.
///
/// Reports are coalesced per account email and feature so a run of offline
/// dictations becomes one request once the network is back. Each report has
/// a stable ID that is sent with it so the backend can ignore a resend of a
/// report it already recorded; once a send has started, a report is never
/// grown again (new seconds start a new report), so a resend always carries
/// exactly what the first attempt did. The queue is a plain value so callers
/// can persist it (it is `Codable`) and test the policy without a network.
public struct PendingUsageReportQueue: Sendable, Codable, Equatable {
    public struct Report: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        public var email: String
        public var feature: String
        public var seconds: Int
        public var firstQueuedAt: Date
        /// Set once a send began. The backend may have recorded it even if
        /// the response was lost, so it must only ever be resent unchanged.
        public var sendStarted: Bool

        public init(
            id: UUID = UUID(),
            email: String,
            feature: String,
            seconds: Int,
            firstQueuedAt: Date,
            sendStarted: Bool = false
        ) {
            self.id = id
            self.email = email
            self.feature = feature
            self.seconds = seconds
            self.firstQueuedAt = firstQueuedAt
            self.sendStarted = sendStarted
        }

        private enum CodingKeys: String, CodingKey {
            case id, email, feature, seconds, firstQueuedAt, sendStarted
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            email = try container.decode(String.self, forKey: .email)
            feature = try container.decode(String.self, forKey: .feature)
            seconds = try container.decode(Int.self, forKey: .seconds)
            firstQueuedAt = try container.decode(Date.self, forKey: .firstQueuedAt)
            sendStarted = try container.decodeIfPresent(Bool.self, forKey: .sendStarted) ?? false
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

    /// Adds `seconds` for `email`/`feature`, merging with a queued report
    /// whose send has not started yet.
    public mutating func enqueue(email: String, feature: String, seconds: Int, now: Date) {
        guard !email.isEmpty, !feature.isEmpty, seconds > 0 else { return }

        if let index = reports.firstIndex(where: {
            $0.email == email && $0.feature == feature && !$0.sendStarted
        }) {
            reports[index].seconds += seconds
        } else {
            reports.append(Report(email: email, feature: feature, seconds: seconds, firstQueuedAt: now))
        }
    }

    /// Freezes a report before it is sent; later seconds start a new report.
    public mutating func markSendStarted(reportID: UUID) {
        guard let index = index(of: reportID) else { return }
        reports[index].sendStarted = true
    }

    /// Removes `seconds` that the backend accepted. Anything left over is
    /// re-queued as a fresh report (new ID, new age) so it is not mistaken
    /// for the part the backend already recorded.
    public mutating func acknowledge(reportID: UUID, seconds: Int, now: Date) {
        guard let index = index(of: reportID) else { return }
        let remaining = reports[index].seconds - seconds
        guard remaining > 0 else {
            reports.remove(at: index)
            return
        }
        reports[index].id = UUID()
        reports[index].seconds = remaining
        reports[index].firstQueuedAt = now
        reports[index].sendStarted = false
    }

    /// Drops a report the backend will never accept.
    public mutating func discard(reportID: UUID) {
        guard let index = index(of: reportID) else { return }
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

    public enum FailureDisposition: Sendable, Equatable {
        /// The backend will never accept it; drop it.
        case discard
        /// The account's session is invalid; keep it, and skip the rest of
        /// that email's reports until the next delivery attempt.
        case retryLaterSkippingEmail
        /// Keep it, and skip that email/feature until the next attempt.
        case retryLaterSkippingFeature
    }

    /// What to do with a report whose delivery failed. Auth failures for an
    /// email that is no longer the signed-in subscriber can never be fixed
    /// by re-verifying, so those reports are dropped rather than retried
    /// until they expire.
    public static func failureDisposition(httpStatus: Int?, isCurrentSubscriber: Bool) -> FailureDisposition {
        if httpStatus == 401 || httpStatus == 403 {
            guard isCurrentSubscriber, httpStatus == 401 else { return .discard }
            return .retryLaterSkippingEmail
        }
        return shouldRetry(httpStatus: httpStatus) ? .retryLaterSkippingFeature : .discard
    }

    private func index(of reportID: UUID) -> Int? {
        reports.firstIndex { $0.id == reportID }
    }
}
