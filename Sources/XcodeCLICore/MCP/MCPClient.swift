import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// MCP client that communicates with xcrun mcpbridge via JSON-RPC over stdin/stdout.
public actor MCPClient {
    /// Read chunk size for the buffered stdout reader. 4 KiB matches a typical
    /// pipe buffer page; larger payloads are accumulated across multiple reads.
    private static let readChunkSize = 4096

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrBuffer: StderrBuffer
    private var nextID: Int64 = 1
    private let debug: Bool
    private let errOut: FileHandle
    /// Buffer of bytes read from the child's stdout that have not yet been
    /// returned to a caller as a complete line. Access is serialized by the
    /// surrounding actor; `readEnvelope` is the only consumer.
    private var readBuffer: Data = Data()
    /// Background task draining the child process's stderr. The reference is
    /// kept on the actor so `close()`/`abort()` can `await` it after the
    /// child exits, ensuring late-arriving stderr is folded into
    /// `stderrBuffer` and (when debug is on) forwarded to `errOut` instead
    /// of being silently dropped when the actor deallocates.
    private var stderrTask: Task<Void, Never>?

    final class StderrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var _buffer = ""

        func append(_ text: String) {
            lock.withLock { _buffer += text }
        }

        var value: String {
            lock.withLock { _buffer }
        }
    }

    public struct Config: Sendable {
        public let command: String
        public let arguments: [String]
        public let environment: [String: String]
        public let debug: Bool
        public let errOut: FileHandle

        public init(
            command: String = "/usr/bin/xcrun",
            arguments: [String] = ["mcpbridge"],
            environment: [String: String] = [:],
            debug: Bool = false,
            errOut: FileHandle = .standardError
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.debug = debug
            self.errOut = errOut
        }
    }

    /// Start a new MCP client with initialized session.
    public static func connect(config: Config, timeoutMS: Int64? = nil) async throws -> MCPClient {
        let client = try MCPClient(config: config)
        do {
            try await client.initialize(timeoutMS: timeoutMS)
        } catch {
            await client.abort()
            throw error
        }
        return client
    }

    private init(config: Config) throws {
        self.debug = config.debug
        self.errOut = config.errOut
        self.stderrBuffer = StderrBuffer()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.command)
        process.arguments = config.arguments
        process.environment = config.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        if debug {
            errOut.write(Data("[debug] starting \(config.command) \(config.arguments.joined(separator: " "))\n".utf8))
        }

        try process.run()

        // Drain the child's stderr asynchronously. The previous
        // implementation polled `availableData` in a tight `while true`
        // loop, which can spin on partial reads and was never awaited at
        // shutdown — meaning bytes the child wrote between `close()` and
        // EOF were silently dropped. `drainStderrToBuffer` uses
        // `FileHandle.bytes.lines`, which suspends until data is ready;
        // storing the resulting task on the actor lets shutdown wait for
        // it to finish.
        self.stderrTask = drainStderrToBuffer(
            handle: stderrPipe.fileHandleForReading,
            buffer: stderrBuffer,
            debug: debug,
            errOut: errOut
        )
    }

    /// Perform the MCP initialize handshake.
    private func initialize(timeoutMS: Int64?) throws {
        let initResult = try request(method: "initialize", params: .object([
            "protocolVersion": .string(MCPConstants.requestProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("xcodecli"),
                "version": .string(Version.current),
            ]),
        ]), timeoutMS: timeoutMS)

        // Verify protocol version
        if case .object(let obj) = initResult,
           case .string(let version) = obj["protocolVersion"] {
            guard MCPConstants.isSupportedVersion(version) else {
                throw XcodeCLIError.mcpUnsupportedProtocol(version: version)
            }
        }

        // Send initialized notification
        try notify(method: "notifications/initialized", params: .object([:]))
    }

    /// Send a JSON-RPC request and wait for the response.
    public func request(method: String, params: JSONValue, timeoutMS: Int64? = nil) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let started = ContinuousClock.now
        let budgetMS = normalizedMCPTimeoutMS(timeoutMS)

        if debug {
            errOut.write(Data("[debug] mcp request -> \(method) (id=\(id))\n".utf8))
        }

        let envelope = RPCEnvelope(
            id: .int(id), method: method, params: params
        )
        try writeJSON(envelope)

        // Read responses until we get ours
        while true {
            try Task.checkCancellation()
            let response = try readEnvelope(
                timeoutMS: budgetMS,
                started: started,
                action: "MCP \(method)"
            )

            if debug {
                errOut.write(Data("[debug] mcp recv\n".utf8))
            }

            // Skip server notifications
            if let method = response.method, !method.isEmpty {
                if response.hasID {
                    // Server request - respond with error
                    try writeJSON(rpcErrorResponse(id: response.id, code: -32601, message: "Method not found"))
                }
                continue
            }

            // Verify response ID matches
            guard let responseID = response.id, case .int(let rid) = responseID, rid == id else {
                continue
            }

            if let error = response.error {
                throw XcodeCLIError.mcpRPCError(code: error.code, message: error.message)
            }

            return response.result ?? .null
        }
    }

    /// Send a JSON-RPC notification (no id, no response expected).
    public func notify(method: String, params: JSONValue) throws {
        if debug {
            errOut.write(Data("[debug] mcp notification -> \(method)\n".utf8))
        }
        let envelope = RPCEnvelope(method: method, params: params)
        try writeJSON(envelope)
    }

    /// List available MCP tools with cursor-based pagination.
    public func listTools(timeoutMS: Int64? = nil) throws -> [JSONValue] {
        var allTools: [JSONValue] = []
        var cursor: String = ""

        while true {
            var params: [String: JSONValue] = [:]
            if !cursor.isEmpty {
                params["cursor"] = .string(cursor)
            }
            let result = try request(method: "tools/list", params: .object(params), timeoutMS: timeoutMS)
            if case .object(let obj) = result {
                if case .array(let tools) = obj["tools"] {
                    allTools.append(contentsOf: tools)
                }
                if case .string(let nextCursor) = obj["nextCursor"], !nextCursor.isEmpty {
                    cursor = nextCursor
                    continue
                }
            }
            break
        }
        return allTools
    }

    /// Call an MCP tool.
    public func callTool(
        name: String,
        arguments: [String: JSONValue],
        timeoutMS: Int64? = nil
    ) throws -> MCPCallResult {
        let result = try request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]), timeoutMS: timeoutMS)

        var resultDict: [String: JSONValue] = [:]
        var isError = false

        if case .object(let obj) = result {
            resultDict = obj
            if case .bool(let e) = obj["isError"] {
                isError = e
            }
        }

        return MCPCallResult(result: resultDict, isError: isError)
    }

    /// Close the client gracefully. Waits for the child to exit and for the
    /// background stderr drain to finish so any late-arriving diagnostics
    /// reach `stderrBuffer`/`errOut` rather than getting dropped.
    public func close() async {
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        await stderrTask?.value
        stderrTask = nil
    }

    /// Abort the client forcefully. Like `close()`, awaits the stderr drain
    /// so we don't lose any messages the child wrote between termination
    /// and EOF on the stderr pipe.
    public func abort() async {
        stdinPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
        await stderrTask?.value
        stderrTask = nil
    }

    // MARK: - I/O

    private func writeJSON(_ envelope: RPCEnvelope) throws {
        let line = try JSONLineCodec.encode(envelope)
        stdinPipe.fileHandleForWriting.write(Data(line.utf8))
    }

    private func readEnvelope(
        timeoutMS: Int64?,
        started: ContinuousClock.Instant,
        action: String
    ) throws -> RPCEnvelope {
        while true {
            let lineData = try readLineBuffered(timeoutMS: timeoutMS, started: started, action: action)

            guard let line = String(data: lineData, encoding: .utf8) else {
                throw XcodeCLIError.mcpRPCError(code: -32700, message: "invalid UTF-8 in response")
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue // skip empty lines without recursion
            }

            return try JSONLineCodec.decode(trimmed)
        }
    }

    /// Read one newline-terminated line from the child's stdout, buffering any
    /// bytes that arrive past the newline for the next call. The returned
    /// `Data` does not include the trailing `\n`.
    private func readLineBuffered(
        timeoutMS: Int64?,
        started: ContinuousClock.Instant,
        action: String
    ) throws -> Data {
        try readBufferedLine(
            from: stdoutPipe.fileHandleForReading,
            buffer: &readBuffer,
            chunkSize: MCPClient.readChunkSize,
            timeoutMS: timeoutMS,
            started: started,
            action: action
        )
    }
}

private func normalizedMCPTimeoutMS(_ timeoutMS: Int64?) -> Int64? {
    guard let timeoutMS, timeoutMS > 0 else { return nil }
    return timeoutMS
}

private func elapsedMS(since started: ContinuousClock.Instant) -> Int64 {
    let elapsed = ContinuousClock.now - started
    return Int64(elapsed.components.seconds) * 1000 +
        Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
}

private func remainingMCPTimeoutMS(
    budgetMS: Int64?,
    started: ContinuousClock.Instant,
    action: String
) throws -> Int32 {
    guard let budgetMS else { return -1 }
    let remaining = budgetMS - elapsedMS(since: started)
    guard remaining > 0 else {
        throw XcodeCLIError.agentTimeout(action: action, budgetMS: budgetMS)
    }
    return remaining > Int64(Int32.max) ? Int32.max : Int32(remaining)
}

/// Read one newline-terminated line from `handle`, draining `buffer` first
/// and refilling from the handle in `chunkSize` chunks when no newline is
/// present. The returned `Data` does not include the trailing `\n`. Bytes
/// that arrive past the newline are left in `buffer` for the next call.
///
/// Throws `XcodeCLIError.mcpInitializationFailed` on EOF — the message
/// distinguishes a clean EOF from one that strands partial bytes in the
/// buffer so diagnostics aren't ambiguous.
///
/// This is package-internal so that `MCPClientBufferedReadTests` can pin the
/// behaviour without spawning a real `xcrun mcpbridge` child.
func readBufferedLine(
    from handle: FileHandle,
    buffer: inout Data,
    chunkSize: Int,
    timeoutMS: Int64? = nil,
    started: ContinuousClock.Instant = ContinuousClock.now,
    action: String = "MCP response"
) throws -> Data {
    let newline = UInt8(ascii: "\n")

    while true {
        if let nlIndex = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex..<nlIndex]
            let after = buffer.index(after: nlIndex)
            buffer = buffer.subdata(in: after..<buffer.endIndex)
            return Data(line)
        }

        // FileHandle.readData(ofLength:) can wait for the full requested
        // length while the writer remains open. MCP responses are usually
        // much smaller than the 4 KiB chunk size, so use POSIX read(2), which
        // returns as soon as any pipe bytes are available.
        let timeout = try remainingMCPTimeoutMS(budgetMS: timeoutMS, started: started, action: action)
        var pollFD = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let pollResult = poll(&pollFD, 1, timeout)
            if pollResult < 0 && errno == EINTR {
                continue
            }
            if pollResult == 0 {
                throw XcodeCLIError.agentTimeout(action: action, budgetMS: timeoutMS ?? 0)
            }
            if pollResult < 0 {
                throw XcodeCLIError.mcpInitializationFailed(
                    reason: "poll child stdout: \(String(cString: strerror(errno)))"
                )
            }
            break
        }

        var chunk = [UInt8](repeating: 0, count: chunkSize)
        let count: Int
        while true {
            let result = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
            if result < 0 && errno == EINTR {
                continue
            }
            count = result
            break
        }

        if count < 0 {
            throw XcodeCLIError.mcpInitializationFailed(
                reason: "read child stdout: \(String(cString: strerror(errno)))"
            )
        }
        if count == 0 {
            if !buffer.isEmpty {
                throw XcodeCLIError.mcpInitializationFailed(
                    reason: "child process closed stdout with \(buffer.count) buffered bytes and no newline"
                )
            }
            throw XcodeCLIError.mcpInitializationFailed(reason: "child process closed stdout")
        }
        buffer.append(contentsOf: chunk[0..<count])
    }
}

/// Spawn a detached task that drains `handle` line by line, appending each
/// line (including a trailing newline) to `buffer` and, when `debug` is
/// enabled, forwarding it to `errOut` prefixed with `[debug] child stderr:`.
///
/// Uses `FileHandle.bytes.lines` so the underlying read suspends instead of
/// busy-spinning — the original `availableData` loop returned immediately
/// with an empty `Data` on partial reads and burned CPU in the meantime.
///
/// Returns the task so callers can `await task.value` during shutdown,
/// guaranteeing that bytes the child wrote between termination and EOF on
/// the stderr pipe still land in `buffer` instead of being dropped on the
/// floor when the underlying actor deallocates.
///
/// Internal so `MCPClientStderrCaptureTests` can drive it directly with a
/// `Pipe` rather than a real subprocess.
func drainStderrToBuffer(
    handle: FileHandle,
    buffer: MCPClient.StderrBuffer,
    debug: Bool,
    errOut: FileHandle
) -> Task<Void, Never> {
    Task.detached {
        do {
            for try await line in handle.bytes.lines {
                let withNewline = line + "\n"
                buffer.append(withNewline)
                if debug {
                    errOut.write(Data("[debug] child stderr: \(withNewline)".utf8))
                }
            }
        } catch {
            // The reader throws on read failure (e.g. fd already closed
            // due to abort). Treat as EOF — there's nothing actionable
            // we can do beyond stopping the drain.
        }
    }
}
