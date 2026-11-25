// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

/// Password-authorized reconciliation. Decrypted bodies exist only in memory; every
/// returned protected body is authenticated to its destination note ID.
enum SyncLockedNoteMerge {
    static func reconcile(base: SyncNotePayload?, local: SyncNotePayload?, remote: SyncNotePayload?,
                          entityID: String, mutationID: String, revision: Int64,
                          key: SymmetricKey) throws -> SyncNoteMergeResult {
        // A concurrent privacy transition preserves both authored versions in their own
        // protection states instead of silently turning protected edits into plaintext.
        if ![base, local, remote].compactMap({ $0 }).allSatisfy(\.isLocked) {
            if let local, local.isLocked { _ = try open(local, key: key) }
            return try conflict(local: local, remote: remote, entityID: entityID, mutationID: mutationID, revision: revision, key: key)
        }
        let old = try base.map { try open($0, key: key) }
        let mine = try local.map { try open($0, key: key) }
        let theirs = try remote.map { try open($0, key: key) }
        let result = try SyncNoteMerge.reconcile(base: old?.note, local: mine?.note, remote: theirs?.note,
            entityID: entityID, rejectedMutationID: mutationID, remoteRevision: revision)
        switch result {
        case .merged(let merged):
            guard var merged else { return .merged(nil) }
            let names = merged.attachmentNames ?? [:]
            guard names.count == merged.attachmentIds.count else { throw NotePrivacyError.invalidPayload }
            var manifest: [String: String] = [:], identities: [String: String] = [:]
            for (id, name) in names {
                identities[name] = id
                if [old, mine, theirs].compactMap({ $0 }).contains(where: {
                    $0.body.indexIDs[name] == id && $0.body.attachments[name] != nil
                }) { manifest[name] = id + ".bch" }
            }
            let body = LockedNotePayload(text: merged.text, attachments: manifest, attachmentIDs: identities)
            merged.isLocked = true; merged.text = ""
            merged.encryptedPayload = try seal(body, id: merged.id, key: key)
            merged.attachmentNames = Dictionary(uniqueKeysWithValues: merged.attachmentIds.map { ($0, $0 + ".bch") })
            try merged.validate()
            return .merged(merged)
        case .conflict:
            return try conflict(local: local, remote: remote, entityID: entityID, mutationID: mutationID, revision: revision, key: key)
        case .needsUnlock: throw NotePrivacyError.invalidPayload
        }
    }

    static func deletedProtectedConflict(remote: SyncNotePayload, entityID: String, mutationID: String,
                                         revision: Int64, key: SymmetricKey) throws -> SyncNoteMergeResult {
        try conflict(local: nil, remote: remote, entityID: entityID, mutationID: mutationID, revision: revision, key: key)
    }

    private static func conflict(local: SyncNotePayload?, remote: SyncNotePayload?, entityID: String,
                                 mutationID: String, revision: Int64, key: SymmetricKey) throws -> SyncNoteMergeResult {
        let info = SyncConflictInfo(originalNoteId: entityID, rejectedMutationId: mutationID, remoteRevision: revision)
        var kept = local, copy = remote
        kept?.conflict = info
        if let remote {
            var remoteCopy = remote
            remoteCopy.id = SyncNoteMerge.conflictID(entityID: entityID, mutationID: mutationID, remoteRevision: revision)
            remoteCopy.conflict = info; remoteCopy.attachmentSnapshots = nil
            if remoteCopy.isLocked {
                var body = try open(remote, key: key).body
                remoteCopy.attachmentIds = body.indexIDs.values.sorted()
                remoteCopy.attachmentNames = Dictionary(uniqueKeysWithValues: remoteCopy.attachmentIds.map { ($0, $0 + ".bch") })
                body.attachmentIDs = body.indexIDs.mapValues { SyncMaterializer.copyAttachmentID($0, noteID: remoteCopy.id) }
                body.attachments = body.attachments.mapValues {
                    SyncMaterializer.copyAttachmentID(String($0.dropLast(4)), noteID: remoteCopy.id) + ".bch"
                }
                remoteCopy.encryptedPayload = try seal(body, id: remoteCopy.id, key: key)
            }
            copy = remoteCopy
        }
        return .conflict(local: kept, remoteCopy: copy)
    }

    static func attachmentConflict(note: SyncNotePayload, attachmentID: String, copyID: String,
                                   info: SyncConflictInfo, key: SymmetricKey) throws -> SyncNotePayload {
        let original = try open(note, key: key)
        let filename = original.body.indexIDs.first(where: { $0.value == attachmentID })?.key ?? "Attachment"
        let copyAsset = SyncMaterializer.copyAttachmentID(attachmentID, noteID: copyID)
        let body = LockedNotePayload(text: "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: filename) + "\n",
            attachments: [filename: copyAsset + ".bch"], attachmentIDs: [filename: copyAsset])
        let copy = Note(id: copyID, text: "", title: "Attachment conflict", titleKey: "attachment conflict",
            createdAt: .now, modifiedAt: .now, isLocked: true, encryptedPayload: try seal(body, id: copyID, key: key))
        var result = SyncNotePayload(note: copy, directTags: [], pinnedTags: [], attachmentIds: [attachmentID], conflict: info)
        result.attachmentNames = [attachmentID: attachmentID + ".bch"]
        return result
    }

    private struct Opened {
        var note: SyncNotePayload
        var body: LockedNotePayload
    }

    private static func open(_ protected: SyncNotePayload, key: SymmetricKey) throws -> Opened {
        try protected.validate()
        guard let cipher = protected.encryptedPayload else { throw NotePrivacyError.invalidPayload }
        let body = try JSONDecoder().decode(LockedNotePayload.self,
            from: NoteCipher.open(cipher, vaultKey: key, context: protected.id))
        guard body.version == 1, body.text.utf16.count <= 500_000,
              Set(body.indexIDs.values).count == body.indexIDs.count,
              Set(body.indexIDs.keys.map(AttachmentFiles.fileSystemKey)).count == body.indexIDs.count,
              Set(protected.attachmentIds).isSubset(of: Set(body.indexIDs.values)) else { throw NotePrivacyError.invalidPayload }
        for (name, id) in body.indexIDs {
            try AttachmentFiles.validate(name)
            guard UUID(uuidString: id) != nil else { throw NotePrivacyError.invalidPayload }
        }
        for (name, blob) in body.attachments {
            guard let id = body.indexIDs[name], blob == id + ".bch" else { throw NotePrivacyError.invalidPayload }
        }
        var note = protected
        note.attachmentSnapshots = nil
        note.isLocked = false; note.encryptedPayload = nil; note.text = body.text
        note.attachmentIds = body.indexIDs.values.sorted()
        note.attachmentNames = Dictionary(uniqueKeysWithValues: body.indexIDs.map { ($0.value, $0.key) })
        return Opened(note: note, body: body)
    }

    private static func seal(_ body: LockedNotePayload, id: String, key: SymmetricKey) throws -> Data {
        try NoteCipher.seal(JSONEncoder().encode(body), vaultKey: key, context: id)
    }
}
