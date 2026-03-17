import Foundation

/// Stores live audio chunks until a background worker can feed them into the
/// transcription stream, while enforcing a hard upper bound on buffered audio.
public final class BufferedAudioBacklog: @unchecked Sendable {
    public struct Batch: Sendable, Equatable {
        public let samples: [Float]
        public let sampleRate: Double
        public let chunkCount: Int

        public init(samples: [Float], sampleRate: Double, chunkCount: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.chunkCount = chunkCount
        }
    }

    public enum EnqueueResult: Sendable, Equatable {
        case accepted(shouldScheduleDrain: Bool, bufferedDuration: TimeInterval)
        case rejected(bufferedDuration: TimeInterval, incomingDuration: TimeInterval)
    }

    public struct Snapshot: Sendable, Equatable {
        public let bufferedDuration: TimeInterval
        public let queuedChunkCount: Int
        public let isDrainScheduled: Bool

        public init(
            bufferedDuration: TimeInterval,
            queuedChunkCount: Int,
            isDrainScheduled: Bool
        ) {
            self.bufferedDuration = bufferedDuration
            self.queuedChunkCount = queuedChunkCount
            self.isDrainScheduled = isDrainScheduled
        }
    }

    private struct Chunk: Sendable {
        let samples: [Float]
        let sampleRate: Double

        var duration: TimeInterval {
            guard sampleRate > 0 else { return 0 }
            return Double(samples.count) / sampleRate
        }
    }

    private let lock = NSLock()
    private let maxBufferedDuration: TimeInterval
    private let targetBatchDuration: TimeInterval

    private var chunks: [Chunk] = []
    private var bufferedDuration: TimeInterval = 0
    private var isDrainScheduled = false

    public init(
        maxBufferedDuration: TimeInterval,
        targetBatchDuration: TimeInterval
    ) {
        self.maxBufferedDuration = maxBufferedDuration
        self.targetBatchDuration = targetBatchDuration
    }

    public func reset() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        bufferedDuration = 0
        isDrainScheduled = false
        lock.unlock()
    }

    public func enqueue(samples: [Float], sampleRate: Double) -> EnqueueResult {
        guard !samples.isEmpty, sampleRate > 0 else {
            return .accepted(shouldScheduleDrain: false, bufferedDuration: snapshot().bufferedDuration)
        }

        let chunk = Chunk(samples: samples, sampleRate: sampleRate)
        let incomingDuration = chunk.duration

        lock.lock()
        defer { lock.unlock() }

        if bufferedDuration + incomingDuration > maxBufferedDuration {
            return .rejected(
                bufferedDuration: bufferedDuration,
                incomingDuration: incomingDuration
            )
        }

        chunks.append(chunk)
        bufferedDuration += incomingDuration

        let shouldScheduleDrain = !isDrainScheduled
        if shouldScheduleDrain {
            isDrainScheduled = true
        }

        return .accepted(
            shouldScheduleDrain: shouldScheduleDrain,
            bufferedDuration: bufferedDuration
        )
    }

    public func dequeueBatch() -> Batch? {
        lock.lock()
        defer { lock.unlock() }

        guard !chunks.isEmpty else {
            isDrainScheduled = false
            return nil
        }

        var firstChunk = chunks.removeFirst()
        bufferedDuration -= firstChunk.duration

        var combinedSamples = firstChunk.samples
        let sampleRate = firstChunk.sampleRate
        var chunkCount = 1
        var combinedDuration = firstChunk.duration

        while let nextChunk = chunks.first,
              nextChunk.sampleRate == sampleRate,
              combinedDuration < targetBatchDuration
        {
            let nextDuration = nextChunk.duration
            if combinedDuration > 0,
               combinedDuration + nextDuration > targetBatchDuration {
                break
            }

            firstChunk = chunks.removeFirst()
            bufferedDuration -= firstChunk.duration
            combinedSamples.append(contentsOf: firstChunk.samples)
            combinedDuration += nextDuration
            chunkCount += 1
        }

        return Batch(
            samples: combinedSamples,
            sampleRate: sampleRate,
            chunkCount: chunkCount
        )
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            bufferedDuration: bufferedDuration,
            queuedChunkCount: chunks.count,
            isDrainScheduled: isDrainScheduled
        )
        lock.unlock()
        return snapshot
    }
}
