// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// …: at the first launch of 1.1, each UNEDITED first-release starter is replaced once by its new text.
@Suite struct GettingStartedUpgradeTests {
    /// A library made by the first release: frozen v1 texts, flag set.
    static func firstReleaseLibrary() throws -> GettingStartedNotesTests.Library {
        let library = try GettingStartedNotesTests.Library()
        try library.store.write { db in
            for note in try GettingStartedNotes.firstShippedNotes() { _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db) }
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [SettingKey<Bool>.gettingStartedSeeded.name])
        }
        return library
    }

    static let target = GettingStartedNotes.ids[4]  // note 5: v1 and v2 differ

    static func v2(_ id: String) throws -> String { try #require(GettingStartedNotes.notes().first { $0.id == id }).text }
    static func v1(_ id: String) throws -> String { try #require(GettingStartedNotes.firstShippedNotes().first { $0.id == id }).text }

    @Test func untouchedFirstReleaseStartersBecomeTheNewTexts() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        #expect(try Self.v1(Self.target) != Self.v2(Self.target))
        let done = try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        #expect(!done.isEmpty)
        for note in try GettingStartedNotes.notes() {
            let stored = try #require(try library.store.note(id: note.id))
            #expect(stored.text == note.text, "\(note.slug)")
            #expect(stored.location == .notes && !stored.isPinnedGlobal && !stored.isLocked)
            #expect(stored.createdAt == note.stamp && stored.modifiedAt == note.stamp, "stamps stay fixed so two devices write identical notes")
        }
        #expect(try library.everyNote().count == 12)
        // Equal to what a brand-new 1.1 library holds, tags included.
        let fresh = try GettingStartedNotesTests.Library(); defer { fresh.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: fresh.store, isNewLibrary: true)
        let tags: (GettingStartedNotesTests.Library) throws -> [String] = { try $0.db.pool.read { try String.fetchAll($0, sql: "SELECT nt.noteId || '|' || t.pathKey FROM note_tag nt JOIN tag t ON t.id = nt.tagId ORDER BY 1") } }
        #expect(try tags(library) == tags(fresh))
    }

    @Test func anEditedStarterStaysAndTheOthersUpgrade() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        let current = try #require(try library.store.note(id: Self.target))
        let edited = try Self.v1(Self.target) + "\nmy own line\n"
        _ = try library.store.updateText(id: Self.target, text: edited, expectedRevision: current.revision)
        try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        #expect(try library.store.note(id: Self.target)?.text == edited)
        let other = GettingStartedNotes.ids[1]
        #expect(try library.store.note(id: other)?.text == Self.v2(other))
    }

    @Test func aDeletedStarterIsNotBroughtBack() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        try library.store.deletePermanently([Self.target])
        try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        #expect(try library.store.note(id: Self.target) == nil)
        #expect(try library.everyNote().count == 11)
    }

    @Test func trashedArchivedPinnedAndLockedStartersStay() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        let ids = GettingStartedNotes.ids
        try library.store.trash([ids[4]])
        try library.store.archive([ids[5]])
        try library.store.setPinned([ids[6]], pinned: true)
        let access = try NotePrivacy(store: library.store).setPassword("upgrade-test-password"); defer { access.revoke() }
        try access.lock(noteId: ids[7])
        try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        #expect(try library.store.note(id: ids[4])?.location == .trash)
        #expect(try library.store.note(id: ids[5])?.location == .archive)
        #expect(try library.store.note(id: ids[6])?.text == Self.v1(ids[6]))
        #expect(try library.store.note(id: ids[7])?.isLocked == true)
        #expect(try access.note(id: ids[7])?.text == Self.v1(ids[7]))
    }

    @Test func aStarterWithPendingTypingStays() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        try FileManager.default.createDirectory(at: library.paths.journal, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: library.paths.journal.appendingPathComponent(Self.target + ".jsonl"))
        try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        #expect(try library.store.note(id: Self.target)?.text == Self.v1(Self.target))
    }

    @Test func nonStarterNotesAreNeverTouched() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        let mine = try library.store.create(text: "# Mine\nstays #getting-started-fan")
        try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        let after = try #require(try library.store.note(id: mine.id))
        #expect(after.text == mine.text && after.revision == mine.revision)
    }

    @Test func itRunsOnceAndLaterEditsOrOldTextsAreNotTouched() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        #expect(try !GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths).isEmpty)
        #expect(try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths).isEmpty)
        // Someone pastes the old text back by hand after the upgrade: the marker holds, it is not replaced again.
        let current = try #require(try library.store.note(id: Self.target))
        _ = try library.store.updateText(id: Self.target, text: Self.v1(Self.target), expectedRevision: current.revision)
        #expect(try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths).isEmpty)
        #expect(try library.store.note(id: Self.target)?.text == Self.v1(Self.target))
    }

    @Test func aNewLibraryIsUnaffectedAndMarkedDone() throws {
        let library = try GettingStartedNotesTests.Library(); defer { library.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        let before = try library.everyNote().map { [$0.id, $0.text, String($0.revision)] }
        #expect(try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths).isEmpty)
        #expect(try library.everyNote().map { [$0.id, $0.text, String($0.revision)] } == before)
        // A library with no starters at all (the person never had them, or imported) gets none made.
        let empty = try GettingStartedNotesTests.Library(); defer { empty.cleanup() }
        #expect(try GettingStartedNotes.upgradeFirstShipped(in: empty.store, paths: empty.paths).isEmpty)
        #expect(try empty.everyNote().isEmpty)
    }

    @Test func theMarkerIsSet() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths)
        #expect(try Settings(db: library.db).value(.gettingStartedUpgraded))
    }

    /// Review M1/S2: a library an account owns is not touched at launch. A write there is a captured edit before the first fetch
    /// (it would bring back a starter deleted elsewhere) or before the first-bind guard has run; the coordinator upgrades it after a cycle.
    @Test func aLibraryBoundToAnAccountIsLeftAloneAtLaunchAndUpgradesAfterASync() throws {
        let library = try Self.firstReleaseLibrary(); defer { library.cleanup() }
        try library.db.pool.write { try $0.execute(sql: "UPDATE sync_control SET accountId='a' WHERE id=1") }
        #expect(try GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths).isEmpty)
        #expect(try library.store.note(id: Self.target)?.text == Self.v1(Self.target))
        #expect(try !Settings(db: library.db).value(.gettingStartedUpgraded), "the marker stays unset: a later sync cycle does it")
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") } == 0, "no pending upload was made")
        #expect(try !GettingStartedNotes.upgradeFirstShipped(in: library.store, paths: library.paths, afterSync: true).isEmpty)
        #expect(try library.store.note(id: Self.target)?.text == Self.v2(Self.target))
    }
}
