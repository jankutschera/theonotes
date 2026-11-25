// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import BaerchenIOS

@Suite @MainActor
struct MobileFirstSyncRecoveryTests {
    @Test func lockedCrashJournalMustRecoverBeforeFirstSyncSafetyBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("first-sync-recovery-" + UUID().uuidString)
        let paths = AppPaths(root: root.appendingPathComponent("source"))
        let source = try MobileLibrary(paths: paths)
        defer { try? source.close(); try? FileManager.default.removeItem(at: root) }
        let password = "synthetic journal password"
        let original = "# Protected Fixture\nBefore crash\n[File](private.bin)"
        let recovered = "# Protected Fixture\nacknowledged-secret-🐻-e\u{301}\n[File](private.bin)"
        let attachment = Data("encrypted-attachment-secret-\(UUID())".utf8)
        let note = try source.store.create(text: original)
        _ = try source.addAttachment(data: attachment, filename: "private.bin", noteID: note.id)
        try await source.unlockNotes(password: password, createPassword: true)
        try source.lockNote(note.id)
        let access = try #require(source.privateAccess)
        let key = try access.journalKey()
        let base = try #require(try access.note(id: note.id))
        try source.close()

        // Write the same encrypted base/entry format that is fsynced before editor acknowledgment.
        // No live NoteSession/debounce timer exists to commit it before the cold launch.
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: key)
        try journal.writeBase(JournalBase(storeRevision: base.revision, baseText: original))
        try journal.append(JournalEntry(txId: "ack-before-crash", baseRevision: 0,
            changeSet: ChangeSet(sections: [.replace(deleteLength: original.utf16.count, insert: recovered)])))
        let pending = try Data(contentsOf: journal.fileURL)
        let pendingBase = try Data(contentsOf: journal.baseURL)
        #expect(pending.range(of: Data("acknowledged-secret".utf8)) == nil)

        let cold = try MobileLibrary(paths: paths)
        defer { try? cold.close() }
        let stored = try #require(try cold.store.note(id: note.id))
        #expect(stored.isLocked && stored.text.isEmpty)
        #expect(cold.privateAccess == nil)
        // This is the exact safety-backup operation awaited by syncNow before its first pull.
        await #expect(throws: BackupError.pendingEdits) { try await cold.makeBackup() }
        #expect(!cold.libraryOperationBusy)
        #expect(try Data(contentsOf: journal.fileURL) == pending)
        #expect(try Data(contentsOf: journal.baseURL) == pendingBase)
        #expect(try cold.store.note(id: note.id) == stored)
        await #expect(throws: CryptoError.wrongPassword) { try await cold.unlockNotes(password: "incorrect") }
        #expect(try Data(contentsOf: journal.fileURL) == pending)
        #expect(try Data(contentsOf: journal.baseURL) == pendingBase)
        #expect(cold.privateAccess == nil)

        // The reachable Unlock Note UI calls this method, which recovers all locked journals.
        try await cold.unlockNotes(password: password)
        #expect(try cold.privateAccess?.note(id: note.id)?.text == recovered)
        #expect(try Data(contentsOf: journal.fileURL).isEmpty)
        #expect(try cold.store.note(id: note.id)?.text.isEmpty == true)
        try cold.lockVault()
        let archive = try await cold.makeBackup()
        let summary = try LibraryBackup(database: cold.database, paths: paths).inspect(archive)
        #expect(summary.noteCount == 1 && summary.lockedNoteCount == 1 && summary.attachmentCount == 1)
        let extracted = root.appendingPathComponent("verified-archive")
        try PortableZIP.extract(archive, to: extracted)
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: extracted.path) {
            let url = extracted.appendingPathComponent(relativePath)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: Data("acknowledged-secret".utf8)) == nil)
            #expect(bytes.range(of: attachment) == nil)
        }

        let restored = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("restored")))
        defer { try? restored.close() }
        let result = try await restored.restoreBackup(archive, mode: .merge, backupPassword: nil, currentPassword: nil)
        #expect(result.restored == 1)
        #expect(try restored.store.note(id: note.id)?.isLocked == true)
        #expect(try restored.store.note(id: note.id)?.text.isEmpty == true)
        try await restored.unlockNotes(password: password)
        #expect(try restored.privateAccess?.note(id: note.id)?.text == recovered)
        let file = try #require(try restored.attachmentURL("private.bin", noteID: note.id))
        #expect(try Data(contentsOf: file) == attachment)
    }
}
