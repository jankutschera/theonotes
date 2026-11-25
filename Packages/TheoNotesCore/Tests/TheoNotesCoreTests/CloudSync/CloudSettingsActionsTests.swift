// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Task 15 (CK-R140): the actions the Settings screens offer besides the switch, as the coordinator performs them.
@Suite(.serialized) struct CloudSettingsActionsTests {
    // MARK: quota

    @Test func iCloudWithNoRoomIsReportedAsQuotaFullNotAsUpToDate() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            try await a.enable()
            await world.cloud.setQuota(bytes: 1)
            let note = try a.noteStore.create(text: "# No room\nbody\n")
            let held = try await a.coordinator.syncNow()
            #expect(held == .quotaFull, "uploads are held, the person has to hear it: \(held)")
            #expect(try a.dirtyGeneration(note.id) != nil, "the edit is kept")
            #expect(await a.coordinator.retry == .onForegroundOrEvery(CloudErrorPolicy.quotaRetryInterval))

            await world.cloud.setQuota(bytes: nil)                          // the person freed some iCloud space
            let state = try await a.coordinator.syncNow()
            if case .upToDate = state {} else { Issue.record("expected up to date once there is room, got \(state)") }
            #expect(await world.cloud.versionCount(of: "e.note.\(note.id)") == 1)
        }
    }

    // MARK: keychain

    @Test func aKeychainThatRefusesTheFirstReadIsReportedAsKeychainUnavailable() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.seedStore.simulate(status: -25308)
            #expect(try await a.enable() == .keychainUnavailable)
            a.seedStore.restoreAvailability()
            let state = try await a.coordinator.syncNow()
            if case .upToDate = state {} else { Issue.record("expected the first sync to go on once the keychain answers, got \(state)") }
        }
    }

    // MARK: recovery words later

    @Test func recoveryWordsCreatedLaterAreSavedAndOtherDevicesKeepWorking() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            try await b.enable()
            try await world.converge()
            #expect(try await a.coordinator.recoveryState() == .acknowledgedSkip)

            let offer = try RecoveryKeyOffer.make()
            let typed = Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, offer.words.split(separator: " ").map(String.init)[$0]) })
            let outcome = try await a.coordinator.saveRecoveryWords(try offer.confirm(typed))
            guard case .replaced = outcome else { Issue.record("expected the words to be replaced, got \(outcome)"); return }
            #expect(try await a.coordinator.recoveryState() == .saved)

            // The second device, set up before, still syncs; a third one can join with the new words.
            try a.edit(note.id, "# One\nedited\n")
            try await world.converge()
            #expect(try b.note(note.id)?.text == "# One\nedited\n")
        }
    }

    @Test func recoveryWordsNeedARunningCoordinator() async throws {
        try await withCoordWorld(1) { world in
            let offer = try RecoveryKeyOffer.make()
            let typed = Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, offer.words.split(separator: " ").map(String.init)[$0]) })
            await #expect(throws: CloudCoordinatorError.notRunning) { _ = try await world.devices[0].coordinator.saveRecoveryWords(try offer.confirm(typed)) }
        }
    }

    // MARK: upload them again

    @Test func uploadThemAgainPreparesTheMissingNotesAndTheNextCycleSendsThem() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# Gone\n")
            try await a.enable()
            await world.cloud.removeRecord("e.note.\(note.id)")
            _ = try await a.coordinator.syncNow()
            await a.fake.pushRemoteChange()
            _ = try await a.coordinator.syncNow()
            if case .itemsMissingInCloud(let count) = await a.coordinator.currentState { #expect(count == 1) }
            else { Issue.record("expected itemsMissingInCloud, got \(await a.coordinator.currentState)"); return }

            #expect(try await a.coordinator.uploadMissingAgain() == 1)
            _ = try await a.coordinator.syncNow()
            #expect(await world.cloud.versionCount(of: "e.note.\(note.id)") >= 1, "the note is back in iCloud")
            #expect(try a.store.allMissing().isEmpty)
            #expect(try a.note(note.id)?.text == "# Gone\n", "the notes on this device were not touched")
        }
    }

    // MARK: delete my iCloud copy

    @Test func deletingTheICloudCopyKeepsEveryNoteOnThisDeviceAndLetsGoOfTheBinding() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            #expect(await world.cloud.recordNames.isEmpty == false)

            try await a.coordinator.deleteICloudCopy()
            #expect(await world.cloud.recordNames.isEmpty, "the copy in iCloud is gone")
            #expect(try a.note(note.id)?.text == "# Mine\n", "this device keeps its notes")
            #expect(try a.store.backend() == .none)
            #expect(try a.store.isSwitchedOn() == false)
            #expect(await a.coordinator.currentState == .off)
            #expect(a.backups >= 2, "a backup was made before anything was deleted")
        }
    }

    @Test func afterDeletingTheCopySyncCanBeSwitchedOnAgainFromScratch() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            try await a.coordinator.deleteICloudCopy()
            let state = try await a.enable()
            if case .upToDate = state {} else { Issue.record("expected a fresh first sync, got \(state)") }
            #expect(await world.cloud.versionCount(of: "e.note.\(note.id)") >= 1)
        }
    }

    // MARK: remove the iCloud key

    @Test func removingTheKeyStopsSyncRemovesTheSeedAndNeedsTheWordsAgain() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            let account = try #require(try a.store.keyState().accountId)
            #expect(try a.seedStore.seed(accountId: account) != nil)

            try await a.coordinator.removeICloudKey()
            #expect(try a.seedStore.seed(accountId: account) == nil)
            #expect(try a.note(note.id)?.text == "# Mine\n")
            #expect(await a.coordinator.currentState == .off)
            #expect(await world.cloud.recordNames.isEmpty == false, "the copy in iCloud is not deleted")
        }
    }

    // MARK: a new iCloud account

    @Test func syncingWithANewAccountSavesABackupLetsGoOfTheOldAccountAndStartsFresh() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            a.realBackups = true
            let note = try a.noteStore.create(text: "# Mine\n")
            try await a.enable()
            let other = FakeCloudKitAccount(user: "someone-else")
            await a.fake.switchAccount(to: other)
            #expect(try await eventually { if case .accountChanged = await a.coordinator.currentState { true } else { false } })
            let backupsBefore = a.backups

            try await a.coordinator.detachForNewAccount()
            #expect(a.backups == backupsBefore + 1)
            #expect(try a.store.backend() == .none)
            #expect(await world.cloud.recordNames.isEmpty == false, "the old account's copy is not touched")

            let state = try await a.enable()
            if case .upToDate = state {} else { Issue.record("expected a fresh first sync with the new account, got \(state)") }
            #expect(await other.recordNames.isEmpty == false)
            #expect(try a.note(note.id)?.text == "# Mine\n")
        }
    }
}
