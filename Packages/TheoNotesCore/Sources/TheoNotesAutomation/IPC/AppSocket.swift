// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Darwin
import Foundation

/// The wire format between `baerchen` / `mcp-server` and the running app: one JSON object per line
/// over a Unix socket, one request and one reply per connection (ruling M5-R150). Only open and
/// selection requests exist; the socket carries no note text except the selection the caller asks for.
public struct AppSocketRequest: Codable, Equatable, Sendable {
    public var id: Int
    /// `ping`, `open` or `getSelection`.
    public var method: String
    public var params: OpenParams?

    public init(id: Int, method: String, params: OpenParams? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct OpenParams: Codable, Equatable, Sendable {
    public var noteId: String
    public var header: String?
    public var edit: Bool
    public var newWindow: Bool
    public var float: Bool
    public var selectionText: String?
    /// UTF-8 byte offset and length of the selection (the caller's view of the note).
    public var selectionOffset: Int?
    public var selectionLength: Int?

    public init(
        noteId: String, header: String? = nil, edit: Bool = false, newWindow: Bool = false, float: Bool = false,
        selectionText: String? = nil, selectionOffset: Int? = nil, selectionLength: Int? = nil
    ) {
        self.noteId = noteId
        self.header = header
        self.edit = edit
        self.newWindow = newWindow
        self.float = float
        self.selectionText = selectionText
        self.selectionOffset = selectionOffset
        self.selectionLength = selectionLength
    }
}

public struct SelectionResult: Codable, Equatable, Sendable {
    public var noteId: String?
    /// UTF-8 bytes, like everything the CLI prints.
    public var selectionOffset: Int?
    public var selectionLength: Int?
    public var selectionText: String?

    public init(
        noteId: String? = nil, selectionOffset: Int? = nil, selectionLength: Int? = nil, selectionText: String? = nil
    ) {
        self.noteId = noteId
        self.selectionOffset = selectionOffset
        self.selectionLength = selectionLength
        self.selectionText = selectionText
    }
}

public struct AppSocketError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: ErrorCode, message: String) {
        self.code = code.rawValue
        self.message = message
    }

    /// The error the app sent, as the CLI reports it; a code this build does not know is `internal`.
    public var automationError: AutomationError {
        AutomationError(code: ErrorCode(rawValue: code) ?? .internal, message: message)
    }
}

public struct AppSocketResponse: Codable, Equatable, Sendable {
    public var id: Int
    public var result: SelectionResult?
    public var error: AppSocketError?

    public init(id: Int, result: SelectionResult? = nil, error: AppSocketError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    /// The result, or the error the app answered with.
    public func requireResult() throws(AutomationError) -> SelectionResult {
        if let error { throw error.automationError }
        return result ?? SelectionResult()
    }
}

/// Socket location and the small POSIX helpers the client, the app's server and the tests share.
public enum AppSocket {
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
    public static let maxPathBytes = 103
    /// The longest request line the app reads (ruling M5-R152).
    public static let maxRequestBytes = 1 << 20
    /// The longest reply line the client reads: a selection can be a whole note.
    public static let maxReplyBytes = 64 << 20

    /// `<data dir>/app.sock`; when that exceeds 103 bytes,
    /// `~/Library/Caches/com.truebrewbirdie.baerchen/sockets/<first 16 hex of SHA-256(data dir path)>.sock`
    /// (ruling M5-R16). Pure: the folder is made by whoever binds.
    public static func path(for paths: AppPaths, home: URL = AutomationContext.defaultHome) -> String {
        let direct = paths.root.appendingPathComponent("app.sock").path
        if direct.utf8.count <= maxPathBytes { return direct }
        let digest = SHA256.hash(data: Data(paths.root.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return fallbackDirectory(home: home).appendingPathComponent(name + ".sock").path
    }

    /// The folder of fallback sockets (mode 0700 when made).
    public static func fallbackDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/com.truebrewbirdie.baerchen/sockets", isDirectory: true)
    }

    /// Whether `path` is the fallback location (its folder may need making).
    public static func isFallback(_ path: String, home: URL) -> Bool {
        path.hasPrefix(fallbackDirectory(home: home).path + "/")
    }

    /// Only the user who runs the app may talk to it (ruling M5-R152). A peer that cannot be
    /// identified is refused.
    public static func allows(peer: uid_t?, own: uid_t) -> Bool {
        guard let peer else { return false }
        return peer == own
    }

    /// The effective user id of the process on the other end of a connected socket.
    public static func peerUserID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// `sockaddr_un` for `path`; nil when it does not fit.
    public static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }

    public enum ConnectFailure: Error, Equatable {
        /// No socket file (`ENOENT`): a definite absence.
        case notRunning
        /// The file is there and the connect was refused (`ECONNREFUSED`). Darwin also reports a
        /// listener whose backlog is full this way, so on its own it proves nothing: the app's start-up
        /// lock tells a crashed app from a busy one (rulings M5-R192, M5-R205).
        case refused
        /// The connect did not finish within the timeout (a full backlog, a connect still pending):
        /// something is there, so treat it as live (ruling M5-R192).
        case busy
        /// Any other failure; says nothing about whether an instance runs.
        case failed(Int32)
        case invalidPath
    }

    /// A connected, blocking stream socket to `path`. A pending connect (`EINPROGRESS`, `EALREADY`)
    /// is waited for with `poll` and read back with `SO_ERROR`, never retried as a fresh connect and
    /// never mistaken for "not running" (ruling M5-R192).
    public static func connect(path: String, timeout: Duration) -> Result<Int32, ConnectFailure> {
        connect(path: path, timeout: timeout, using: systemConnect)
    }

    /// The `connect(2)` call; tests substitute one that fails with an errno Darwin does not produce on
    /// demand (`EALREADY`, `EAGAIN`).
    typealias ConnectCall = @Sendable (_ fd: Int32, _ address: inout sockaddr_un) -> Int32

    static let systemConnect: ConnectCall = { fd, address in
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(
        path: String, timeout: Duration, using call: ConnectCall
    ) -> Result<Int32, ConnectFailure> {
        guard var address = address(for: path) else { return .failure(.invalidPath) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.failed(errno)) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let deadline = ContinuousClock.now + timeout

        func finish(_ result: Result<Int32, ConnectFailure>) -> Result<Int32, ConnectFailure> {
            if case .failure = result { close(fd) }
            return result
        }
        while true {
            let status = call(fd, &address)
            if status == 0 || errno == EISCONN {
                _ = fcntl(fd, F_SETFL, flags)
                return .success(fd)
            }
            switch errno {
            case EINTR:
                continue
            case EINPROGRESS, EALREADY:
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var ready: Int32
                repeat { ready = poll(&poller, 1, remainingMilliseconds(until: deadline)) } while ready < 0 && errno == EINTR
                guard ready > 0 else { return finish(.failure(.busy)) }
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size)
                switch failure {
                case 0:
                    _ = fcntl(fd, F_SETFL, flags)
                    return .success(fd)
                case ENOENT: return finish(.failure(.notRunning))
                case ECONNREFUSED: return finish(.failure(.refused))
                case EAGAIN: break
                default: return finish(.failure(.failed(failure)))
                }
            case EAGAIN:
                break
            case ENOENT:
                return finish(.failure(.notRunning))
            case ECONNREFUSED:
                return finish(.failure(.refused))
            default:
                return finish(.failure(.failed(errno)))
            }
            // A full backlog: try again until the timeout is used up.
            if ContinuousClock.now >= deadline { return finish(.failure(.busy)) }
            usleep(10_000)
        }
    }

    /// Whether a running app holds the start-up lock beside the socket (`<socket>.lock`). The lock is
    /// taken for the life of the app and dropped by the kernel when it dies, so a held lock means a live
    /// instance even when its backlog is full and connects are refused (ruling M5-R205). A missing or
    /// unlocked file means nobody holds it.
    public static func lockIsHeld(socketPath: String) -> Bool {
        let fd = open(socketPath + ".lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Receive and send time limits for a blocking socket: a backstop per call; the whole-request
    /// limit is the `deadline` of `readLine` / `writeAll`.
    public static func setTimeouts(_ fd: Int32, receive: Duration, send: Duration) {
        var tv = timeval(tv_sec: Int(seconds(receive)), tv_usec: Int32((seconds(receive) - Double(Int(seconds(receive)))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        tv = timeval(tv_sec: Int(seconds(send)), tv_usec: Int32((seconds(send) - Double(Int(seconds(send)))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Milliseconds left until `deadline`, rounded up, for `poll` (0 when it has passed).
    static func remainingMilliseconds(until deadline: ContinuousClock.Instant) -> Int32 {
        let left = deadline - ContinuousClock.now
        guard left > .zero else { return 0 }
        let parts = left.components
        // Clamp the seconds before multiplying, so a huge deadline cannot overflow (ruling M5-R211).
        guard parts.seconds < Int64(Int32.max) / 1000 else { return Int32.max }
        let milliseconds = parts.seconds * 1000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(min(milliseconds, Int64(Int32.max)))
    }

    public enum LineResult {
        /// A line without its terminator.
        case line(Data)
        /// More than the limit arrived without a line end.
        case tooLong
        /// The deadline passed (or one receive timed out) before a whole line arrived.
        case timeout
        /// The peer closed before sending anything, or the read failed.
        case closed
    }

    /// Reads up to the first `\n` (or the end of the stream: a last line without a terminator counts).
    /// Bytes after the newline are dropped: a connection carries one request. `deadline` bounds the
    /// whole line on a monotonic clock, so a peer that trickles bytes cannot hold the connection
    /// (ruling M5-R193).
    public static func readLine(
        from fd: Int32, maxBytes: Int, deadline: ContinuousClock.Instant? = nil
    ) -> LineResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            if let deadline {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, remainingMilliseconds(until: deadline))
                if ready == 0 { return .timeout }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .closed
                }
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .timeout }
                return .closed
            }
            if count == 0 { return data.isEmpty ? .closed : .line(data) }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data.count > maxBytes ? .tooLong : .line(data)
            }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maxBytes { return .tooLong }
        }
    }

    /// Writes all of `data`; false when the peer went away or the deadline (or one send timeout) passed.
    public static func writeAll(_ data: Data, to fd: Int32, deadline: ContinuousClock.Instant? = nil) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                if let deadline {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&poller, 1, remainingMilliseconds(until: deadline))
                    if ready == 0 { return false }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                }
                let written = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += written
            }
            return true
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
