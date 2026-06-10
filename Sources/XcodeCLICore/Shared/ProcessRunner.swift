import Foundation

private final class CancellableProcess: @unchecked Sendable {
    let process = Process()

    private let lock = NSLock()
    private var cancelled = false

    func runAndWait() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }

            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
                lock.unlock()
            } catch {
                process.terminationHandler = nil
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        cancelled = true
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Result of running an external process.
public struct ProcessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Abstraction over external process execution for testability.
public protocol ProcessRunning: Sendable {
    func run(
        _ command: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?,
        stdinData: Data?
    ) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async throws -> ProcessResult {
        try await run(command, arguments: arguments, environment: environment,
                      workingDirectory: workingDirectory, stdinData: nil)
    }
}

/// Default implementation using Foundation.Process.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ command: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?,
        stdinData: Data?
    ) async throws -> ProcessResult {
        let cancellableProcess = CancellableProcess()
        let process = cancellableProcess.process
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let environment {
            process.environment = environment
        }
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(stdinData)
            stdinPipe.fileHandleForWriting.closeFile()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        return try await withTaskCancellationHandler {
            // Drain pipes concurrently so a child producing more than the pipe
            // buffer cannot deadlock while the parent waits for termination.
            let stdoutReader = Task.detached {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrReader = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            let exitCode: Int32
            do {
                exitCode = try await cancellableProcess.runAndWait()
                try Task.checkCancellation()
            } catch {
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                throw error
            }

            let stdoutData = await stdoutReader.value
            let stderrData = await stderrReader.value

            return ProcessResult(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: exitCode
            )
        } onCancel: {
            cancellableProcess.cancel()
        }
    }
}
