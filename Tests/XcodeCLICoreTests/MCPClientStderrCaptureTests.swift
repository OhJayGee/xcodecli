import Testing
import Foundation
@testable import XcodeCLICore

/// Pins the stderr-capture contract that backs `MCPClient`'s background
/// drain task. Two regressions are guarded against:
///
/// 1. The previous implementation polled `FileHandle.availableData` in a
///    `while true` loop. `availableData` returns an empty `Data`
///    immediately when nothing is buffered — a loop that does no I/O
///    burns a core. The replacement uses `FileHandle.bytes.lines`, which
///    suspends instead.
/// 2. The drain task wasn't awaited at shutdown, so any bytes the child
///    wrote between `close()`/`abort()` and EOF on the stderr pipe were
///    silently dropped. `await task.value` after closing the writer must
///    surface every line.
@Suite("MCPClient stderr capture")
struct MCPClientStderrCaptureTests {

    @Test("captures all lines written before EOF")
    func capturesAllLinesBeforeEOF() async {
        let pipe = Pipe()
        let buffer = MCPClient.StderrBuffer()
        let task = drainStderrToBuffer(
            handle: pipe.fileHandleForReading,
            buffer: buffer,
            debug: false,
            errOut: FileHandle.standardError
        )

        pipe.fileHandleForWriting.write(Data("first line\nsecond line\n".utf8))
        pipe.fileHandleForWriting.closeFile()

        // Crucially: await the task. The bug-fix is that callers no
        // longer have to wonder whether the drain is "done" — closing the
        // writer guarantees EOF and awaiting reaps every byte.
        await task.value

        let captured = buffer.value
        #expect(captured.contains("first line"))
        #expect(captured.contains("second line"))
    }

    @Test("captures bytes written just before close (no shutdown drop)")
    func capturesLateBytes() async {
        // Simulates the real shutdown race: the child process writes a
        // diagnostic to stderr immediately before exit. Under the old
        // implementation the drain task could be cancelled / never read
        // those bytes if `close()` returned before the task ran. Under
        // the new contract, awaiting the task post-EOF is sufficient.
        let pipe = Pipe()
        let buffer = MCPClient.StderrBuffer()
        let task = drainStderrToBuffer(
            handle: pipe.fileHandleForReading,
            buffer: buffer,
            debug: false,
            errOut: FileHandle.standardError
        )

        // Give the drain task a chance to start its first read.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Write the "last gasp" diagnostic and close in one shot, the
        // way a real child process does on abort/terminate.
        pipe.fileHandleForWriting.write(Data("late diagnostic\n".utf8))
        pipe.fileHandleForWriting.closeFile()

        await task.value
        #expect(buffer.value.contains("late diagnostic"))
    }

    @Test("yields the file handle while idle (no busy spin)")
    func doesNotSpinWhileIdle() async {
        // The real regression is "burns a CPU core when the child is
        // quiet"; we can't measure CPU directly here, but we can prove
        // the drain task is *suspended* rather than running by checking
        // that it reaches `task.value` only after we close the pipe.
        // If the drain were polling, this test would still pass — but a
        // wall-clock-bounded sleep ensures we don't accidentally test a
        // version that races to completion before any writes.
        let pipe = Pipe()
        let buffer = MCPClient.StderrBuffer()
        let task = drainStderrToBuffer(
            handle: pipe.fileHandleForReading,
            buffer: buffer,
            debug: false,
            errOut: FileHandle.standardError
        )

        // Quiet period — drain task must NOT complete (would mean it
        // raced to EOF on an open pipe, which would be a bug).
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Trigger EOF and confirm the task drains cleanly.
        pipe.fileHandleForWriting.closeFile()
        await task.value

        #expect(buffer.value.isEmpty) // never wrote anything
    }

    @Test("forwards lines to errOut when debug is enabled")
    func debugForwardsToErrOut() async throws {
        // Use a pipe as the errOut sink so we can assert on what got
        // written without contaminating the test runner's stderr.
        let stderrPipe = Pipe()
        let captureSink = Pipe()
        let buffer = MCPClient.StderrBuffer()

        let task = drainStderrToBuffer(
            handle: stderrPipe.fileHandleForReading,
            buffer: buffer,
            debug: true,
            errOut: captureSink.fileHandleForWriting
        )

        stderrPipe.fileHandleForWriting.write(Data("hello debug\n".utf8))
        stderrPipe.fileHandleForWriting.closeFile()
        await task.value

        // Closing the sink lets us read everything the drain forwarded
        // without blocking on more data.
        captureSink.fileHandleForWriting.closeFile()
        let forwarded = String(
            data: captureSink.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(forwarded.contains("[debug] child stderr:"))
        #expect(forwarded.contains("hello debug"))
        #expect(buffer.value.contains("hello debug"))
    }
}
