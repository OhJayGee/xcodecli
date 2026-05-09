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
}
