// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import notify
import Synchronization

public final class ObservationToken: Sendable {
    private let onCancel: Mutex<(@Sendable () -> Void)?>

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = Mutex(onCancel)
    }

    public func cancel() {
        let action = onCancel.withLock { slot -> (@Sendable () -> Void)? in
            defer { slot = nil }
            return slot
        }
        action?()
    }

    deinit { cancel() }
}

/// Cross-process "the library changed" signal over libnotify (Darwin notifications). It uses `notify_*`
/// directly, not `CFNotificationCenterGetDarwinNotifyCenter()`: in a process that adds and removes many
/// observers on many threads (the parallel test suites, the CLI and MCP server), the CF layer was seen to
/// skip posts that a plain `notify_register_dispatch` registration in the same process received every
/// time. The wire format is the same notification name, so processes that still post through CF are heard.
public final class ChangeNotifier: Sendable {
    public static let name = "com.truebrewbirdie.baerchen.db-changed"

    /// Callbacks run here, never on the main queue: observers hop to their own actor.
    private static let queue = DispatchQueue(label: "theonotes.change-notifier")

    /// The Darwin notification this instance posts and observes: `ChangeNotifier.name` (every
    /// process of the app), or a private one (tests that must not see other stores' posts).
    private let channel: String

    public init(name: String = ChangeNotifier.name) {
        channel = name
    }

    public func post() {
        notify_post(channel)
    }

    /// The handler runs for every post until the token is cancelled; after `cancel()` no new call starts,
    /// even for a post already queued.
    public func observe(_ handler: @escaping @Sendable () -> Void) -> ObservationToken {
        let active = Mutex(true)
        var token = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(channel, &token, Self.queue) { _ in
            if active.withLock({ $0 }) { handler() }
        }
        guard status == NOTIFY_STATUS_OK else { return ObservationToken {} }
        let registered = token
        return ObservationToken {
            active.withLock { $0 = false }
            notify_cancel(registered)
        }
    }
}
