// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct GuardedAttachmentReplacementTests {
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    @Test(arguments: [false, true])
    func sourceGuardRejectsChangedBytesAndRevisionWithoutNewFiles(locked: Bool) throws {
        let paths = try TempPaths(), db = try AppDatabase.inMemory()
        defer { try? db.pool.close() }
        let store = NoteStore(db: db, notifier: nil, paths: paths.paths)
        let files = AttachmentStore(paths: paths.paths, database: db)
        let original = Data("original".utf8), changed = Data("changed".utf8)
        let note = try store.create(text: AttachmentMarkdown.link(for: "source.png"))
        _ = try files.add(data: original, filename: "source.png", to: note.id)
        let access = try NotePrivacy(store: store).setPassword("fixture-password")
        if locked { try access.lock(noteId: note.id) }
        let revision = try #require(try store.note(id: note.id)).revision
        let valid = AttachmentSourceGuard(filename: "source.png", plaintextSHA256: hash(original), maximumBytes: 64, expectedNoteRevision: revision)
        let wrongHash = AttachmentSourceGuard(filename: "source.png", plaintextSHA256: hash(changed), maximumBytes: 64, expectedNoteRevision: revision)
        let wrongRevision = AttachmentSourceGuard(filename: "source.png", plaintextSHA256: hash(original), maximumBytes: 64, expectedNoteRevision: revision + 1)
        let before = try FileManager.default.contentsOfDirectory(atPath: paths.paths.attachments.appendingPathComponent(note.id).path).sorted()
        for rejected in [wrongHash, wrongRevision] {
            #expect(throws: AttachmentSourceGuard.Failure.changed) {
                if locked { _ = try access.addAttachments([ImportedAttachment(filename: "edited.png", data: changed)], to: note.id, validatingSource: rejected) }
                else { _ = try files.addBatch([ImportedAttachment(filename: "edited.png", data: changed)], to: note.id, validatingSource: rejected) }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.paths.attachments.appendingPathComponent(note.id).path).sorted() == before)
        }
        let names: [String]
        if locked { names = try access.addAttachments([ImportedAttachment(filename: "edited.png", data: changed)], to: note.id, validatingSource: valid) }
        else { names = try files.addBatch([ImportedAttachment(filename: "edited.png", data: changed)], to: note.id, validatingSource: valid) }
        #expect(names == ["edited.png"])
        if locked {
            #expect(try access.attachmentData("source.png", noteId: note.id, maximumBytes: 64) == original)
            #expect(try access.attachmentData("edited.png", noteId: note.id, maximumBytes: 64) == changed)
            #expect(try store.note(id: note.id)?.text == "")
        } else {
            #expect(try Data(contentsOf: #require(files.url(for: "source.png", noteId: note.id))) == original)
            #expect(try Data(contentsOf: #require(files.url(for: "edited.png", noteId: note.id))) == changed)
        }
    }
    @Test(arguments: [false, true])
    func queuedGuardedCopyRechecksAfterConcurrentWriterChangesSource(locked: Bool) async throws {
        let temporary = try TempPaths(), paths = temporary.paths, db = try AppDatabase.inMemory()
        defer { try? db.pool.close() }
        let store = NoteStore(db: db, notifier: nil, paths: paths), files = AttachmentStore(paths: paths, database: db)
        let original = Data("before external writer".utf8), changed = Data("after external writer".utf8)
        let note = try store.create(text: AttachmentMarkdown.link(for: "source.png")), noteID = note.id
        _ = try files.add(data: original, filename: "source.png", to: noteID)
        let access = try NotePrivacy(store: store).setPassword("fixture-password")
        if locked { try access.lock(noteId: noteID) }
        let revision = try #require(try store.note(id: noteID)).revision
        let ticket = AttachmentSourceGuard(filename: "source.png", plaintextSHA256: hash(original), maximumBytes: 128, expectedNoteRevision: revision)
        let filename: String, replacement: Data
        if locked {
            filename = try #require(try await db.pool.read { try String.fetchOne($0, sql: "SELECT filename FROM attachment WHERE noteId=?", arguments: [noteID]) })
            let encrypted = paths.root.appendingPathComponent("fixture-encrypted.bch")
            defer { try? FileManager.default.removeItem(at: encrypted) }
            try ChunkedCipher.encrypt(data: changed, output: encrypted, keyEncryptionKey: access.journalKey(), context: filename)
            replacement = try Data(contentsOf: encrypted)
        } else { filename = "source.png"; replacement = changed }
        let sourceURL = paths.attachments.appendingPathComponent(noteID).appendingPathComponent(filename)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let mutation = Task.detached {
            try db.pool.write { _ in
                entered.signal()
                guard release.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
                // Simulates another coordinated process changing only attachment bytes, not note revision.
                try replacement.write(to: sourceURL, options: .atomic)
            }
        }
        let started = await Task.detached { guardedAttachmentWriterStarted(entered) }.value
        guard started else {
            release.signal(); _ = try? await mutation.value
            Issue.record("Concurrent writer failed to start within its bounded deadline")
            return
        }
        let copy = Task.detached {
            let input = [ImportedAttachment(filename: "edited.png", data: Data("new draft".utf8))]
            if locked { return try access.addAttachments(input, to: noteID, validatingSource: ticket) }
            return try files.addBatch(input, to: noteID, validatingSource: ticket)
        }
        release.signal()
        try await mutation.value
        await #expect(throws: AttachmentSourceGuard.Failure.changed) { _ = try await copy.value }
        #expect(try store.note(id: noteID)?.revision == revision)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.attachments.appendingPathComponent(noteID).path)
        #expect(names == [filename], "Stale source rejection must create no new attachment or batch")
    }

}

/// Dispatch marks wait noasync; keep it in a synchronous function executed off the caller executor.
private func guardedAttachmentWriterStarted(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
}
