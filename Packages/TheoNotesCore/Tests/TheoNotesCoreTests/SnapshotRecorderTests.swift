// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The recorder takes a snapshot when a note's session closes and after a 15-minute pause in
/// typing (FOC-R180 ... FOC-R183). The writer decides what is stored; the recorder never writes
/// snapshot text anywhere else, and never logs it.
@MainActor
@Suite struct SnapshotRecorderTests {
    nonisolated static let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class WallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = SnapshotRecorderTests.start
        func tick() -> Date { lock.withLock { date += 60; return date } }
    }

    @MainActor struct Env {
        let library: PrivacyTestLibrary
        let sessionClock = TestClock()
        let recorderClock = TestClock()
        /// Wall time for the snapshots: one minute later on every read, so their order is fixed.
        let wallClock = WallClock()
        var store: NoteStore { library.store }

        init() throws { library = try PrivacyTestLibrary() }

        func session(_ noteId: String) throws -> NoteSession {
            try NoteSession(noteId: noteId, store: store, journalDirectory: library.paths.journal, clock: sessionClock)
        }

        func recorder(_ session: NoteSession, writer: (any SnapshotWriting)? = nil) -> SnapshotRecorder {
            SnapshotRecorder(session: session, writer: writer ?? store, clock: recorderClock, now: { [wallClock] in wallClock.tick() })
        }
    }

    /// Types `string` at the end of the note, as the editor would.
    static func type(_ string: String, into session: NoteSession) {
        var sections: [ChangeSet.Section] = []
        let length = session.text.utf16.count
        if length > 0 { sections.append(.retain(length)) }
        sections.append(.replace(deleteLength: 0, insert: string))
        let expected = session.revision + 1
        let result = session.apply(txId: UUID().uuidString, baseRevision: session.revision,
                                   changeSet: ChangeSet(sections: sections), origin: nil)
        #expect(result == .acked(revision: expected))
    }

    /// An acknowledged transaction that changes nothing, or deletes `count` characters from the end.
    static func edit(deletingLast count: Int, from session: NoteSession) {
        let length = session.text.utf16.count
        var sections: [ChangeSet.Section] = []
        if length - count > 0 { sections.append(.retain(length - count)) }
        if count > 0 { sections.append(.replace(deleteLength: count, insert: "")) }
        let expected = session.revision + 1
        let result = session.apply(txId: UUID().uuidString, baseRevision: session.revision,
                                   changeSet: ChangeSet(sections: sections), origin: nil)
        #expect(result == .acked(revision: expected))
    }

    static func texts(_ store: NoteStore, _ noteId: String) throws -> [String] {
        try store.snapshots(noteId: noteId).map { try store.snapshotText(id: $0.id) }
    }

    static func settle() async { for _ in 0..<30 { await Task.yield() } }

    // MARK: idle

    @Test func idleAfterAnEditTakesOneSnapshot() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.type("!", into: session)
        env.recorderClock.advance(by: .seconds(899))
        await Self.settle()
        #expect(try Self.texts(env.store, note.id).isEmpty)

        env.recorderClock.advance(by: .seconds(1))
        await recorder.idleTask?.value
        #expect(try Self.texts(env.store, note.id) == ["start!"])
        #expect(SnapshotRecorder.idleInterval == .seconds(900))
    }

    @Test func idleStretchTakesAtMostOne() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.type("!", into: session)
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value
        for _ in 0..<4 {
            env.recorderClock.advance(by: .seconds(900))
            await Self.settle()
        }
        #expect(try Self.texts(env.store, note.id) == ["start!"])
        #expect(recorder.idleTask == nil)

        // The next edit opens a new stretch.
        Self.type("?", into: session)
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value
        #expect(try Self.texts(env.store, note.id) == ["start!?", "start!"])
    }

    @Test func aNewEditRestartsTheIdleTimer() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.type("a", into: session)
        env.recorderClock.advance(by: .seconds(600))
        Self.type("b", into: session)
        env.recorderClock.advance(by: .seconds(600))  // 1200 s after the first edit, 600 s after the second
        await Self.settle()
        #expect(try Self.texts(env.store, note.id).isEmpty)

        env.recorderClock.advance(by: .seconds(300))
        await recorder.idleTask?.value
        #expect(try Self.texts(env.store, note.id) == ["startab"])
    }

    @Test func changesFromElsewhereDoNotStartTheIdleTimer() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        _ = try env.store.updateText(id: note.id, text: "from sync", expectedRevision: note.revision, now: Self.start)
        #expect(try session.handleExternalChange() == .adopted)
        #expect(recorder.idleTask == nil)
        env.recorderClock.advance(by: .seconds(1800))
        await Self.settle()
        #expect(try Self.texts(env.store, note.id).isEmpty)
    }

    @Test func anEditThatChangesNothingTakesNoIdleSnapshot() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.edit(deletingLast: 0, from: session)  // acknowledged and reported as an edit, same text
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value
        #expect(try Self.texts(env.store, note.id).isEmpty)

        // Typed and taken back again: the text is the one the note opened with.
        Self.type("x", into: session)
        Self.edit(deletingLast: 1, from: session)
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value
        #expect(try Self.texts(env.store, note.id).isEmpty)
    }

    @Test func anIdleSnapshotIsSkippedWhenTheTextIsTheOneAlreadyRecorded() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.type("!", into: session)
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value
        // The session has long committed "start!"; going back to it later is still no news.
        Self.type("?", into: session)
        Self.edit(deletingLast: 1, from: session)
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value
        #expect(try Self.texts(env.store, note.id) == ["start!"])
    }

    @Test func anEmptyNewNoteOpenedAndClosedRecordsNothing() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "")
        let recorder = env.recorder(try env.session(note.id)); defer { recorder.stop() }

        recorder.sessionWillClose()
        recorder.sessionWillClose()
        #expect(try Self.texts(env.store, note.id).isEmpty)
    }

    @Test func clearingANoteIsStillRecordedOnClose() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.edit(deletingLast: 5, from: session)
        #expect(session.text.isEmpty)
        recorder.sessionWillClose()
        #expect(try Self.texts(env.store, note.id) == [""])
    }

    // MARK: close

    @Test func closeTakesASnapshotOfTheText() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        Self.type("!", into: session)  // not committed yet: the store still holds "start"
        #expect(try env.store.note(id: note.id)?.text == "start")
        recorder.sessionWillClose()
        #expect(try Self.texts(env.store, note.id) == ["start!"])
        #expect(recorder.idleTask == nil)  // the pending idle snapshot is not needed any more
    }

    @Test func closeWithoutEditsAddsNothingWhenTheNewestIsEqual() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        _ = try env.store.takeSnapshot(noteId: note.id, text: "start", now: Self.start)
        let session = try env.session(note.id)
        let recorder = env.recorder(session); defer { recorder.stop() }

        recorder.sessionWillClose()
        recorder.sessionWillClose()
        #expect(try Self.texts(env.store, note.id) == ["start"])

        // An unedited note with no history yet gets its first snapshot, once.
        let other = try env.store.create(text: "other")
        let otherRecorder = env.recorder(try env.session(other.id)); defer { otherRecorder.stop() }
        otherRecorder.sessionWillClose()
        otherRecorder.sessionWillClose()
        #expect(try Self.texts(env.store, other.id) == ["other"])
    }

    // MARK: stop

    @Test func aStoppedRecorderRecordsNothing() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session)

        Self.type("!", into: session)
        recorder.stop()
        recorder.stop()
        #expect(recorder.idleTask == nil)
        env.recorderClock.advance(by: .seconds(1800))
        Self.type("?", into: session)
        env.recorderClock.advance(by: .seconds(1800))
        await Self.settle()
        recorder.sessionWillClose()
        #expect(try Self.texts(env.store, note.id).isEmpty)
    }

    // MARK: errors

    struct Failing: SnapshotWriting {
        struct Failure: Error, CustomStringConvertible {
            let text: String
            var description: String { "could not store: " + text }
        }
        func takeSnapshot(noteId: String, text: String, now: Date) throws -> NoteSnapshot? { throw Failure(text: text) }
    }

    @Test func writerErrorsAreSwallowedAndLoggedWithoutText() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let started = Date.now.addingTimeInterval(-1)
        let secret = "recordersecret" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let note = try env.store.create(text: "start")
        let session = try env.session(note.id)
        let recorder = env.recorder(session, writer: Failing()); defer { recorder.stop() }

        Self.type(secret, into: session)
        env.recorderClock.advance(by: .seconds(900))
        await recorder.idleTask?.value  // swallowed: the task finished normally
        recorder.sessionWillClose()  // swallowed too

        // The recorder is still alive: the next edit arms the timer again.
        Self.type("more", into: session)
        #expect(recorder.idleTask != nil)

        let noteId = note.id
        let messages = try await SnapshotPrivacyTests.logMessages(since: started) { @Sendable messages in
            messages.filter { $0.contains(noteId) && $0.contains("snapshot") }.count >= 2
        }
        #expect(messages.filter { $0.contains(noteId) }.count >= 2)  // one for the idle snapshot, one for the close
        #expect(!messages.contains { $0.contains(secret) })
    }

    // MARK: locked notes

    @Test func aLockedNoteIsNeverRecordedAsPlaintext() async throws {
        let env = try Env(); defer { env.library.cleanup() }
        let access = try env.library.access(); defer { access.revoke() }
        let secret = "lockedrecorder" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let note = try env.store.create(text: "# Private\nstart")
        try access.lock(noteId: note.id)
        let session = try NoteSession(noteId: note.id, store: access, journalDirectory: env.library.paths.journal,
                                      journalKey: access.journalKey(), clock: env.sessionClock)

        // The plain store refuses a locked note: nothing is written, and the recorder carries on.
        let plain = env.recorder(session)
        Self.type(secret, into: session)
        env.recorderClock.advance(by: .seconds(900))
        await plain.idleTask?.value
        plain.sessionWillClose()
        plain.stop()
        let rows = try await env.library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_snapshot")! }
        #expect(rows == 0)

        // The locked-note access seals it.
        let sealed = env.recorder(session, writer: access); defer { sealed.stop() }
        sealed.sessionWillClose()
        let stored = try SnapshotPrivacyTests.stored(note.id, in: env.library.db)
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { $0.text == nil && $0.sealed != nil })
        #expect(try access.snapshotText(id: try #require(stored.first).id) == "# Private\nstart" + secret)
    }
}
