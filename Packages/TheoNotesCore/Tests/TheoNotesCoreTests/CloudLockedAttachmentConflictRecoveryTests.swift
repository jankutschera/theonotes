// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct CloudLockedAttachmentConflictRecoveryTests {
    private func receiver(_ device: PublisherDevice, rig: BlobRig, access: LockedNoteAccess) -> CloudReconciler {
        CloudReconciler(database: device.db, paths: device.paths, store: device.store,
            accountID: device.accountID, vaultKey: device.key,
            pinner: CloudAssetPinner(directory: device.paths.cloudPinned), blobs: rig.transfer,
            noteAccess: { access })
    }

    private func replace(_ bytes: Data, device: PublisherDevice, access: LockedNoteAccess,
                         noteID: String, opaqueName: String) throws {
        let temporary = device.paths.root.appendingPathComponent("edited-inner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ChunkedCipher.encrypt(data: bytes, output: temporary, keyEncryptionKey: access.journalKey(), context: opaqueName)
        try AttachmentFiles(paths: device.paths, database: device.db).write(
            [ImportedAttachment(filename: opaqueName, data: Data(contentsOf: temporary))],
            noteId: noteID, replacing: true) { _ in }
    }

    @Test(arguments: [false, true])
    func lockedCloudConflictUnlockRetainsBothReadableAttachments(firstDeviceWins: Bool) async throws {
        try await withBlobWorld(2) { world in
            let devices = world.devices, rigs = devices.map { BlobRig($0) }
            for (device, rig) in zip(devices, rigs) { device.publishThrough(rig) }
            let baseline = Data("protected baseline".utf8)
            let left = Data("protected left offline bytes".utf8), right = Data("protected right offline bytes".utf8)
            let note = try devices[0].noteStore.create(text: "# Private attachment\n" + AttachmentMarkdown.link(for: "private.bin"))
            _ = try AttachmentStore(paths: devices[0].paths, database: devices[0].db)
                .add(data: baseline, filename: "private.bin", to: note.id)
            let firstAccess = try NotePrivacy(store: devices[0].noteStore).setPassword("fixture-password")
            try firstAccess.lock(noteId: note.id)
            try await devices[0].publish()
            try await devices[1].fetchEntities()
            _ = try await devices[1].receiver(rigs[1]).applyPending()
            let secondAccess = try NotePrivacy(store: devices[1].noteStore).unlock(password: "fixture-password")
            let accesses = [firstAccess, secondAccess]
            let attachmentID = try devices[0].attachmentID(of: note.id), opaqueName = attachmentID + ".bch"
            for (index, bytes) in [left, right].enumerated() {
                try replace(bytes, device: devices[index], access: accesses[index], noteID: note.id, opaqueName: opaqueName)
            }
            let winner = firstDeviceWins ? 0 : 1, loser = firstDeviceWins ? 1 : 0
            try await devices[winner].publish()
            let rejected = try await devices[loser].publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == attachmentID })
            try await devices[loser].fetchEntities()
            _ = try await receiver(devices[loser], rig: rigs[loser], access: accesses[loser]).applyPending()
            let protectedNotes = try devices[loser].noteStore.allNotes()
            #expect(protectedNotes.count == 2)
            #expect(protectedNotes.allSatisfy { $0.isLocked && $0.text.isEmpty })
            for protectedNote in protectedNotes { try accesses[loser].removeLock(noteId: protectedNote.id) }
            var recovered: [Data] = []
            for unlocked in try devices[loser].noteStore.allNotes() {
                let links = NoteParser.attachmentLinks(in: unlocked.text)
                #expect(links.count == 1, "Unlock must expose a recognized attachment, including the conflict copy")
                for link in links {
                    let live = try await devices[loser].db.pool.read {
                        try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE noteId=? AND filename=? AND deletedAt IS NULL)",
                                          arguments: [unlocked.id, link.filename]) == true
                    }
                    #expect(live, "Unlock/index must retain the conflict attachment row")
                    if live { recovered.append(try Data(contentsOf: devices[loser].installed(noteID: unlocked.id, filename: link.filename))) }
                }
            }
            #expect(Set(recovered) == Set([left, right]))
        }
    }
}
