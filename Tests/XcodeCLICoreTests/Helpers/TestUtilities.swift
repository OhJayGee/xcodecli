import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import XcodeCLICore

/// Write a JSON-RPC envelope to a pipe's writing end.
func writeLine(_ handle: FileHandle, _ json: String) {
    handle.write(Data((json + "\n").utf8))
}

/// Read a single JSON-RPC response line from a pipe's reading end.
/// Returns only the first newline-delimited line, even if more data is available.
func readLine(from handle: FileHandle, timeout: TimeInterval = 2.0) -> String? {
    var data = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let chunk = handle.availableData
        if chunk.isEmpty {
            Thread.sleep(forTimeInterval: 0.01)
            continue
        }
        data.append(chunk)
        if let str = String(data: data, encoding: .utf8),
           let newlineRange = str.rangeOfCharacter(from: .newlines) {
            return String(str[str.startIndex..<newlineRange.lowerBound])
        }
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Decode a JSON-RPC envelope from a string.
func decodeEnvelope(_ json: String) throws -> RPCEnvelope {
    try JSONLineCodec.decode(json)
}

// MARK: - Agent socket test helpers

enum AgentSocketTestError: Error {
    case mkdtempFailed(String)
    case socketCreateFailed(String)
    case connectFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case pathTooLong(String)
}

/// Create a fresh temporary directory with mode 0o700 suitable for hosting an
/// agent socket. The path is short enough to fit in `sockaddr_un.sun_path`
/// (104 bytes on Darwin minus the trailing slash + filename).
func makeTempSupportDir(prefix: String = "xcodecli-agent-test") throws -> String {
    let template = "/tmp/\(prefix)-XXXXXX"
    var bytes = Array(template.utf8)
    bytes.append(0)
    let result: String? = bytes.withUnsafeMutableBufferPointer { buf -> String? in
        guard let base = buf.baseAddress else { return nil }
        return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cBase -> String? in
            guard mkdtemp(cBase) != nil else { return nil }
            return String(cString: cBase)
        }
    }
    guard let path = result else {
        throw AgentSocketTestError.mkdtempFailed(String(cString: strerror(errno)))
    }
    chmod(path, 0o700)
    return path
}

/// Connect a Unix-domain client socket to `socketPath`. Returns the connected fd.
private func connectAgentSocket(_ socketPath: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw AgentSocketTestError.socketCreateFailed(String(cString: strerror(errno)))
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard setUnixSocketPath(&addr, to: socketPath) else {
        Darwin.close(fd)
        throw AgentSocketTestError.pathTooLong(socketPath)
    }
    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else {
        let err = String(cString: strerror(errno))
        Darwin.close(fd)
        throw AgentSocketTestError.connectFailed("connect \(socketPath): \(err)")
    }
    return fd
}

/// Write all bytes of `data` to `fd`, retrying on EINTR / partial writes.
private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        var written = 0
        while written < ptr.count {
            let n = Darwin.write(fd, base + written, ptr.count - written)
            if n < 0 {
                if errno == EINTR { continue }
                throw AgentSocketTestError.writeFailed(String(cString: strerror(errno)))
            }
            if n == 0 { throw AgentSocketTestError.writeFailed("write returned 0") }
            written += n
        }
    }
}

/// Read from `fd` until a newline is seen, EOF, or `timeout` elapses. Returns
/// the bytes read up to (but excluding) the newline.
private func readLineBytes(_ fd: Int32, timeout: TimeInterval = 3.0) throws -> Data {
    var tv = timeval()
    tv.tv_sec = Int(timeout)
    tv.tv_usec = Int32((timeout - Double(Int(timeout))) * 1_000_000)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
        if data.contains(UInt8(ascii: "\n")) { break }
    }
    if let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
        return data[data.startIndex..<nl]
    }
    return data
}

/// Send a JSON request followed by a newline to the agent at `socketPath` and
/// return the response line as a UTF-8 string.
@discardableResult
func sendRequest(socketPath: String, json: String, timeout: TimeInterval = 3.0) throws -> String {
    let fd = try connectAgentSocket(socketPath)
    defer { Darwin.close(fd) }
    var payload = Data(json.utf8)
    payload.append(UInt8(ascii: "\n"))
    try writeAll(fd, payload)
    let line = try readLineBytes(fd, timeout: timeout)
    return String(data: line, encoding: .utf8) ?? ""
}

/// Send a `stop` request to the agent. Best-effort: ignores the response body.
func sendStopRequest(socketPath: String, timeout: TimeInterval = 3.0) throws {
    _ = try sendRequest(socketPath: socketPath, json: "{\"method\":\"stop\"}", timeout: timeout)
}

/// Send raw bytes (no automatic newline) to the agent and read the response
/// line. Used by the oversized-request test.
@discardableResult
func sendRawAndReadResponse(socketPath: String, raw: String, timeout: TimeInterval = 8.0) throws -> String {
    let fd = try connectAgentSocket(socketPath)
    defer { Darwin.close(fd) }
    try writeAll(fd, Data(raw.utf8))
    let line = try readLineBytes(fd, timeout: timeout)
    return String(data: line, encoding: .utf8) ?? ""
}
