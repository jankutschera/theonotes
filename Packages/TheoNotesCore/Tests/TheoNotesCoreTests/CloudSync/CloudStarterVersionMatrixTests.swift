// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// The shipped-version list in the first-sync merge: a device of the first release (frozen v1 texts)
/// and a device of this release (v2 texts) on one iCloud account, through the real coordinator and `FakeCloudKit`.
@Suite(.serialized) struct CloudStarterVersionMatrixTests {
    static let target = StarterFixtures.ids[4]  // note 5: its v2 text differs from v1 in most lines

    static func texts() throws -> (v1: String, v2: String) {
        let v1 = try #require(GettingStartedNotes.firstShippedNotes().first { $0.id == target }).text
        let v2 = try #require(GettingStartedNotes.notes().first { $0.id == target }).text
        #expect(v1 != v2, "the two versions differ")
        return (v1, v2)
    }

    /// Device `old` made the first-release set, device `new` this release's; both switch sync on in the given order.
    static func world(first: Int, edit: (CoordDevice, CoordDevice) throws -> Void = { _, _ in }) async throws -> CoordWorld {
        let world = try CoordWorld.make(2)
        let old = world.devices[0], new = world.devices[1]
        try StarterFixtures.seedFirstShipped(old)
        try StarterFixtures.seed(new)
        try edit(old, new)
        for index in [first, 1 - first] { try await world.devices[index].enable() }
        try await world.converge()
        return world
    }

    @Test func untouchedFirstReleaseAndUntouchedThisReleaseConvergeOnTheNewTexts() async throws {
        let (_, v2) = try Self.texts()
        for first in [0, 1] {
            let world = try await Self.world(first: first); defer { world.cleanup() }
            try CloudFirstRunMatrixTests.expectCleanStarterSet(world.devices)
            for device in world.devices { #expect(try device.note(Self.target)?.text == v2, "first=\(first) on \(device.name)") }
        }
    }

    /// Review r1 S3: the `old` device merges like a 1.0.x build, whose list held the first set only. Both enable orders converge on
    /// the new texts, and extra sync rounds save nothing more (no upload ping-pong).
    @Test func aFirstReleaseBuildWithOnlyTheFirstBaseConvergesOnTheNewTextsWithoutPingPong() async throws {
        let (_, v2) = try Self.texts()
        for first in [0, 1] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let old = world.devices[0], new = world.devices[1]
            await old.coordinator.useStarterVersions(CloudStarterBase.firstShippedPayloads.mapValues { [$0] })
            try StarterFixtures.seedFirstShipped(old)
            try StarterFixtures.seed(new)
            for index in [first, 1 - first] { try await world.devices[index].enable() }
            try await world.converge()
            try CloudFirstRunMatrixTests.expectCleanStarterSet(world.devices)
            for device in world.devices { #expect(try device.note(Self.target)?.text == v2, "first=\(first) on \(device.name)") }
            var saved: [Int] = []
            for id in StarterFixtures.ids { saved.append(await world.cloud.versionCount(of: "e.note.\(id)")) }
            for _ in 0..<3 { for device in world.devices { try await device.coordinator.syncNow() } }
            var later: [Int] = []
            for id in StarterFixtures.ids { later.append(await world.cloud.versionCount(of: "e.note.\(id)")) }
            #expect(later == saved, "first=\(first): no note is saved again after convergence")
            #expect(saved.allSatisfy { $0 <= 2 }, "first=\(first): at most the first upload and the one newer text: \(saved)")
        }
    }

    @Test func thisReleaseAgainstThisReleaseIsIdentical() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        for device in world.devices { try StarterFixtures.seed(device) }
        for device in world.devices { try await device.enable() }
        try await world.converge()
        try CloudFirstRunMatrixTests.expectCleanStarterSet(world.devices)
        await CloudFirstRunMatrixTests.expectNothingResaved(world)
    }

    @Test func anEditedNewTextAgainstAnUntouchedNewTextWinsWithoutACopy() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        for device in world.devices { try StarterFixtures.seed(device) }
        let (_, v2) = try Self.texts()
        try a.edit(Self.target, v2 + "\nMy own ending.\n")
        try await a.enable(); try await b.enable()
        try await world.converge()
        for device in world.devices {
            #expect(try device.note(Self.target)?.text == v2 + "\nMy own ending.\n")
            #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
        }
    }

    @Test func anEditedFirstReleaseTextAgainstAnUntouchedNewTextKeepsTheEditWithoutACopy() async throws {
        let (v1, _) = try Self.texts()
        for first in [0, 1] {
            let world = try await Self.world(first: first, edit: { old, _ in try old.edit(Self.target, v1 + "\nMy own ending.\n") })
            defer { world.cleanup() }
            for device in world.devices {
                #expect(try device.note(Self.target)?.text == v1 + "\nMy own ending.\n", "first=\(first) on \(device.name)")
                #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
            }
        }
    }

    @Test func anEditedNewTextAgainstAnUntouchedFirstReleaseTextKeepsTheEditWithoutACopy() async throws {
        let (_, v2) = try Self.texts()
        for first in [0, 1] {
            let world = try await Self.world(first: first, edit: { _, new in try new.edit(Self.target, v2 + "\nMy own ending.\n") })
            defer { world.cleanup() }
            for device in world.devices {
                #expect(try device.note(Self.target)?.text == v2 + "\nMy own ending.\n", "first=\(first) on \(device.name)")
                #expect(try device.count("note") == 12 && device.conflictCopies() == 0)
            }
        }
    }

    @Test func twoEditsOfDifferentVersionsLoseNeitherEdit() async throws {
        // The old device appended a line to v1, the new device a line to v2. Neither side is untouched, so the oldest shipped version is the
        // base: the three-way text merge keeps both endings, or makes one conflict copy. Never a lost edit, never a second copy.
        let (v1, v2) = try Self.texts()
        let world = try await Self.world(first: 0, edit: { old, new in
            try old.edit(Self.target, v1 + "\nOld device's ending.\n"); try new.edit(Self.target, v2 + "\nNew device's ending.\n")
        })
        defer { world.cleanup() }
        for _ in 0..<5 { for device in world.devices { try await device.coordinator.syncNow() } }
        #expect(try world.devices[0].fingerprint() == world.devices[1].fingerprint())
        let everything = try world.devices[0].notes().filter { $0.id == Self.target || $0.text.contains("ending.") }.map(\.text).joined()
        #expect(everything.contains("Old device's ending.") && everything.contains("New device's ending."), "both edits survive")
        let counts = try world.devices.map { try $0.count("note") }
        #expect(counts.allSatisfy { $0 == 12 || $0 == 13 }, "at most one conflict copy, found \(counts)")
    }

    @Test func aDeletionOrATrashFollowsAnUntouchedCopyOfEitherVersion() async throws {
        let deleted = StarterFixtures.ids[2], trashed = StarterFixtures.ids[6]
        for (first, oldDeletes) in [(0, true), (1, true), (0, false), (1, false)] {
            let world = try await Self.world(first: first); defer { world.cleanup() }
            let actor = oldDeletes ? world.devices[0] : world.devices[1], other = oldDeletes ? world.devices[1] : world.devices[0]
            try actor.hardDelete(deleted); try actor.trash(trashed)
            try await world.converge()
            #expect(try other.note(deleted)?.location == .trash, "first=\(first) oldDeletes=\(oldDeletes): the hard deletion reaches the untouched copy")
            #expect(try other.note(trashed)?.location == .trash)
            #expect(try world.devices.allSatisfy { try $0.conflictCopies() == 0 })
        }
    }

    @Test func aDeletedCopyStaysDeletedWhenTheOtherReleaseJoinsLater() async throws {
        // A (first release) deleted note 5 before it ever met the cloud; B (this release) uploaded its untouched copy first.
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let old = world.devices[0], new = world.devices[1]
        try StarterFixtures.seedFirstShipped(old); try StarterFixtures.seed(new)
        try old.hardDelete(Self.target)
        try await new.enable()
        try await world.converge([new])
        try await old.enable()
        try await world.converge()
        #expect(try old.note(Self.target) == nil)
        #expect(try new.note(Self.target)?.location == .trash, "the deletion stands for the untouched new text too")
    }
}
