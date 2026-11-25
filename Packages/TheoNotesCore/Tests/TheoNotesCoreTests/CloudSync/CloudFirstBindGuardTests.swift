// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The first-bind guard (STARTER-R4, matrix S13 to S20): a library that made its own Getting Started notes (a fresh iPhone) joins an
/// iCloud library that has notes but never had them. The real `seedNewLibrary`, the real coordinator, `FakeCloudKit`.
@Suite(.serialized) struct CloudFirstBindGuardTests {
    static func starterVersions(_ world: CoordWorld) async -> [Int] {
        var counts: [Int] = []
        for id in StarterFixtures.ids { counts.append(await world.cloud.versionCount(of: "e.note.\(id)")) }
        return counts
    }

    static func starterCount(_ device: CoordDevice) throws -> Int { try StarterFixtures.starterNotes(device).count }

    /// A: a Mac library from before the starters existed: three notes of the person's own, synced.
    static func libraryWithoutStarters(_ world: CoordWorld) async throws -> [String] {
        let a = world.devices[0]
        let mine = try (1...3).map { try a.noteStore.create(text: "# My note \($0)\n\nBody \($0).\n").id }
        try await a.enable()
        try await world.converge([a])
        return mine
    }

    // MARK: S13

    @Test func aFreshlySeededDeviceDoesNotPublishStartersIntoALibraryThatNeverHadThem() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let mine = try await Self.libraryWithoutStarters(world)
        try StarterFixtures.seed(b)
        #expect(try Self.starterCount(b) == 12)
        try await b.enable()
        try await world.converge()
        for device in world.devices {
            #expect(Set(try device.notes().map(\.id)) == Set(mine), "\(device.name): only the person's own notes")
            #expect(try device.conflictCopies() == 0)
        }
        #expect(await Self.starterVersions(world) == Array(repeating: 0, count: 12), "nothing of the starters reached the cloud")
        #expect(try b.dirty().filter { StarterFixtures.ids.contains($0.id) }.isEmpty, "no marker, no tombstone")
        #expect(try b.string("SELECT value FROM setting WHERE key='gettingStartedSeeded'") == "true", "the flag stays: nothing makes them again")
        for _ in 0..<3 { for device in world.devices { try await device.coordinator.syncNow() } }
        #expect(try world.devices.allSatisfy { try $0.notes().count == 3 })
        #expect(await Self.starterVersions(world) == Array(repeating: 0, count: 12))
        _ = a
    }

    // MARK: S13b

    @Test func aFirstDeviceWithAnEmptyCloudPublishesItsStartersOnce() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge([b])
        #expect(await Self.starterVersions(world) == Array(repeating: 1, count: 12))
        let mine = try a.noteStore.create(text: "# Mine\n").id
        try await a.enable()
        try await world.converge()
        for device in world.devices { #expect(try device.count("note") == 13 && device.conflictCopies() == 0) }
        #expect(try a.note(mine) != nil)
        #expect(await Self.starterVersions(world) == Array(repeating: 1, count: 12), "A took them, nobody saved them again")
    }

    // MARK: S14, S20: what the guard never touches

    @Test func anEditedStarterAndTheOwnNotesSurviveTheGuard() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let b = world.devices[1]
        _ = try await Self.libraryWithoutStarters(world)
        try StarterFixtures.seed(b)
        let edited = StarterFixtures.ids[3], trashed = StarterFixtures.ids[5], moved = StarterFixtures.ids[7]
        try b.edit(edited, try #require(try b.note(edited)).text + "\nMy own ending.\n")
        try b.trash(trashed)
        try b.sql("UPDATE note SET location='archive' WHERE id='\(moved)'")
        let own = try b.noteStore.create(text: "# Written on the phone\n").id
        try await b.enable()
        try await world.converge()
        for device in world.devices {
            #expect(try device.note(edited)?.text.hasSuffix("My own ending.\n") == true, "\(device.name): the edit is published")
            #expect(try device.note(trashed) != nil, "\(device.name): a trashed starter is the person's choice")
            #expect(try device.note(moved) != nil)
            #expect(try device.note(own) != nil)
            #expect(try Self.starterCount(device) == 12, "\(device.name): not a fresh device, so the guard removes nothing (STARTER-R10)")
            #expect(try device.conflictCopies() == 0)
        }
        #expect(await Self.starterVersions(world) == Array(repeating: 1, count: 12))
    }

    @Test func aStarterThatHasARecordPairSurvivesTheGuard() async throws {
        // The Mac has the starters (and notes of its own); the iPhone made its own set. They collapse, nothing is dropped.
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(a)
        _ = try a.noteStore.create(text: "# Mac note\n")
        try await a.enable()
        try await world.converge([a])
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge()
        for device in world.devices { #expect(try Self.starterCount(device) == 12 && device.count("note") == 13 && device.conflictCopies() == 0) }
        #expect(await Self.starterVersions(world) == Array(repeating: 1, count: 12))
    }

    static func pair(_ device: CoordDevice, _ id: String) throws {
        try device.sql("INSERT INTO ck_record(entityType, entityId, systemFields, ancestor, ver, inc) VALUES('note','\(id)',x'00',x'00',1,'i')")
    }

    @Test func theGuardDeletesOnlyWhatItIsSureOfInASingleTransaction() async throws {
        // Direct: on a fresh device the untouched starters the cloud does not know go; a starter and a note of the person's own that
        // the cloud knows stay.
        let world = try CoordWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        try StarterFixtures.seed(a)
        let dropped = StarterFixtures.ids[1], paired = StarterFixtures.ids[2]
        let own = try a.noteStore.create(text: "# Mine\n").id
        // with no note in the cloud the guard does nothing at all
        let none = try await a.database.pool.write { db in try CloudSyncStore.dropUnpublishedStarters(in: db) }
        #expect(none.isEmpty)
        try Self.pair(a, own)          // the person's note is already in the cloud: the device is still fresh
        try Self.pair(a, paired)       // an untouched starter the cloud already holds is never the guard's
        // Bound to an account, so the capture triggers are live: a plain delete here would write a tombstone.
        try a.sql("UPDATE sync_control SET backend='cloudkit', accountId='guard-account' WHERE id=1")
        try a.sql("DELETE FROM sync_dirty")
        let gone = try await a.database.pool.write { db in try CloudSyncStore.dropUnpublishedStarters(in: db) }
        #expect(Set(gone) == Set(StarterFixtures.ids).subtracting([paired]))
        #expect(try a.note(paired) != nil)
        #expect(try a.note(dropped) == nil)
        #expect(try a.note(own) != nil)
        #expect(try a.count("note") == 2)
        let outbox = try a.dirty()
        #expect(outbox.isEmpty, "the guard writes no tombstone and no marker: \(outbox)")
        #expect(try a.string("SELECT applying FROM sync_control WHERE id=1") == "0")
        // Control: the same library's ordinary delete does write a tombstone, so the check above can fail.
        try a.noteStore.deletePermanently([own])
        #expect(try a.string("SELECT tombstone FROM sync_dirty WHERE entityType='note' AND localId='\(own)'") == "1")
    }

    @Test func oneUnpublishedNoteOfThePersonsOwnMeansNotFreshAndNothingGoes() throws {
        // STARTER-R10, direct: each of these alone makes the device "not fresh", and the guard removes nothing at all.
        for (label, touch) in [
            ("an own note", { (d: CoordDevice) in _ = try d.noteStore.create(text: "# Written before sync\n") }),
            ("an edited starter", { (d: CoordDevice) in try d.edit(StarterFixtures.ids[0], try #require(try d.note(StarterFixtures.ids[0])).text + "\nEdited.\n") }),
            ("a trashed own note", { (d: CoordDevice) in let id = try d.noteStore.create(text: "# Gone\n").id; try d.trash(id) }),
        ] as [(String, (CoordDevice) throws -> Void)] {
            let world = try CoordWorld.make(1); defer { world.cleanup() }
            let a = world.devices[0]
            try StarterFixtures.seed(a)
            try touch(a)
            try a.sql("INSERT INTO ck_record(entityType, entityId, systemFields, ancestor, ver, inc) VALUES('note','cloud-note',x'00',x'00',1,'i')")
            let gone = try a.database.pool.write { db in try CloudSyncStore.dropUnpublishedStarters(in: db) }
            #expect(gone.isEmpty, "\(label): nothing removed")
            #expect(try Self.starterCount(a) == 12, "\(label)")
        }
    }

    @Test func aDeviceWithOneOwnUnpublishedNoteKeepsAndUploadsItsStarters() async throws {
        // STARTER-R10 through the coordinator: a long-standing library (or a note written before switching sync on) joins a cloud
        // that has notes but no starters. Its starters upload as before; the other device receives them.
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let mine = try await Self.libraryWithoutStarters(world)
        let b = world.devices[1]
        try StarterFixtures.seed(b)
        let own = try b.noteStore.create(text: "# Written on the Mac before sync\n").id
        try await b.enable()
        try await world.converge()
        for device in world.devices {
            #expect(try Self.starterCount(device) == 12, "\(device.name): the starters stayed and arrived")
            #expect(Set(try device.notes().map(\.id)) == Set(mine + [own] + StarterFixtures.ids))
            #expect(try device.conflictCopies() == 0)
        }
        #expect(await Self.starterVersions(world) == Array(repeating: 1, count: 12))
        #expect(try b.string("SELECT value FROM setting WHERE key='gettingStartedDroppedBySync'") == nil)
    }

    // MARK: S15, S16

    @Test func startersDeletedEverywhereStayDeletedForAFreshlySeededDevice() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(a)
        let mine = try a.noteStore.create(text: "# Mine\n").id
        try await a.enable()
        for id in StarterFixtures.ids { try a.hardDelete(id) }
        try await world.converge([a])
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge()
        for device in world.devices {
            // an untouched copy follows a remote deletion into the Trash, like any remote deletion (CK-R132); none is visible
            let visible = try device.notes().filter { $0.location != .trash }
            #expect(visible.map(\.id) == [mine], "\(device.name): nothing came back, found \(visible.count) visible")
        }
        #expect(try world.devices.allSatisfy { try $0.conflictCopies() == 0 })
    }

    @Test func restoreAfterTheGuardMakesThemAgainAndTheyReachTheOtherDevice() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        _ = try await Self.libraryWithoutStarters(world)
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge()
        #expect(try Self.starterCount(b) == 0)
        let restored = try StarterFixtures.restore(b)
        #expect(restored.added.count == 12)
        try await world.converge()
        for device in world.devices { #expect(try Self.starterCount(device) == 12 && device.count("note") == 15 && device.conflictCopies() == 0) }
        #expect(await Self.starterVersions(world) == Array(repeating: 1, count: 12))
        _ = a
    }

    // MARK: S21 (review r1 M1): the guard's drop is not the person's deletion, also after sync off/on or a detach

    static func dropOnB(_ world: CoordWorld) async throws {
        _ = try await libraryWithoutStarters(world)
        let b = world.devices[1]
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge()
        #expect(try starterCount(b) == 0, "the guard dropped B's starters")
    }

    static func expectRestoreReachesEveryone(_ world: CoordWorld, _ label: String) async throws {
        let a = world.devices[0], b = world.devices[1]
        #expect(try b.store.deletedStarters().isEmpty, "\(label): the guard's drop is not recorded as the person's deletion")
        #expect(try StarterFixtures.restore(a).added.count == 12)
        try await world.converge()
        for device in world.devices {
            let starters = try StarterFixtures.starterNotes(device)
            #expect(starters.count == 12 && starters.allSatisfy { $0.location == .notes }, "\(label): \(device.name) shows the twelve, none in the Trash")
            #expect(try device.conflictCopies() == 0)
        }
        _ = b
    }

    @Test func syncOffAndOnAfterTheGuardLetsAnotherDevicesRestoreThrough() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        try await Self.dropOnB(world)
        let b = world.devices[1]
        await b.coordinator.disable()
        try await b.enable()
        try await world.converge()
        try await Self.expectRestoreReachesEveryone(world, "off/on")
    }

    @Test func aDetachAndRebindAfterTheGuardLetsAnotherDevicesRestoreThrough() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        try await Self.dropOnB(world)
        let b = world.devices[1]
        b.realBackups = true
        try await b.coordinator.detachForNewAccount()
        try await b.enable()
        try await world.converge()
        try await Self.expectRestoreReachesEveryone(world, "detach")
    }

    // MARK: S22 (review r1 M2): a Restore while sync is off is the person's action and survives the next switch-on

    @Test func aRestoreWhileSyncIsOffSurvivesTheNextSwitchOn() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        try await Self.dropOnB(world)
        let b = world.devices[1]
        await b.coordinator.disable()
        #expect(try StarterFixtures.restore(b).added.count == 12)
        try await b.enable()
        try await world.converge()
        for device in world.devices {
            let starters = try StarterFixtures.starterNotes(device)
            #expect(starters.count == 12 && starters.allSatisfy { $0.location == .notes }, "\(device.name): the restored notes stay and arrive")
            #expect(try device.conflictCopies() == 0)
        }
    }

    // MARK: S23 (review r1 S1): an open editor and its journal

    @Test @MainActor func aStarterWithUncommittedTypingKeepsTheGuardOffAndTheTextArrives() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        _ = try await Self.libraryWithoutStarters(world)
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(b)
        let welcome = StarterFixtures.ids[0]
        let session = try NoteSession(noteId: welcome, store: b.noteStore, journalDirectory: b.paths.journal, commitDelay: .seconds(60))
        let length = session.text.utf16.count
        #expect(session.apply(txId: "typed", baseRevision: session.revision,
                              changeSet: ChangeSet(sections: [.retain(length), .replace(deleteLength: 0, insert: "Typed on the phone.\n")]), origin: nil)
                == .acked(revision: session.revision))
        #expect(CloudFirstRun.startersWithPendingJournal(in: b.paths) == [welcome], "the keystrokes wait in the journal, not in the note")
        try await b.enable()
        try await world.converge()
        #expect(try Self.starterCount(b) == 12, "a pending journal keeps the guard off: nothing removed under the open editor")
        try session.flush()
        try await world.converge()
        #expect(try a.note(welcome)?.text.hasSuffix("Typed on the phone.\n") == true, "the typing reaches the other device")
        #expect(try world.devices.allSatisfy { try $0.conflictCopies() == 0 })
    }

    @Test func aJournalSetAsideForRecoveryKeepsTheGuardOff() async throws {
        // Review r2 should-fix 2: a journal moved aside as `<id>.jsonl.unreplayed` (`EditJournal`) counts at any size, as in the import
        // merge and the backup check.
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        _ = try await Self.libraryWithoutStarters(world)
        let b = world.devices[1]
        try StarterFixtures.seed(b)
        let welcome = StarterFixtures.ids[0], format = StarterFixtures.ids[1]
        try FileManager.default.createDirectory(at: b.paths.journal, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: b.paths.journal.appendingPathComponent(welcome + ".jsonl.unreplayed").path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: b.paths.journal.appendingPathComponent(format + ".base.unreplayed.2").path, contents: Data("x".utf8)))
        #expect(CloudFirstRun.startersWithPendingJournal(in: b.paths) == [welcome, format])
        try await b.enable()
        try await world.converge()
        #expect(try Self.starterCount(b) == 12, "a starter with a journal set aside for recovery keeps the guard off")
    }

    final class RecordingCommits: SyncCommitCoordinator, @unchecked Sendable {
        let scopes = LockedBox<[SyncCommitScope]>([])
        func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult { try await commit(scope: .unknown, change) }
        func commit(scope: SyncCommitScope, _ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
            scopes.update { $0.append(scope) }
            return try change()
        }
    }

    @Test func theGuardRunsThroughTheEditorsCommitCoordination() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        _ = try await Self.libraryWithoutStarters(world)
        let b = world.devices[1]
        let commits = RecordingCommits()
        b.commits.update { $0 = commits }
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge()
        #expect(try Self.starterCount(b) == 0, "a fresh device is still cleaned")
        #expect(commits.scopes.value.contains(.unknown), "the switch-on with the guard ran inside the host's coordination: \(commits.scopes.value)")
    }

    /// The host's editor coordination refuses once (iOS: `.busy` or `.composing`), then works.
    final class RefusingOnceCommits: SyncCommitCoordinator, @unchecked Sendable {
        struct EditorBusy: Error {}
        let refusals = LockedBox(1)
        func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult { try await commit(scope: .unknown, change) }
        func commit(scope: SyncCommitScope, _ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
            if scope == .unknown, refusals.value > 0 { refusals.update { $0 -= 1 }; throw EditorBusy() }
            return try change()
        }
    }

    @Test func aBusyEditorAtSwitchOnRetriesInsteadOfFailing() async throws {
        // Review r2 should-fix 1: the switch-on waits for the editor; a refusal must not end the first sync with an error.
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        _ = try await Self.libraryWithoutStarters(world)
        let b = world.devices[1]
        b.commits.update { $0 = RefusingOnceCommits() }
        try StarterFixtures.seed(b)
        let state = try await b.enable()
        #expect(state == .syncing, "the first sync waits and goes on, got \(state)")
        #expect(try b.store.isUploadEnabled() == false && b.store.isSwitchedOn())
        #expect(try Self.starterCount(b) == 12, "nothing was removed while the editor refused")
        try await world.converge()
        #expect(try b.store.isUploadEnabled(), "the next cycle switched uploads on")
        #expect(try Self.starterCount(b) == 0, "and the guard ran then")
        #expect(await Self.starterVersions(world) == Array(repeating: 0, count: 12))
    }

    @Test func storeAndCloudErrorsAreNotTakenForAnEditorWait() {
        #expect(CloudSyncCoordinator.isEditorWait(RefusingOnceCommits.EditorBusy()))
        #expect(!CloudSyncCoordinator.isEditorWait(CloudSyncStoreError.accountMismatch))
        #expect(!CloudSyncCoordinator.isEditorWait(CancellationError()))
        #expect(!CloudSyncCoordinator.isEditorWait(URLError(.notConnectedToInternet)))
    }

    // MARK: S19

    @Test func devicesEnablingTogetherInEveryOrderNeverDuplicateOrLoseAStarter() async throws {
        for order in [[0, 1], [1, 0], [0, 1, 1, 0], [1, 1, 0, 0]] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            try StarterFixtures.seed(a); try StarterFixtures.seed(b)
            _ = try a.noteStore.create(text: "# Mac note\n")
            try await CloudFirstRunMatrixTests.enableTogether(world, order: order)
            try await world.converge()
            for device in world.devices {
                #expect(try Self.starterCount(device) == 12 && device.count("note") == 13 && device.conflictCopies() == 0, "order \(order) on \(device.name)")
                #expect(Set(try device.visibleTitles()).count == 13)
            }
            #expect(await Self.starterVersions(world).allSatisfy { $0 == 1 }, "order \(order)")
        }
    }
}
