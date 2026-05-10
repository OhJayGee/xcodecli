import Testing
import Foundation
@testable import XcodeCLICore

/// Tests for `readBufferedLine`, the buffered line reader that backs
/// `MCPClient.readEnvelope`. Pinning the behaviour here avoids the overhead
/// of spawning `xcrun mcpbridge` and lets us exercise edge cases (empty
/// lines, multi-line chunks, EOF mid-line) directly against a `Pipe`.
@Suite("MCPClient buffered read")
struct MCPClientBufferedReadTests {

    /// Write `bytes` to `pipe` and close the writing end so that subsequent
    /// reads from the reading end see EOF after consuming all bytes.
    private func writeAndClose(_ pipe: Pipe, _ bytes: Data) {
        pipe.fileHandleForWriting.write(bytes)
        pipe.fileHandleForWriting.closeFile()
    }

    @Test("returns a single line when buffer empty")
    func singleLine() throws {
        let pipe = Pipe()
        writeAndClose(pipe, Data("hello\n".utf8))

        var buffer = Data()
        let line = try readBufferedLine(
            from: pipe.fileHandleForReading,
            buffer: &buffer,
            chunkSize: 4096
        )
        #expect(String(data: line, encoding: .utf8) == "hello")
        #expect(buffer.isEmpty)
    }

    @Test("returns lines back-to-back from a single chunk")
    func multiLineSingleChunk() throws {
        // Both lines arrive in the same read; second call must come from the
        // buffered remainder without a syscall against an EOF pipe.
        let pipe = Pipe()
        writeAndClose(pipe, Data("first\nsecond\n".utf8))

        var buffer = Data()
        let l1 = try readBufferedLine(from: pipe.fileHandleForReading, buffer: &buffer, chunkSize: 4096)
        #expect(String(data: l1, encoding: .utf8) == "first")
        // Buffer must still hold "second\n" so the second call doesn't
        // observe EOF — this is the bug-fix pin.
        #expect(buffer.count == "second\n".utf8.count)

        let l2 = try readBufferedLine(from: pipe.fileHandleForReading, buffer: &buffer, chunkSize: 4096)
        #expect(String(data: l2, encoding: .utf8) == "second")
        #expect(buffer.isEmpty)
    }

    @Test("reassembles a line that spans multiple read chunks")
    func lineSpansChunks() throws {
        // chunkSize=8 forces the reader to refill twice before the newline.
        let pipe = Pipe()
        writeAndClose(pipe, Data("0123456789ABCDEF\n".utf8))

        var buffer = Data()
        let line = try readBufferedLine(
            from: pipe.fileHandleForReading,
            buffer: &buffer,
            chunkSize: 8
        )
        #expect(String(data: line, encoding: .utf8) == "0123456789ABCDEF")
        #expect(buffer.isEmpty)
    }

    @Test("returns empty Data for an empty line")
    func emptyLine() throws {
        let pipe = Pipe()
        writeAndClose(pipe, Data("\n".utf8))

        var buffer = Data()
        let line = try readBufferedLine(from: pipe.fileHandleForReading, buffer: &buffer, chunkSize: 4096)
        #expect(line.isEmpty)
    }

    @Test("clean EOF before any bytes throws")
    func eofImmediate() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.closeFile()

        var buffer = Data()
        #expect(throws: XcodeCLIError.self) {
            _ = try readBufferedLine(
                from: pipe.fileHandleForReading,
                buffer: &buffer,
                chunkSize: 4096
            )
        }
    }

    @Test("EOF after partial line throws and mentions buffered bytes")
    func eofMidLine() throws {
        let pipe = Pipe()
        // No trailing newline — reader must fail on EOF rather than return
        // the partial line.
        writeAndClose(pipe, Data("partial-no-newline".utf8))

        var buffer = Data()
        do {
            _ = try readBufferedLine(
                from: pipe.fileHandleForReading,
                buffer: &buffer,
                chunkSize: 4096
            )
            Issue.record("expected EOF error")
        } catch let XcodeCLIError.mcpInitializationFailed(reason) {
            #expect(reason.contains("buffered"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("preserves bytes after newline across calls")
    func leftoverPersistsAcrossCalls() throws {
        // Write the full payload (two complete lines plus a trailing
        // fragment) and close the writer in one shot. After the first two
        // readBufferedLine calls return, the third must observe EOF and
        // surface the partial fragment via the dedicated error message —
        // proving that bytes which arrive after the most recent newline
        // really do persist in the buffer rather than being thrown away.
        let pipe = Pipe()
        writeAndClose(pipe, Data("aaa\nbbb\nccc".utf8))

        var buffer = Data()
        let l1 = try readBufferedLine(from: pipe.fileHandleForReading, buffer: &buffer, chunkSize: 4096)
        #expect(String(data: l1, encoding: .utf8) == "aaa")
        let l2 = try readBufferedLine(from: pipe.fileHandleForReading, buffer: &buffer, chunkSize: 4096)
        #expect(String(data: l2, encoding: .utf8) == "bbb")
        // Buffer must still hold the partial trailing fragment.
        #expect(String(data: buffer, encoding: .utf8) == "ccc")

        do {
            _ = try readBufferedLine(
                from: pipe.fileHandleForReading,
                buffer: &buffer,
                chunkSize: 4096
            )
            Issue.record("expected EOF error after partial fragment")
        } catch let XcodeCLIError.mcpInitializationFailed(reason) {
            #expect(reason.contains("buffered"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
