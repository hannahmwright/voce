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
    #expect(queue.reports[0] == .init(email: "a@example.com", feature: "app", seconds: 7, firstQueuedAt: now))
    #expect(queue.reports[1].seconds == 5)
    #expect(queue.reports[2].email == "b@example.com")
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

@Test("Acknowledging keeps seconds queued while a report was in flight")
func pendingUsageReportsAcknowledgePartially() {
    let now = Date()
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 10, now: now)

    // Sent 10, then 2 more arrived before the response.
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 2, now: now)
    queue.acknowledge(email: "a@example.com", feature: "app", seconds: 10)
    #expect(queue.reports.count == 1)
    #expect(queue.reports[0].seconds == 2)

    queue.acknowledge(email: "a@example.com", feature: "app", seconds: 2)
    #expect(queue.isEmpty)

    // Acknowledging something that is not queued is harmless.
    queue.acknowledge(email: "a@example.com", feature: "app", seconds: 2)
    #expect(queue.isEmpty)
}

@Test("Discard and expiry drop reports")
func pendingUsageReportsDiscardAndExpire() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "cloud", seconds: 3, now: now)
    queue.enqueue(email: "a@example.com", feature: "local", seconds: 3, now: now.addingTimeInterval(-PendingUsageReportQueue.maximumReportAge - 1))

    queue.discard(email: "a@example.com", feature: "cloud")
    queue.pruneExpired(now: now)

    #expect(queue.reports.map(\.feature) == ["app"])
}

@Test("Usage reports survive a persistence round trip")
func pendingUsageReportsRoundTrip() throws {
    var queue = PendingUsageReportQueue()
    queue.enqueue(email: "a@example.com", feature: "app", seconds: 3, now: Date(timeIntervalSince1970: 1_000))

    let data = try JSONEncoder().encode(queue)
    let decoded = try JSONDecoder().decode(PendingUsageReportQueue.self, from: data)
    #expect(decoded == queue)
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
