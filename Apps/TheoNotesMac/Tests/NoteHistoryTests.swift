// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// Focus layer C16: the history recorder wired into the app's sessions, the sealed snapshot at
/// relock, and the Note History model (spec A5, FOC-R11, FOC-R16, FOC-R290 … FOC-R299).
@MainActor
@Suite struct NoteHistoryTests {
    // MARK: Fixtures

    /// A temporary library with a real `AppEnvironment` and a hand-driven clock for the idle timer.
    @MainActor
    final class PlainEnv {
        let root = URL(fileURLWithPath: "/tmp/theo-history-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let clock = ManualVaultClock()
        let environment: AppEnvironment
        private nonisolated(unsafe) let pool: any DatabaseWriter

        init() throws {
            environment = try AppEnvironment(
                paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
                appLockLifecycle: nil, appIdleSeconds: { 0 })
            environment.snapshotClock = clock
            pool = environment.database.pool
        }

        deinit {
            try? pool.close()
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        /// The text of every version of `noteId`, newest first.
        func versions(_ noteId: String) throws -> [String] {
            try store.snapshots(noteId: noteId).map { try store.snapshotText(id: $0.id) }
        }

        /// No window shows any note: sessions nobody listens to are saved and dropped.
        func closeAllSessions() { environment.setOpenNoteIds([], for: ObjectIdentifier(self)) }
    }

    /// Closes the library's database before its folder goes.
    static func destroy(_ fixture: LockedFixture) {
        try? fixture.environment.database.pool.close()
        fixture.destroy()
    }

    /// Types `string` at the end of the session's text, as the editor would.
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

    /// Lets queued main-actor work run until `condition` holds (bounded).
    static func settle(until condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }

    struct SnapshotRow: Sendable {
        let noteId: String
        let text: String?
        let sealed: Data?
    }

    /// The `note_snapshot` rows as stored, optionally of one note.
    static func snapshotRows(_ database: AppDatabase, of noteId: String? = nil) throws -> [SnapshotRow] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT noteId, text, sealedText FROM note_snapshot")
                .map { SnapshotRow(noteId: $0["noteId"], text: $0["text"], sealed: $0["sealedText"]) }
        }.filter { noteId == nil || $0.noteId == noteId }
    }

    /// One integer from the library, e.g. a COUNT.
    static func scalar(_ database: AppDatabase, _ sql: String, _ arguments: [String] = []) throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: sql, arguments: StatementArguments(arguments)) ?? -1 }
    }

    static func noteCount(_ environment: AppEnvironment) throws -> Int {
        try environment.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") ?? -1 }
    }

    /// Every table, as sorted row descriptions, for "this wrote nothing".
    static func digest(_ database: AppDatabase) throws -> [String] {
        try database.pool.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
                """)
            return tables.flatMap { table in
                ((try? Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"")) ?? []).map { "\(table): \($0)" }.sorted()
            }
        }
    }

    // MARK: The recorder in the app's sessions

    @Test func closingASessionTakesASnapshot() throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "first draft")
        let session = try env.environment.session(for: note.id)
        #expect(env.environment.recorder(for: session) != nil)
        Self.type(" and more", into: session)
        #expect(try env.versions(note.id).isEmpty)

        env.closeAllSessions()

        #expect(env.environment.openSessionCount == 0 && env.environment.recorderCount == 0)
        #expect(try env.versions(note.id) == ["first draft and more"])
    }

    @Test func idleSnapshotUsesTheRecorder() async throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "idle draft")
        let session = try env.environment.session(for: note.id)
        Self.type(" typed", into: session)
        await env.clock.waitForSleeper()
        #expect(env.clock.sleeperCount == 1)
        #expect(try env.versions(note.id).isEmpty)

        env.clock.advance(by: SnapshotRecorder.idleInterval)
        await Self.settle { (try? env.versions(note.id).count) == 1 }

        #expect(try env.versions(note.id) == ["idle draft typed"])
        // The idle stretch yields one version; another quarter hour without typing adds none.
        env.clock.advance(by: SnapshotRecorder.idleInterval)
        await Task.yield()
        #expect(try env.versions(note.id).count == 1)
    }

    @Test func closedSessionsLeaveNoRecorder() throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "recovered")
        let session = try env.environment.session(for: note.id)
        env.closeAllSessions()
        #expect(env.environment.recorder(for: session) == nil)
        #expect(env.environment.recorderCount == 0)
    }

    @Test func lockingANoteSnapshotsItsOpenTextAndTheLockSealsIt() async throws {
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        // Remove Lock first, so the note is plain and has a session.
        let failures = await f.environment.changingLockState(of: [f.noteId]) { try f.vault.requireAccess().removeLock(noteId: $0) }
        #expect(failures.isEmpty)
        let session = try f.environment.session(for: f.noteId)
        Self.type(" extra", into: session)

        let locking = await f.environment.changingLockState(of: [f.noteId]) { try f.vault.requireAccess().lock(noteId: $0) }
        #expect(locking.isEmpty)

        let rows = try Self.snapshotRows(f.environment.database, of: f.noteId)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.text == nil && $0.sealed != nil })
        let access = try f.vault.requireAccess()
        let texts = try access.snapshots(noteId: f.noteId).map { try access.snapshotText(id: $0.id) }
        #expect(texts.contains { $0.hasSuffix(" extra") })
    }

    @Test func relockSnapshotsLockedSessionsBeforeTheKeyIsRevoked() async throws {
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        let session = try f.environment.session(for: f.noteId)
        #expect(f.environment.isKeyedSession(session))
        Self.type("\ntyped before relock", into: session)

        f.vault.relock()
        #expect(!f.vault.isUnlocked)

        // A sealed row exists, on disk, with no plaintext beside it.
        let rows = try Self.snapshotRows(f.environment.database, of: f.noteId)
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { $0.text == nil && $0.sealed != nil })

        // After the next unlock it opens with the typed text.
        try await f.environment.unlockNotes(password: LockedFixture.password)
        let access = try f.vault.requireAccess()
        let listed = try access.snapshots(noteId: f.noteId)
        let only = try #require(listed.first)
        #expect(listed.count == 1 && only.isSealed)
        #expect(try access.snapshotText(id: only.id) == f.text + "\ntyped before relock")
    }

    @Test func closingAKeyedSessionAfterRevokeDoesNotThrowOrWrite() async throws {
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        let session = try f.environment.session(for: f.noteId)
        #expect(f.environment.recorder(for: session) != nil)
        let before = try Self.digest(f.environment.database)

        // The key goes away without the will-relock pass (a revoke from elsewhere).
        try f.vault.requireAccess().revoke()
        f.environment.setOpenNoteIds([], for: ObjectIdentifier(f.environment))

        #expect(f.environment.openSessionCount == 0 && f.environment.recorderCount == 0)
        #expect(try Self.digest(f.environment.database) == before)
        let plain = try Self.scalar(f.environment.database, "SELECT COUNT(*) FROM note_snapshot WHERE text IS NOT NULL")
        #expect(plain == 0)
    }

    @Test func theRecorderPicksTheWriterByTheNoteLockState() async throws {
        // An unlocked note's session records plaintext rows; a locked note's session records sealed ones.
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        let plainNote = try f.environment.store.create(text: "a plain note")
        let plainSession = try f.environment.session(for: plainNote.id)
        let lockedSession = try f.environment.session(for: f.noteId)
        Self.type(" one", into: plainSession)
        Self.type(" two", into: lockedSession)

        f.environment.setOpenNoteIds([], for: ObjectIdentifier(f.environment))

        let plainRows = try Self.snapshotRows(f.environment.database, of: plainNote.id)
        let lockedRows = try Self.snapshotRows(f.environment.database, of: f.noteId)
        #expect(plainRows.count == 1 && plainRows.first?.text == "a plain note one" && plainRows.first?.sealed == nil)
        #expect(lockedRows.count == 1 && lockedRows.first?.text == nil && lockedRows.first?.sealed != nil)
    }

    @Test func lockedNoteSnapshotsAreSealedOnDisk() async throws {
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        let session = try f.environment.session(for: f.noteId)
        Self.type("\nzqxhistorymarker", into: session)
        f.environment.setOpenNoteIds([], for: ObjectIdentifier(f.environment))
        f.vault.relock()

        let marker = "zqxhistorymarker"
        let leaks = try Self.scalar(f.environment.database, """
            SELECT COUNT(*) FROM note_snapshot
             WHERE text IS NOT NULL OR instr(sealedText, CAST(? AS BLOB)) > 0 OR instr(sealedText, CAST(? AS BLOB)) > 0
            """, [marker, LockedFixture.secret])
        #expect(leaks == 0)
        let sealed = try Self.scalar(
            f.environment.database, "SELECT COUNT(*) FROM note_snapshot WHERE noteId = ? AND sealedText IS NOT NULL", [f.noteId])
        #expect(sealed >= 1)
    }

    // MARK: The model

    @Test func previewWritesNothing() throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "one")
        _ = try env.store.takeSnapshot(noteId: note.id, text: "version one", now: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try env.store.takeSnapshot(noteId: note.id, text: "version two", now: Date(timeIntervalSince1970: 1_800_000_100))
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        #expect(model.items.count == 2)
        let before = try Self.digest(env.environment.database)

        let older = try #require(model.items.last)
        let text = model.preview(older)

        #expect(text == "version one")
        #expect(model.previewText == "version one" && model.previewedId == older.id)
        #expect(try Self.digest(env.environment.database) == before)
    }

    @Test func theListFollowsTheTableWithoutAChangeNotification() async throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "one")
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        #expect(model.items.isEmpty)

        _ = try env.store.takeSnapshot(noteId: note.id, text: "first", now: Date(timeIntervalSince1970: 1_800_000_000))
        await Self.settle { model.items.count == 1 }
        #expect(model.items.map(\.preview) == ["first"])

        _ = try env.store.takeSnapshot(noteId: note.id, text: "second", now: Date(timeIntervalSince1970: 1_800_000_100))
        await Self.settle { model.items.count == 2 }
        #expect(model.items.map(\.preview) == ["second", "first"])

        model.close()
        _ = try env.store.takeSnapshot(noteId: note.id, text: "third", now: Date(timeIntervalSince1970: 1_800_000_200))
        await Task.yield()
        #expect(model.items.count == 2)
    }

    @Test func restoreAsCopyOpensANewNoteAndKeepsTheSource() throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "current text")
        let old = try #require(try env.store.takeSnapshot(noteId: note.id, text: "an older version", now: Date(timeIntervalSince1970: 1_800_000_000)))
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        var opened: [String] = []
        model.openNote = { opened.append($0); return true }
        let sourceBefore = try #require(try env.store.note(id: note.id))
        let historyBefore = try env.store.snapshots(noteId: note.id)

        let version = try #require(model.items.first)
        let copy = try #require(model.restoreAsCopy(version))

        #expect(copy.id != note.id && copy.text == "an older version")
        #expect(opened == [copy.id])
        let sourceAfter = try #require(try env.store.note(id: note.id))
        #expect(sourceAfter.text == "current text" && sourceAfter.revision == sourceBefore.revision)
        #expect(sourceAfter.modifiedAt == sourceBefore.modifiedAt)
        #expect(try env.store.snapshots(noteId: note.id) == historyBefore)
        #expect(old.id == version.id)
    }

    @Test func replaceAsksAndSnapshotsFirst() async throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "the old text")
        let old = try #require(try env.store.takeSnapshot(noteId: note.id, text: "the old text", now: Date(timeIntervalSince1970: 1_800_000_000)))
        _ = try env.store.updateText(id: note.id, text: "the new text", expectedRevision: note.revision)
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        var questions = 0
        var textWhenAsked: String?
        var answer = false
        model.confirmReplace = {
            questions += 1
            textWhenAsked = try? env.store.note(id: note.id)?.text
            return answer
        }

        // Cancel: asked once, nothing written.
        let version = try #require(model.items.first)
        let before = try Self.digest(env.environment.database)
        #expect(await !model.replace(version))
        #expect(questions == 1 && textWhenAsked == "the new text")
        #expect(try Self.digest(env.environment.database) == before)

        // Replace: the current text is a version of its own, then the chosen version is the text.
        answer = true
        #expect(await model.replace(version))
        #expect(questions == 2)
        #expect(try env.store.note(id: note.id)?.text == "the old text")
        #expect(try env.versions(note.id).contains("the new text"))
        #expect(try env.versions(note.id).contains("the old text"))
        #expect(old.noteId == note.id)
    }

    @Test func replaceSavesWhatWasTypedFirst() async throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "start")
        _ = try env.store.takeSnapshot(noteId: note.id, text: "start", now: Date(timeIntervalSince1970: 1_800_000_000))
        let session = try env.environment.session(for: note.id)
        Self.type(" and typed", into: session)
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        model.confirmReplace = { true }

        #expect(await model.replace(try #require(model.items.first)))

        #expect(try env.versions(note.id).contains("start and typed"))
        #expect(try env.store.note(id: note.id)?.text == "start")
    }

    @Test func lockedNoteHistoryNeedsTheVault() async throws {
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        let session = try f.environment.session(for: f.noteId)
        Self.type("\nsecond", into: session)
        f.vault.relock()
        #expect(!f.vault.isUnlocked)

        let model = NoteHistoryModel(noteId: f.noteId, environment: f.environment)
        var opened: [String] = []
        model.openNote = { opened.append($0); return true }
        model.confirmReplace = { true }
        #expect(model.needsVault && model.items.isEmpty)
        let notesBefore = try Self.noteCount(f.environment)
        let before = try Self.digest(f.environment.database)

        // Nothing can be previewed, restored or replaced without the key.
        let probe = NoteSnapshot(id: "none", noteId: f.noteId, takenAt: .now, isSealed: true, preview: nil)
        #expect(model.preview(probe) == nil && model.previewText == nil)
        #expect(model.restoreAsCopy(probe) == nil && opened.isEmpty)
        #expect(await !model.replace(probe))
        #expect(try Self.noteCount(f.environment) == notesBefore)
        #expect(try Self.digest(f.environment.database) == before)

        // The unlock lets it open, and a relock takes the previews off again.
        try await f.environment.unlockNotes(password: LockedFixture.password)
        await Self.settle { !model.items.isEmpty }
        #expect(!model.needsVault && model.items.count == 1)
        let shown = try #require(model.items.first)
        #expect(shown.preview == LockedFixture.title)
        #expect(model.preview(shown) == f.text + "\nsecond")

        f.vault.relock()
        await Self.settle { model.items.isEmpty }
        #expect(model.needsVault && model.items.isEmpty && model.previewText == nil)
    }

    @Test func aLockedNotesCopyIsLockedAndReplaceSealsTheCurrentText() async throws {
        let f = try await LockedFixture()
        defer { Self.destroy(f) }
        let access = try f.vault.requireAccess()
        let old = try #require(try access.takeSnapshot(noteId: f.noteId, text: "# old locked version", now: Date(timeIntervalSince1970: 1_800_000_000)))
        let model = NoteHistoryModel(noteId: f.noteId, environment: f.environment)
        model.confirmReplace = { true }
        var opened: [String] = []
        model.openNote = { opened.append($0); return true }

        let version = try #require(model.items.first)
        let copy = try #require(model.restoreAsCopy(version))
        #expect(copy.isLocked && opened == [copy.id])

        #expect(await model.replace(version))
        let text = try access.note(id: f.noteId)?.text
        #expect(text == "# old locked version")
        let sealed = try Self.scalar(
            f.environment.database, "SELECT COUNT(*) FROM note_snapshot WHERE noteId = ? AND text IS NULL AND sealedText IS NOT NULL", [f.noteId])
        #expect(sealed == 2 && old.noteId == f.noteId)
    }

    @Test func appLockShowsNothingAndDoesNothing() async throws {
        let env = try ReminderEnv()
        let note = try env.store.create(text: "history")
        _ = try env.store.takeSnapshot(noteId: note.id, text: "history", now: Date(timeIntervalSince1970: 1_800_000_000))
        env.authenticator.script(.success)
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        model.confirmReplace = { true }
        #expect(model.items.count == 1)
        model.preview(try #require(model.items.first))
        #expect(model.previewText == "history")

        env.environment.appLock.lock()

        #expect(model.isAppLocked && model.items.isEmpty && model.previewText == nil)
        let probe = NoteSnapshot(id: "x", noteId: note.id, takenAt: .now, isSealed: false, preview: nil)
        #expect(model.preview(probe) == nil && model.restoreAsCopy(probe) == nil)
        #expect(await !model.replace(probe))
        model.reload()
        #expect(model.items.isEmpty)
    }

    // MARK: Fix round 1

    /// The real path of Note ▸ Note History… over a note window: opening the sheet must not save, evict
    /// or snapshot anything (FOC-R297).
    @Test func openingTheHistoryWritesNothing() async throws {
        let suiteName = "TheoNotesHistory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let env = try PlainEnv()
        let app = AppModel(environment: env.environment, defaults: defaults)
        let shown = try env.store.create(text: "shown note")
        let other = try env.store.create(text: "another note")
        _ = try env.store.takeSnapshot(noteId: shown.id, text: "shown note", now: Date(timeIntervalSince1970: 1_800_000_000))
        // The shown note holds typed, uncommitted text; another note has a session nobody shows.
        let shownSession = try env.environment.session(for: shown.id)
        Self.type(" typed", into: shownSession)
        let page = FakeEditorPage()
        let editor = EditorBridgeController(environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        let window = app.makeNoteWindow(noteId: shown.id, editor: editor)
        // A session of another note that no window shows: a flush-all would evict it and snapshot it.
        _ = try env.environment.session(for: other.id)
        let before = try Self.digest(env.environment.database)
        let sessionsBefore = env.environment.openSessionCount

        app.showNoteHistory(main: nil, noteWindow: window)
        await Task.yield()
        // The sheet read the list and its first version; none of that wrote.
        NSApp.windows.filter { $0.title == NoteHistoryModel.title }.forEach { $0.close() }

        #expect(try Self.digest(env.environment.database) == before)
        #expect(env.environment.openSessionCount == sessionsBefore)
        #expect(try env.store.note(id: shown.id)?.text == "shown note")
        #expect(try env.store.snapshots(noteId: other.id).isEmpty)
    }

    /// An editor transaction that is typed but not yet at the host: Replace waits for the editor,
    /// finds it ahead of the session, writes nothing and says so (FOC-R297).
    @Test func replaceRefusesWhileAnEditorTransactionIsStillOnItsWay() async throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "start")
        _ = try env.store.takeSnapshot(noteId: note.id, text: "an older text", now: Date(timeIntervalSince1970: 1_800_000_000))
        let page = FakeEditorPage()
        let editor = EditorBridgeController(environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try editor.open(noteId: note.id)
        _ = editor.handle(.ready(version: EditorBridge.version))
        let session = try #require(editor.session)
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        model.confirmReplace = { true }
        let version = try #require(model.items.first)
        let before = try Self.digest(env.environment.database)

        // The page's document is "start more"; the host has not received " more" yet.
        let first = Task { await model.replace(version) }
        await Self.settle { !page.checksumRequestIds.isEmpty }
        let requestId = try #require(page.checksumRequestIds.last)
        _ = editor.handle(.checksum(requestId: requestId, noteId: note.id, sha256: sha256Hex("start more")))
        #expect(await first.value == false)
        #expect(model.notice == "Your latest typing has not been saved yet. Try again in a moment.")
        #expect(try Self.digest(env.environment.database) == before)

        // The transaction arrives; the editor and the session agree and Replace goes through.
        let tx = EditorToHostMessage.changes(
            noteId: note.id, txId: "t1", baseRevision: session.revision, revision: session.revision + 1,
            changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " more")]))
        #expect(editor.handle(tx) == .acked(revision: session.revision))
        let second = Task { await model.replace(version) }
        await Self.settle { page.checksumRequestIds.count == 2 }
        let secondId = try #require(page.checksumRequestIds.last)
        _ = editor.handle(.checksum(requestId: secondId, noteId: note.id, sha256: sha256Hex("start more")))
        #expect(await second.value == true)
        #expect(try env.store.note(id: note.id)?.text == "an older text")
        #expect(try env.versions(note.id).contains("start more"))
    }

    /// At full retention one row goes out as another comes in: count, newest id and sealed count do
    /// not change, the list must (FOC-R294).
    @Test func theListFollowsARetentionSwapAtFullRetention() async throws {
        let env = try PlainEnv()
        let note = try env.store.create(text: "x")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0...20 {
            _ = try env.store.takeSnapshot(noteId: note.id, text: "version \(index)", now: base.addingTimeInterval(Double(index) * 60))
        }
        let model = NoteHistoryModel(noteId: note.id, environment: env.environment)
        #expect(model.items.count == 21)
        let before = model.items.map(\.id)

        // A version dated between the 11th and 12th: it displaces the 20th newest, not the floor.
        _ = try env.store.takeSnapshot(noteId: note.id, text: "inserted", now: base.addingTimeInterval(10.5 * 60))
        await Self.settle { model.items.map(\.id) != before }

        #expect(model.items.count == 21)
        #expect(model.items.map(\.preview).contains("inserted"))
        #expect(!model.items.map(\.preview).contains("version 1"))
    }

    @Test func theMenuItemIsOffWithoutAnAppWhileLockedAndForTheWrongSelection() throws {
        #expect(NoteHistoryMenu.title == "Note History…")
        #expect(NoteHistoryModel.restoreTitle == "Restore as Copy" && NoteHistoryModel.replaceTitle == "Replace This Note…")
        #expect(NoteHistoryModel.replaceQuestion == "Replace the note with this version? The current text is kept in the history.")
        #expect(NoteHistoryMenu.isDisabled(app: nil, hasMainWindow: true, hasNoteWindow: false, state: .unavailable))
        let one = NoteListItemFixture.state(selected: 1, scope: .notes)
        let none = NoteListItemFixture.state(selected: 0, scope: .notes)
        let trash = NoteListItemFixture.state(selected: 1, scope: .trash)
        #expect(one.canShowHistory && !none.canShowHistory && !trash.canShowHistory)
    }
}

/// Builds the command state the menu reads, without a window.
enum NoteListItemFixture {
    static func state(selected: Int, scope: SidebarScope) -> NoteCommandState {
        let items = (0..<max(selected, 1)).map { index in
            NoteListItem(
                id: "n\(index)", title: "n\(index)", subtitle: "", modifiedAt: .now, createdAt: .now, isPinned: false,
                isLocked: false, isReadOnly: false, hasAttachments: false, firstImageFilename: nil)
        }
        return NoteCommandState(
            scope: scope, items: items, selectedNoteIDs: Set(items.prefix(selected).map(\.id)), counts: SidebarCounts())
    }
}
