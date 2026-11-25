// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The first-sync matrix (CK-R13 as amended, REL-R70 to R79, CK-R20): the REAL `GettingStartedNotes` on two or three libraries, the
/// real coordinator, `FakeCloudKit`. No case accepts a lost edit. The first shipped text set is the merge base of a starter note
/// at first contact (CK-R130), so an untouched copy follows whatever the other side did and only real edits make conflict copies.
@Suite(.serialized) struct CloudFirstRunMatrixTests {
    // MARK: helpers

    static func seeded(_ count: Int) throws -> CoordWorld {
        let world = try CoordWorld.make(count)
        for device in world.devices { #expect(try StarterFixtures.seed(device).count == 12) }
        return world
    }

    /// 12 notes, one per starter id, none duplicated by title, no conflict copy anywhere.
    static func expectCleanStarterSet(_ devices: [CoordDevice], sourceLocation: SourceLocation = #_sourceLocation) throws {
        for device in devices {
            let titles = try device.visibleTitles()
            #expect(titles.count == 12, "\(device.name) shows \(titles.count) notes", sourceLocation: sourceLocation)
            #expect(Set(titles).count == titles.count, "\(device.name) has duplicate titles", sourceLocation: sourceLocation)
            #expect(try device.count("note") == 12, sourceLocation: sourceLocation)
            #expect(try device.conflictCopies() == 0, sourceLocation: sourceLocation)
            #expect(try StarterFixtures.starterNotes(device).count == 12, sourceLocation: sourceLocation)
        }
        let first = try devices[0].fingerprint()
        for device in devices.dropFirst() { #expect(try device.fingerprint() == first, sourceLocation: sourceLocation) }
    }

    /// Every note record in the cloud is still at version 1.
    static func expectNothingResaved(_ world: CoordWorld, sourceLocation: SourceLocation = #_sourceLocation) async {
        for id in StarterFixtures.ids {
            #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 1, "note \(id) was saved more than once", sourceLocation: sourceLocation)
        }
    }

    static func uploadedNoteRecords(_ device: CoordDevice) -> [String] {
        device.gateway.savedNames.filter { $0.hasPrefix("e.note.") }
    }

    // MARK: S1 to S3

    @Test func identicalUntouchedSequential() async throws {
        let world = try Self.seeded(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try await a.enable()
        try await b.enable()
        try await world.converge()
        try Self.expectCleanStarterSet(world.devices)
        // The second device found everything in the cloud and published none of it (E0 review point 1).
        #expect(Self.uploadedNoteRecords(b).isEmpty, "the second device re-uploaded \(Self.uploadedNoteRecords(b).count) notes")
        await Self.expectNothingResaved(world)
        // the device-local flag stays local (REL-R72)
        #expect(try a.string("SELECT value FROM setting WHERE key='gettingStartedSeeded'") != nil)
        #expect(await world.cloud.recordNames.allSatisfy { $0 == "keybundle" || $0.hasPrefix("e.note.") || $0.hasPrefix("e.setting.") || $0.hasPrefix("e.tagPreference.") || $0.hasPrefix("e.m-") })
    }

    @Test func oneEditedOneUntouched() async throws {
        for editedFirst in [true, false] {
            let world = try Self.seeded(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let target = StarterFixtures.ids[2]
            let original = try #require(try a.note(target)).text
            try a.edit(target, original + "\nMy own line.\n")
            if editedFirst { try await a.enable(); try await b.enable() } else { try await b.enable(); try await a.enable() }
            try await world.converge()
            try Self.expectCleanStarterSet(world.devices)
            for device in world.devices { #expect(try device.note(target)?.text == original + "\nMy own line.\n", "\(device.name), edited first: \(editedFirst)") }
        }
    }

    // MARK: S2 and S8 (devices activating together)

    static let interleavingSteps: Set<String> = ["firstRun.afterKeys", "firstRun.afterConfigure", "firstRun.afterDownload", "firstRun.afterEnable",
                                                 "firstRun.afterCleanup", "cycle.beforeUpload", "firstRun.afterUpload"]

    /// Runs `enable` on every device at once; at each of the coordinator's step boundaries the schedule says which device goes next.
    static func enableTogether(_ world: CoordWorld, order: [Int]) async throws {
        let baton = Baton(order: order, count: world.devices.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, device) in world.devices.enumerated() {
                device.hooks.onEveryStep { name in if Self.interleavingSteps.contains(name) { await baton.yield(index) } }
                group.addTask {
                    await baton.acquire(index)
                    do { _ = try await device.enable() } catch { await baton.finish(index); throw error }
                    await baton.finish(index)
                }
            }
            try await group.waitForAll()
        }
        for device in world.devices { device.hooks.clear() }
    }

    @Test func identicalUntouchedSimultaneousEveryInterleaving() async throws {
        // every choice of "who goes next" at the first seven step boundaries of the two first-runs: 128 schedules
        let depth = 7
        for pattern in 0..<(1 << depth) {
            let order = [0] + (0..<depth).map { (pattern >> $0) & 1 }
            let world = try Self.seeded(2); defer { world.cleanup() }
            try await Self.enableTogether(world, order: order)
            try await world.converge()
            try Self.expectCleanStarterSet(world.devices)
            await Self.expectNothingResaved(world)
            #expect(try world.devices.allSatisfy { try $0.count("ck_inflight") == 0 }, "schedule \(order)")
        }
    }

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func threeDevicesActivateTogether() async throws {
        for seed in 0..<24 {
            var rng = SplitMix64(state: UInt64(seed) &* 7919 &+ 1)
            let order = (0..<14).map { _ in Int.random(in: 0..<3, using: &rng) }
            let world = try Self.seeded(3); defer { world.cleanup() }
            try await Self.enableTogether(world, order: order)
            try await world.converge()
            try Self.expectCleanStarterSet(world.devices)
            await Self.expectNothingResaved(world)
        }
    }

    // MARK: S4

    static func retitled(_ text: String, _ title: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[0] = title
        return lines.joined(separator: "\n")
    }

    @Test func bothEditedDifferentlyOffline() async throws {
        let world = try Self.seeded(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let target = StarterFixtures.ids[0]
        let original = try #require(try a.note(target)).text
        let textA = Self.retitled(original, "# A changed the title"), textB = Self.retitled(original, "# B changed the title")
        try a.edit(target, textA); try b.edit(target, textB)
        try await a.enable(); try await b.enable()
        try await world.converge()
        // one note at the fixed id and exactly one conflict copy per divergent note; both texts survive
        for device in world.devices {
            #expect(try device.count("note") == 13, "\(device.name)")
            let others = try device.notes().filter { $0.id != target && !StarterFixtures.ids.contains($0.id) }
            #expect(others.count == 1, "\(device.name) has \(others.count) conflict copies")
            let texts = Set([try #require(try device.note(target)).text, others.first?.text ?? ""])
            #expect(texts == [textA, textB], "no edit is lost on \(device.name)")
        }
        let marked = try world.devices.flatMap { device in try device.database.pool.read { try Row.fetchAll($0, sql: "SELECT originalNoteId FROM sync_conflict") } }
        #expect(!marked.isEmpty && marked.allSatisfy { ($0["originalNoteId"] as String) == target }, "the copy is linked to the original")
        // the same fixed id holds the same text everywhere, and it stays so over more cycles
        let settled = try world.devices.map { try $0.fingerprint() }
        for _ in 0..<5 {
            for device in world.devices { try await device.coordinator.syncNow() }
            #expect(try world.devices.map { try $0.fingerprint() } == settled)
        }
        #expect(try world.devices.allSatisfy { try $0.count("note") == 13 })
    }

    // MARK: S5, S6

    @Test func oneTrashedOneUntouched() async throws {
        for trashedFirst in [true, false] {
            let world = try Self.seeded(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let target = StarterFixtures.ids[3]
            try a.trash(target)
            if trashedFirst { try await a.enable(); try await b.enable() } else { try await b.enable(); try await a.enable() }
            try await world.converge()
            for device in world.devices {
                #expect(try device.note(target)?.location == .trash, "\(device.name), trashed first: \(trashedFirst)")
                #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
            }
            #expect(try a.fingerprint() == b.fingerprint())
        }
    }

    @Test func oneHardDeletedOneUntouched() async throws {
        let world = try Self.seeded(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let target = StarterFixtures.ids[4]
        try await a.enable()
        try a.hardDelete(target)
        try await a.coordinator.syncNow()
        // the cloud now holds an encrypted tombstone (an ordinary-looking record, version 2)
        #expect(await world.cloud.versionCount(of: "e.note.\(target)") == 2)
        try await b.enable()
        try await world.converge()
        // per REL-R74 the untouched copy goes to Trash because it is the last copy of that text; nobody recreates it
        #expect(try b.note(target)?.location == .trash)
        #expect(try a.note(target) == nil)
        #expect(await world.cloud.versionCount(of: "e.note.\(target)") == 2, "the preserved copy is not echoed back")
        #expect(try a.count("note") == 11 && b.count("note") == 12)
        #expect(try a.conflictCopies() == 0 && b.conflictCopies() == 0)
        for _ in 0..<5 { for device in world.devices { try await device.coordinator.syncNow() } }
        #expect(try b.note(target)?.location == .trash)
        #expect(try a.note(target) == nil)
        #expect(await world.cloud.versionCount(of: "e.note.\(target)") == 2)
    }

    // MARK: S7

    @Test func editedOfflineAfterActivation() async throws {
        let world = try Self.seeded(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try await a.enable(); try await b.enable()
        try await world.converge()
        let target = StarterFixtures.ids[5]
        let original = try #require(try a.note(target)).text
        // two edits in different places: the ordinary three-way merge against the stored ancestor keeps both
        try a.edit(target, Self.retitled(original, "# Title by A"))
        try b.edit(target, original + "\nA last line from B.\n")
        try await world.converge()
        let merged = Self.retitled(original, "# Title by A") + "\nA last line from B.\n"
        for device in world.devices {
            #expect(try device.note(target)?.text == merged, "\(device.name)")
            #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
        }
    }

    // MARK: S9, S10

    @Test func deletedOnAThenRestoreMissingOnB() async throws {
        for hardDeletedOnBToo in [false, true] {
            let world = try Self.seeded(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let target = StarterFixtures.ids[6]
            let restoredText = try #require(try a.note(target)).text
            try await a.enable(); try await b.enable()
            try await world.converge()
            try a.hardDelete(target)
            try await world.converge()
            #expect(try a.note(target) == nil)
            #expect(try b.note(target)?.location == .trash)
            if hardDeletedOnBToo { try b.hardDelete(target); try await world.converge(); #expect(try b.note(target) == nil) }
            // B's Help > Restore Getting Started Notes: the note comes back with the same id and stamps on top of the tombstone
            let restored = try StarterFixtures.restore(b)
            #expect(hardDeletedOnBToo ? restored.added == [target] : restored.movedBackFromTrash == [target])
            try await world.converge()
            for device in world.devices {
                let note = try #require(try device.note(target), "restore wins on \(device.name)")
                #expect(note.text == restoredText && note.location == .notes)
                if hardDeletedOnBToo { #expect(note.createdAt == (try GettingStartedNotes.notes().first { $0.id == target })?.stamp) }
                #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
            }
            // nobody deletes or recreates it again
            let versions = await world.cloud.versionCount(of: "e.note.\(target)")
            for _ in 0..<5 { for device in world.devices { try await device.coordinator.syncNow() } }
            #expect(await world.cloud.versionCount(of: "e.note.\(target)") == versions)
            #expect(try world.devices.allSatisfy { try $0.note(target)?.location == .notes })
        }
    }

    @Test func restoreMissingOnAfterSyncRecreatesWithSameIdAndStampsAndSyncs() async throws {
        let world = try Self.seeded(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let target = StarterFixtures.ids[7]
        let expected = try #require(try GettingStartedNotes.notes().first { $0.id == target })
        try await a.enable(); try await b.enable()
        try await world.converge()
        try a.hardDelete(target)
        try await world.converge()
        // sync stays on; the person restores on A
        #expect(try StarterFixtures.restore(a).added == [target])
        try await world.converge()
        for device in world.devices {
            let note = try #require(try device.note(target), "\(device.name)")
            #expect(note.text == expected.text && note.createdAt == expected.stamp && note.modifiedAt == expected.stamp)
            #expect(note.location == .notes && note.id == target)
            #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
        }
    }

    // MARK: S11

    @Test func laterAppVersionWithDifferentTextsForTheSameIdsMakesOneConflictCopyOnce() async throws {
        // (a) the person edited a first-version note on A; B runs the later version whose text for that id differs: the edit and
        // the new text overlap, so there is exactly one conflict copy, made once. Everything else is not an edit and makes none.
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(a)
        try StarterFixtures.seedLaterVersion(b)
        let target = StarterFixtures.ids[1]
        let original = try #require(try a.note(target)).text
        try a.edit(target, original + "\nMy own ending.\n")
        try await a.enable(); try await b.enable()
        try await world.converge()
        for device in world.devices {
            #expect(try device.count("note") == 13, "\(device.name): 12 notes and one conflict copy")
            let others = try device.notes().filter { !StarterFixtures.ids.contains($0.id) }
            #expect(others.count == 1)
        }
        for _ in 0..<5 { for device in world.devices { try await device.coordinator.syncNow() } }
        #expect(try world.devices.allSatisfy { try $0.count("note") == 13 }, "the copy is made once")
        #expect(try a.fingerprint() == b.fingerprint())
        // (b) nobody edited: the later texts are the only change and they simply win, with no copy at all
        let calm = try CoordWorld.make(2); defer { calm.cleanup() }
        try StarterFixtures.seed(calm.devices[0])
        try StarterFixtures.seedLaterVersion(calm.devices[1])
        try await calm.devices[0].enable(); try await calm.devices[1].enable()
        try await calm.converge()
        for device in calm.devices {
            #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
            #expect(try device.note(StarterFixtures.ids[0])?.text.hasSuffix("New in the later version.\n") == true)
        }
    }

    // MARK: S12

    @Test func newDeviceJoinsAfterNotesWereDeletedEverywhereIsNotReseeded() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(a)
        try await a.enable()
        for id in StarterFixtures.ids { try a.hardDelete(id) }
        try await a.coordinator.syncNow()
        // B is a new library that joins the existing cloud: the app does not make starter notes for it (isNewLibrary is false)
        #expect(try GettingStartedNotes.seedNewLibrary(in: b.noteStore, isNewLibrary: false).isEmpty)
        try await b.enable()
        try await world.converge()
        #expect(try b.count("note") == 0 && a.count("note") == 0)
        // the device-local flag is not synced (REL-R72): it never arrived on B
        #expect(try b.string("SELECT value FROM setting WHERE key='gettingStartedSeeded'") == nil)
        // and nothing recreated them in the cloud
        for id in StarterFixtures.ids { #expect(await world.cloud.versionCount(of: "e.note.\(id)") == 2, "live, then deleted") }
    }

    @Test func joiningDeviceThatAlreadySeededLocallyBeforeEnablingCollapsesIdentical() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try StarterFixtures.seed(a)
        try await a.enable()
        try await world.converge([a])
        // B made its own set earlier, offline from the cloud, and only now switches sync on
        try StarterFixtures.seed(b)
        try await b.enable()
        try await world.converge()
        try Self.expectCleanStarterSet(world.devices)
        #expect(Self.uploadedNoteRecords(b).isEmpty)
        await Self.expectNothingResaved(world)
    }
}
