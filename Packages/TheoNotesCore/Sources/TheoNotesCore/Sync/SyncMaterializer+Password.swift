// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public enum SyncNotePasswordError: LocalizedError, Sendable {
    case differentVaults
    public var errorDescription: String? {
        "These libraries use different note encryption keys. Their protected notes need vault reconciliation before the password change can be applied."
    }
}

extension SyncMaterializer {
    struct PasswordAuthorization: Sendable {
        let localEnvelope: Data
        let conversionKeys: (SymmetricKey, SymmetricKey)?
    }
    /// PBKDF2 and key verification happen outside the SQLite writer. The exact local
    /// envelope is checked again at commit so a concurrent password change cannot race it.
    func authorizePasswordEnvelope(_ value: SyncRemoteValue, access: LockedNoteAccess?, password: String?) async throws -> PasswordAuthorization? {
        guard case .lockEnvelope(let remote) = value, let access, let password else { return nil }
        let local = try await database.pool.read { db -> Data? in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == true else { return nil }
            return try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1")
        }
        guard let local, local != remote else { return nil }
        let key = try access.journalKey()
        let remoteKey = try JSONDecoder().decode(CryptoEnvelope.self, from: remote).unwrap(password: password)
        let different = key.withUnsafeBytes({ Data($0) }) != remoteKey.withUnsafeBytes({ Data($0) })
        if different {
            try await database.pool.read { try Self.requireUnpublishedProtectedLibrary(in: $0) }
        }
        // Access from an unrelated library must not authorize replacement of this vault.
        let proof = try NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)).restoreAccess(
            vaultKey: key, matching: JSONDecoder().decode(CryptoEnvelope.self, from: local))
        proof.revoke()
        _ = try access.journalKey()
        if different { _ = try LibraryBackup(database: database, paths: paths).createRolling() }
        return PasswordAuthorization(localEnvelope: local, conversionKeys: different ? (key, remoteKey) : nil)
    }

    static func requireUnpublishedProtectedLibrary(in db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == false,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") == 0,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_shadow WHERE entityType='note' AND entityId IN (SELECT id FROM note WHERE isLocked=1)") == 0 else {
            throw SyncNotePasswordError.differentVaults
        }
    }

    /// Only for unpublished first-sync libraries. Published ancestors/outbox ciphertext
    /// must never be rewritten under a new vault key behind the server's revision history.
    func stageInitialVaultConversion(from oldKey: SymmetricKey, to newKey: SymmetricKey,
                                     files: AttachmentFiles, staged: inout [AttachmentFiles.Staged], in db: Database) throws {
        try Self.requireUnpublishedProtectedLibrary(in: db)
        guard try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM staging_batch)+(SELECT COUNT(*) FROM privacy_transition)") == 0 else { throw NotePrivacyError.pendingAttachments }
        let fm = FileManager.default
        for note in try Note.fetchAll(db, sql: "SELECT * FROM note WHERE isLocked=1") {
            try Task.checkCancellation()
            for entry in try fm.contentsOfDirectory(at: paths.journal, includingPropertiesForKeys: [.fileSizeKey])
                where entry.lastPathComponent.hasPrefix(note.id + ".") {
                let size = try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if entry.lastPathComponent.contains(".unreplayed") || (entry.pathExtension == "jsonl" && size > 0) { throw NotePrivacyError.pendingEdits }
            }
            guard let cipher = note.encryptedPayload else { throw NotePrivacyError.invalidPayload }
            let plaintext = try NoteCipher.open(cipher, vaultKey: oldKey, context: note.id)
            let body = try JSONDecoder().decode(LockedNotePayload.self, from: plaintext)
            guard body.version == 1 else { throw NotePrivacyError.invalidPayload }
            let directory = files.directory(for: note.id)
            var names: [String] = []
            let attributes: [FileAttributeKey: Any]?
            do { attributes = try fm.attributesOfItem(atPath: directory.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { attributes = nil }
            if let attributes {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NotePrivacyError.invalidPayload }
                for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    let name = file.lastPathComponent
                    try AttachmentFiles.validate(name)
                    guard name.hasSuffix(".bch"), UUID(uuidString: String(name.dropLast(4))) != nil,
                          try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw NotePrivacyError.invalidPayload }
                    names.append(name)
                }
            }
            let batch = try files.stageTransformed(names, noteId: note.id) { name, output in
                try ChunkedCipher.reencrypt(input: directory.appendingPathComponent(name), output: output,
                    fromKey: oldKey, toKey: newKey, fromContext: name, toContext: name)
            }
            staged.append(batch)
            try AttachmentFiles.record(batch, in: db)
            try db.execute(sql: "UPDATE note SET encryptedPayload=?,revision=revision+1 WHERE id=?",
                arguments: [try NoteCipher.seal(plaintext, vaultKey: newKey, context: note.id), note.id])
            try db.execute(sql: "DELETE FROM sync_attachment_cache WHERE attachmentId IN (SELECT id FROM attachment WHERE noteId=?)", arguments: [note.id])
            try db.execute(sql: "UPDATE attachment SET sha256=NULL,byteSize=NULL,fileModifiedAt=NULL WHERE noteId=?", arguments: [note.id])
        }
    }
}
