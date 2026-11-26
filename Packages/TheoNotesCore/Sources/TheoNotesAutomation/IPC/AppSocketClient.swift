// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Darwin
import Foundation

/// The CLI's and MCP server's end of the app socket.
public enum AppSocketClient {
    public static let notRunningMessage = "Theo Notes is not running with this library"
    public static let timeoutMessage = "Theo Notes did not answer in time"

    /// A failure that says nothing about whether an app runs (permission denied, a path that cannot be a
    /// socket address): never "not running", so nothing is launched on its account.
    static func unreachable(_ reason: String) -> AutomationError {
        AutomationError(code: .appUnavailable, message: "Could not reach Theo Notes: \(reason)")
    }

    /// Whether `error` says there is no app to talk to (as opposed to an app that failed to answer).
    public static func isNotRunning(_ error: AutomationError) -> Bool {
        error.code == .appUnavailable && error.message == notRunningMessage
    }

    /// Sends one request and returns the app's reply, which may carry an `error`. No socket, or one
    /// nobody listens on (a crashed app), is `app_unavailable` "Theo Notes is not running with this
    /// library"; so is a peer that is not the same user (the socket is not ours to trust).
    public static func send(
        _ request: AppSocketRequest, paths: AppPaths, home: URL = AutomationContext.defaultHome,
        connectTimeout: Duration = .seconds(1), replyTimeout: Duration = .seconds(5)
    ) throws(AutomationError) -> AppSocketResponse {
        let notRunning = AutomationError(code: .appUnavailable, message: notRunningMessage)
        let socketPath = AppSocket.path(for: paths, home: home)
        let fd: Int32
        switch AppSocket.connect(path: socketPath, timeout: connectTimeout) {
        case .success(let connected): fd = connected
        case .failure(.busy): throw AutomationError(code: .appUnavailable, message: timeoutMessage)
        case .failure(.notRunning): throw notRunning
        case .failure(.refused):
            // A refusal is a crashed app unless a live one holds the lock (a full backlog also refuses).
            if AppSocket.lockIsHeld(socketPath: socketPath) {
                throw AutomationError(code: .appUnavailable, message: timeoutMessage)
            }
            throw notRunning
        case .failure(.failed(let code)):
            throw unreachable(String(cString: strerror(code)))
        case .failure(.invalidPath):
            throw unreachable("the socket path is too long")
        }
        defer { close(fd) }
        guard AppSocket.allows(peer: AppSocket.peerUserID(of: fd), own: geteuid()) else { throw notRunning }
        AppSocket.setTimeouts(fd, receive: replyTimeout, send: replyTimeout)
        // One monotonic limit for the whole exchange, so a peer that trickles bytes cannot stretch it.
        let deadline = ContinuousClock.now + replyTimeout

        var line: Data
        do {
            line = try JSONEncoder().encode(request)
        } catch {
            throw AutomationError(code: .internal, message: "The app request could not be encoded")
        }
        line.append(0x0A)
        guard AppSocket.writeAll(line, to: fd, deadline: deadline) else {
            throw AutomationError(code: .appUnavailable, message: timeoutMessage)
        }
        switch AppSocket.readLine(from: fd, maxBytes: AppSocket.maxReplyBytes, deadline: deadline) {
        case .line(let data):
            guard let response = try? JSONDecoder().decode(AppSocketResponse.self, from: data) else {
                throw AutomationError(code: .internal, message: "Theo Notes sent a reply that could not be read")
            }
            return response
        case .timeout:
            throw AutomationError(code: .appUnavailable, message: timeoutMessage)
        case .closed:
            throw AutomationError(code: .appUnavailable, message: "Theo Notes closed the connection without an answer")
        case .tooLong:
            throw AutomationError(code: .internal, message: "Theo Notes sent a reply that is too long")
        }
    }
}
