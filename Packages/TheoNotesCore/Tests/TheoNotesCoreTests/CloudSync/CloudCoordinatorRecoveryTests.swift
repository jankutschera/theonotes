// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Fix round 1 (Codex review of Task 10): a first sync that was blocked goes on by itself (I1), a changed key bundle is verified
/// before any further data work (I2), and a starter note deleted before the first binding does not come back (I3).

/// Fails the fetch of `BlobPart` records while `blocked` (the cloud has the parts, they just cannot be read now).
final class PartBlockingGateway: CloudKitGateway, @unchecked Sendable {
    let inner: CoordGateway
    private let flag = LockedBox<Bool>(false)
    nonisolated let events: AsyncStream<CloudGatewayEvent>
    init(_ inner: CoordGateway) { self.inner = inner; events = inner.events }
    var blocked: Bool { get { flag.value } set { flag.update { $0 = newValue } } }
    func prepare() async throws -> CloudAccountState { try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws { try await inner.submit(saves) }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] {
        if flag.value, names.contains(where: { $0.hasPrefix("b.") }) { throw CloudSyncError.offline }
        return try await inner.fetch(names, keys: keys)
    }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws { try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
}

@Suite(.serialized) struct CloudCoordinatorRecoveryTests {
    static func upToDate(_ coordinator: CloudSyncCoordinator) async -> Bool {
        if case .upToDate = await coordinator.currentState { return true }
        return false
    }

    // MARK: I1, a blocked first sync goes on by itself

    @Test func aFirstSyncBlockedOnNotePasswordGoesOnWhenThePasswordComesWithoutASecondEnable() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let secret = try a.noteStore.create(text: "# Secret\nbody\n")
            try NotePrivacy(store: a.noteStore).setPassword("correct horse").lock(noteId: secret.id)
            #expect(try await a.enable() == .needsNotePassword)
            let state = try await a.coordinator.syncNow(notePassword: "correct horse")
            #expect(state == .upToDate(lastSync: a.clockValue.value))
            #expect(try a.store.isUploadEnabled() && a.store.backend() == .cloudkit)
            #expect(await world.cloud.recordNames.contains("e.note.\(secret.id)"))
        }
    }

    @Test func aFirstSyncBlockedOnTheKeychainGoesOnWhenTheSeedArrives() async throws {
        let world = try CoordWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let note = try a.noteStore.create(text: "# One\n")
        try await a.enable()
        // a second device whose iCloud Keychain has not brought the seed yet
        let b = try CoordDevice("late", cloud: world.cloud, keychain: InMemoryCloudKeychain())
        defer { b.cleanup() }
        #expect(try await b.enable() == .waitingForKeychain)
        #expect(try b.note(note.id) == nil)
        let account = try #require(try a.store.keyState().accountId)
        try b.seedStore.saveSeed(try #require(try a.seedStore.seed(accountId: account)), accountId: account)
        // no second enable: the next cycle (a timer, a signal) takes the first sync on
        _ = try await b.coordinator.syncNow()
        #expect(try b.note(note.id)?.text == "# One\n")
        #expect(try b.store.isUploadEnabled())
        #expect(await Self.upToDate(b.coordinator))
    }

    @Test func aFirstSyncBlockedOnTheAccountGoesOnWhenTheAccountReturns() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            await a.fake.signOut()
            #expect(try await a.enable() == .signedOutOfICloud)
            await a.fake.signIn(user: world.cloud)
            // the account event alone restarts the first sync
            #expect(try await eventually(timeout: 10) { await world.cloud.recordNames.contains("e.note.\(note.id)") })
            #expect(try await eventually { await Self.upToDate(a.coordinator) })
        }
    }

    @Test func aFirstSyncBlockedOnADependencyGoesOnWhenItClearsWithoutASecondEnable() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Scan\n![f](f.bin)\n")
        let bytes = Data((0..<(2 * blobMiB + 11)).map { UInt8(($0 &* 13) % 251) })
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "f.bin", to: note.id)
        try await a.enable()
        // B can see the note and its file entity, but not the parts of the blob
        let blocking = PartBlockingGateway(b.gateway)
        blocking.blocked = true
        let state = try await b.enable(using: b.makeCoordinator(gateway: blocking))
        #expect(state == .syncing)
        #expect(try b.store.isUploadEnabled() == false, "uploads stay off while a fetched version waits")
        blocking.blocked = false
        // the signal alone (nobody calls enable again)
        await b.fake.pushRemoteChange()
        #expect(try await eventually(timeout: 15) { try b.store.isUploadEnabled() })
        #expect(try await eventually(timeout: 15) { await Self.upToDate(b.coordinator) })
        #expect(try Data(contentsOf: b.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("f.bin")) == bytes)
    }

    @Test func theSwitchStaysOnAcrossARestartWhileTheFirstSyncIsBlocked() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let secret = try a.noteStore.create(text: "# Secret\n")
            try NotePrivacy(store: a.noteStore).setPassword("correct horse").lock(noteId: secret.id)
            #expect(try await a.enable() == .needsNotePassword)
            await a.coordinator.endAsIfTheProcessDied()
            // the app starts again; nobody asked to enable again, but the person's switch is still on
            #expect(try await a.makeCoordinator().launch() == .needsNotePassword)
            // The password comes before the keys now: no key exists yet after this restart, so the person is asked about the
            // recovery words again (the choice made before the restart lived in memory only), then the first sync goes on.
            await #expect(throws: CloudCoordinatorError.recoveryChoiceRequired) { _ = try await a.coordinator.syncNow(notePassword: "correct horse") }
            #expect(try await a.enable(notePassword: "correct horse") == .upToDate(lastSync: a.clockValue.value))
            // switched off means off
            await a.coordinator.disable()
            #expect(try await a.makeCoordinator().launch() == .off)
        }
    }

    // MARK: I2, a changed key bundle is verified before further data work

    static func rotate(_ a: CoordDevice) async throws {
        let keys = try await a.liveKeys()
        let rotation = CloudRecoveryRotation(seeds: a.seedStore, bundles: CloudKeyBundleStore(gateway: a.gateway, results: a.store), state: a.store)
        let offer = try RecoveryKeyOffer.make()
        let list = offer.words.split(separator: " ").map(String.init)
        let choice = try offer.confirm(Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, list[$0]) }))
        _ = try await rotation.createOrReplaceRecoveryKey(choice, keys: keys)
    }

    /// Writes `bundle` over the cloud's current key bundle, as another (older or newer) client could.
    static func put(_ bundle: CloudKeyBundle, from a: CoordDevice, in cloud: FakeCloudKitAccount) async throws {
        let current = try #require(await cloud.record(named: "keybundle"))
        let record = try CloudKeyBundleCodec.record(bundle, systemFields: current.systemFields)
        try await a.gateway.submit([CloudSave(attemptId: "replay-" + UUID().uuidString, accountGeneration: try a.store.generation(), record: record)])
    }

    @Test func aChangedValidBundleIsVerifiedAndTheCycleGoesOn() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            let before = try #require(try b.store.cachedKeyBundle()).rev
            try await Self.rotate(a)
            try a.edit(note.id, "# One\nafter the rotation\n")
            try await a.coordinator.syncNow()
            #expect(try await b.coordinator.syncNow() == .upToDate(lastSync: b.clockValue.value))
            #expect(try b.store.cachedKeyBundle()?.rev == before + 1)
            #expect(try b.note(note.id)?.text == "# One\nafter the rotation\n")
        }
    }

    @Test func anInvalidBundleDuringAnActiveSessionPausesDataWork() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            try a.edit(note.id, "# One\nedited on A\n")
            try await a.coordinator.syncNow()
            await a.fake.corrupt(record: "keybundle", field: "envelope")
            try b.sql("INSERT INTO setting(key,value) VALUES('hideMarkdown','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            let savesBefore = b.gateway.saves.count
            let state = try await b.coordinator.syncNow()
            #expect(state == .failed(kind: "keyBundleUnreadable"), "got \(state)")
            #expect(try b.note(note.id)?.text == "# One\n", "the fetched change is not applied while the keys are unverified")
            #expect(b.gateway.saves.count == savesBefore, "and nothing is published")
            // still held on the next cycle, with no new signal about the bundle
            #expect(try await b.coordinator.syncNow() == .failed(kind: "keyBundleUnreadable"))
            #expect(try b.note(note.id)?.text == "# One\n")
        }
    }

    @Test func aRolledBackBundleDuringAnActiveSessionPausesDataWorkUntilTheRealOneReturns() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            let older = try #require(try b.store.cachedKeyBundle())
            try await Self.rotate(a)
            try await b.coordinator.syncNow()
            let newer = try #require(try b.store.cachedKeyBundle())
            #expect(newer.rev > older.rev)
            try a.edit(note.id, "# One\nedited on A\n")
            try await a.coordinator.syncNow()
            // somebody puts the old bundle back
            try await Self.put(older, from: a, in: world.cloud)
            try b.sql("INSERT INTO setting(key,value) VALUES('hideMarkdown','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            let savesBefore = b.gateway.saves.count
            let state = try await b.coordinator.syncNow()
            #expect(state == .failed(kind: "keyRollback"), "got \(state)")
            #expect(try b.note(note.id)?.text == "# One\n")
            #expect(b.gateway.saves.count == savesBefore)
            #expect(try b.store.cachedKeyBundle()?.rev == newer.rev, "the verified copy is not replaced by a rolled-back one")
            // the real bundle returns: the held work goes on
            try await Self.put(newer, from: a, in: world.cloud)
            _ = try await b.coordinator.syncNow()
            #expect(try await b.coordinator.syncNow() == .upToDate(lastSync: b.clockValue.value))
            #expect(try b.note(note.id)?.text == "# One\nedited on A\n")
        }
    }

    // MARK: I3, a starter note deleted before the first binding stays deleted

    @Test func aStarterNoteDeletedOnAAndUntouchedOnBStaysDeleted() async throws {
        for deletedFirst in [true, false] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            for device in world.devices { try StarterFixtures.seed(device) }
            let target = StarterFixtures.ids[3]
            try a.hardDelete(target)
            if deletedFirst { try await a.enable(); try await b.enable() } else { try await b.enable(); try await a.enable() }
            try await world.converge()
            #expect(try a.note(target) == nil, "deleted first: \(deletedFirst)")
            // B's copy was the last one: it is in the Trash, not in Notes
            #expect(try b.note(target)?.location != .notes)
            #expect(try a.count("note") == 11 && b.conflictCopies() == 0 && a.conflictCopies() == 0)
            // nobody brings it back
            for _ in 0..<3 { for device in world.devices { try await device.coordinator.syncNow() } }
            #expect(try a.note(target) == nil && b.note(target)?.location != .notes)
        }
    }

    @Test func aStarterNoteDeletedOnAAndEditedOnBKeepsTheEdit() async throws {
        for deletedFirst in [true, false] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            for device in world.devices { try StarterFixtures.seed(device) }
            let target = StarterFixtures.ids[3]
            let edited = try #require(try b.note(target)).text + "\nMy own addition.\n"
            try b.edit(target, edited)
            try a.hardDelete(target)
            if deletedFirst { try await a.enable(); try await b.enable() } else { try await b.enable(); try await a.enable() }
            try await world.converge()
            for device in world.devices {
                #expect(try device.note(target)?.text == edited && device.note(target)?.location == .notes, "\(device.name), deleted first: \(deletedFirst)")
                #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
            }
        }
    }

    @Test func anOrdinaryNoteDeletedBeforeBindingIsNotAffected() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let gone = try a.noteStore.create(text: "# Gone\n")
            try a.hardDelete(gone.id)
            try await a.enable(); try await b.enable()
            try await world.converge()
            #expect(await world.cloud.recordNames.contains("e.note.\(gone.id)") == false)
            #expect(try a.string("SELECT deletedStarters FROM ck_state") == nil || a.string("SELECT deletedStarters FROM ck_state") == "[]")
        }
    }

    // MARK: round 2

    @Test func anUndecodableBundleMidSessionStopsDataWork() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            try a.edit(note.id, "# One\nedited on A\n")
            try await a.coordinator.syncNow()
            // the bundle record becomes something this build cannot even decode (the sink quarantines it)
            await a.fake.injectUnsupportedVersion(record: "keybundle")
            try b.sql("INSERT INTO setting(key,value) VALUES('hideMarkdown','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            let savesBefore = b.gateway.saves.count
            let state = try await b.coordinator.syncNow()
            #expect(state == .failed(kind: "keyBundleUnreadable"), "got \(state)")
            #expect(try b.note(note.id)?.text == "# One\n", "no data is applied")
            #expect(b.gateway.saves.count == savesBefore, "nothing is published")
            #expect(try await b.coordinator.syncNow() == .failed(kind: "keyBundleUnreadable"), "and the next cycle is held the same way")
            #expect(try b.note(note.id)?.text == "# One\n")
        }
    }

    @Test func afterADetachOrADisableALaunchStartsNoSync() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            #expect(try a.store.isSwitchedOn())
            // detach (the CloudKit branch): the switch goes with the rest of the binding
            await a.coordinator.endAsIfTheProcessDied()
            try a.sql("INSERT INTO backup_catalog(id, filename, createdAt, plaintextNoteIds) VALUES('b1','baerchen-b1.baerchen-backup', datetime('now'), '[]')")
            try SyncAccountDetach.detach(database: a.db, expectedBackend: .cloudkit, verifiedBackupID: "b1")
            #expect(try a.store.isSwitchedOn() == false && a.store.deletedStarters().isEmpty && a.store.cachedKeyBundle() == nil)
            let calls = a.gateway.callCount
            #expect(try await a.makeCoordinator().launch() == .off)
            #expect(a.gateway.callCount == calls, "no sync started")
            // and the same after the person switched it off
            let b = try CoordDevice("off", cloud: world.cloud, keychain: world.keychain)
            defer { b.cleanup() }
            _ = try b.noteStore.create(text: "# Two\n")
            try await b.enable()
            await b.coordinator.disable()
            let before = b.gateway.callCount
            #expect(try await b.makeCoordinator().launch() == .off)
            #expect(b.gateway.callCount == before)
        }
    }

    @Test func aNewerFetchedVersionReplacesAHeldOneAndAppliesAfterTheKeyHoldWithoutLosingALocalEdit() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let base = "# Note\nfirst line\n\nmiddle\n\nlast line\n"
            let note = try a.noteStore.create(text: base)
            try await a.enable(); try await b.enable()
            let older = try #require(try b.store.cachedKeyBundle())
            try await Self.rotate(a)
            try await b.coordinator.syncNow()
            let newer = try #require(try b.store.cachedKeyBundle())
            try a.edit(note.id, "# Note\nfirst line by A\n\nmiddle\n\nlast line\n")
            try await a.coordinator.syncNow()
            // somebody puts the old bundle back: B holds the first version
            try await Self.put(older, from: a, in: world.cloud)
            #expect(try await b.coordinator.syncNow() == .failed(kind: "keyRollback"))
            let held = try #require(try b.store.remote(recordName: "e.note.\(note.id)")).ver
            // the real bundle returns for a moment, A publishes a second version, the old bundle is put back again:
            // the newest version replaces the held one
            try await Self.put(newer, from: a, in: world.cloud)
            try a.edit(note.id, "# Note\nfirst line by A, again\n\nmiddle\n\nlast line\n")
            try await a.coordinator.syncNow()
            try await Self.put(older, from: a, in: world.cloud)
            #expect(try await b.coordinator.syncNow() == .failed(kind: "keyRollback"))
            #expect(try #require(try b.store.remote(recordName: "e.note.\(note.id)")).ver > held)
            // B edits another part meanwhile
            try b.edit(note.id, base.replacingOccurrences(of: "last line", with: "last line by B"))
            try await Self.put(newer, from: a, in: world.cloud)
            _ = try await b.coordinator.syncNow()
            try await world.converge()
            let expected = "# Note\nfirst line by A, again\n\nmiddle\n\nlast line by B\n"
            #expect(try b.note(note.id)?.text == expected && a.note(note.id)?.text == expected, "newest version applied, local edit kept")
            #expect(try b.conflictCopies() == 0 && a.conflictCopies() == 0)
        }
    }
}
