// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Task 15: the Mac and iOS apps must be able to tell a person that the recovery words they just saved belong to a setup
/// that lost the race against another device.
@Suite(.serialized) struct CloudLostSetupRaceTests {
    private func raceLoser(_ cloud: FakeCloudKitAccount) async throws -> (winner: CoordDevice, loser: CoordDevice) {
        let winner = try CoordDevice("winner", cloud: cloud, keychain: InMemoryCloudKeychain())
        let loser = try CoordDevice("loser", cloud: cloud, keychain: InMemoryCloudKeychain())
        // The loser has started its own key creation (keys made, nothing in iCloud yet) when the winner finishes its setup.
        let creation = CloudKeyCreation(seeds: loser.seedStore, probe: loser.seedStore,
                                        bundles: CloudKeyBundleStore(gateway: loser.gateway, results: loser.store), state: loser.store)
        try await creation.begin(RecoveryChoice.skip(acknowledged: true))
        try await winner.enable()
        return (winner, loser)
    }

    @Test func theDeviceThatLosesTheKeySetupRaceKnowsIt() async throws {
        let (winner, loser) = try await raceLoser(FakeCloudKitAccount())
        defer { winner.cleanup(); loser.cleanup() }
        #expect(await winner.coordinator.lostSetupRace == false)

        _ = try await loser.enable()
        #expect(await loser.coordinator.lostSetupRace, "the loser's saved words protect nothing and the app has to say so")
        #expect(try loser.store.keyState().recovery == .none, "the loser never completed a setup of its own")

        await loser.coordinator.dismissLostSetupRace()
        #expect(await loser.coordinator.lostSetupRace == false)
    }

    @Test func wordsConfirmedAfterAnotherDeviceFinishedFirstAreNeverUsedAndTheDeviceKnowsIt() async throws {
        let cloud = FakeCloudKitAccount()
        let winner = try CoordDevice("winner", cloud: cloud, keychain: InMemoryCloudKeychain())
        let loser = try CoordDevice("loser", cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { winner.cleanup(); loser.cleanup() }
        // The person sees the recovery step on the second device while the first one is still setting up; then confirms the words.
        let offer = try RecoveryKeyOffer.make()
        let words = offer.words.split(separator: " ").map(String.init)
        let choice = try offer.confirm(Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, words[$0]) }))
        try await winner.enable()

        _ = try await loser.enable(recovery: choice)
        #expect(await loser.coordinator.lostSetupRace, "the confirmed words were never part of any setup")

        // A skip protects nothing and promised nothing: no notice.
        let other = try CoordDevice("other", cloud: cloud, keychain: InMemoryCloudKeychain())
        defer { other.cleanup() }
        _ = try await other.enable()
        #expect(await other.coordinator.lostSetupRace == false)
    }

    @Test func restartingAfterOwnSetupNeverReportsALostRace() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let offer = try RecoveryKeyOffer.make()
            let words = offer.words.split(separator: " ").map(String.init)
            let choice = try offer.confirm(Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, words[$0]) }))
            try await a.enable(recovery: choice)
            await a.coordinator.disable()
            let again = a.makeCoordinator()
            _ = try await again.enable(recovery: choice)
            #expect(await again.lostSetupRace == false, "the keys in iCloud are this device's own")
        }
    }

    @Test func aDeviceThatSetUpAloneNeverReportsALostRace() async throws {
        try await withCoordWorld(1) { world in
            _ = try await world.devices[0].enable()
            #expect(await world.devices[0].coordinator.lostSetupRace == false)
        }
    }

    @Test func switchingOffClearsTheNotice() async throws {
        let (winner, loser) = try await raceLoser(FakeCloudKitAccount())
        defer { winner.cleanup(); loser.cleanup() }
        _ = try await loser.enable()
        #expect(await loser.coordinator.lostSetupRace)
        await loser.coordinator.disable()
        #expect(await loser.coordinator.lostSetupRace == false)
    }
}
