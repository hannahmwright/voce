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
