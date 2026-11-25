// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Fix round 2 of review point 2: attachments across independent incarnations, the ancestry proof, the release of a retried
/// quarantine, and the recheck of the quarantine row inside the commit.
@Suite struct CloudReceiverFixRound2Tests {
    @Test func anIndependentRecoveryWithADifferingAttachmentLosesNeitherTheLocalNorTheRemoteBytes() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let local = Data("LOCAL-BYTES-HELD-BY-B".utf8), remote = Data("REMOTE-BYTES-RECOVERED-BY-A".utf8)
        let note = try a.noteStore.create(text: "# Files\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: local, filename: "doc.txt", to: note.id)
        try a.edit(note.id, "# Files\n![doc](doc.txt)\n")
        try a.publishAttachments(of: note.id)
        try await a.sync()
        try b.copyBlobs(from: a)
        try await b.sync()
        #expect(try Data(contentsOf: b.attachmentFile(note.id, "doc.txt")) == local)
        let id = try a.attachmentID(of: note.id)
        // A changes the file and prepares it; then the cloud loses the attachment record and A recovers it (a new incarnation).
        try remote.write(to: a.attachmentFile(note.id, "doc.txt"))
        try a.sql("INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1", [id])
        _ = try await a.publisher.prepare()
        await world.account.removeRecord("e.attachment.\(id)")
        try await a.fullFetch()
        guard case .prepared = try a.incarnation.recover(entityType: "attachment", entityId: id) else { Issue.record("the attachment could not be recovered"); return }
        try await a.publish()
        #expect(await world.account.record(named: "e.attachment.\(id)") != nil)
        try b.copyBlobs(from: a)
        try await b.fullFetch()
        let report = try await b.reconciler.applyPending()
        #expect(report.quarantined.isEmpty)
        #expect(try Data(contentsOf: b.attachmentFile(note.id, "doc.txt")) == local, "the local bytes stay in place")
        #expect(try b.int("SELECT COUNT(*) FROM sync_dirty WHERE entityType='attachment' AND localId=?", [id]) == 1, "and are published again")
        let conflicts = try b.notes().filter { $0.text.contains("Attachment conflict") }
        #expect(conflicts.count == 1)
        let preserved = try #require(conflicts.first)
        #expect(try Data(contentsOf: b.attachmentFile(preserved.id, "doc.txt")) == remote, "the remote bytes live on as an attachment of the conflict note")
        for _ in 0..<3 { try await b.sync(); try b.copyBlobs(from: a); try await a.sync() }
        #expect(try b.store.quarantineRows().isEmpty && b.store.allMissing().isEmpty)
        #expect(try Data(contentsOf: b.attachmentFile(preserved.id, "doc.txt")) == remote)
    }

    /// The attachment's own version arrives alone (its note is not pending): the attachment path itself must keep the local bytes.
    @Test func anIndependentAttachmentVersionArrivingAloneKeepsTheLocalBytesAndPreservesTheRemoteOnes() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let local = Data("LOCAL-BYTES".utf8), remote = Data("REMOTE-BYTES-OF-ANOTHER-INCARNATION".utf8)
        let note = try a.noteStore.create(text: "# Files\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: local, filename: "doc.txt", to: note.id)
        try a.edit(note.id, "# Files\n![doc](doc.txt)\n")
        try a.publishAttachments(of: note.id)
        try await a.sync(); try b.copyBlobs(from: a); try await b.sync()
        let id = try a.attachmentID(of: note.id)
        try remote.write(to: a.attachmentFile(note.id, "doc.txt"))
        try a.sql("INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1", [id])
        _ = try await a.publisher.prepare()
        await world.account.removeRecord("e.attachment.\(id)")
        try await a.fullFetch()
        guard case .prepared = try a.incarnation.recover(entityType: "attachment", entityId: id) else { Issue.record("not recoverable"); return }
        try await a.publish()
        try b.copyBlobs(from: a)
        try await b.fullFetch()
        // Only the attachment is pending on B; the note's newer version is not.
        let pendingNote = try #require(try b.store.remote(recordName: "e.note.\(note.id)"))
        _ = try b.store.deleteRemote(pendingNote, accountGeneration: try b.store.generation())
        _ = try await b.reconciler.applyPending()
        #expect(try Data(contentsOf: b.attachmentFile(note.id, "doc.txt")) == local, "the local bytes were not replaced")
        let conflicts = try b.notes().filter { $0.text.contains("Attachment conflict") }
        #expect(conflicts.count == 1)
        #expect(try Data(contentsOf: b.attachmentFile(try #require(conflicts.first).id, "doc.txt")) == remote)
        #expect(try b.int("SELECT COUNT(*) FROM sync_dirty WHERE entityType='attachment' AND localId=?", [id]) == 1)
    }

    @Test func contentEqualityAsAnAncestryProofIncludesTheAttachmentSnapshots() throws {
        let snapshot = CloudRemoteReaderDifferentialTests.attachment("asset", noteId: "n1")
        let plain = CloudRemoteReaderDifferentialTests.note("n1")
        let pinned = CloudRemoteReaderDifferentialTests.note("n1", snapshot: snapshot)
        #expect(!SyncRemoteValue.note(plain).sameContent(as: .note(pinned)), "a note with another pinned file is not the same content")
        #expect(SyncRemoteValue.note(pinned).sameContent(as: .note(pinned)))
        let other = SyncAttachmentPayload(id: snapshot.id, noteId: snapshot.noteId, filename: snapshot.filename, isLocked: snapshot.isLocked,
                                          blobHash: snapshot.blobHash, cipherBytes: snapshot.cipherBytes, fileBytes: snapshot.fileBytes,
                                          fileHash: String(repeating: "ee", count: 32), uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        #expect(!SyncRemoteValue.note(pinned).sameContent(as: .note(CloudRemoteReaderDifferentialTests.note("n1", snapshot: other))))
    }

    @Test func aRetriedQuarantineWhosePayloadDoesNotOpenKeepsTheQuarantineUntilTheVersionIsApplied() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let note = try a.noteStore.create(text: "# Retry\nbody\n")
        try await a.sync()
        await world.account.corrupt(record: "e.note.\(note.id)", field: "cipher")        // header fine, ciphertext damaged
        await world.account.injectUnsupportedVersion(record: "e.note.\(note.id)")        // and written by a newer format
        try await b.fetch()
        let row = try #require(try b.store.quarantineRows().first)
        let newer = CloudFeedSink(store: b.store, pinner: CloudAssetPinner(directory: b.paths.cloudPinned),
                                  decode: { record in var copy = record; if case .int(99)? = copy.fields["v"] { copy.fields["v"] = .int(1) }; return try CloudRecordCodec.decode(copy) })
        let retry = try CloudQuarantine(store: b.store, pinner: CloudAssetPinner(directory: b.paths.cloudPinned), sink: newer).retryAll()
        #expect(retry.released == ["e.note.\(note.id)"], "handed to the receiver")
        #expect(try b.store.quarantineRows().first?.rawFields == row.rawFields, "but the row is still there: the payload was not opened")
        let report = try await b.reconciler.applyPending()
        #expect(report.fenced.map(\.entityId) == [note.id] && report.applied.isEmpty)
        #expect(try b.store.isFenced(entityType: "note", entityId: note.id))
        #expect(try b.store.quarantineRows().first?.rawFields == row.rawFields)
        #expect(try b.notes().isEmpty)
    }

    @Test func aQuarantineRowThatChangedAfterItWasInspectedIsNotReleased() throws {
        let d = try PublisherDevice("recheck", account: nil); defer { d.cleanup() }
        var unsupported = Rec.entity("n1", 5); unsupported.fields["v"] = .int(99)
        _ = try d.sink.intake(unsupported, delivery: .incremental)
        let inspected = try #require(try d.store.quarantineRow(recordName: "e.note.n1")).rawFields
        let valid = try Rec.sealedNote(d, id: "n1", ver: 6, text: "# Six\n")
        let version = try Rec.version(valid)
        // Between the inspection and the commit another unreadable version of the record is quarantined.
        var newer = Rec.entity("n1", 7); newer.fields["v"] = .int(98)
        _ = try d.sink.intake(newer, delivery: .incremental)
        #expect(try d.store.quarantineRow(recordName: "e.note.n1")?.rawFields != inspected)
        #expect(throws: CloudSyncStoreError.quarantineChanged("e.note.n1")) {
            try d.store.recordApplied(accountGeneration: try d.store.generation(), remote: version, ancestor: version.sealed ?? Data(),
                                      releasingQuarantine: true, expectedQuarantine: inspected)
        }
        #expect(try d.store.quarantineRows().count == 1, "the newer quarantine row is still there")
        #expect(try d.store.pair(for: d.ref("n1")) == nil)
        // The row that was inspected may be released.
        let current = try #require(try d.store.quarantineRow(recordName: "e.note.n1")).rawFields
        try d.store.recordApplied(accountGeneration: try d.store.generation(), remote: version, ancestor: version.sealed ?? Data(),
                                  releasingQuarantine: true, expectedQuarantine: current)
        #expect(try d.store.quarantineRows().isEmpty)
    }
}
