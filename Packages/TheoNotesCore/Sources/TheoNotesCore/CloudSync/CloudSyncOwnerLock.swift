// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation

/// Only one sync owner per library (CK-R133). The app process is the owner: it alone runs the CloudKit gateway, the key layer
/// and the blob transfers (the blob assembly files rely on an in-process per-hash lock, CK-R112, and two engines on one library
/// would race for the same base pairs). The command-line helper and the MCP server (`theonotes`) never sync: they write through
/// the SQLite triggers like any other writer and the app's next cycle uploads what they changed.
///
/// The lock is an exclusive `flock` on a file inside the library folder. It is held by the open file, so a crash or a kill
/// releases it, and a second owner is refused whether it lives in this process or in another one (`flock` locks belong to the
/// open file description, not to the process).
public final class CloudSyncOwnerLock: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// Another coordinator (in this process or another) owns this library.
        case ownedElsewhere
        case cannotOpen(Int32)
    }

    public static let fileName = "CloudSyncOwner.lock"

    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    /// Takes the lock or throws `.ownedElsewhere`. Never blocks.
    public static func acquire(root: URL) throws -> CloudSyncOwnerLock {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.cannotOpen(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK { throw Failure.ownedElsewhere }
            throw Failure.cannotOpen(reason)
        }
        return CloudSyncOwnerLock(descriptor: descriptor)
    }

    public var isHeld: Bool { lock.withLock { descriptor >= 0 } }

    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}
