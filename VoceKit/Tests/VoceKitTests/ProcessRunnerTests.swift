import Foundation
import Testing
@testable import VoceKit

@Test("ProcessRunner timeout returns promptly for a hung subprocess")
func processRunnerTimeoutReturnsPromptlyForHungSubprocess() async throws {
    let start = ContinuousClock.now

    do {
        _ = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeoutNanoseconds: 100_000_000
        )
        Issue.record("Expected ProcessRunner to time out.")
    } catch let error as ProcessRunner.TimeoutError {
        #expect(error.timeoutNanoseconds == 100_000_000)
    }

    let duration = start.duration(to: .now)
    #expect(duration < .seconds(2))
}

@Test("ProcessRunner resumes promptly and does not launch when the task is already cancelled")
func processRunnerPreCancelledTaskDoesNotHangOrLaunch() async throws {
    let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("voce-process-runner-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }

    let task = Task {
        // Wait until cancellation has been delivered before calling run, so the
        // cancellation handler fires before the continuation body executes.
        while !Task.isCancelled {
            await Task.yield()
        }
        return try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path]
        )
    }
    task.cancel()

    let start = ContinuousClock.now
    do {
        _ = try await task.value
        Issue.record("Expected CancellationError for a pre-cancelled task.")
    } catch is CancellationError {
        // Expected.
    }
    #expect(start.duration(to: .now) < .seconds(2))

    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test("ProcessRunner timeout wrapper resumes promptly when the task is already cancelled")
func processRunnerTimeoutWrapperPreCancelledTaskDoesNotHang() async throws {
    let task = Task {
        while !Task.isCancelled {
            await Task.yield()
        }
        return try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeoutNanoseconds: 10_000_000_000
        )
    }
    task.cancel()

    let start = ContinuousClock.now
    do {
        _ = try await task.value
        Issue.record("Expected CancellationError for a pre-cancelled task.")
    } catch is CancellationError {
        // Expected.
    }
    #expect(start.duration(to: .now) < .seconds(2))
}
