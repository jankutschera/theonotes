// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@MainActor
@Suite struct NoteSessionTests {
    /// File-backed database (so a second NoteStore can act as an external writer) plus a journal dir.
    final class Env {
        let root: URL
        let storeA: NoteStore
        let storeB: NoteStore
        let dbURL: URL
        var journalDir: URL { root.appendingPathComponent("Journal", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("baerchen-session-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            dbURL = root.appendingPathComponent("Baerchen.sqlite")
            storeA = NoteStore(db: try AppDatabase(path: dbURL), notifier: nil, paths: AppPaths(root: root))
            storeB = NoteStore(db: try AppDatabase(path: dbURL), notifier: nil, paths: AppPaths(root: root))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes `text` (and bumps the revision) bypassing NoteStore, e.g. a row stored with CRs.
        func writeRaw(_ noteId: String, _ text: String) throws {
            try AppDatabase(path: dbURL).pool.write { db in
                try db.execute(
                    sql: "UPDATE note SET text = ?, revision = revision + 1 WHERE id = ?", arguments: [text, noteId]
                )
            }
        }

        func journalEntries(_ noteId: String) throws -> [JournalEntry] {
            try EditJournal(directory: journalDir, noteId: noteId).entries()
        }
    }

    private func insert(at pos: Int, _ s: String, length: Int) -> ChangeSet {
        var sections: [ChangeSet.Section] = []
        if pos > 0 { sections.append(.retain(pos)) }
        sections.append(.replace(deleteLength: 0, insert: s))
        if length - pos > 0 { sections.append(.retain(length - pos)) }
        return ChangeSet(sections: sections)
    }

    private func replace(_ text: String, _ target: String, with replacement: String) -> ChangeSet {
        let ns = text as NSString
        let range = ns.range(of: target)
        var sections: [ChangeSet.Section] = []
        if range.location > 0 { sections.append(.retain(range.location)) }
        sections.append(.replace(deleteLength: range.length, insert: replacement))
        let tail = ns.length - range.location - range.length
        if tail > 0 { sections.append(.retain(tail)) }
        return ChangeSet(sections: sections)
    }

    /// R15: the app tells the editor's typing from changes made elsewhere by these reports.
    @Test func testActivityReportsEditsCommitsAndExternalChanges() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "Title\n\nbody")
        let session = try NoteSession(noteId: note.id, store: env.storeA, journalDirectory: env.journalDir)
        var log: [String] = []
        let listener = session.addActivityListener { activity in
            switch activity {
            case .edited: log.append("edited")
            case .committed(let text, _): log.append("committed \(text)")
            case .externalChange(let previous, let text, _): log.append("external \(previous) -> \(text)")
            }
        }

        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: replace("Title\n\nbody", "Title", with: "Mine"), origin: nil) == .acked(revision: 1))
        try session.flush()
        #expect(log == ["edited", "committed Mine\n\nbody"])

        // Clean session: an external write is adopted.
        log = []
        var current = try #require(try env.storeB.note(id: note.id))
        _ = try env.storeB.updateText(id: note.id, text: "Cli\n\nbody", expectedRevision: current.revision)
        #expect(try session.handleExternalChange() == .adopted)
        #expect(log == ["external Mine\n\nbody -> Cli\n\nbody"])

        // Unsaved typing: the external change is reported alone, then the merged commit.
        log = []
        #expect(session.apply(txId: "t2", baseRevision: 2, changeSet: replace("Cli\n\nbody", "body", with: "body!"), origin: nil) == .acked(revision: 3))
        current = try #require(try env.storeB.note(id: note.id))
        _ = try env.storeB.updateText(id: note.id, text: "Other\n\nbody", expectedRevision: current.revision)
        #expect(try session.handleExternalChange() == .merged)
        #expect(log == ["edited", "external Cli\n\nbody -> Other\n\nbody", "committed Other\n\nbody!"])

        // A conflict keeps the external text in a copy: only the session's commit is reported.
        log = []
        #expect(session.apply(txId: "t3", baseRevision: 4, changeSet: replace("Other\n\nbody!", "Other", with: "Local"), origin: nil) == .acked(revision: 5))
        current = try #require(try env.storeB.note(id: note.id))
        _ = try env.storeB.updateText(id: note.id, text: "Remote\n\nbody!", expectedRevision: current.revision)
        guard case .conflictCopy = try session.handleExternalChange() else {
            Issue.record("expected a conflict copy")
            return
        }
        #expect(log == ["edited", "committed Local\n\nbody!"])

        // Several listeners; a removed one, and all after `removeAllListeners`, hear nothing.
        var second = 0
        _ = session.addActivityListener { _ in second += 1 }
        session.removeListener(listener)
        log = []
        let text = session.text
        _ = session.apply(txId: "t4", baseRevision: session.revision, changeSet: insert(at: 0, "x", length: text.utf16.count), origin: nil)
        #expect(log.isEmpty && second == 1)
        #expect(session.textListenerCount == 0)  // activity listeners are not editors
        session.removeAllListeners()
        _ = session.apply(txId: "t5", baseRevision: session.revision, changeSet: insert(at: 0, "y", length: text.utf16.count + 1), origin: nil)
        #expect(second == 1)
    }

    @Test func testApplyAcksAndJournalsBeforeCommit() async throws {
        let env = try Env()
        let note = try env.storeA.create(text: "")
        let clock = TestClock()
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: clock
        )
        #expect(session.revision == 0)
        let result = session.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 0, "Hi 👩‍👩‍👧", length: 0), origin: nil)
        #expect(result == .acked(revision: 1))
        #expect(session.text == "Hi 👩‍👩‍👧")
        #expect(try env.journalEntries(note.id).count == 1)
        #expect(try env.storeA.note(id: note.id)?.text == "")

        clock.advance(by: .milliseconds(399))
        for _ in 0..<20 { await Task.yield() }
        #expect(try env.storeA.note(id: note.id)?.text == "")
        #expect(try env.journalEntries(note.id).count == 1)

        clock.advance(by: .milliseconds(1))
        await session.commitTask?.value
        #expect(try env.storeA.note(id: note.id)?.text == "Hi 👩‍👩‍👧")
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(session.committedText == "Hi 👩‍👩‍👧")
        #expect(session.committedStoreRevision == 2)
    }

    @Test func testEachApplyReschedulesCommit() async throws {
        let env = try Env()
        let note = try env.storeA.create(text: "")
        let clock = TestClock()
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: clock
        )
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 0, "a", length: 0), origin: nil)
        clock.advance(by: .milliseconds(300))
        _ = session.apply(txId: "t2", baseRevision: 1, changeSet: insert(at: 1, "b", length: 1), origin: nil)
        clock.advance(by: .milliseconds(300))
        for _ in 0..<20 { await Task.yield() }
        #expect(try env.storeA.note(id: note.id)?.text == "")
        clock.advance(by: .milliseconds(100))
        await session.commitTask?.value
        #expect(try env.storeA.note(id: note.id)?.text == "ab")
    }

    @Test func testDuplicateTxIdIsIdempotent() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        let cs = insert(at: 1, "y", length: 1)
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: cs, origin: nil) == .acked(revision: 1))
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: cs, origin: nil) == .duplicate(revision: 1))
        #expect(session.text == "xy")
        #expect(session.revision == 1)
        #expect(try env.journalEntries(note.id).count == 1)
    }

    @Test func testBaseRevisionMismatchIsRejected() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        #expect(session.apply(txId: "t1", baseRevision: 3, changeSet: insert(at: 1, "y", length: 1), origin: nil)
            == .needsFullText(currentRevision: 0))
        // Changeset whose length does not match the document is rejected the same way.
        #expect(session.apply(txId: "t2", baseRevision: 0, changeSet: insert(at: 0, "y", length: 5), origin: nil)
            == .needsFullText(currentRevision: 0))
        #expect(session.text == "x")
        #expect(session.revision == 0)
        #expect(try env.journalEntries(note.id).isEmpty)
        // A rejected txId is not remembered: resending it on the right base is applied.
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 1, "y", length: 1), origin: nil)
            == .acked(revision: 1))
    }

    @Test func testFlushCommitsPendingText() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "")
        let session = try NoteSession(noteId: note.id, store: env.storeA, journalDirectory: env.journalDir)
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 0, "typed", length: 0), origin: nil)
        try session.flush()
        #expect(try env.storeA.note(id: note.id)?.text == "typed")
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(session.commitTask == nil)
        // Flushing a clean session is a no-op (no extra store revision).
        try session.flush()
        #expect(try env.storeA.note(id: note.id)?.revision == 2)
    }

    @Test func testRecoveryReplaysJournal() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "")
        let alphabet = Array("ab漢😀\n")
        var expected = ""
        do {
            let session = try NoteSession(
                noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
            )
            for i in 0..<100 {
                let ch = String(alphabet[i % alphabet.count])
                let len = expected.utf16.count
                let result = session.apply(
                    txId: "t\(i)", baseRevision: i, changeSet: insert(at: len, ch, length: len), origin: nil
                )
                #expect(result == .acked(revision: i + 1))
                expected += ch
            }
            #expect(try env.storeA.note(id: note.id)?.text == "")
        }
        #expect(try env.journalEntries(note.id).count == 100)

        let recovered = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        #expect(recovered.text == expected)
        #expect(try env.storeA.note(id: note.id)?.text == expected)
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(recovered.committedText == expected)
    }

    @Test func testExternalChangeWithoutLocalEditsIsAdopted() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "hello\nworld 漢字")
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        var replaced: [(String, ChangeSet)] = []
        _ = session.addTextListener { replaced.append(($0, $1)) }

        #expect(try session.handleExternalChange() == .unchanged)
        #expect(replaced.isEmpty)

        _ = try env.storeB.updateText(id: note.id, text: "hello\nthere 👩‍👩‍👧 漢字", expectedRevision: 1)
        #expect(try session.handleExternalChange() == .adopted)
        #expect(session.text == "hello\nthere 👩‍👩‍👧 漢字")
        #expect(session.committedText == "hello\nthere 👩‍👩‍👧 漢字")
        #expect(session.committedStoreRevision == 2)
        #expect(session.revision == 1)
        #expect(replaced.count == 1)
        #expect(replaced[0].0 == "hello\nthere 👩‍👩‍👧 漢字")
        #expect(try replaced[0].1.apply(to: "hello\nworld 漢字") == "hello\nthere 👩‍👩‍👧 漢字")

        // A revision bump without a text change re-bases silently.
        _ = try env.storeB.updateText(id: note.id, text: "hello\nthere 👩‍👩‍👧 漢字", expectedRevision: 2)
        #expect(try session.handleExternalChange() == .unchanged)
        #expect(session.committedStoreRevision == 3)
        #expect(session.revision == 1)
        #expect(replaced.count == 1)

        // JS continues on the adopted revision.
        #expect(session.apply(txId: "t1", baseRevision: 1, changeSet: insert(at: 0, "> ", length: session.text.utf16.count), origin: nil)
            == .acked(revision: 2))
    }

    @Test func testExternalChangeWithLocalEditsMergesCleanly() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        var replaced: [(String, ChangeSet)] = []
        let editor = session.addTextListener { replaced.append(($0, $1)) }

        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: editor)
            == .acked(revision: 1))
        _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3", expectedRevision: 1)

        #expect(try session.handleExternalChange() == .merged)
        let merged = "LOCAL1\nline2\nREMOTE3"
        #expect(session.text == merged)
        #expect(session.revision == 2)
        #expect(try env.storeA.note(id: note.id)?.text == merged)
        #expect(session.committedText == merged)
        #expect(session.committedStoreRevision == 3)
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(replaced.count == 1)
        #expect(try replaced[0].1.apply(to: "LOCAL1\nline2\nline3") == merged)
    }

    @Test func testExternalChangeWithLocalEditsCreatesConflictCopy() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        var replacedCount = 0
        let editor = session.addTextListener { _, _ in replacedCount += 1 }

        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line2", with: "local2"), origin: editor)
        let remote = "line1\nremote2\nline3"
        _ = try env.storeB.updateText(id: note.id, text: remote, expectedRevision: 1)

        let outcome = try session.handleExternalChange()
        guard case .conflictCopy(let copyId) = outcome else {
            Issue.record("expected conflictCopy, got \(outcome)")
            return
        }
        let local = "line1\nlocal2\nline3"
        #expect(copyId != note.id)
        #expect(session.text == local)
        #expect(session.revision == 1)
        #expect(replacedCount == 0)
        #expect(try env.storeA.note(id: note.id)?.text == local)
        #expect(try env.storeA.note(id: copyId)?.text == remote)
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(session.committedText == local)
    }

    @Test func testFlushCommitsWhenExternalWriteLeftTextUnchanged() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "base")
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 4, "!", length: 4), origin: nil)
        _ = try env.storeB.updateText(id: note.id, text: "base", expectedRevision: 1)
        try session.flush()
        #expect(try env.storeA.note(id: note.id)?.text == "base!")
        #expect(session.committedText == "base!")
        #expect(session.revision == 1)
        #expect(try env.journalEntries(note.id).isEmpty)
    }

    @Test func testFlushOnRevisionConflictMergesExternalChange() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let session = try NoteSession(
            noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock()
        )
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: nil)
        _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3", expectedRevision: 1)
        try session.flush()
        #expect(try env.storeA.note(id: note.id)?.text == "LOCAL1\nline2\nREMOTE3")
        #expect(session.text == "LOCAL1\nline2\nREMOTE3")
        #expect(try env.journalEntries(note.id).isEmpty)
    }

    // MARK: - Recovery anchored on the journal base (R6)

    private func session(_ env: Env, _ noteId: String) throws -> NoteSession {
        try NoteSession(noteId: noteId, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock())
    }

    private struct InjectedFault: Error {}

    @Test func testCrashBetweenCommitAndTruncateDoesNotCorrupt() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "abcd")
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "e1", baseRevision: 0, changeSet: insert(at: 0, "X", length: 4), origin: nil)
            _ = s.apply(txId: "e2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 1, insert: "")]), origin: nil)
            #expect(s.text == "Xabc")
            // Truncation never happens: the state a kill right after store.updateText leaves behind.
            s.journal.faultInjector = { op, _ in if case .truncate = op { throw InjectedFault() } }
            try s.flush()
            #expect(try env.storeA.note(id: note.id)?.text == "Xabc")
            #expect(try env.journalEntries(note.id).count == 2)
        }
        let revisionBefore = try #require(try env.storeA.note(id: note.id)).revision
        let recovered = try session(env, note.id)
        #expect(recovered.text == "Xabc")
        #expect(try env.storeA.note(id: note.id)?.text == "Xabc")
        #expect(try env.storeA.note(id: note.id)?.revision == revisionBefore)
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: recovered.journal.baseURL.path))
        #expect(try env.storeA.allNotes().count == 1)
    }

    @Test func testRecoveryMergesExternalWriteMadeBeforeReplay() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: nil)
        }
        _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3", expectedRevision: 1)
        let recovered = try session(env, note.id)
        #expect(recovered.text == "LOCAL1\nline2\nREMOTE3")
        #expect(try env.storeA.note(id: note.id)?.text == "LOCAL1\nline2\nREMOTE3")
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(try env.storeA.allNotes().count == 1)
    }

    @Test func testRecoveryCreatesConflictCopyForExternalWriteMadeBeforeReplay() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line2", with: "local2"), origin: nil)
        }
        let remote = "line1\nremote2\nline3"
        _ = try env.storeB.updateText(id: note.id, text: remote, expectedRevision: 1)
        let recovered = try session(env, note.id)
        let local = "line1\nlocal2\nline3"
        #expect(recovered.text == local)
        #expect(try env.storeA.note(id: note.id)?.text == local)
        let others = try env.storeA.allNotes().filter { $0.id != note.id }
        #expect(others.map(\.text) == [remote])
        #expect(try env.journalEntries(note.id).isEmpty)
    }

    @Test func testReplayFailureMovesJournalAsideAndKeepsData() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "ab")
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "good", baseRevision: 0, changeSet: insert(at: 2, "c", length: 2), origin: nil)
        }
        // An entry that cannot apply to base + earlier entries.
        try EditJournal(directory: env.journalDir, noteId: note.id)
            .append(JournalEntry(txId: "bad", baseRevision: 1, changeSet: insert(at: 0, "X", length: 9)))

        let recovered = try session(env, note.id)
        #expect(recovered.text == "ab")
        #expect(try env.storeA.note(id: note.id)?.text == "ab")
        #expect(try env.journalEntries(note.id).isEmpty)
        let asideJournal = env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed")
        let asideBase = env.journalDir.appendingPathComponent("\(note.id).base.unreplayed")
        let kept = try String(contentsOf: asideJournal, encoding: .utf8)
        #expect(kept.contains("\"good\"") && kept.contains("\"bad\""))
        #expect(try JSONDecoder().decode(JournalBase.self, from: Data(contentsOf: asideBase)).baseText == "ab")
        // The fresh journal works.
        #expect(recovered.apply(txId: "n1", baseRevision: 0, changeSet: insert(at: 2, "!", length: 2), origin: nil) == .acked(revision: 1))
        #expect(try env.journalEntries(note.id).map(\.txId) == ["n1"])
    }

    @Test func testAppendFailureIsNotAckedAndLeavesNoResidue() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let s = try session(env, note.id)
        _ = s.apply(txId: "t0", baseRevision: 0, changeSet: insert(at: 1, "y", length: 1), origin: nil)
        s.journal.faultInjector = { op, _ in if case .synchronize = op { throw InjectedFault() } }
        #expect(s.apply(txId: "t1", baseRevision: 1, changeSet: insert(at: 2, "z", length: 2), origin: nil)
            == .needsFullText(currentRevision: 1))
        #expect(s.text == "xy")
        #expect(try env.journalEntries(note.id).map(\.txId) == ["t0"])
        s.journal.faultInjector = nil
        #expect(s.apply(txId: "t1", baseRevision: 1, changeSet: insert(at: 2, "z", length: 2), origin: nil) == .acked(revision: 2))
        #expect(try env.journalEntries(note.id).map(\.txId) == ["t0", "t1"])
    }

    @Test func testPoisonedJournalRefusesAcksUntilReset() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let s = try session(env, note.id)
        s.journal.faultInjector = { op, handle in
            switch op {
            case .write(let data):
                try handle.write(contentsOf: data.prefix(data.count / 2))
                throw InjectedFault()
            case .truncate: throw InjectedFault()
            case .synchronize, .synchronizeTruncation: break
            }
        }
        #expect(s.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 1, "y", length: 1), origin: nil)
            == .needsFullText(currentRevision: 0))
        #expect(s.journal.isPoisoned)
        // Writes work again but the journal still cannot be reset: no ack.
        s.journal.faultInjector = { op, _ in if case .truncate = op { throw InjectedFault() } }
        #expect(s.apply(txId: "t2", baseRevision: 0, changeSet: insert(at: 1, "y", length: 1), origin: nil)
            == .needsFullText(currentRevision: 0))
        s.journal.faultInjector = nil
        #expect(s.apply(txId: "t3", baseRevision: 0, changeSet: insert(at: 1, "y", length: 1), origin: nil) == .acked(revision: 1))
        #expect(!s.journal.isPoisoned)
        #expect(try env.journalEntries(note.id).map(\.txId) == ["t3"])
    }

    @Test func testTruncateFailureDuringMergeKeepsRemoteEdits() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let merged = "LOCAL1\nline2\nREMOTE3"
        do {
            let s = try session(env, note.id)
            s.journal.faultInjector = { op, _ in if case .truncate = op { throw InjectedFault() } }
            _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: nil)
            _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3", expectedRevision: 1)
            #expect(try s.handleExternalChange() == .merged)
            #expect(s.text == merged)
            #expect(try env.storeA.note(id: note.id)?.text == merged)
            let len = s.text.utf16.count
            // Truncation keeps failing: the journal is broken, so nothing is acked.
            #expect(s.apply(txId: "t2", baseRevision: 2, changeSet: insert(at: len, "!", length: len), origin: nil)
                == .needsFullText(currentRevision: 2))
            s.journal.faultInjector = nil
            #expect(s.apply(txId: "t2", baseRevision: 2, changeSet: insert(at: len, "!", length: len), origin: nil) == .acked(revision: 3))
            #expect(try replayJournal(env, note.id) == s.text)
            // Killed before the next commit: "!" exists only in the journal.
        }
        #expect(try env.storeA.note(id: note.id)?.text == merged)
        let recovered = try session(env, note.id)
        let aside = env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed")
        #expect(!FileManager.default.fileExists(atPath: aside.path))
        #expect(recovered.text == merged + "!")
        #expect(try env.storeA.note(id: note.id)?.text == merged + "!")
        #expect(try env.journalEntries(note.id).isEmpty)
        #expect(try env.storeA.allNotes().count == 1)
    }

    @Test func testRepeatedConflictsStopAfterThreeAttempts() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let s = try session(env, note.id)
        _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: nil)
        _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3-0", expectedRevision: 1)
        var bumps = 0
        s.beforeCommitForTesting = {
            bumps += 1
            let current = try! #require(try env.storeB.note(id: note.id))
            _ = try! env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3-\(bumps)", expectedRevision: current.revision)
        }
        #expect(throws: StoreError.revisionConflict(current: 5)) { try s.handleExternalChange() }
        #expect(bumps == 3)
        #expect(s.text == "LOCAL1\nline2\nline3")
        #expect(try env.journalEntries(note.id).map(\.txId) == ["t1"])
    }

    // MARK: - Fix round 2

    /// base.baseText + entries, i.e. what recovery would replay.
    private func replayJournal(_ env: Env, _ noteId: String) throws -> String? {
        let journal = try EditJournal(directory: env.journalDir, noteId: noteId)
        guard let base = try journal.base() else { return nil }
        return try journal.entries().reduce(base.baseText) { try $1.changeSet.apply(to: $0) }
    }

    @Test func testHalfSucceededTruncateThenEditsThenRelaunch() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "abcd")
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "e1", baseRevision: 0, changeSet: insert(at: 0, "X", length: 4), origin: nil)
            _ = s.apply(txId: "e2", baseRevision: 1, changeSet: insert(at: 5, "Y", length: 5), origin: nil)
            // ftruncate succeeds, the fsync after it fails: file is empty but the session can't know.
            s.journal.faultInjector = { op, _ in if case .synchronizeTruncation = op { throw InjectedFault() } }
            try s.flush()
            #expect(try env.storeA.note(id: note.id)?.text == "XabcdY")
            #expect(try s.journal.isEmpty())
            #expect(s.apply(txId: "e3", baseRevision: 2, changeSet: insert(at: 6, "Z", length: 6), origin: nil)
                == .needsFullText(currentRevision: 2))
            s.journal.faultInjector = nil
            #expect(s.apply(txId: "e3", baseRevision: 2, changeSet: insert(at: 6, "Z", length: 6), origin: nil) == .acked(revision: 3))
            #expect(try s.journal.base()?.baseText == "XabcdY")
            #expect(try replayJournal(env, note.id) == "XabcdYZ")
        }
        let recovered = try session(env, note.id)
        #expect(recovered.text == "XabcdYZ")
        #expect(try env.storeA.note(id: note.id)?.text == "XabcdYZ")
        #expect(!FileManager.default.fileExists(atPath: env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed").path))
    }

    @Test func testBaseIsRewrittenWhenJournalFileIsEmpty() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "ab")
        let s = try session(env, note.id)
        _ = s.apply(txId: "e1", baseRevision: 0, changeSet: insert(at: 2, "c", length: 2), origin: nil)
        // The file got emptied (and the base removed) while the session still believes it has
        // entries, the state a truncate that failed after shortening the file leaves behind.
        try s.journal.truncate()
        _ = s.apply(txId: "e2", baseRevision: 1, changeSet: insert(at: 3, "d", length: 3), origin: nil)
        #expect(try s.journal.base()?.baseText == "abc")
        #expect(try replayJournal(env, note.id) == "abcd")
    }

    @Test func testFailedTruncateAfterRecoveryMergeThenEditsThenRelaunch() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: nil)
        }
        _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3", expectedRevision: 1)
        let merged = "LOCAL1\nline2\nREMOTE3"
        do {
            let s = try NoteSession(
                noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: TestClock(),
                journalFaultInjector: { op, _ in if case .truncate = op { throw InjectedFault() } }
            )
            #expect(s.text == merged)
            #expect(try env.storeA.note(id: note.id)?.text == merged)
            // The recovery merge is journaled, so the stale journal still reproduces `text`.
            #expect(try replayJournal(env, note.id) == merged)
            let len = merged.utf16.count, rev = s.revision
            #expect(s.apply(txId: "t2", baseRevision: rev, changeSet: insert(at: len, "!", length: len), origin: nil)
                == .needsFullText(currentRevision: rev))
            s.journal.faultInjector = nil
            #expect(s.apply(txId: "t2", baseRevision: rev, changeSet: insert(at: len, "!", length: len), origin: nil) == .acked(revision: rev + 1))
            #expect(try replayJournal(env, note.id) == merged + "!")
        }
        let recovered = try session(env, note.id)
        #expect(recovered.text == merged + "!")
        #expect(try env.storeA.note(id: note.id)?.text == merged + "!")
        #expect(try env.storeA.allNotes().count == 1)
        #expect(!FileManager.default.fileExists(atPath: env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed").path))
    }

    @Test func testSyntheticAppendOnPoisonedJournalIsRefused() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let s = try session(env, note.id)
        _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line1", with: "LOCAL1"), origin: nil)
        // Poison: torn write that cannot be rolled back.
        s.journal.faultInjector = { op, handle in
            switch op {
            case .write(let data):
                try handle.write(contentsOf: data.prefix(data.count / 2))
                throw InjectedFault()
            case .truncate: throw InjectedFault()
            case .synchronize, .synchronizeTruncation: break
            }
        }
        _ = s.apply(txId: "t2", baseRevision: 1, changeSet: insert(at: 0, "#", length: 18), origin: nil)
        #expect(s.journal.isPoisoned)
        // Writes would succeed now; only truncation fails. No synthetic entry may be appended.
        var writes = 0
        s.journal.faultInjector = { op, _ in
            if case .write = op { writes += 1 }
            if case .truncate = op { throw InjectedFault() }
        }
        _ = try env.storeB.updateText(id: note.id, text: "line1\nline2\nREMOTE3", expectedRevision: 1)
        #expect(try s.handleExternalChange() == .merged)
        #expect(writes == 0)
        #expect(s.text == "LOCAL1\nline2\nREMOTE3")
        #expect(try env.storeA.note(id: note.id)?.text == "LOCAL1\nline2\nREMOTE3")
        s.journal.faultInjector = nil
        #expect(s.apply(txId: "t3", baseRevision: 2, changeSet: insert(at: 0, "#", length: 20), origin: nil) == .acked(revision: 3))
        #expect(try replayJournal(env, note.id) == "#LOCAL1\nline2\nREMOTE3")
    }

    @Test func testMissingBaseMovesJournalAside() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "ab")
        try EditJournal(directory: env.journalDir, noteId: note.id)
            .append(JournalEntry(txId: "orphan", baseRevision: 0, changeSet: insert(at: 2, "c", length: 2)))
        let recovered = try session(env, note.id)
        #expect(recovered.text == "ab")
        #expect(try env.storeA.note(id: note.id)?.text == "ab")
        #expect(try env.journalEntries(note.id).isEmpty)
        let aside = env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed")
        #expect(try String(contentsOf: aside, encoding: .utf8).contains("\"orphan\""))
        #expect(!FileManager.default.fileExists(atPath: env.journalDir.appendingPathComponent("\(note.id).base.unreplayed").path))
    }

    // MARK: - Line endings, byte-exact dirty checks, journal format

    @Test func testCRLFStoredNoteOpensNormalizedAndEditsRoundTrip() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "")
        try env.writeRaw(note.id, "a\r\nb")
        let s = try session(env, note.id)
        #expect(s.text == "a\nb")
        #expect(s.text.utf16.count == 3) // what CodeMirror's EditorState holds for "a\r\nb"
        // The editor's changeset is computed on its 3-unit document.
        #expect(s.apply(txId: "t1", baseRevision: 0, changeSet: insert(at: 3, "X", length: 3), origin: nil) == .acked(revision: 1))
        #expect(s.text == "a\nbX")
        try s.flush()
        #expect(try env.storeA.note(id: note.id)?.text == "a\nbX")
    }

    @Test func testExternalCRLFWriteIsAdoptedNormalized() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "one\ntwo")
        let s = try session(env, note.id)
        var replaced: [(String, ChangeSet)] = []
        let editor = s.addTextListener { replaced.append(($0, $1)) }
        try env.writeRaw(note.id, "one\r\ntwo\r\nthree\r")
        #expect(try s.handleExternalChange() == .adopted)
        #expect(s.text == "one\ntwo\nthree\n")
        #expect(replaced.count == 1)
        #expect(try replaced[0].1.apply(to: "one\ntwo") == "one\ntwo\nthree\n")
        #expect(s.apply(txId: "t1", baseRevision: 1, changeSet: insert(at: 14, "!", length: 14), origin: editor) == .acked(revision: 2))

        // A CR-only rewrite of the same text is not a text change.
        try s.flush()
        let stored = try #require(try env.storeA.note(id: note.id))
        try env.writeRaw(note.id, stored.text.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(try s.handleExternalChange() == .unchanged)
        #expect(replaced.count == 1)
    }

    @Test func testNormalizationOnlyChangeIsCommitted() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "caf\u{E9}") // NFC
        let s = try session(env, note.id)
        // Replace "é" (1 unit) with "e" + combining acute (2 units): canonically equal, bytes differ.
        let cs = ChangeSet(sections: [.retain(3), .replace(deleteLength: 1, insert: "e\u{301}")])
        #expect(s.apply(txId: "t1", baseRevision: 0, changeSet: cs, origin: nil) == .acked(revision: 1))
        try s.flush()
        let stored = try #require(try env.storeA.note(id: note.id))
        #expect(Array(stored.text.utf8) == Array("cafe\u{301}".utf8))
        #expect(try env.journalEntries(note.id).isEmpty)
    }

    @Test func testUndecodableMiddleLineMovesJournalAside() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "ab")
        do {
            let s = try session(env, note.id)
            #expect(s.apply(txId: "e1", baseRevision: 0, changeSet: insert(at: 2, "c", length: 2), origin: nil) == .acked(revision: 1))
        }
        let url = env.journalDir.appendingPathComponent("\(note.id).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"txId\":garbage\n".utf8))
        try handle.close()
        try EditJournal(directory: env.journalDir, noteId: note.id)
            .append(JournalEntry(txId: "e3", baseRevision: 2, changeSet: insert(at: 3, "d", length: 3)))

        let recovered = try session(env, note.id)
        #expect(recovered.text == "ab") // not "abcd" with the middle line silently skipped
        #expect(try env.storeA.note(id: note.id)?.text == "ab")
        let aside = env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed")
        #expect(try String(contentsOf: aside, encoding: .utf8).contains("garbage"))
        #expect(recovered.apply(txId: "n1", baseRevision: 0, changeSet: insert(at: 2, "!", length: 2), origin: nil) == .acked(revision: 1))
    }

    @Test func testUnknownJournalVersionMovesJournalAside() throws {
        for file in ["jsonl", "base"] {
            let env = try Env()
            let note = try env.storeA.create(text: "ab")
            do {
                let s = try session(env, note.id)
                #expect(s.apply(txId: "e1", baseRevision: 0, changeSet: insert(at: 2, "c", length: 2), origin: nil) == .acked(revision: 1))
            }
            let url = env.journalDir.appendingPathComponent("\(note.id).\(file)")
            let raw = try String(contentsOf: url, encoding: .utf8)
            #expect(raw.contains(#""v":1"#), "\(file) has no format version: \(raw)")
            try raw.replacingOccurrences(of: #""v":1"#, with: #""v":99"#).write(to: url, atomically: true, encoding: .utf8)

            let recovered = try session(env, note.id)
            #expect(recovered.text == "ab", "\(file)")
            #expect(try env.storeA.note(id: note.id)?.text == "ab")
            let aside = env.journalDir.appendingPathComponent("\(note.id).jsonl.unreplayed")
            #expect(FileManager.default.fileExists(atPath: aside.path), "\(file)")
        }
    }

    // MARK: - Conflict copy reporting (M1 Task 5)

    @Test func testConflictCopyIsReportedThroughCallback() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let session = try session(env, note.id)
        var reported: [String] = []
        _ = session.addConflictCopyListener { reported.append($0) }

        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line2", with: "local2"), origin: nil)
        _ = try env.storeB.updateText(id: note.id, text: "line1\nremote2\nline3", expectedRevision: 1)
        // flush() hits the revision conflict and resolves it through handleExternalChange().
        try session.flush()

        let copy = try #require(try env.storeA.allNotes().first { $0.id != note.id })
        #expect(reported == [copy.id])
        #expect(session.recoveryConflictCopyId == nil)
    }

    @Test func testRecoveryConflictCopyIsExposed() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        do {
            let s = try session(env, note.id)
            _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line2", with: "local2"), origin: nil)
        }
        _ = try env.storeB.updateText(id: note.id, text: "line1\nremote2\nline3", expectedRevision: 1)
        let recovered = try session(env, note.id)
        let copy = try #require(try env.storeA.allNotes().first { $0.id != note.id })
        #expect(recovered.recoveryConflictCopyId == copy.id)
    }

    // MARK: - Several editors on one session (M4 Task 9, Review Focus #5)

    /// An editor as the session sees it: its own document and revision, updated by forwarded
    /// changes like the web editor's `applyExternalChange` (which needs revision - 1 == its own).
    @MainActor
    final class FakeEditor {
        let session: NoteSession
        private(set) var doc: String
        private(set) var revision: Int
        private(set) var received = 0
        private(set) var outOfOrder = 0
        private(set) var token: NoteSession.ListenerToken?

        init(_ session: NoteSession) {
            self.session = session
            doc = session.text
            revision = session.revision
            token = session.addTextListener { [unowned self] _, changeSet in
                if self.session.revision - 1 != self.revision { self.outOfOrder += 1 }
                self.doc = (try? changeSet.apply(to: self.doc)) ?? "<unappliable>"
                self.revision = self.session.revision
                self.received += 1
            }
        }

        /// Types `s` at `pos` (default: the end) and sends the transaction like the editor does.
        @discardableResult
        func type(_ s: String, at pos: Int? = nil, txId: String) -> ApplyResult {
            let length = doc.utf16.count
            let at = pos ?? length
            var sections: [ChangeSet.Section] = []
            if at > 0 { sections.append(.retain(at)) }
            sections.append(.replace(deleteLength: 0, insert: s))
            if length - at > 0 { sections.append(.retain(length - at)) }
            let changeSet = ChangeSet(sections: sections)
            let base = revision
            doc = (try? changeSet.apply(to: doc)) ?? doc
            revision += 1
            return session.apply(txId: txId, baseRevision: base, changeSet: changeSet, origin: token)
        }

        func detach() {
            if let token { session.removeListener(token) }
            token = nil
        }
    }

    @Test func testLocalEditIsForwardedToOtherListenersButNotItsOrigin() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "hello")
        let s = try session(env, note.id)
        let a = FakeEditor(s)
        let b = FakeEditor(s)
        #expect(s.textListenerCount == 2)

        #expect(a.type(" world", txId: "a1") == .acked(revision: 1))
        #expect(a.received == 0)
        #expect(b.received == 1)
        #expect(b.doc == "hello world")
        #expect(b.revision == 1)
        #expect(b.outOfOrder == 0)

        // B continues on the forwarded revision; A receives B's edit.
        #expect(b.type("!", txId: "b1") == .acked(revision: 2))
        #expect(a.doc == "hello world!")
        #expect(a.revision == 2)
        #expect(s.text == "hello world!")
    }

    @Test func testSameNoteInTwoEditorsStaysInSyncWithoutConflictCopies() async throws {
        let env = try Env()
        let note = try env.storeA.create(text: "Shared\n")
        let clock = TestClock()
        let s = try NoteSession(noteId: note.id, store: env.storeA, journalDirectory: env.journalDir, clock: clock)
        var copies: [String] = []
        _ = s.addConflictCopyListener { copies.append($0) }
        let a = FakeEditor(s)
        let b = FakeEditor(s)

        for round in 0..<6 {
            #expect(a.type("a\(round) ", txId: "a\(round)") == .acked(revision: s.revision))
            #expect(b.type("b\(round)\n", at: 0, txId: "b\(round)") == .acked(revision: s.revision))
            if round.isMultiple(of: 2) {
                // A debounced commit lands between keystrokes, then its echo arrives.
                clock.advance(by: .milliseconds(400))
                await s.commitTask?.value
                #expect(try s.handleExternalChange() == .unchanged)
            }
        }
        try s.flush()
        #expect(try s.handleExternalChange() == .unchanged)

        #expect(a.doc == s.text)
        #expect(b.doc == s.text)
        #expect(a.revision == s.revision)
        #expect(b.revision == s.revision)
        #expect(a.outOfOrder == 0 && b.outOfOrder == 0)
        #expect(a.received == 6 && b.received == 6)
        #expect(copies.isEmpty)
        #expect(try env.storeA.allNotes().map(\.id) == [note.id])
        #expect(try env.storeA.note(id: note.id)?.text == s.text)
        #expect(try env.journalEntries(note.id).isEmpty)
    }

    @Test func testExternalChangeReachesEveryListener() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "one")
        let s = try session(env, note.id)
        let a = FakeEditor(s)
        let b = FakeEditor(s)
        _ = try env.storeB.updateText(id: note.id, text: "one two", expectedRevision: 1)
        #expect(try s.handleExternalChange() == .adopted)
        #expect(a.doc == "one two" && b.doc == "one two")
        #expect(a.revision == 1 && b.revision == 1)
        // A local edit from A after the external change still reaches B in order.
        #expect(a.type("!", txId: "a1") == .acked(revision: 2))
        #expect(b.doc == "one two!")
        #expect(b.outOfOrder == 0)
    }

    @Test func testApplyWithoutOrUnknownOriginForwardsToAll() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let s = try session(env, note.id)
        let a = FakeEditor(s)
        let gone = FakeEditor(s)
        let goneToken = try #require(gone.token)
        gone.detach()
        #expect(s.textListenerCount == 1)

        // E.g. a transaction typed just before the editor switched away from this note.
        let cs = ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "y")])
        #expect(s.apply(txId: "t1", baseRevision: 0, changeSet: cs, origin: goneToken) == .acked(revision: 1))
        #expect(a.doc == "xy")
        #expect(gone.received == 0)
        let cs2 = ChangeSet(sections: [.retain(2), .replace(deleteLength: 0, insert: "z")])
        #expect(s.apply(txId: "t2", baseRevision: 1, changeSet: cs2, origin: nil) == .acked(revision: 2))
        #expect(a.doc == "xyz")
    }

    @Test func testRejectedAndDuplicateTransactionsAreNotForwarded() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let s = try session(env, note.id)
        let a = FakeEditor(s)
        let b = FakeEditor(s)
        #expect(a.type("1", txId: "a1") == .acked(revision: 1))
        #expect(b.received == 1)
        // Same txId again (a resend): duplicate, not forwarded twice.
        let resend = ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "1")])
        #expect(s.apply(txId: "a1", baseRevision: 0, changeSet: resend, origin: a.token) == .duplicate(revision: 1))
        // Stale base revision: needsFullText, not forwarded.
        #expect(s.apply(txId: "a2", baseRevision: 0, changeSet: resend, origin: a.token) == .needsFullText(currentRevision: 1))
        #expect(b.received == 1)
        #expect(b.doc == "x1")
    }

    @Test func testListenerRemovingItselfDuringDeliveryIsSafe() throws {
        let env = try Env()
        let note = try env.storeA.create(text: "x")
        let s = try session(env, note.id)
        var calls: [String] = []
        var first: NoteSession.ListenerToken?
        first = s.addTextListener { _, _ in
            calls.append("first")
            if let first { s.removeListener(first) }
        }
        _ = s.addTextListener { _, _ in calls.append("second") }
        let cs = ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "y")])
        _ = s.apply(txId: "t1", baseRevision: 0, changeSet: cs, origin: nil)
        #expect(calls == ["first", "second"])
        #expect(s.textListenerCount == 1)
        s.removeListener(try #require(first)) // removing twice is harmless
        #expect(s.textListenerCount == 1)

        _ = s.addConflictCopyListener { _ in Issue.record("removed by removeAllListeners") }
        s.removeAllListeners()
        #expect(s.textListenerCount == 0)
        let cs2 = ChangeSet(sections: [.retain(2), .replace(deleteLength: 0, insert: "z")])
        _ = s.apply(txId: "t2", baseRevision: 1, changeSet: cs2, origin: nil)
        #expect(calls == ["first", "second"])
    }

    @Test func testConflictCopyIsReportedToEveryListener() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.storeA.create(text: base)
        let s = try session(env, note.id)
        var first: [String] = [], second: [String] = []
        _ = s.addConflictCopyListener { first.append($0) }
        let removed = s.addConflictCopyListener { _ in Issue.record("removed listener was called") }
        _ = s.addConflictCopyListener { second.append($0) }
        s.removeListener(removed)
        // Conflict-copy listeners are not editors.
        #expect(s.textListenerCount == 0)

        _ = s.apply(txId: "t1", baseRevision: 0, changeSet: replace(base, "line2", with: "local2"), origin: nil)
        _ = try env.storeB.updateText(id: note.id, text: "line1\nremote2\nline3", expectedRevision: 1)
        try s.flush()
        let copy = try #require(try env.storeA.allNotes().first { $0.id != note.id })
        #expect(first == [copy.id])
        #expect(second == [copy.id])
    }
}
