// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import Testing
@testable import TheoNotesCore

/// FOC-R306: the privacy cleanup lock is a flock(2) on `.privacy-cleanup.lock`. A child process
/// that is spawned while a descriptor is open holds a copy of it until the child execs, and a
/// flock belongs to the open file description, not to the descriptor: the lock looks held for a
/// moment after its owner closed it. Other suites in the same test process spawn children all the
/// time, so back-to-back cleanups of one library (a lock followed by Remove Lock) failed with
/// `cleanupPending` now and then. The app spawns processes too (imports, automation).
@Suite struct CleanupLockSpawnTests {
    private static func lockPath(_ library: PrivacyTestLibrary) -> String {
        library.paths.root.appendingPathComponent(".privacy-cleanup.lock").path
    }

    @Test func aCleanupLockThatIsOnlyHeldBrieflyIsWaitedFor() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Brief\nbody")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        let held = try #require(try BatchLock.acquire(Self.lockPath(library)))
        // Released shortly after Remove Lock starts waiting for it.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.1)
            held.release()
        }

        try access.removeLock(noteId: note.id)

        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try library.pendingCount() == 0)
    }

    /// The real mechanism: the lock's owner closed its descriptor, a child process still holds a
    /// copy of it (here until its stdin closes), and the next cleanup of the library must wait.
    @Test func aCleanupLockOnlyAChildStillHoldsIsWaitedFor() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Child\nbody")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)

        let lockFD = open(Self.lockPath(library), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        try #require(lockFD >= 0)
        try #require(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        var pipeFDs: [Int32] = [0, 0]
        try #require(pipe(&pipeFDs) == 0)
        let (stdinRead, stdinWrite) = (pipeFDs[0], pipeFDs[1])
        // Only the dup2'd copies below reach the child; the child must not hold its own stdin's
        // write end, or it would never see the end of its input.
        try #require(fcntl(stdinRead, F_SETFD, FD_CLOEXEC) == 0)
        try #require(fcntl(stdinWrite, F_SETFD, FD_CLOEXEC) == 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The child gets the lock's descriptor as fd 3 (no close-on-exec) and the pipe as stdin.
        try #require(posix_spawn_file_actions_adddup2(&actions, lockFD, 3) == 0)
        try #require(posix_spawn_file_actions_adddup2(&actions, stdinRead, 0) == 0)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/cat"), nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        let status = posix_spawn(&pid, "/bin/cat", &actions, nil, argv, envp)
        close(stdinRead)
        try #require(status == 0)
        defer { waitpid(pid, nil, 0) }
        // The owner is done; only the child's copy keeps the lock.
        close(lockFD)
        // The child ends (and with it the lock) shortly after Remove Lock starts waiting.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.1)
            close(stdinWrite)
        }

        try access.removeLock(noteId: note.id)

        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try library.pendingCount() == 0)
    }
}
