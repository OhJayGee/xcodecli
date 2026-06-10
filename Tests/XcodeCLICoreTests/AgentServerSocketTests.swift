import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import XcodeCLICore

// Note: a true foreign-UID test would require spawning a child process
// under a different UID via sudo, which is impractical for `swift test`.
// The peerUID() helper is exercised indirectly: if it returned the wrong
// UID or failed, the same-UID ping test would fail because the server
// would reject our own connection.

@Suite("AgentServer socket file invariants")
struct AgentServerSocketTests {

    private func makePaths(in tempDir: String) -> AgentPaths.Paths {
        AgentPaths.Paths(
            supportDir: tempDir,
            socketPath: (tempDir as NSString).appendingPathComponent("daemon.sock"),
            pidPath: (tempDir as NSString).appendingPathComponent("daemon.pid"),
            logPath: (tempDir as NSString).appendingPathComponent("agent.log"),
            plistPath: (tempDir as NSString).appendingPathComponent("ignored.plist")
        )
    }

    /// Wait until `path` exists or `deadline` elapses.
    private func waitForFile(_ path: String, deadline: Date) async {
        while !FileManager.default.fileExists(atPath: path) {
            if Date() > deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeFakeMCPBridge(in tempDir: String) throws -> String {
        let path = (tempDir as NSString).appendingPathComponent("fake-mcpbridge.sh")
        let script = #"""
        #!/bin/sh
        IFS= read -r initialize || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fake-mcpbridge","version":"1"}}}'
        IFS= read -r initialized || exit 1

        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
          /bin/sleep 0.1
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"TestTool"}]}}\n' "$id"
        done
        """#
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(chmod(path, 0o700) == 0)
        return path
    }

    @Test("socket file is an S_IFSOCK with mode 0o600 owned by current uid")
    func socketFileInvariants() async throws {
        let tempDir = try makeTempSupportDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let paths = makePaths(in: tempDir)
        let cfg = AgentServerConfig(paths: paths, label: "test.xcodecli.agent", idleTimeout: 60, baseEnv: [:], debug: false)
        let server = AgentServer(config: cfg)

        let runTask = Task { try await server.run() }

        await waitForFile(paths.socketPath, deadline: Date().addingTimeInterval(2.0))
        #expect(FileManager.default.fileExists(atPath: paths.socketPath))

        // Validate the on-disk file is a socket owned by us with mode 0o600.
        var st = stat()
        #expect(lstat(paths.socketPath, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        #expect(st.st_uid == getuid())
        #expect((st.st_mode & 0o777) == 0o600)

        // Send a `stop` request to terminate the server.
        try sendStopRequest(socketPath: paths.socketPath)
        _ = try? await runTask.value
    }

    @Test("same-UID ping succeeds end-to-end")
    func sameUIDPingSucceeds() async throws {
        let tempDir = try makeTempSupportDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let paths = makePaths(in: tempDir)
        let cfg = AgentServerConfig(paths: paths, label: "test.xcodecli.agent", idleTimeout: 60, baseEnv: [:], debug: false)
        let server = AgentServer(config: cfg)
        let runTask = Task { try await server.run() }

        await waitForFile(paths.socketPath, deadline: Date().addingTimeInterval(2.0))
        #expect(FileManager.default.fileExists(atPath: paths.socketPath))

        let response = try sendRequest(socketPath: paths.socketPath, json: "{\"method\":\"ping\"}")
        #expect(response.contains("\"status\""))   // ping returns the runtime status payload, not an error

        try sendStopRequest(socketPath: paths.socketPath)
        _ = try? await runTask.value
    }

    @Test("oversized request returns an error response and closes")
    func oversizedRequestRejected() async throws {
        let tempDir = try makeTempSupportDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let paths = makePaths(in: tempDir)
        let cfg = AgentServerConfig(paths: paths, label: "test.xcodecli.agent", idleTimeout: 60, baseEnv: [:], debug: false)
        let server = AgentServer(config: cfg)
        let runTask = Task { try await server.run() }

        await waitForFile(paths.socketPath, deadline: Date().addingTimeInterval(2.0))
        #expect(FileManager.default.fileExists(atPath: paths.socketPath))

        // 2 MiB of 'A' with no newline — exceeds the 1 MiB cap.
        let bigBlob = String(repeating: "A", count: 2 * 1024 * 1024)
        let response = try sendRawAndReadResponse(socketPath: paths.socketPath, raw: bigBlob)
        #expect(response.contains("exceeds") || response.contains("error"))

        try sendStopRequest(socketPath: paths.socketPath)
        _ = try? await runTask.value
    }

    // Regression guard for TODO #7: the fake bridge delays each response so
    // two simultaneous requests contend for the same MCPClient connection.
    // Actor isolation must keep request/response pairs coherent.
    @Test("concurrent same-session tools/list requests stay coherent")
    func concurrentSameSessionRequestsStayCoherent() async throws {
        let tempDir = try makeTempSupportDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let paths = makePaths(in: tempDir)
        let fakeBridge = try makeFakeMCPBridge(in: tempDir)
        let cfg = AgentServerConfig(
            paths: paths,
            label: "test.xcodecli.agent",
            idleTimeout: 60,
            baseEnv: [:],
            debug: false,
            mcpCommand: fakeBridge,
            mcpArguments: []
        )
        let server = AgentServer(config: cfg)
        let runTask = Task { try await server.run() }

        await waitForFile(paths.socketPath, deadline: Date().addingTimeInterval(2.0))
        #expect(FileManager.default.fileExists(atPath: paths.socketPath))

        let req = #"{"method":"tools/list","xcodePID":"42","sessionID":"test-session"}"#
        let sock = paths.socketPath

        let t1 = Task<String, Error>.detached {
            try sendRequest(socketPath: sock, json: req)
        }
        let t2 = Task<String, Error>.detached {
            try sendRequest(socketPath: sock, json: req)
        }
        let responses = try await [t1.value, t2.value]
        for response in responses {
            let decoded = try JSONDecoder().decode(AgentResponse.self, from: Data(response.utf8))
            #expect(decoded.error == nil)
            #expect(decoded.tools?.count == 1)
        }

        let ping = try sendRequest(socketPath: paths.socketPath, json: #"{"method":"ping"}"#)
        #expect(ping.contains("status"))

        try sendStopRequest(socketPath: paths.socketPath)
        _ = try? await runTask.value
        try? await Task.sleep(for: .milliseconds(200))
    }
}
