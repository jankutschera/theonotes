// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The coordinator over `FakeCloudKit`: first run, the enable-marker cleanup, cycles, switching off, ownership, events, launch and
/// the library rules.
@Suite struct CloudSyncCoordinatorTests {
    // MARK: a plain round trip

    @Test func twoDevicesSyncAnOrdinaryLibrary() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\nhello #tag\n")
            #expect(try await a.enable() == .upToDate(lastSync: a.clockValue.value))
            #expect(try await b.enable() == .upToDate(lastSync: b.clockValue.value))
            #expect(try b.note(note.id)?.text == "# One\nhello #tag\n")
            try a.edit(note.id, "# One\nhello again #tag\n")
            try await world.converge()
            #expect(try b.note(note.id)?.text == "# One\nhello again #tag\n")
            #expect(try a.fingerprint() == b.fingerprint())
        }
    }

    // MARK: the cleanup of rows the enable step dirtied (E0 review point 1, Critical)

    /// Two libraries with the same `count` notes (same ids, texts and stamps), like two starter sets.
    static func identicalNotes(_ world: CoordWorld, count: Int) throws -> [String] {
        let ids = (0..<count).map { String(format: "00000000-0000-4000-8000-%012d", $0 + 1) }
        for device in world.devices {
            try device.noteStore.write { db in
                for (index, id) in ids.enumerated() {
                    _ = try NoteStore.insert(id: id, text: "# Note \(index)\nbody \(index)\n", now: Date(timeIntervalSince1970: 1_793_188_800 - Double(index)), in: db)
                }
            }
        }
        return ids
    }

    @Test func theEnableStepMarksEverythingAtGenerationZeroAndAnEditRaisesIt() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let one = try a.noteStore.create(text: "# One\n"), two = try a.noteStore.create(text: "# Two\n")
            try a.store.bind(accountId: "ck-test", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
            // bound, uploads off: a person's edit is captured at once, with a real generation
            try a.edit(one.id, "# One edited\n")
            let first = try #require(try a.dirtyGeneration(one.id))
            #expect(first >= 1)
            #expect(try a.store.enableUploads() >= 1)
            #expect(try a.dirtyGeneration(one.id) == first, "a row a person's edit made keeps its own generation")
            #expect(try a.dirtyGeneration(two.id) == CloudSyncStore.enableGeneration)
            #expect(try a.store.enableMarkerCount() >= 1)
            try a.edit(two.id, "# Two edited\n")
            let raised = try #require(try a.dirtyGeneration(two.id))
            #expect(raised > CloudSyncStore.enableGeneration, "an edit raises the marker above the enable generation")
            try a.sql("DELETE FROM note WHERE id='\(two.id)'")
            #expect(try #require(try a.dirtyGeneration(two.id)) > raised)
            // repeating the switch creates nothing
            #expect(try a.store.enableUploads() == 0)
        }
    }

    @Test func cleanupClearsOnlyUneditedMarkersOfContentTheCloudHolds() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let ids = try Self.identicalNotes(world, count: 6)
            try await a.enable(); try await b.enable()
            try await world.converge()
            #expect(try b.dirty().isEmpty, "the second device published nothing it just downloaded")
            // sync off on B, an edit while off, then on again: every row is marked, the edited one keeps its own generation
            await b.coordinator.disable()
            try b.edit(ids[1], "# Note 1\nedited while off\n")
            #expect(try b.dirtyGeneration(ids[1]) == 1)
            try await b.enable()
            try await world.converge()
            #expect(await world.cloud.versionCount(of: "e.note.\(ids[1])") == 2)
            for id in ids where id != ids[1] { #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 1, "\(id) was published again") }
            #expect(try a.note(ids[1])?.text == "# Note 1\nedited while off\n")
            #expect(try b.store.enableMarkerCount() == 0)
        }
    }

    @Test func anEditBetweenEnableAndCleanupKeepsItsMarker() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let ids = try Self.identicalNotes(world, count: 6)
        try await a.enable()
        // on B the person edits note 0 at the one moment between the enable step and the cleanup, and edits note 1 and restores its
        // text. Neither marker may be cleared: an edit is an edit, even one that changed nothing in the end.
        b.hooks.on("firstRun.afterEnable") {
            try? b.edit(ids[0], "# Note 0\nedited in the window\n")
            try? b.edit(ids[1], "# Note 1\ntemporary\n")
            try? b.edit(ids[1], "# Note 1\nbody 1\n")
            // and something marks note 2 dirty without changing what it says (an apply, an import, a stage): not the enable step's either
            try? b.sql("UPDATE sync_dirty SET generation=generation+1 WHERE entityType='note' AND localId='\(ids[2])'")
        }
        try await b.enable()
        try await world.converge()
        #expect(try a.note(ids[0])?.text == "# Note 0\nedited in the window\n")
        #expect(await world.cloud.versionCount(of: "e.note.\(ids[0])") == 2)
        #expect(await world.cloud.versionCount(of: "e.note.\(ids[1])") == 2, "the restored note is kept dirty and saved once")
        #expect(await world.cloud.versionCount(of: "e.note.\(ids[2])") == 2, "a marker something else raised is not the enable step's any more")
        for id in ids.dropFirst(3) { #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 1) }
    }

    @Test func aCrashBetweenEnableAndCleanupLeavesMarkersTheNextRunClears() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let ids = try Self.identicalNotes(world, count: 6)
        try await a.enable()
        let crash = CrashPoint()
        crash.arm("firstRun.afterEnable")
        let first = b.makeCoordinator(crash: crash)
        await #expect(throws: CrashInjected(boundary: "firstRun.afterEnable")) { _ = try await b.enable(using: first) }
        #expect(try b.store.isUploadEnabled())
        #expect(try b.store.enableMarkerCount() >= ids.count, "the markers are durable")
        // after the restart the first run goes on and the markers go without a single upload
        try await b.enable(using: b.makeCoordinator())
        try await world.converge()
        #expect(try b.store.enableMarkerCount() == 0)
        #expect(b.gateway.savedNames.filter { $0.hasPrefix("e.note.") }.isEmpty)
        for id in ids { #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 1) }
    }

    @Test func aCrashInsideTheCleanupChangesNothingAndTheNextRunFinishesIt() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let ids = try Self.identicalNotes(world, count: 4)
        try await a.enable()
        let crash = CrashPoint()
        crash.arm("cleanup.beforeTransaction")
        await #expect(throws: CrashInjected(boundary: "cleanup.beforeTransaction")) { _ = try await b.enable(using: b.makeCoordinator(crash: crash)) }
        try await b.enable(using: b.makeCoordinator())
        try await world.converge()
        #expect(try b.store.enableMarkerCount() == 0)
        for id in ids { #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 1) }
    }

    @Test func editsRacingTheCleanupNeverLoseADirtyMarker() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let ids = try Self.identicalNotes(world, count: 40)
        try await a.enable()
        let crash = CrashPoint()
        crash.arm("firstRun.afterEnable")
        await #expect(throws: CrashInjected(boundary: "firstRun.afterEnable")) { _ = try await b.enable(using: b.makeCoordinator(crash: crash)) }
        let keys = try await b.liveKeys()
        let edited = Array(ids.prefix(20))
        // the cleanup and a person's edits run at the same time
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<5 { _ = try? b.store.cleanUpEnableMarkers(accountID: keys.accountID, vaultKey: keys.vaultKey) }
            }
            group.addTask {
                for (index, id) in edited.enumerated() { try? b.edit(id, "# Note \(index)\nedited \(index) during the cleanup\n") }
            }
        }
        for (index, id) in edited.enumerated() {
            #expect(try b.note(id)?.text == "# Note \(index)\nedited \(index) during the cleanup\n")
            let generation = try b.dirtyGeneration(id)
            #expect((generation ?? 0) >= 1, "the edit of \(id) lost its dirty marker (generation \(String(describing: generation)))")
        }
        // and they all reach the cloud, the untouched notes do not
        try await b.enable(using: b.makeCoordinator())
        try await world.converge()
        for (index, id) in edited.enumerated() {
            #expect(try a.note(id)?.text == "# Note \(index)\nedited \(index) during the cleanup\n")
        }
        for id in ids.dropFirst(20) { #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 1) }
    }

    // MARK: the first shipped starter texts are the merge base

    @Test func theFirstShippedStarterTextsAreFrozen() throws {
        // The FROZEN first shipped set (Resources/starter-v1-*.md) is the oldest merge base. Never edit those files. When a bundled text
        // changes, the frozen set stays as it is and the new set becomes one more shipped version.
        let frozen = try GettingStartedNotes.firstShippedNotes()
        #expect(frozen.count == 12)
        func digest(_ texts: [String]) -> String {
            SHA256.hash(data: Data(texts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        // the first eight: the digest this test has pinned since the first release
        #expect(digest(frozen.prefix(8).map(\.text)) == "62d9a18e2af3bba52b0bc68aa62150d0f755b6231fb845a97dc59b20bab3be32", "the first shipped starter texts changed")
        #expect(digest(frozen.map(\.text)) == "81b00823d8ac9170cf970b78341644cd96c216cf63bc51fd6f68878b9a48ff10")
        // and the base is what a real device of the first release uploaded, payload for payload (digest taken from 2e51ba4a, which
        // built it from the bundled texts of that commit)
        var all = Data()
        for id in GettingStartedNotes.ids { all.append(try #require(CloudStarterBase.firstShippedPayloads[id])); all.append(0) }
        let payloadDigest = SHA256.hash(data: all).map { String(format: "%02x", $0) }.joined()
        #expect(payloadDigest == "48ea8b9d3dfaf423d01bdd0a7b9ec06ef6db34803724a4efd664e56ae720d99d", "\(payloadDigest)")
        #expect(CloudStarterBase.firstShippedPayloads.count == 12)
        // The bundled set (v2, shipped with 1.1) is pinned too: it becomes a shipped version the moment 1.1 is out (review r1 S2).
        // Re-pinned in place for the scenario texts: no build with the earlier v2 texts ever shipped.
        #expect(digest(try GettingStartedNotes.notes().map(\.text)) == "c90dc5b9449a3a70d5826ad75bd933e4a29426ee0e51d72a9dfedae8599b0882",
                "a bundled starter text changed: copy the current files to Resources/starter-v2-*.md and add them to CloudStarterBase.shippedPayloads (STARTER-R1, R2) BEFORE changing a text, then update this digest")
        // v2 is frozen as Resources/starter-v2-*.md: byte for byte what is bundled today, until a v3 is intentionally added
        let second = try GettingStartedNotes.secondShippedNotes()
        #expect(second.count == 12)
        #expect(digest(second.map(\.text)) == "c90dc5b9449a3a70d5826ad75bd933e4a29426ee0e51d72a9dfedae8599b0882", "the frozen v2 starter texts changed")
        #expect(second.map(\.text) == (try GettingStartedNotes.notes().map(\.text)), "a bundled text moved away from the frozen v2: add a v3 set first")
        var v2all = Data()
        for id in GettingStartedNotes.ids { v2all.append(try #require(CloudStarterBase.secondShippedPayloads[id])); v2all.append(0) }
        let v2Payloads = SHA256.hash(data: v2all).map { String(format: "%02x", $0) }.joined()
        #expect(v2Payloads == "0263c5f136e46f3d3474d8fc76ba2cf33108326bd93ccf596c8fb8bc4b9366cd", "\(v2Payloads)")
        for id in GettingStartedNotes.ids {  // v1, v2 (when different), nothing more: the bundled set equals v2
            let list = try #require(CloudStarterBase.shippedPayloads[id])
            #expect(list.first == CloudStarterBase.firstShippedPayloads[id] && list.last == CloudStarterBase.secondShippedPayloads[id] && list.count <= 2)
        }
        for note in frozen {
            let payload = try #require(CloudStarterBase.firstShippedPayloads[note.id])
            let decoded = try SyncPayloadCodec.decode(SyncNotePayload.self, from: payload)
            #expect(decoded.text == note.text && decoded.id == note.id)
        }
    }

    // MARK: single owner per library

    @Test func aSecondOwnerOfTheSameLibraryIsRefused() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            let first = a.makeCoordinator()
            try await a.enable(using: first)
            let second = a.makeCoordinator()
            await #expect(throws: CloudCoordinatorError.ownedElsewhere) { _ = try await a.enable(using: second) }
            await #expect(throws: CloudCoordinatorError.ownedElsewhere) { _ = try await second.launch() }
            await first.disable()
            // after the owner stopped the library can be taken over
            #expect(try await a.enable(using: second) == .upToDate(lastSync: a.clockValue.value))
        }
    }

    @Test func theOwnerLockIsAnExclusiveFileLockInTheLibraryFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ck-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CloudSyncOwnerLock.acquire(root: root)
        #expect(first.isHeld)
        #expect(throws: CloudSyncOwnerLock.Failure.ownedElsewhere) { _ = try CloudSyncOwnerLock.acquire(root: root) }
        // another library is another owner
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("ck-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: other) }
        _ = try CloudSyncOwnerLock.acquire(root: other)
        first.release()
        #expect(!first.isHeld)
        _ = try CloudSyncOwnerLock.acquire(root: root)
    }

    @Test func theCommandLineAndTheMcpServerNeverSync() throws {
        // `theonotes` (CLI and MCP) write through the SQLite triggers; only the app process owns the gateway, the keys and the blobs
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["CloudSync", "CloudKit", "CloudKey", "CloudGateway", "CloudBlob", "CloudPublisher", "CloudReconciler"]
        var checked = 0
        for target in ["baerchen", "TheoNotesAutomation"] {
            let folder = package.appendingPathComponent("Sources/\(target)")
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                for word in forbidden { #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)") }
            }
        }
        #expect(checked > 0, "the CLI and MCP sources were found")
    }

    // MARK: library rules

    @Test func cloudflareBoundLibraryRefusesCloudKitEnable() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try a.sql("UPDATE sync_control SET accountId='cloudflare-account' WHERE id=1")
            #expect(try a.store.backend() == .cloudflare)
            await #expect(throws: CloudCoordinatorError.boundToCloudflare) { _ = try await a.enable() }
            await #expect(throws: CloudCoordinatorError.boundToCloudflare) { _ = try await a.coordinator.launch() }
            // nothing was touched: not the cloud, not the keychain, not the library
            #expect(a.gateway.callCount == 0 && a.backups == 0)
            #expect(a.seedStore.keychain.log.isEmpty)
            #expect(try a.store.backend() == .cloudflare && a.string("SELECT accountId FROM sync_control") == "cloudflare-account")
            // and the store itself refuses to bind it
            #expect(throws: CloudSyncStoreError.backendConflict(.cloudflare)) {
                try a.store.bind(accountId: "ck-x", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
            }
        }
    }

    @Test func libraryCopyIsHardOff() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            await a.coordinator.disable()
            // a copy of this library, bound and enabled in its tables, opened the way `--data-dir` does
            try a.sql("UPDATE sync_control SET enabled=1 WHERE id=1")
            let copyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ck-copy-\(UUID())")
            defer { try? FileManager.default.removeItem(at: copyRoot) }
            try FileManager.default.copyItem(at: a.paths.root, to: copyRoot)
            let copy = try CoordDevice("copy", cloud: world.cloud, keychain: InMemoryCloudKeychain(), root: copyRoot)
            defer { try? copy.database.pool.close() }
            copy.syncPolicy = .localOnly
            #expect(try copy.store.backend() == .cloudkit && copy.store.isUploadEnabled())
            await #expect(throws: CloudCoordinatorError.libraryCopyNeverSyncs) { _ = try await copy.coordinator.launch() }
            await #expect(throws: CloudCoordinatorError.libraryCopyNeverSyncs) { _ = try await copy.coordinator.enable(recovery: nil) }
            #expect(copy.gateway.callCount == 0 && copy.seedStore.keychain.log.isEmpty, "a library copy never reaches iCloud or the keychain")
            #expect(await copy.coordinator.currentState == .off)
        }
    }

    @Test func anUnconfiguredBuildDoesNothing() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let coordinator = a.makeCoordinator(configuration: nil)
            let enabled = try await coordinator.enable(recovery: nil), launched = try await coordinator.launch()
            #expect(enabled == .notAvailableInThisBuild && launched == .notAvailableInThisBuild)
            #expect(a.gateway.callCount == 0 && a.seedStore.keychain.log.isEmpty)
        }
    }

    @Test func protectedLibraryAsksForNotePasswordBeforeFirstSync() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# Private\nsecret body\n")
            let access = try NotePrivacy(store: a.noteStore).setPassword("correct horse")
            try access.lock(noteId: note.id)
            // without the password: asked for, before any backup, binding or upload
            #expect(try await a.enable() == .needsNotePassword)
            #expect(a.backups == 0, "the safety backup waits for the password")
            #expect(try a.store.backend() == .none && a.store.isUploadEnabled() == false)
            #expect(a.gateway.savedNames.allSatisfy { $0 == "keybundle" }, "no note data is saved before the password")
            // a wrong password changes nothing either
            await #expect(throws: CryptoError.wrongPassword) { _ = try await a.enable(notePassword: "wrong") }
            #expect(try a.store.backend() == .none && a.backups == 0)
            // with it, the first sync runs and the locked note reaches the other device still locked
            #expect(try await a.enable(notePassword: "correct horse") == .upToDate(lastSync: a.clockValue.value))
            #expect(a.backups == 1 && a.passwordChecks >= 1)
        }
    }

    // MARK: switching off

    @Test func disableStopsEngineAndLeavesLibrary() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            try await world.converge()
            let before = try a.fingerprint()
            let namesBefore = await world.cloud.recordNames, callsBefore = a.gateway.callCount
            let seedBefore = try a.seedStore.seed(accountId: try #require(try a.store.keyState().accountId))
            await a.coordinator.disable()
            // the library is untouched, the cloud and the keychain too, and the engine makes no further call
            #expect(try a.fingerprint() == before && a.store.backend() == .cloudkit)
            #expect(await world.cloud.recordNames == namesBefore)
            #expect(try a.seedStore.seed(accountId: try #require(try a.store.keyState().accountId)) == seedBefore)
            #expect(await a.coordinator.currentState == .off)
            await #expect(throws: CloudCoordinatorError.notRunning) { _ = try await a.coordinator.syncNow() }
            await a.fake.pushRemoteChange()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(a.gateway.callCount == callsBefore, "a stopped engine does not touch the cloud")
            #expect(a.gateway.deletes.isEmpty)
            // edits made meanwhile are captured and go out when it is switched on again
            try a.edit(note.id, "# One\nedited while off\n")
            #expect(try a.dirtyGeneration(note.id) == 1)
            try await a.enable(using: a.makeCoordinator())
            try await world.converge()
            #expect(try b.note(note.id)?.text == "# One\nedited while off\n")
        }
    }

    // MARK: events

    @Test func remoteChangeEventTriggersOneCoalescedCycle() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            try await world.converge()
            let coordinator = a.coordinator
            // everything the setup made has settled: no signal is still on its way to A
            var last = -1
            while true {
                let seen = await coordinator.handledEvents
                if seen == last { break }
                last = seen
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            let base = await coordinator.completedCycles
            // a burst of ten "something changed" signals; the first starts a cycle, which is held at its start
            let hold = Latch(), entered = LockedBox<Bool>(false)
            a.hooks.on("cycle.begin") { entered.update { $0 = true }; await hold.wait() }
            let eventsBefore = await coordinator.handledEvents
            await a.fake.pushRemoteChange()
            #expect(try await eventually { entered.value })
            // B changes the note meanwhile; the rest of the burst reaches the listener while the first cycle is held
            try b.edit(note.id, "# One\nfrom B\n")
            try await b.coordinator.syncNow()
            for _ in 0..<9 { await a.fake.pushRemoteChange() }
            #expect(try await eventually { await coordinator.handledEvents >= eventsBefore + 10 })
            last = -1
            while true {
                let seen = await coordinator.handledEvents
                if seen == last { break }
                last = seen
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            a.hooks.clear()
            await hold.release()
            let reached = try await eventually { await coordinator.completedCycles >= base + 2 }
            try await Task.sleep(nanoseconds: 400_000_000)
            let total = await coordinator.completedCycles
            #expect(reached && total == base + 2, "the burst made \(total - base) cycles, base \(base)")
            #expect(try a.note(note.id)?.text == "# One\nfrom B\n", "the cycle the signal started pulled the change")
        }
    }

    @Test func anAccountChangeEventPausesAndTheSameAccountReturningResumes() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            let coordinator = a.coordinator
            await a.fake.signOut()
            #expect(try await eventually { await coordinator.currentState == .signedOutOfICloud })
            try a.edit(note.id, "# One\nwhile signed out\n")
            let savesBefore = a.gateway.saves.count
            #expect(try await coordinator.syncNow() == .signedOutOfICloud)
            #expect(a.gateway.saves.count == savesBefore, "nothing is sent while signed out")
            #expect(try a.dirtyGeneration(note.id) != nil, "the edit waits in the journal")
            await a.fake.signIn(user: world.cloud)
            #expect(try await eventually(timeout: 10) { await world.cloud.versionCount(of: "e.note.\(note.id)") == 2 })
            #expect(try await eventually { if case .upToDate = await coordinator.currentState { true } else { false } })
        }
    }

    @Test func anotherAccountPausesAndNeverReceivesTheLibrary() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            let coordinator = a.coordinator
            let other = FakeCloudKitAccount(user: "someone-else")
            await a.fake.switchAccount(to: other)
            #expect(try await eventually { if case .accountChanged = await coordinator.currentState { true } else { false } })
            try a.edit(note.id, "# One\nafter the switch\n")
            if case .accountChanged = try await coordinator.syncNow() {} else { Issue.record("expected the account-changed state") }
            if case .accountChanged = try await coordinator.foreground() {} else { Issue.record("foreground does not lift it either") }
            #expect(await other.recordNames.isEmpty, "the other person's iCloud received nothing")
            #expect(try a.dirtyGeneration(note.id) != nil)
        }
    }

    @Test func aRemovedSyncedCopyIsReportedAndNotCreatedAgain() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            let coordinator = a.coordinator
            await world.cloud.removeZone(reason: .userDeletedZone)
            await a.fake.pushRemoteChange()
            #expect(try await eventually { if case .zoneRemoved = await coordinator.currentState { true } else { false } })
            #expect(await world.cloud.recordNames.isEmpty, "nothing creates it again by itself")
            // the person chooses to upload again: only now may the zone be made again
            try await coordinator.chooseUploadAgain()
            // the zone is made again together with the key bundle (c); no note is uploaded by this step
            #expect(try a.store.zoneState() == .created)
            #expect(await world.cloud.recordNames == [CloudRecordCodec.keyBundleRecordName])
        }
    }

    // MARK: launch

    @Test func launchTreatsSendingAsUnknownAndResolvesThroughTheFence() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            let crash = CrashPoint()
            let first = a.makeCoordinator(crash: crash)
            try await a.enable(using: first)
            // a save lands in the cloud, its answer never reaches the app, and the process dies right after the send
            try a.edit(note.id, "# One\nedited\n")
            await a.fake.loseNextResponseAfterCommit(report: .silence)
            crash.arm("publisher.afterSubmit")
            await #expect(throws: CrashInjected(boundary: "publisher.afterSubmit")) { _ = try await first.syncNow() }
            #expect(try a.store.allInflight().map(\.state) == [.sending])
            #expect(await world.cloud.versionCount(of: "e.note.\(note.id)") == 2)
            // the next launch: sending becomes unknown, the fence-level resolution finds the cloud's version is ours and records it
            let restarted = a.makeCoordinator()
            #expect(try await restarted.launch() == .upToDate(lastSync: a.clockValue.value))
            #expect(a.gateway.calls.contains("fetch:sid"), "unknown outcomes are resolved through the generation fence")
            #expect(try a.store.allInflight().isEmpty && a.dirtyGeneration(note.id) == nil)
            #expect(try a.store.pair(for: CloudEntityRef(entityType: "note", entityId: note.id))?.ver == 2)
            #expect(await world.cloud.versionCount(of: "e.note.\(note.id)") == 2, "the save was not repeated")
        }
    }

    @Test func launchWorksOfflineFromTheCachedKeyBundle() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            #expect(try a.store.cachedKeyBundle() != nil, "the verified bundle was kept")
            await a.coordinator.endAsIfTheProcessDied()
            let flaky = FlakyGateway(a.gateway)
            flaky.isOffline = true
            let restarted = a.makeCoordinator(gateway: flaky)
            let state = try await restarted.launch()
            guard case .offline = state else { Issue.record("expected offline, got \(state)"); return }
            // the engine is there: the library keeps capturing, and the first cycle online sends what was written offline
            try a.edit(note.id, "# One\nwritten offline\n")
            flaky.isOffline = false
            #expect(try await restarted.syncNow() == .upToDate(lastSync: a.clockValue.value))
            #expect(await world.cloud.versionCount(of: "e.note.\(note.id)") == 2)
            // without the cached copy an offline launch has no keys and says it is offline
            await restarted.endAsIfTheProcessDied()
            try a.sql("UPDATE ck_state SET keyBundleCache=NULL")
            flaky.isOffline = true
            let bare = a.makeCoordinator(gateway: flaky)
            guard case .offline = try await bare.launch() else { Issue.record("expected offline"); return }
            await #expect(throws: CloudCoordinatorError.notRunning) { _ = try await bare.syncNow() }
        }
    }

    @Test func launchSweepsPinnedFilesAndRetriesQuarantineForANewBuild() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            await a.coordinator.endAsIfTheProcessDied()
            // a pinned file no row names, a day old, is swept; a young one stays (a crash between copy and commit leaves such files)
            let stray = a.paths.cloudPinned.appendingPathComponent("stray/old.bin"), young = a.paths.cloudPinned.appendingPathComponent("stray/young.bin")
            try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: stray); try Data("y".utf8).write(to: young)
            // Ages are measured on the harness clock (fixed), not the wall clock.
            let now = a.clockValue.value
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: stray.path)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: young.path)
            let restarted = a.makeCoordinator(appBuild: "build-2")
            _ = try await restarted.launch()
            #expect(!FileManager.default.fileExists(atPath: stray.path) && FileManager.default.fileExists(atPath: young.path))
            // quarantine retry ran with the new build number
            #expect(try a.store.lastAppBuild() == "build-2")
        }
    }

    @Test func anUnreadableRecordIsKeptAndShownAndOtherNotesStillSync() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let good = try a.noteStore.create(text: "# Good\n"), bad = try a.noteStore.create(text: "# Bad\n")
            try await a.enable()
            await a.fake.injectUnsupportedVersion(record: "e.note.\(bad.id)")
            try await b.enable()
            #expect(try b.note(good.id) != nil)
            #expect(try b.note(bad.id) == nil)
            #expect(await b.coordinator.currentState == .needsAppUpdate)
            #expect(try b.store.quarantineRows().count == 1, "the record is kept, not skipped and not deleted")
            #expect(await world.cloud.recordNames.contains("e.note.\(bad.id)"))
        }
    }

    @Test func theDrainTimeoutDefaultIsTenSeconds() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            #expect(CloudSyncCoordinator.defaultDrainTimeout == 10)
            #expect(a.makeCoordinator().drainTimeout == 10)
            #expect(a.makeCoordinator(drainTimeout: 2).drainTimeout == 2)
        }
    }

    // MARK: keys

    @Test func noDataRecordSavedBeforeKeyCreationAndRecoveryStep() async throws {
        // killed in the middle of key creation, at three different steps: the cloud never holds a data record yet
        for boundary in ["keys.afterSeed", "keys.afterBundleWritten", "keys.afterRecoveryState"] {
            let world = try CoordWorld.make(1); defer { world.cleanup() }
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            let crash = CrashPoint()
            crash.arm(boundary)
            await #expect(throws: CrashInjected(boundary: boundary)) { _ = try await a.enable(using: a.makeCoordinator(crash: crash)) }
            #expect(await world.cloud.recordNames.allSatisfy { $0 == "keybundle" }, "\(boundary): only the key bundle may exist")
            #expect(a.gateway.savedNames.allSatisfy { $0 == "keybundle" })
            try await a.enable(using: a.makeCoordinator())
            #expect(await world.cloud.recordNames.contains { $0.hasPrefix("e.note.") })
            #expect(a.gateway.savedNames.first == "keybundle")
        }
    }

    @Test func keysAreCreatedBeforeAnyDataRecordAndThePublisherIsGatedOnThem() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            // the very first record the cloud ever received is the key bundle; every data record came after it
            let names = a.gateway.savedNames
            #expect(names.first == "keybundle")
            #expect(names.filter { $0 == "keybundle" }.count == 1)
            #expect(names.dropFirst().allSatisfy { $0.hasPrefix("e.") || $0.hasPrefix("b.") })
            // the gate: with the seed gone from the keychain, key creation no longer counts as complete and nothing more is saved
            let account = try #require(try a.store.keyState().accountId)
            try a.seedStore.removeSeed(accountId: account)
            try a.edit(note.id, "# One\nafter the seed vanished\n")
            let before = a.gateway.saves.count
            let state = try await a.coordinator.syncNow()
            #expect(state == .failed(kind: "keys"))
            #expect(a.gateway.saves.count == before)
        }
    }

    @Test func aReplacedRecoveryKeyOnAnotherDeviceRefreshesTheVerifiedCopy() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable(); try await b.enable()
            let revision = try #require(try b.store.cachedKeyBundle()).rev
            // A replaces the recovery key (the bundle's revision goes up); B's next cycle sees the record and keeps the new copy
            let keys = try await a.liveKeys()
            let rotation = CloudRecoveryRotation(seeds: a.seedStore, bundles: CloudKeyBundleStore(gateway: a.gateway, results: a.store), state: a.store)
            let offer = try RecoveryKeyOffer.make()
            let list = offer.words.split(separator: " ").map(String.init)
            let choice = try offer.confirm(Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, list[$0]) }))
            #expect(try await rotation.createOrReplaceRecoveryKey(choice, keys: keys) == .replaced(revision: revision + 1))
            try await b.coordinator.syncNow()
            #expect(try b.store.cachedKeyBundle()?.rev == revision + 1)
        }
    }

    // MARK: attachments through the real blob transfer

    @Test func attachmentsTravelThroughTheRealBlobTransferBothWays() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# Scan\n![Receipt](receipt.png)\n")
            let bytes = Data((0..<(2 * blobMiB + 5000)).map { UInt8(($0 &* 31 &+ ($0 >> 8)) % 251) })
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "receipt.png", to: note.id)
            try await a.enable(); try await b.enable()
            try await world.converge()
            #expect(!a.blobSettings.diagnostics.uploadedParts.isEmpty, "the publisher uploaded the blob parts through the transfer")
            #expect(!b.blobSettings.diagnostics.downloadedParts.isEmpty, "the receiver downloaded them through the same transfer")
            let installed = b.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("receipt.png")
            #expect(try Data(contentsOf: installed) == bytes)
        }
    }
}
