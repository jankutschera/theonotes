// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Generic regression: conflict Markdown must keep the copied attachment live when indexed.
/// Uses existing fake CloudKit records + real publisher/reconciler/blob transfer, no sketch codec.
@Suite struct CloudAttachmentConflictRecoveryTests {
    private func reachable(_ device: PublisherDevice) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for note in try device.noteStore.allNotes() {
            let links = NoteParser.attachmentLinks(in: note.text)
            #expect(links.count == 1, "Every original/conflict note must retain its attachment link")
            for link in links {
                let live = try device.db.pool.read {
                    try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE noteId=? AND filename=? AND deletedAt IS NULL)",
                                      arguments: [note.id, link.filename]) == true
                }
                #expect(live, "Conflict indexing must not tombstone its copied attachment")
                if live { result[note.id] = try Data(contentsOf: device.installed(noteID: note.id, filename: link.filename)) }
            }
        }
        return result
    }

    @Test(arguments: [false, true])
    func conflictingBinaryAttachmentRemainsReadableBeforeAndAfterPublication(firstDeviceWins: Bool) async throws {
        try await withBlobWorld(2) { world in
            let devices = world.devices, rigs = devices.map { BlobRig($0) }
            for (device, rig) in zip(devices, rigs) { device.publishThrough(rig) }
            let baseline = Data("baseline attachment".utf8)
            let left = Data("independent offline left bytes".utf8)
            let right = Data("independent offline right bytes".utf8)
            let filename = "conflict.bin"
            let note = try devices[0].noteStore.create(text: "# Attachment\n" + AttachmentMarkdown.link(for: filename))
            _ = try AttachmentStore(paths: devices[0].paths, database: devices[0].db)
                .add(data: baseline, filename: filename, to: note.id)
            try await devices[0].publish()
            try await devices[1].fetchEntities()
            _ = try await devices[1].receiver(rigs[1]).applyPending()
            #expect(try reachable(devices[1])[note.id] == baseline)
            let attachmentID = try devices[0].attachmentID(of: note.id)
            for (index, bytes) in [left, right].enumerated() {
                try AttachmentFiles(paths: devices[index].paths, database: devices[index].db).write(
                    [ImportedAttachment(filename: filename, data: bytes)], noteId: note.id, replacing: true) { _ in }
            }
            let winner = firstDeviceWins ? 0 : 1, loser = firstDeviceWins ? 1 : 0
            try await devices[winner].publish()
            let rejected = try await devices[loser].publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == attachmentID })
            try await devices[loser].fetchEntities()
            _ = try await devices[loser].receiver(rigs[loser]).applyPending()
            let immediate = try reachable(devices[loser])
            #expect(immediate.count == 2)
            #expect(Set(immediate.values) == Set([left, right]))
            for _ in 0..<6 {
                for index in devices.indices {
                    try await devices[index].fetchEntities()
                    _ = try await devices[index].receiver(rigs[index]).applyPending()
                    try await devices[index].publish()
                }
            }
            for device in devices {
                let versions = try reachable(device)
                #expect(versions.count == 2)
                #expect(Set(versions.values) == Set([left, right]))
                #expect(try device.store.allRemote().isEmpty)
                #expect(try device.rowCount("ck_inflight") == 0)
            }
        }
    }
}
