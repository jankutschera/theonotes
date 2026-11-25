// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct CloudJournalGateTests {
    @Test func activatedLaunchResumesAfterJournalKeyAndAfterMoveAside() async throws {
        for moveAside in [false, true] {
            try await withCoordWorld(2) { world in
                let donor = world.devices[0], recipient = world.devices[1]
                try await donor.enable(); try await recipient.enable()
                let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
                defer { access.revoke() }
                _ = try await donor.coordinator.syncNow(notePassword: "vault password")
                recipient.needsJournalKey.update { $0 = true }
                await recipient.coordinator.endAsIfTheProcessDied()
                let restarted = recipient.makeCoordinator()
                #expect(try await restarted.launch() == .needsNotePassword)
                if moveAside { recipient.needsJournalKey.update { $0 = false } }
                _ = try await restarted.syncNow(notePassword: moveAside ? nil : "vault password")
                #expect(await restarted.completedCycles > 0)
                #expect(recipient.journalRecoveries.value == (moveAside ? 0 : 1))
            }
        }
    }
    @Test func offlineFetchDoesNotOfferMoveAsideAsIfKeyWereAbsent() async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable()
            recipient.needsJournalKey.update { $0 = true }
            await recipient.fake.failNext(.offline)
            let state = try await recipient.enable()
            if case .offline = state {} else { Issue.record("Expected offline status") }
            #expect(!recipient.offerSealedMoveAside.value && recipient.gateway.savedNames.isEmpty)
        }
    }
    @Test func mixedLockedNotesInstallKeyAndReportUnopenableCountWithoutChangingBytes() async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable()
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password"); defer { access.revoke() }
            _ = try await donor.coordinator.syncNow(notePassword: "vault password")
            let matching = try NoteCipher.seal(Data("match".utf8), vaultKey: access.journalKey(), context: "matching")
            let foreign = try NoteCipher.seal(Data("foreign".utf8), vaultKey: SymmetricKey(size: .bits256), context: "foreign")
            try await recipient.db.pool.write { db in
                for (id, bytes) in [("matching", matching), ("foreign", foreign)] {
                    try Note(id: id, text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now,
                             isLocked: true, encryptedPayload: bytes).insert(db)
                }
            }
            recipient.needsJournalKey.update { $0 = true }
            let state = try await recipient.enable(notePassword: "vault password")
            #expect(state.message.contains("1 protected note"))
            #expect(try recipient.note("foreign")?.encryptedPayload == foreign)
            #expect(recipient.journalRecoveries.value == 1)
        }
    }
    @Test(arguments: [false, true]) func unavailableSyncKeyOffersBytePreservingMoveAsideWithoutPassword(missingAccountKey: Bool) async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable()
            if missingAccountKey { try await donor.gateway.delete([CloudRecordCodec.keyBundleRecordName]) }
            do {
                let journal = try EditJournal(directory: recipient.paths.journal, noteId: "orphan", encryptionKey: SymmetricKey(size: .bits256))
                try journal.writeBase(JournalBase(storeRevision: 0, baseText: "saved"))
                try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " edit")])))
            }
            recipient.realJournalRecovery.update { $0 = true }
            let before = try Data(contentsOf: recipient.paths.journal.appendingPathComponent("orphan.base"))
            #expect(try await recipient.enable() == .failed(kind: "journalKeyUnavailable"))
            #expect(recipient.offerSealedMoveAside.value)
            #expect(recipient.gateway.savedNames.isEmpty && recipient.backups == 0)
            let report = try await MainActor.run {
                try JournalRecoveryCoordinator.recover(store: recipient.noteStore, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [], allowSealedMoveAside: true)
            }
            #expect(report.keyState == .waitingForSyncKey && report.quarantineFiles.count == 2)
            let selection = try JournalQuarantine.inspect(libraryRoot: recipient.paths.root, fileNames: report.quarantineFiles)
            let directory = try await MainActor.run { try JournalQuarantine.moveAfterConfirmation(selection, store: recipient.noteStore) }
            #expect(try Data(contentsOf: directory.appendingPathComponent("orphan.base")) == before)
            #expect(await recipient.journalRecoveryState() == .ready)
            _ = try await recipient.enable()
            #expect(await recipient.coordinator.completedCycles > 0)
        }
    }
    @Test func keyBundleBelowPinnedRevisionCannotInstallVault() async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable()
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            _ = try await donor.coordinator.syncNow(notePassword: "vault password")
            let keys = try await donor.liveKeys()
            try recipient.seedStore.raiseHighWaterMark(999, accountId: keys.accountID)
            recipient.needsJournalKey.update { $0 = true }
            let state = try await recipient.enable(notePassword: "vault password")
            #expect(state == .failed(kind: "keyMismatch"))
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() == nil)
            #expect(recipient.gateway.savedNames.isEmpty && recipient.journalRecoveries.value == 0)
        }
    }
    @Test func journalAppearingAfterBackupStopsBeforeKeyCreationOrUpload() async throws {
        try await withCoordWorld(1) { world in
            let device = world.devices[0]
            device.hooks.on("firstRun.afterBackup") { device.needsJournalKey.update { $0 = true } }
            let state = try await device.enable()
            #expect(state == .failed(kind: "journalKeyUnavailable"))
            #expect(device.gateway.savedNames.isEmpty && device.journalRecoveries.value == 0)
        }
    }
    @Test(arguments: [true, false]) func sealedOrphanWithoutEnvelopeTriggersCloudIntakeAndRecovery(matches: Bool) async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable()
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            _ = try await donor.coordinator.syncNow(notePassword: "vault password")
            do {
                let journalKey = try matches ? access.journalKey() : SymmetricKey(size: .bits256)
                let journal = try EditJournal(directory: recipient.paths.journal, noteId: "sealed-orphan", encryptionKey: journalKey)
                try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Base"))
                try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " saved")])))
            }
            recipient.realJournalRecovery.update { $0 = true }
            recipient.realBackups = true
            #expect(try await recipient.enable() == .needsNotePassword)
            #expect(recipient.backups == 0 && recipient.journalRecoveries.value == 0)
            if !matches {
                #expect(try await recipient.enable(notePassword: "vault password") == .failed(kind: "journalRecoveryBlocked"))
                #expect(try NotePrivacy(store: recipient.noteStore).envelope() != nil)
                let report = try await MainActor.run { try JournalRecoveryCoordinator.recover(store: recipient.noteStore, access: recipient.journalAccess.value, liveSessionIDs: [], dirtyLiveSessionIDs: []) }
                #expect(report.quarantineFiles.contains("sealed-orphan.base"))
                let selection = try JournalQuarantine.inspect(libraryRoot: recipient.paths.root, fileNames: report.quarantineFiles)
                _ = try await MainActor.run { try JournalQuarantine.moveAfterConfirmation(selection, store: recipient.noteStore) }
                _ = try await recipient.enable(notePassword: "vault password")
                #expect(try !LibraryBackup(database: recipient.db, paths: recipient.paths).localBackups().isEmpty)
                return
            }
            await #expect(throws: BackupError.pendingEdits) { _ = try await recipient.enable(notePassword: "vault password") }
            let recovered = try #require(try recipient.noteStore.allNotes().first)
            let unlocked = try NotePrivacy(store: recipient.noteStore).unlock(password: "vault password")
            defer { unlocked.revoke() }
            #expect(try recovered.isLocked && unlocked.note(id: recovered.id)?.text == "Base saved")
            #expect(recipient.journalRecoveries.value == 1)
            let retirement = try #require(recipient.journalRetirement.value)
            try MissingJournalRecovery.removeLeftover(retirement, access: recipient.journalAccess.value)
            _ = try await recipient.enable(notePassword: "vault password")
            #expect(try !LibraryBackup(database: recipient.db, paths: recipient.paths).localBackups().isEmpty)
        }
    }
    @Test func firstSyncWaitsForVaultRecoveryBeforeBackupAndOrdinarySync() async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable()
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            _ = try await donor.coordinator.syncNow(notePassword: "vault password")
            _ = try recipient.noteStore.create(text: "Local note")
            recipient.needsJournalKey.update { $0 = true }
            let before = try recipient.fingerprint()
            #expect(try await recipient.enable() == .needsNotePassword)
            #expect(recipient.backups == 0 && recipient.journalRecoveries.value == 0)
            #expect(try recipient.fingerprint() == before)
            #expect(recipient.gateway.savedNames.isEmpty)
            _ = try await recipient.enable(notePassword: "vault password")
            #expect(recipient.journalRecoveries.value == 1 && recipient.backups == 1)
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() != nil)
        }
    }

    @Test func activeSyncDoesNotPushOrPullUntilRecoveryCommits() async throws {
        try await withCoordWorld(2) { world in
            let donor = world.devices[0], recipient = world.devices[1]
            try await donor.enable(); try await recipient.enable()
            let access = try NotePrivacy(store: donor.noteStore).setPassword("vault password")
            defer { access.revoke() }
            _ = try await donor.coordinator.syncNow(notePassword: "vault password")
            _ = try recipient.noteStore.create(text: "Unsent local text")
            recipient.needsJournalKey.update { $0 = true }
            let before = try recipient.fingerprint(), outgoing = recipient.gateway.savedNames.count
            let remote = try recipient.count("ck_remote"), inflight = try recipient.count("ck_inflight")
            #expect(try await recipient.coordinator.syncNow() == .needsNotePassword)
            #expect(try recipient.fingerprint() == before && recipient.count("ck_remote") == remote && recipient.count("ck_inflight") == inflight)
            #expect(recipient.gateway.savedNames.count == outgoing && recipient.journalRecoveries.value == 0)
            _ = try await recipient.coordinator.syncNow(notePassword: "vault password")
            #expect(recipient.journalRecoveries.value == 1)
            #expect(try NotePrivacy(store: recipient.noteStore).envelope() != nil)
        }
    }
}
