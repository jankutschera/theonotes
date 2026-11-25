// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct NotificationLedgerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    let tmp: TempPaths
    init() throws { tmp = try TempPaths() }

    private func store() throws -> NoteStore {
        NoteStore(db: try .inMemory(), notifier: nil, paths: tmp.paths)
    }

    private func plan(_ store: NoteStore, appLock: Bool = false) throws -> [PlannedNotification] {
        try PingPlanner.plan(store: store, appLockEnabled: appLock, now: Self.now)
    }

    private func ledgerRows(_ store: NoteStore) throws -> [String: String?] {
        try store.db.pool.read { db in
            var result: [String: String?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT identifier, contentHash FROM notification_ledger") {
                result[row["identifier"] as String] = row["contentHash"] as String?
            }
            return result
        }
    }

    @Test func reconcileReusesUnchangedAndReplacesChangedContent() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        let note = try store.create(text: "# Plan\ncall the dentist")
        let steady = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        let moving = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(3), now: Self.now)

        let first = try ledger.reconcile(planned: try plan(store))
        #expect(first.add.count == 2)
        #expect(first.remove.isEmpty)
        let ids = Dictionary(uniqueKeysWithValues: first.add.map { ($0.notification.pingId, $0.identifier) })

        // Nothing changed: nothing to add, nothing to remove, the same identifiers stay.
        let again = try ledger.reconcile(planned: try plan(store))
        #expect(again.add.isEmpty)
        #expect(again.remove.isEmpty)

        // One reminder moves: only it is replaced, under a new identifier.
        _ = try store.setPing(noteId: note.id, anchor: moving.anchor, fireAt: Self.at(4), now: Self.now)
        let changed = try ledger.reconcile(planned: try plan(store))
        #expect(changed.add.map(\.notification.pingId) == [moving.id])
        let newId = try #require(changed.add.first).identifier
        #expect(newId != ids[moving.id])
        #expect(changed.remove == [try #require(ids[moving.id])])
        #expect(!changed.remove.contains(try #require(ids[steady.id])))
    }

    @Test func aHandledReminderIsRemoved() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        let note = try store.create(text: "# Plan")
        let ping = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        let added = try ledger.reconcile(planned: try plan(store))
        try store.handlePing(id: ping.id)

        let result = try ledger.reconcile(planned: try plan(store))

        #expect(result.add.isEmpty)
        #expect(result.remove == [try #require(added.add.first).identifier])
        // The row stays until the notification is confirmed gone, so a cold launch can still find it.
        #expect(try ledger.entries().count == 1)
    }

    @Test func reconcileRecordsBeforeReturningAdds() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        let note = try store.create(text: "# Plan")
        let ping = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)

        let result = try ledger.reconcile(planned: try plan(store))

        let added = try #require(result.add.first)
        let rows = try ledger.entries()
        #expect(rows == [LedgerEntry(identifier: added.identifier, kind: .reminder, pingId: ping.id, noteId: note.id,
                                     contentHash: added.notification.contentHash)])
    }

    @Test func reconcileNeverRemovesTimerIdentifiers() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        try ledger.record(LedgerEntry(identifier: "timer:abc", kind: .timer, pingId: nil, noteId: nil, contentHash: "deadbeef"), now: Self.now)
        let note = try store.create(text: "# Plan")
        _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        let first = try ledger.reconcile(planned: try plan(store))
        #expect(first.remove.isEmpty)
        let none = try ledger.reconcile(planned: [])
        #expect(none.remove == [try #require(first.add.first).identifier])
        #expect(!none.remove.contains("timer:abc"))
        #expect(try ledger.entries().contains { $0.identifier == "timer:abc" })
    }

    @Test func identifiersCarryNoNoteText() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        let note = try store.create(text: "# Canary Title\ncanary body line")
        let ping = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(2), now: Self.now)

        let identifier = try #require(try ledger.reconcile(planned: try plan(store)).add.first).identifier

        let prefix = "reminder:\(ping.id):"
        #expect(identifier.hasPrefix(prefix))
        let suffix = String(identifier.dropFirst(prefix.count))
        #expect(UUID(uuidString: suffix) != nil)
        #expect(!identifier.lowercased().contains("canary"))
        #expect(!identifier.contains(note.id) || ping.id.contains(note.id))
    }

    @Test func coldLaunchRemovalsCoverLockedDeletedAndAppLockedNotes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let store = library.store
        let ledger = NotificationLedger(store: store)
        let locked = try store.create(text: "# Locked")
        let open = try store.create(text: "# Open")
        let gone = try store.create(text: "# Gone")
        for note in [locked, open, gone] {
            _ = try store.setPing(noteId: note.id, anchor: nil, fireAt: Self.at(2), now: Self.now)
        }
        let added = try ledger.reconcile(planned: try plan(store))
        let idByNote = Dictionary(uniqueKeysWithValues: added.add.map { ($0.notification.noteId, $0.identifier) })
        try ledger.record(LedgerEntry(identifier: "timer:t1", kind: .timer, pingId: nil, noteId: open.id, contentHash: nil), now: Self.now)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: locked.id)
        try store.trash([gone.id])
        try store.deletePermanently([gone.id])

        #expect(Set(try ledger.coldLaunchRemovals(appLockEnabled: false)) == [try #require(idByNote[locked.id]), try #require(idByNote[gone.id])])
        #expect(Set(try ledger.coldLaunchRemovals(appLockEnabled: true))
            == [try #require(idByNote[locked.id]), try #require(idByNote[gone.id]), try #require(idByNote[open.id])])
        #expect(!(try ledger.coldLaunchRemovals(appLockEnabled: true)).contains("timer:t1"))
    }

    @Test func aReminderRowWithoutANoteIsRemovedOnColdLaunch() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        try ledger.record(LedgerEntry(identifier: "reminder:x:u", kind: .reminder, pingId: "x", noteId: nil, contentHash: "abcd1234"), now: Self.now)
        #expect(try ledger.coldLaunchRemovals(appLockEnabled: false) == ["reminder:x:u"])
    }

    @Test func lockedNotesLedgerRowsHaveNoContentHash() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let store = library.store
        let ledger = NotificationLedger(store: store)
        let note = try store.create(text: "# Plan\ncall the dentist")
        _ = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(2), now: Self.now)
        let before = try ledger.reconcile(planned: try plan(store))
        let oldId = try #require(before.add.first).identifier
        #expect(try ledgerRows(store)[oldId] != .some(nil))

        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        // The lock transaction already cleared the hash of the old row.
        #expect(try ledgerRows(store)[oldId] == .some(nil))

        // The title-only notification of the locked note is recorded without a hash too, and replaces the old one.
        let after = try ledger.reconcile(planned: try plan(store))
        #expect(after.remove == [oldId])
        let newRow = try #require(after.add.first)
        #expect(newRow.identifier != oldId)
        #expect(newRow.notification.body == nil)
        #expect(try ledgerRows(store)[newRow.identifier] == .some(nil))
        // A locked note's notification is never trusted as unchanged: it is rebuilt every time.
        let rebuilt = try ledger.reconcile(planned: try plan(store))
        #expect(rebuilt.add.count == 1)
        // (The first replacement's row is still listed: rows stay until the scheduler confirms them gone.)
        #expect(Set(rebuilt.remove) == [oldId, newRow.identifier])
        try ledger.forget([oldId])
        let settled = try ledger.reconcile(planned: try plan(store))
        #expect(settled.add.count == 1)
        #expect(Set(settled.remove) == [try #require(rebuilt.add.first).identifier, newRow.identifier])
    }

    @Test func sweepUnknownFindsReminderIdsMissingFromTheLedger() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        try ledger.record(LedgerEntry(identifier: "reminder:a:known", kind: .reminder, pingId: "a", noteId: nil, contentHash: nil), now: Self.now)
        try ledger.record(LedgerEntry(identifier: "reminder:b:known", kind: .reminder, pingId: "b", noteId: nil, contentHash: nil), now: Self.now)

        let unknown = ledger.sweepUnknown(
            pending: ["reminder:a:known", "reminder:c:stray", "timer:t1", "other.app.id"],
            delivered: ["reminder:b:known", "reminder:d:stray", "reminder:c:stray"])

        #expect(unknown == ["reminder:c:stray", "reminder:d:stray"])
    }

    @Test func confirmGoneForgetsOnlyAbsentIds() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        for id in ["reminder:a:1", "reminder:b:2", "timer:t1", "timer:t2"] {
            try ledger.record(LedgerEntry(identifier: id, kind: id.hasPrefix("timer") ? .timer : .reminder, pingId: nil, noteId: nil, contentHash: nil), now: Self.now)
        }

        try ledger.confirmGone(pending: ["reminder:a:1"], delivered: ["timer:t1", "unrelated"])

        #expect(Set(try ledger.entries().map(\.identifier)) == ["reminder:a:1", "timer:t1"])
    }

    @Test func forgetDeletesOnlyTheGivenIdentifiers() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        for id in ["reminder:a:1", "reminder:b:2"] {
            try ledger.record(LedgerEntry(identifier: id, kind: .reminder, pingId: nil, noteId: nil, contentHash: nil), now: Self.now)
        }
        try ledger.forget(["reminder:a:1", "never-recorded"])
        #expect(try ledger.entries().map(\.identifier) == ["reminder:b:2"])
    }

    @Test func recordingTheSameIdentifierTwiceUpdatesTheRow() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        try ledger.record(LedgerEntry(identifier: "timer:t1", kind: .timer, pingId: nil, noteId: nil, contentHash: "aaaaaaaa"), now: Self.now)
        try ledger.record(LedgerEntry(identifier: "timer:t1", kind: .timer, pingId: nil, noteId: nil, contentHash: "bbbbbbbb"), now: Self.at(1))
        #expect(try ledger.entries().map(\.contentHash) == ["bbbbbbbb"])
    }

    @Test func appLockPlanIsRebuiltWithGenericText() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        let note = try store.create(text: "# Canary Title\ncanary body")
        _ = try store.setPing(noteId: note.id, anchor: try #require(LineAnchor.at(line: 2, in: note.text)), fireAt: Self.at(2), now: Self.now)
        let open = try ledger.reconcile(planned: try plan(store))
        let redacted = try ledger.reconcile(planned: try plan(store, appLock: true))
        #expect(redacted.add.count == 1)
        #expect(redacted.remove == [try #require(open.add.first).identifier])
        #expect(try #require(redacted.add.first).notification.title == PingPlanner.genericTitle)
    }

    @Test func recordRefusesAnIdentifierOutsideItsKindsNamespace() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        #expect(throws: LedgerError.identifierKindMismatch(identifier: "timer:x")) {
            try ledger.record(LedgerEntry(identifier: "timer:x", kind: .reminder, pingId: nil, noteId: nil, contentHash: nil), now: Self.now)
        }
        #expect(throws: LedgerError.identifierKindMismatch(identifier: "reminder:x:y")) {
            try ledger.record(LedgerEntry(identifier: "reminder:x:y", kind: .timer, pingId: nil, noteId: nil, contentHash: nil), now: Self.now)
        }
        #expect(throws: LedgerError.identifierKindMismatch(identifier: "REMINDER:x:y")) {
            try ledger.record(LedgerEntry(identifier: "REMINDER:x:y", kind: .reminder, pingId: nil, noteId: nil, contentHash: nil), now: Self.now)
        }
        #expect(try ledger.entries().isEmpty)
    }

    @Test func malformedRowsStayOutsideTheReminderLifecycle() throws {
        let store = try store()
        let ledger = NotificationLedger(store: store)
        // Rows no `record` call could have written: kind says reminder, the identifier does not.
        try store.db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO notification_ledger(identifier, kind, pingId, noteId, contentHash, recordedAt) VALUES
                ('timer:evil', 'reminder', NULL, NULL, NULL, ?),
                ('other:evil', 'reminder', NULL, NULL, NULL, ?),
                ('REMINDER:evil', 'reminder', NULL, NULL, NULL, ?),
                ('reminder:ok:1', 'reminder', 'ok', NULL, NULL, ?)
                """, arguments: [Self.now, Self.now, Self.now, Self.now])
        }

        #expect(try ledger.coldLaunchRemovals(appLockEnabled: true) == ["reminder:ok:1"])
        #expect(try ledger.coldLaunchRemovals(appLockEnabled: false) == ["reminder:ok:1"])
        #expect(try ledger.reconcile(planned: []).remove == ["reminder:ok:1"])
    }

    @Test func categoryAndActionIdentifiers() {
        #expect(NotificationLedger.categoryIdentifier == "reminder")
        #expect(NotificationLedger.snoozeHourAction == "reminder.snooze.hour")
        #expect(NotificationLedger.snoozeNineAction == "reminder.snooze.nine")
    }
}
