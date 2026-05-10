import Testing
import Foundation
@testable import XcodeCLICore

/// Pins the contract change for `AgentClient.uninstall`: cleanup errors are
/// no longer aggregated. The first `removeItem` failure short-circuits with
/// the underlying error; advisory `stop`/`bootout` failures are dropped
/// (they're handled by the outer `uninstall` wrapper, not here).
@Suite("AgentClient uninstall cleanup")
struct AgentClientUninstallTests {

    /// Build a `Paths` rooted under `dir` and populate every file/dir the
    /// uninstall path tries to remove. Returns the paths object so the test
    /// can pass it back to `removeAgentFiles`.
    private func populate(in dir: String) throws -> AgentPaths.Paths {
        let fm = FileManager.default
        // Layout matches AgentPaths.resolvePaths: a "support" subdirectory
        // for runtime files and a sibling location for the LaunchAgent
        // plist. Using the real layout keeps the test honest about which
        // paths are reached and in which order.
        let supportDir = (dir as NSString).appendingPathComponent("support")
        let launchAgents = (dir as NSString).appendingPathComponent("LaunchAgents")
        try fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: launchAgents, withIntermediateDirectories: true)

        let paths = AgentPaths.Paths(
            supportDir: supportDir,
            socketPath: (supportDir as NSString).appendingPathComponent("daemon.sock"),
            pidPath: (supportDir as NSString).appendingPathComponent("daemon.pid"),
            logPath: (supportDir as NSString).appendingPathComponent("agent.log"),
            plistPath: (launchAgents as NSString).appendingPathComponent("agent.plist")
        )

        // Touch every file (sock is a regular file in this test — the
        // uninstall path doesn't care what kind of inode it is).
        for path in [paths.socketPath, paths.pidPath, paths.logPath, paths.plistPath] {
            try Data().write(to: URL(fileURLWithPath: path))
        }
        return paths
    }

    private func makeTempDir() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("xcodecli-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("removes every agent artifact when all are present")
    func removesAllArtifacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = try populate(in: dir)

        try removeAgentFiles(paths: paths, fileManager: FileManager.default)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: paths.plistPath))
        #expect(!fm.fileExists(atPath: paths.socketPath))
        #expect(!fm.fileExists(atPath: paths.pidPath))
        #expect(!fm.fileExists(atPath: paths.logPath))
        #expect(!fm.fileExists(atPath: paths.supportDir))
    }

    @Test("missing files are silently skipped")
    func missingFilesSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Create only the plist; everything else is absent. The previous
        // implementation already had `fileExists` guards, but pin the
        // behaviour so a future refactor doesn't regress to `removeItem`
        // throwing on missing files.
        let supportDir = (dir as NSString).appendingPathComponent("support")
        let launchAgents = (dir as NSString).appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(atPath: launchAgents, withIntermediateDirectories: true)

        let paths = AgentPaths.Paths(
            supportDir: supportDir, // does not exist
            socketPath: (supportDir as NSString).appendingPathComponent("daemon.sock"),
            pidPath: (supportDir as NSString).appendingPathComponent("daemon.pid"),
            logPath: (supportDir as NSString).appendingPathComponent("agent.log"),
            plistPath: (launchAgents as NSString).appendingPathComponent("agent.plist")
        )
        try Data().write(to: URL(fileURLWithPath: paths.plistPath))

        try removeAgentFiles(paths: paths, fileManager: FileManager.default)
        #expect(!FileManager.default.fileExists(atPath: paths.plistPath))
    }

    @Test("first removal failure short-circuits and rethrows")
    func firstFailureShortCircuits() throws {
        let dir = try makeTempDir()
        defer {
            // Restore permissions so the cleanup defer can wipe the tree.
            _ = chmod(dir, 0o755)
            let support = (dir as NSString).appendingPathComponent("support")
            _ = chmod(support, 0o755)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let paths = try populate(in: dir)

        // Lock down the support dir so `removeItem(daemon.sock)` (the
        // second target in the iteration order, after the plist) fails
        // with EACCES. We expect the throw to propagate from that single
        // failure — the previous implementation would have continued and
        // tried every other path, then aggregated the messages.
        let support = paths.supportDir
        #expect(chmod(support, 0o500) == 0) // r-x: cannot remove children

        do {
            try removeAgentFiles(paths: paths, fileManager: FileManager.default)
            Issue.record("expected removeAgentFiles to throw on permission denial")
        } catch {
            // We deliberately avoid asserting on the exact message —
            // FileManager error wording differs across OS versions. What
            // matters is (a) we threw at all, (b) we threw with a single
            // underlying error rather than an aggregated string.
            let desc = "\(error)"
            #expect(!desc.contains(";")) // aggregator used "; " as separator
        }

        // The plist (first in the iteration) should be gone; the socket
        // (second, where we failed) should still be there. Pins the
        // short-circuit behaviour: subsequent files are NOT touched.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: paths.plistPath))
        #expect(fm.fileExists(atPath: paths.socketPath))
        #expect(fm.fileExists(atPath: paths.pidPath))
        #expect(fm.fileExists(atPath: paths.logPath))
    }
}
