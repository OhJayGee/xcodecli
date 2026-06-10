import Foundation
import Dispatch
import Testing
@testable import XcodeCLICore

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("captures output and exit status")
    func capturesOutputAndExitStatus() async throws {
        let result = try await SystemProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"],
            environment: nil,
            workingDirectory: nil,
            stdinData: nil
        )

        #expect(result.stdout == "stdout")
        #expect(result.stderr == "stderr")
        #expect(result.exitCode == 7)
    }

    @Test("launch failure returns without leaving pipe readers blocked")
    func launchFailureReturns() async {
        let startedAt = ContinuousClock.now

        do {
            _ = try await SystemProcessRunner().run(
                "/path/that/does/not/exist",
                arguments: [],
                environment: nil,
                workingDirectory: nil,
                stdinData: nil
            )
            Issue.record("expected process launch to fail")
        } catch {
            // Expected.
        }

        #expect(ContinuousClock.now - startedAt < .seconds(2))
    }

    @Test("cancellation terminates a running child process")
    func cancellationTerminatesChild() async throws {
        let runner = SystemProcessRunner()
        let startedAt = ContinuousClock.now
        let task = Task {
            try await runner.run(
                "/bin/sleep",
                arguments: ["10"],
                environment: nil,
                workingDirectory: nil,
                stdinData: nil
            )
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            task.cancel()
        }

        do {
            _ = try await task.value
            Issue.record("expected process execution to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        #expect(ContinuousClock.now - startedAt < .seconds(2))
    }
}
