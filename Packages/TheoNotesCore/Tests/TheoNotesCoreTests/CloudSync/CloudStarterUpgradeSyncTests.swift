// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// with sync on: the one-time replacement of untouched first-release starters, through the real coordinator and
/// `FakeCloudKit`. No conflict copy, no ping-pong, an edit on the other device wins.
@Suite(.serialized) struct CloudStarterUpgradeSyncTests {
    static let target = StarterFixtures.ids[4]  // its v2 text differs from v1 in most lines

    /// Two devices of the first release, bound to one account and settled on the v1 texts.
    /// A first-release library has no marker; a 1.1 coordinator would upgrade it after its first cycle, so the marker is set to keep
    /// the devices on v1 until `launch` simulates the first 1.1 launch.
    static func markUpgraded(_ device: CoordDevice) throws {
        try device.database.pool.write {
            try $0.execute(sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value='true'",
                           arguments: [SettingKey<Bool>.gettingStartedUpgraded.name])
        }
    }

    static func bindWithoutUploads(_ device: CoordDevice) throws {
        try device.database.pool.write { try $0.execute(sql: "UPDATE sync_control SET accountId='a', enabled=0 WHERE id=1") }
    }

    static func settledFirstRelease() async throws -> CoordWorld {
        let world = try CoordWorld.make(2)
        for device in world.devices { try StarterFixtures.seedFirstShipped(device); try markUpgraded(device) }
        for device in world.devices { try await device.enable() }
        try await world.converge()
        return world
    }

    /// The first launch of 1.1 on `device`: the marker is not there, and the launch call runs. On a bound library it does nothing (the
    /// coordinator upgrades after its next cycle); on an unbound one it replaces the starters.
    @discardableResult
    static func launch(_ device: CoordDevice) throws -> [String] {
        try device.database.pool.write { try $0.execute(sql: "DELETE FROM setting WHERE key=?", arguments: [SettingKey<Bool>.gettingStartedUpgraded.name]) }
        return try GettingStartedNotes.upgradeFirstShipped(in: device.noteStore, paths: device.paths)
    }

    static func saved(_ world: CoordWorld) async -> [Int] {
        var counts: [Int] = []
        for id in StarterFixtures.ids { counts.append(await world.cloud.versionCount(of: "e.note.\(id)")) }
        return counts
    }

    static func expectSettled(_ world: CoordWorld, text v2: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try CloudFirstRunMatrixTests.expectCleanStarterSet(world.devices, sourceLocation: sourceLocation)
        for device in world.devices { #expect(try device.note(target)?.text == v2, "\(device.name)", sourceLocation: sourceLocation) }
        let before = await saved(world)
        for _ in 0..<3 { for device in world.devices { try await device.coordinator.syncNow() } }
        #expect(await saved(world) == before, "no note is saved again after convergence", sourceLocation: sourceLocation)
    }

    @Test func oneDeviceUpgradesAndTheOtherFollowsWithoutACopy() async throws {
        let world = try await Self.settledFirstRelease(); defer { world.cleanup() }
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == Self.target }).text
        #expect(try Self.launch(world.devices[0]).isEmpty)
        try await world.converge()
        try await Self.expectSettled(world, text: v2)
        // The second device upgrades later: its notes are already the new texts, nothing is written.
        let before = await Self.saved(world)
        #expect(try Self.launch(world.devices[1]).isEmpty)
        try await world.converge()
        #expect(await Self.saved(world) == before)
    }

    @Test func bothDevicesUpgradeBeforeTheyMeetAndTheNotesCollapse() async throws {
        let world = try await Self.settledFirstRelease(); defer { world.cleanup() }
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == Self.target }).text
        for device in world.devices { _ = try Self.launch(device) }
        try await world.converge()
        try await Self.expectSettled(world, text: v2)
    }

    /// An edit of the old text on the other device, not yet synced when this one upgrades: the ordinary three-way merge (base = the
    /// old text) keeps the edit inside the new text, with no conflict copy, and both devices end identical.
    @Test func anEditOnTheOtherDeviceIsKeptInTheMergeWithoutACopy() async throws {
        let world = try await Self.settledFirstRelease(); defer { world.cleanup() }
        let v1 = try #require(GettingStartedNotes.firstShippedNotes().first { $0.id == Self.target }).text
        try world.devices[1].edit(Self.target, v1 + "\nmy own line\n")
        #expect(try Self.launch(world.devices[0]).isEmpty)
        try await world.converge()
        for device in world.devices { #expect(try device.note(Self.target)?.text.contains("my own line") == true, "\(device.name)") }
        #expect(try world.devices[0].note(Self.target)?.text == world.devices[1].note(Self.target)?.text)
        #expect(try world.devices.allSatisfy { try $0.conflictCopies() == 0 })
    }

    /// The edit reached this device before it upgraded: the starter is "touched" and stays as the person wrote it.
    @Test func anEditThatAlreadyArrivedStopsTheUpgrade() async throws {
        let world = try await Self.settledFirstRelease(); defer { world.cleanup() }
        let v1 = try #require(GettingStartedNotes.firstShippedNotes().first { $0.id == Self.target }).text
        let edited = v1 + "\nmy own line\n"
        try world.devices[1].edit(Self.target, edited)
        try await world.converge()
        for device in world.devices { _ = try Self.launch(device) }
        try await world.converge()
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == StarterFixtures.ids[1] }).text
        for device in world.devices { #expect(try device.note(StarterFixtures.ids[1])?.text == v2, "the untouched starters are upgraded on \(device.name)") }
        for device in world.devices { #expect(try device.note(Self.target)?.text == edited, "\(device.name)") }
        #expect(try world.devices.allSatisfy { try $0.conflictCopies() == 0 })
    }

    @Test func aFirstReleaseBuildFollowsTheUpgradeWithoutPingPong() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let old = world.devices[0], new = world.devices[1]
        await old.coordinator.useStarterVersions(CloudStarterBase.firstShippedPayloads.mapValues { [$0] })
        for device in world.devices { try StarterFixtures.seedFirstShipped(device); try Self.markUpgraded(device) }
        for device in world.devices { try await device.enable() }
        try await world.converge()
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == Self.target }).text
        _ = try Self.launch(new)
        try await world.converge()
        try await Self.expectSettled(world, text: v2)
    }

    @Test func anUpgradeWithSyncOffMeetsTheOldCloudCopyLater() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == Self.target }).text
        let old = world.devices[0], new = world.devices[1]
        try StarterFixtures.seedFirstShipped(old); try Self.markUpgraded(old)
        try StarterFixtures.seedFirstShipped(new)
        #expect(try !Self.launch(new).isEmpty, "an unbound library is upgraded at launch")
        for device in [old, new] { try await device.enable() }
        try await world.converge()
        try await Self.expectSettled(world, text: v2)
    }

    /// Review M1: device B deleted starter 5 and synced; device A, which has not synced since, launches 1.1. The upgrade waits for A's
    /// first cycle, which brings the deletion, so nothing is written to the deleted note: no starter back, no conflict copy.
    @Test func aStarterDeletedOnAnotherDeviceStaysDeletedWhenThisOneUpgrades() async throws {
        let world = try await Self.settledFirstRelease(); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try b.trash(Self.target)
        try b.hardDelete(Self.target)
        try await b.coordinator.syncNow()
        #expect(try Self.launch(a).isEmpty, "bound: nothing is written at launch")
        #expect(try a.note(Self.target) != nil, "the deletion has not reached A yet")
        try await world.converge()
        // A deletion reaches an untouched copy as a note in the Trash (the existing rule, `aDeletionOrATrashFollowsAnUntouchedCopy…`).
        #expect(try a.note(Self.target)?.location == .trash, "A: the starter is in the Trash, not back in Notes")
        #expect(try b.note(Self.target) == nil)
        for device in world.devices {
            #expect(try device.conflictCopies() == 0, "\(device.name)")
            #expect(try device.visibleTitles().count == 11, "\(device.name) shows no deleted starter")
        }
        let other = StarterFixtures.ids[1]
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == other }).text
        for device in world.devices { #expect(try device.note(other)?.text == v2, "the rest is upgraded on \(device.name)") }
        #expect(try a.string("SELECT value FROM setting WHERE key='gettingStartedUpgraded'") == "true")
    }

    /// Review S2: a library an account owns whose uploads are not switched on yet (a blocked first sync) gets nothing written, so the
    /// first-bind guard (which skips a starter with a pending upload) still sees untouched starters.
    @Test func aBoundLibraryWithUploadsOffGetsNoDirtyMarkerFromTheLaunch() async throws {
        let world = try CoordWorld.make(1); defer { world.cleanup() }
        let device = world.devices[0]
        try StarterFixtures.seedFirstShipped(device)
        try Self.bindWithoutUploads(device)
        #expect(try Self.launch(device).isEmpty)
        #expect(try device.count("sync_dirty") == 0)
    }
}
