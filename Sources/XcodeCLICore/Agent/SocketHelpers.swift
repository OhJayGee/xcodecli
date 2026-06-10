import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Safely set the sun_path field of a sockaddr_un from a Swift String.
/// Uses withUnsafeMutableBytes to correctly access the full sun_path buffer.
/// Returns false if the path was truncated (exceeds sun_path capacity).
@discardableResult
func setUnixSocketPath(_ addr: inout sockaddr_un, to path: String) -> Bool {
    var truncated = false
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        buffer.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count)
        path.withCString { cStr in
            let pathLen = strlen(cStr)
            let len = min(pathLen, buffer.count - 1)
            if pathLen > buffer.count - 1 { truncated = true }
            buffer.baseAddress!.copyMemory(from: cStr, byteCount: len)
        }
    }
    return !truncated
}

/// Metadata captured from `lstat` for a socket file path.
struct SocketFileMetadata {
    let isSocket: Bool
    let mode: mode_t   // mode_t includes file-type bits in S_IFMT and permission bits in 0o777
    let uid: uid_t
}

/// `lstat` the path and return its metadata. Returns nil if the path does not exist
/// or `lstat` fails. Uses lstat (not stat) so a symlink at the path is reported as
/// a symlink, not as the target's type.
func lstatSocketMetadata(at path: String) -> SocketFileMetadata? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let isSocket = (st.st_mode & S_IFMT) == S_IFSOCK
    return SocketFileMetadata(isSocket: isSocket, mode: st.st_mode, uid: st.st_uid)
}

/// Returns the effective UID of the peer connected to `fd`, or nil on error.
/// Wraps Darwin's getpeereid() (declared in <unistd.h>; available on Darwin
/// without an extra import beyond `import Darwin`).
func peerUID(of fd: Int32) -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
}

/// Write all bytes to a file descriptor, handling partial writes and EINTR.
/// Returns true on success, false on failure.
func writeAllToFD(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { ptr -> Bool in
        guard let base = ptr.baseAddress else { return false }
        var written = 0
        while written < ptr.count {
            var n = Darwin.send(fd, base + written, ptr.count - written, MSG_NOSIGNAL)
            if n < 0 && errno == ENOTSOCK {
                n = Darwin.write(fd, base + written, ptr.count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            written += n
        }
        return true
    }
}
