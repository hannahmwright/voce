import Foundation
import Testing
@testable import VoceKit

@Test("Usage reports coalesce per email and feature")
func pendingUsageReportsCoalesce() {
    let now = Date(timeIntervalSince1970: 1_000)
    var queue = PendingUsageReportQueue()

    queue.enqueue(email: "a@example.com", feature: "app", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 4, now: now.addingTimeInterval(60))
    queue.enqueue(email: "a@example.com", feature: "cloud", seconds: 5, now: now)
    queue.enqueue(email: "b@example.com", feature: "app", seconds: 6, now: now)

    #expect(queue.reports.count == 3)
    #expect(queue.reports[0].email == "a@example.com")
    #expect(queue.reports[0].feature == "app")
    #expect(queue.reports[0].seconds == 7)
    #expect(queue.reports[0].firstQueuedAt == now)
    #expect(queue.reports[1].seconds == 5)
    #expect(queue.reports[2].email == "b@example.com")
    #expect(Set(queue.reports.map(\.id)).count == 3)
}

@Test("Coalesced usage reports never exceed the backend's per-report cap")
func pendingUsageReportsSplitAtCap() {
    let cap = PendingUsageReportQueue.maximumReportSeconds
    let now = Date()
    var queue = PendingUsageReportQueue()

    // A long offline stretch: the open report fills up, then new ones start.
    queue.enqueue(email: "a@example.com", feature: "app", seconds: cap - 100, now: now)
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 300, now: now)
    #expect(queue.reports.map(\.seconds) == [cap, 200])

    // A single amount larger than the cap is split across reports.
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 2 * cap + 50, now: now)
    #expect(queue.reports.map(\.seconds) == [cap, cap, cap, 250])
    #expect(queue.reports.reduce(0) { $0 + $1.seconds } == 3 * cap + 250)
    #expect(Set(queue.reports.map(\.id)).count == 4)
    #expect(queue.reports.allSatisfy { $0.seconds <= cap })

    // Other features are unaffected.
    queue.enqueue(email: "a@example.com", feature: "cloud", seconds: 5, now: now)
    #expect(queue.reports.last?.seconds == 5)
}

@Test("Usage reports ignore empty input")
func pendingUsageReportsIgnoreEmptyInput() {
    var queue = PendingUsageReportQueue()
    let now = Date()

    queue.enqueue(email: "", feature: "app", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 0, now: now)

    #expect(queue.isEmpty)
}

@Test("A report is frozen once its send starts, so a resend is identical")
func pendingUsageReportsFreezeOnSend() throws {
    let now = Date()
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 10, now: now)
    let sent = try #require(queue.reports.first)

    queue.markSendStarted(reportID: sent.id)
    // Seconds arriving while the request is in flight start a new report.
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 2, now: now)

    #expect(queue.reports.count == 2)
    #expect(queue.reports[0].id == sent.id)
    #expect(queue.reports[0].seconds == 10)
    #expect(queue.reports[0].sendStarted)
    #expect(queue.reports[1].seconds == 2)
    #expect(!queue.reports[1].sendStarted)

    // A failed send keeps the frozen report as is for an identical resend.
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 1, now: now)
    #expect(queue.reports[0].seconds == 10)
    #expect(queue.reports[1].seconds == 3)

    queue.acknowledge(reportID: sent.id, seconds: 10, now: now)
    #expect(queue.reports.count == 1)
    #expect(queue.reports[0].seconds == 3)

    // Acknowledging something that is not queued is harmless.
    queue.acknowledge(reportID: sent.id, seconds: 10, now: now)
    #expect(queue.reports.count == 1)
}

@Test("A partial acknowledgement re-queues the rest as a fresh report")
func pendingUsageReportsPartialAcknowledgement() throws {
    let queuedAt = Date(timeIntervalSince1970: 1_000)
    let acknowledgedAt = queuedAt.addingTimeInterval(600)
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 10, now: queuedAt)
    let sent = try #require(queue.reports.first)
    queue.markSendStarted(reportID: sent.id)

    queue.acknowledge(reportID: sent.id, seconds: 4, now: acknowledgedAt)

    let rest = try #require(queue.reports.first)
    #expect(queue.reports.count == 1)
    #expect(rest.seconds == 6)
    #expect(rest.id != sent.id)
    #expect(rest.firstQueuedAt == acknowledgedAt)
    #expect(!rest.sendStarted)
}

@Test("Discard and expiry drop reports")
func pendingUsageReportsDiscardAndExpire() throws {
    let now = Date(timeIntervalSince1970: 10_000_000)
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "cloud", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "local", seconds: 3, now: now.addingTimeInterval(-PendingUsageReportQueue.maximumReportAge - 1))

    let cloud = try #require(queue.reports.first { $0.feature == "cloud" })
    queue.discard(reportID: cloud.id)
    queue.pruneExpired(now: now)

    #expect(queue.reports.map(\.feature) == ["app"])
}

@Test("Usage reports survive a persistence round trip")
func pendingUsageReportsRoundTrip() throws {
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 3, now: Date(timeIntervalSince1970: 1_000))
    queue.markSendStarted(reportID: try #require(queue.reports.first).id)

    let data = try JSONEncoder().encode(queue)
    let decoded = try JSONDecoder().decode(PendingUsageReportQueue.self, from: data)
    #expect(decoded == queue)
}

@Test("Reports persisted before report IDs existed still decode")
func pendingUsageReportsDecodeLegacyReports() throws {
    let legacy = #"{"reports":[{"email":"a@example.com","feature":"app","seconds":3,"firstQueuedAt":0}]}"#
    let decoded = try JSONDecoder().decode(PendingUsageReportQueue.self, from: Data(legacy.utf8))
    #expect(decoded.reports.count == 1)
    #expect(decoded.reports[0].seconds == 3)
    #expect(!decoded.reports[0].sendStarted)
}

@Test("Only transient usage report failures are retried")
func pendingUsageReportsRetryPolicy() {
    #expect(PendingUsageReportQueue.shouldRetry(httpStatus: nil))
    #expect(PendingUsageReportQueue.shouldRetry(httpStatus: 401))
    #expect(PendingUsageReportQueue.shouldRetry(httpStatus: 408))
    #expect(PendingUsageReportQueue.shouldRetry(httpStatus: 429))
    #expect(PendingUsageReportQueue.shouldRetry(httpStatus: 500))
    #expect(PendingUsageReportQueue.shouldRetry(httpStatus: 503))
    #expect(!PendingUsageReportQueue.shouldRetry(httpStatus: 400))
    #expect(!PendingUsageReportQueue.shouldRetry(httpStatus: 404))
    #expect(!PendingUsageReportQueue.shouldRetry(httpStatus: 422))
}

@Test("Failed reports skip only their own email or feature, and stale accounts are dropped")
func pendingUsageReportsFailureDisposition() {
    typealias Queue = PendingUsageReportQueue
    #expect(Queue.failureDisposition(httpStatus: nil, isCurrentSubscriber: true) == .retryLaterSkippingFeature)
    #expect(Queue.failureDisposition(httpStatus: nil, isCurrentSubscriber: false) == .retryLaterSkippingFeature)
    #expect(Queue.failureDisposition(httpStatus: 503, isCurrentSubscriber: true) == .retryLaterSkippingFeature)
    #expect(Queue.failureDisposition(httpStatus: 401, isCurrentSubscriber: true) == .retryLaterSkippingEmail)
    #expect(Queue.failureDisposition(httpStatus: 401, isCurrentSubscriber: false) == .discard)
    #expect(Queue.failureDisposition(httpStatus: 403, isCurrentSubscriber: false) == .discard)
    #expect(Queue.failureDisposition(httpStatus: 403, isCurrentSubscriber: true) == .discard)
    #expect(Queue.failureDisposition(httpStatus: 400, isCurrentSubscriber: true) == .discard)
}
