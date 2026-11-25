// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesCore

/// Blocks the caller, never awaited work: the signal comes from a plain thread, not the cooperative pool.
private func waitOff(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 60) == .success }

/// A real second SQLite connection holds a read transaction across the lock commit.
struct PrivacyTestLibrary: Sendable {
    let paths: AppPaths
    let db: AppDatabase
    let store: NoteStore
    init() throws {
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("m9-privacy-\(UUID())"))
        try paths.createDirectories()
        db = try AppDatabase(path: paths.database)
        store = NoteStore(db: db, notifier: nil, paths: paths)
        try db.pool.writeWithoutTransaction {
            try $0.execute(sql: "PRAGMA busy_timeout = 1; PRAGMA wal_autocheckpoint = 0")
        }
    }
    func access(password: String = "fixture-password", iterations: Int = 1) throws -> LockedNoteAccess {
        let (envelope, key) = try CryptoEnvelope.create(password: password, iterations: iterations)
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [try JSONEncoder().encode(envelope)])
        }
        return LockedNoteAccess(store: store, key: key, envelope: envelope)
    }
    func pinnedReader() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.allowsUnsafeTransactions = true
        let reader = try DatabaseQueue(path: paths.database.path, configuration: configuration)
        try reader.writeWithoutTransaction {
            try $0.execute(sql: "BEGIN DEFERRED TRANSACTION")
            _ = try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note")
        }
        return reader
    }
    func pendingCount() throws -> Int {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM privacy_transition")! }
    }
    func cleanup() {
        try? db.pool.close()
        try? FileManager.default.removeItem(at: paths.root)
    }
}

struct PrivacyCleanupRetryTests {
    @MainActor @Test func readerReleaseConvergesWithoutBlockingMainActor() async throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Public title\nprivate reader fixture")
        let access = try library.access()
        let reader = try library.pinnedReader()
        defer { try? reader.close() }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id) }
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try library.pendingCount() == 1)
        let cleanup = Task { try await NotePrivacy(store: library.store).finishPendingCleanupWithRetry() }
        try await Task.sleep(for: .milliseconds(250))
        try await reader.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        try await cleanup.value
        #expect(try library.pendingCount() == 0)
        #expect(try access.note(id: note.id)?.text == note.text)
    }

    @Test func pinnedReaderExhaustsAndCancellationRetainsDurableTransition() async throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Title\nprivate")
        let access = try library.access()
        let reader = try library.pinnedReader()
        defer { try? reader.close() }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id) }
        let privacy = NotePrivacy(store: library.store)
        await #expect(throws: NotePrivacyError.cleanupPending) { try await privacy.finishPendingCleanupWithRetry() }
        #expect(try library.pendingCount() == 1)
        #expect(throws: NotePrivacyError.cleanupPending) {
            try access.addAttachment(data: Data("exhausted".utf8), filename: "exhausted.txt", to: note.id)
        }
        let cleanup = Task { try await privacy.finishPendingCleanupWithRetry() }
        try await Task.sleep(for: .milliseconds(50))
        cleanup.cancel()
        await #expect(throws: CancellationError.self) { try await cleanup.value }
        #expect(try library.pendingCount() == 1)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(throws: NotePrivacyError.cleanupPending) { try access.removeLock(noteId: note.id) }
        #expect(throws: NotePrivacyError.cleanupPending) {
            try access.addAttachment(data: Data("cancelled".utf8), filename: "cancelled.txt", to: note.id)
        }
        try await reader.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        try await privacy.finishPendingCleanupWithRetry()
        #expect(try library.pendingCount() == 0)
    }

    @Test func pendingLockRejectsLateAttachmentAndResumesAfterCleanup() async throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Late attachment")
        let access = try library.access()
        let reader = try library.pinnedReader()
        defer { try? reader.close() }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id) }
        let revision = try #require(try access.note(id: note.id)).revision
        #expect(throws: NotePrivacyError.cleanupPending) {
            try access.addAttachment(data: Data("late bytes".utf8), filename: "late.txt", to: note.id)
        }
        #expect(throws: NotePrivacyError.cleanupPending) {
            try access.updateText(id: note.id, text: "# Late attachment\n[late](late.txt)", expectedRevision: revision)
        }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.removeLock(noteId: note.id) }
        #expect(throws: NotePrivacyError.cleanupPending) { try library.store.deletePermanently([note.id]) }
        #expect(try access.note(id: note.id)?.revision == revision)
        try await reader.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        try await NotePrivacy(store: library.store).finishPendingCleanupWithRetry()
        let name = try access.addAttachment(data: Data("late bytes".utf8), filename: "late.txt", to: note.id)
        let current = try #require(try access.note(id: note.id))
        _ = try access.updateText(id: note.id, text: "# Late attachment\n[late](\(name))", expectedRevision: current.revision)
        try await NotePrivacy(store: library.store).finishPendingCleanupWithRetry()
        let output = library.paths.root.appendingPathComponent("verified.txt")
        try access.decryptAttachment(name, noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == Data("late bytes".utf8))
        #expect(try library.pendingCount() == 0)
    }

    @Test func pendingUnlockBlocksPlainAndStagedMutationsAndSweep() async throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Pending unlock")
        let access = try library.access()
        try access.lock(noteId: note.id)
        _ = try access.addAttachment(data: Data("retained".utf8), filename: "retained.txt", to: note.id)
        let lock = try #require(try BatchLock.acquire(library.paths.root.appendingPathComponent(".privacy-cleanup.lock").path))
        defer { lock.release() }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.removeLock(noteId: note.id) }
        #expect(try library.pendingCount() == 1)
        let current = try #require(try library.store.note(id: note.id))
        #expect(!current.isLocked)
        let plain = AttachmentStore(paths: library.paths, database: library.db)
        #expect(throws: NotePrivacyError.cleanupPending) { try plain.add(data: Data(), filename: "late.txt", to: note.id) }
        #expect(throws: NotePrivacyError.cleanupPending) { try plain.rename("retained.txt", to: "renamed.txt", in: note.id) }
        #expect(throws: NotePrivacyError.cleanupPending) { try plain.delete("retained.txt", from: note.id) }
        #expect(throws: NotePrivacyError.cleanupPending) {
            try library.store.updateText(id: note.id, text: "replacement", expectedRevision: current.revision)
        }
        let draft = ImportedNoteDraft(text: "import", createdAt: .now, modifiedAt: .now)
        #expect(throws: NotePrivacyError.cleanupPending) {
            try library.store.replaceImported(noteID: note.id, draft: draft, expectedRevision: current.revision)
        }
        let files = AttachmentFiles(paths: library.paths, database: library.db)
        #expect(throws: NotePrivacyError.cleanupPending) {
            try files.place(Data(), filename: "direct.txt", noteId: note.id)
        }
        #expect(throws: NotePrivacyError.cleanupPending) {
            try files.write([ImportedAttachment(filename: "staged.txt", data: Data())], noteId: note.id, replacing: true) { _ in }
        }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id) }
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id, now: .now.addingTimeInterval(3600)).isEmpty)
        #expect(plain.url(for: "retained.txt", noteId: note.id) != nil)
        lock.release()
        try await NotePrivacy(store: library.store).finishPendingCleanupWithRetry()
        _ = try plain.add(data: Data("resumed".utf8), filename: "resumed.txt", to: note.id)
        #expect(try library.pendingCount() == 0)
    }

    @Test func overlappingCleanupCannotUseManifestAfterFinalization() async throws {
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Overlap")
        let access = try library.access()
        let reader = try library.pinnedReader()
        defer { try? reader.close() }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id) }
        try await reader.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        // The first cleanup blocks on its own thread, not in the cooperative pool: a pool thread parked in a
        // semaphore under a fully loaded test run starved the rest of this test past the wait.
        let entered = Mutex(false)
        let enteredSignal = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let guarded = library.store.guarded { _, stage in
            if case .begin = stage, !entered.withLock({ let was = $0; $0 = true; return was }) {
                enteredSignal.signal()
                #expect(resume.wait(timeout: .now() + 60) == .success)
            }
        }
        let firstResult = Mutex<Result<Void, any Error>?>(nil)
        let firstDone = DispatchSemaphore(value: 0)
        Thread {
            firstResult.withLock { $0 = Result { try NotePrivacy(store: guarded).finishPendingCleanup() } }
            firstDone.signal()
        }.start()
        try #require(waitOff(enteredSignal))
        // A separate store still shares the same on-disk cleanup lock.
        let other = NoteStore(db: library.db, notifier: nil, paths: library.paths)
        #expect(throws: NotePrivacyError.cleanupPending) { try NotePrivacy(store: other).finishPendingCleanup() }
        resume.signal()
        try #require(waitOff(firstDone))
        try firstResult.withLock { $0 }?.get()
        let name = try access.addAttachment(data: Data("new generation".utf8), filename: "new.txt", to: note.id)
        try NotePrivacy(store: other).finishPendingCleanup()
        let output = library.paths.root.appendingPathComponent("overlap-verified.txt")
        try access.decryptAttachment(name, noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == Data("new generation".utf8))
    }

    @Test func alreadyCancelledTaskDoesNoCleanupWork() async throws {
        let attempts = Mutex(0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NotePrivacy.retryCleanup { attempts.withLock { $0 += 1 } }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(attempts.withLock { $0 } == 0)
    }

    @Test func retryAttemptsAreBoundedAndOnlyCleanupPendingIsRetried() async throws {
        let attempts = Mutex(0)
        await #expect(throws: NotePrivacyError.cleanupPending) {
            try await NotePrivacy.retryCleanup {
                attempts.withLock { $0 += 1 }
                throw NotePrivacyError.cleanupPending
            }
        }
        #expect(attempts.withLock { $0 } == 5)
        attempts.withLock { $0 = 0 }
        await #expect(throws: NotePrivacyError.pendingEdits) {
            try await NotePrivacy.retryCleanup {
                attempts.withLock { $0 += 1 }
                throw NotePrivacyError.pendingEdits
            }
        }
        #expect(attempts.withLock { $0 } == 1)
    }
}
