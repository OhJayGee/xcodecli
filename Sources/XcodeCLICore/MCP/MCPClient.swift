import Foundation

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
    public static func connect(config: Config) async throws -> MCPClient {
        let client = try MCPClient(config: config)
        try await client.initialize()
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

        // Capture stderr in background
        let buffer = stderrBuffer
        let isDebug = debug
        let errHandle = errOut
        Task.detached {
            while true {
                let data = stderrPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    buffer.append(text)
                    if isDebug {
                        errHandle.write(Data("[debug] child stderr: \(text)".utf8))
                    }
                }
            }
        }
    }

    /// Perform the MCP initialize handshake.
    private func initialize() throws {
        let initResult = try request(method: "initialize", params: .object([
            "protocolVersion": .string(MCPConstants.requestProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("xcodecli"),
                "version": .string(Version.current),
            ]),
        ]))

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
    public func request(method: String, params: JSONValue) throws -> JSONValue {
        let id = nextID
        nextID += 1

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
            let response = try readEnvelope()

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
    public func listTools() throws -> [JSONValue] {
        var allTools: [JSONValue] = []
        var cursor: String = ""

        while true {
            var params: [String: JSONValue] = [:]
            if !cursor.isEmpty {
                params["cursor"] = .string(cursor)
            }
            let result = try request(method: "tools/list", params: .object(params))
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
    public func callTool(name: String, arguments: [String: JSONValue]) throws -> MCPCallResult {
        let result = try request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]))

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

    /// Close the client gracefully.
    public func close() {
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }

    /// Abort the client forcefully.
    public func abort() {
        stdinPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - I/O

    private func writeJSON(_ envelope: RPCEnvelope) throws {
        let line = try JSONLineCodec.encode(envelope)
        stdinPipe.fileHandleForWriting.write(Data(line.utf8))
    }

    private func readEnvelope() throws -> RPCEnvelope {
        while true {
            let lineData = try readLineBuffered()

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
    private func readLineBuffered() throws -> Data {
        try readBufferedLine(
            from: stdoutPipe.fileHandleForReading,
            buffer: &readBuffer,
            chunkSize: MCPClient.readChunkSize
        )
    }
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
    chunkSize: Int
) throws -> Data {
    let newline = UInt8(ascii: "\n")

    while true {
        if let nlIndex = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex..<nlIndex]
            let after = buffer.index(after: nlIndex)
            buffer = buffer.subdata(in: after..<buffer.endIndex)
            return Data(line)
        }

        // `readData(ofLength:)` is the blocking variant: returns up to
        // `length` bytes and returns an empty Data on EOF.
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty {
            if !buffer.isEmpty {
                throw XcodeCLIError.mcpInitializationFailed(
                    reason: "child process closed stdout with \(buffer.count) buffered bytes and no newline"
                )
            }
            throw XcodeCLIError.mcpInitializationFailed(reason: "child process closed stdout")
        }
        buffer.append(chunk)
    }
}
