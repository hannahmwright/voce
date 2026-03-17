import Foundation
import Testing
@testable import VoceKit

@Test("BufferedAudioBacklog schedules only one drain worker while data is queued")
func bufferedAudioBacklogSchedulesDrainOnce() {
    let backlog = BufferedAudioBacklog(
        maxBufferedDuration: 1.0,
        targetBatchDuration: 0.25
    )

    let first = backlog.enqueue(samples: [0, 1, 2, 3], sampleRate: 8)
    let second = backlog.enqueue(samples: [4, 5, 6, 7], sampleRate: 8)

    #expect(
        first == .accepted(
            shouldScheduleDrain: true,
            bufferedDuration: 0.5
        )
    )
    #expect(
        second == .accepted(
            shouldScheduleDrain: false,
            bufferedDuration: 1.0
        )
    )
}

@Test("BufferedAudioBacklog coalesces queued chunks into a single drain batch")
func bufferedAudioBacklogCoalescesBatches() {
    let backlog = BufferedAudioBacklog(
        maxBufferedDuration: 2.0,
        targetBatchDuration: 0.5
    )

    _ = backlog.enqueue(samples: [1, 2], sampleRate: 8)
    _ = backlog.enqueue(samples: [3, 4], sampleRate: 8)

    let batch = backlog.dequeueBatch()

    #expect(batch == .init(samples: [1, 2, 3, 4], sampleRate: 8, chunkCount: 2))
    #expect(backlog.snapshot() == .init(bufferedDuration: 0, queuedChunkCount: 0, isDrainScheduled: true))
    #expect(backlog.dequeueBatch() == nil)
    #expect(backlog.snapshot() == .init(bufferedDuration: 0, queuedChunkCount: 0, isDrainScheduled: false))
}

@Test("BufferedAudioBacklog keeps sample rates on separate drain batches")
func bufferedAudioBacklogDoesNotMixSampleRates() {
    let backlog = BufferedAudioBacklog(
        maxBufferedDuration: 2.0,
        targetBatchDuration: 1.0
    )

    _ = backlog.enqueue(samples: [1, 2], sampleRate: 8)
    _ = backlog.enqueue(samples: [3, 4], sampleRate: 16)

    let firstBatch = backlog.dequeueBatch()
    let secondBatch = backlog.dequeueBatch()

    #expect(firstBatch == .init(samples: [1, 2], sampleRate: 8, chunkCount: 1))
    #expect(secondBatch == .init(samples: [3, 4], sampleRate: 16, chunkCount: 1))
}

@Test("BufferedAudioBacklog rejects chunks that exceed the configured audio budget")
func bufferedAudioBacklogRejectsOverflow() {
    let backlog = BufferedAudioBacklog(
        maxBufferedDuration: 0.5,
        targetBatchDuration: 0.25
    )

    _ = backlog.enqueue(samples: [0, 1], sampleRate: 8)
    let result = backlog.enqueue(samples: [2, 3, 4], sampleRate: 8)

    #expect(
        result == .rejected(
            bufferedDuration: 0.25,
            incomingDuration: 0.375
        )
    )
    #expect(
        backlog.snapshot() == .init(
            bufferedDuration: 0.25,
            queuedChunkCount: 1,
            isDrainScheduled: true
        )
    )
}
