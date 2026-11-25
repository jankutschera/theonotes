// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public struct SyncConflictInfo: Codable, Equatable, Sendable {
    public var originalNoteId: String
    public var rejectedMutationId: String
    public var remoteRevision: Int64
}

/// Only portable semantics. Local revision, title/search keys, editor position and derived
/// indexes are deliberately absent. Dates are UTC milliseconds, independent of Codable's
/// Foundation date strategy. Locked bodies remain inner ciphertext under the password vault.
public struct SyncNotePayload: Codable, Equatable, Sendable {
    public var version = 1
    public var id: String
    public var text: String
    public var title: String
    public var createdAt: Int64
    public var modifiedAt: Int64
    public var location: NoteLocation
    public var trashedAt: Int64?
    public var archivedAt: Int64?
    public var isPinnedGlobal: Bool
    public var isReadOnly: Bool
    public var isLocked: Bool
    public var encryptedPayload: Data?
    public var directTags: [String]
    public var pinnedTags: [String]
    public var attachmentIds: [String]
    /// Identity/filename placeholders let Markdown arrive before a missing file or its upload.
    /// Protected names are opaque UUID.bch values. Absent in older protocol-v1 payloads.
    public var attachmentNames: [String: String]? = nil
    /// Pins the encrypted file representation used by this note version. Later attachment
    /// revisions can have another lock state; these references preserve a coherent fallback.
    public var attachmentSnapshots: [String: SyncAttachmentPayload]? = nil
    public var conflict: SyncConflictInfo?

    public init(note: Note, directTags: [String], pinnedTags: [String], attachmentIds: [String], conflict: SyncConflictInfo? = nil) {
        id = note.id; text = note.isLocked ? "" : note.text; title = note.title
        createdAt = Self.milliseconds(note.createdAt); modifiedAt = Self.milliseconds(note.modifiedAt)
        location = note.location; trashedAt = note.trashedAt.map(Self.milliseconds); archivedAt = note.archivedAt.map(Self.milliseconds)
        isPinnedGlobal = note.isPinnedGlobal; isReadOnly = note.isReadOnly; isLocked = note.isLocked
        encryptedPayload = note.encryptedPayload; self.directTags = directTags.sorted(); self.pinnedTags = pinnedTags.sorted()
        self.attachmentIds = attachmentIds.sorted(); self.conflict = conflict
    }
    public func validate() throws {
        guard version == 1 else { throw SyncProtocolError.unsupportedVersion }
        try SyncWire.validateID(id)
        guard text.utf16.count <= 500_000, !isLocked || text.isEmpty,
              isLocked || encryptedPayload == nil,
              Set(attachmentIds).count == attachmentIds.count,
              directTags.count <= 10_000, pinnedTags.count <= 10_000,
              [createdAt, modifiedAt, trashedAt ?? 0, archivedAt ?? 0].allSatisfy({ $0 >= -SyncWire.maximumRevision && $0 <= SyncWire.maximumRevision })
        else { throw SyncProtocolError.invalidPayload }
        for id in attachmentIds { try SyncWire.validateID(id) }
        if let attachmentNames {
            guard Set(attachmentNames.keys) == Set(attachmentIds),
                  Set(attachmentNames.values.map(AttachmentFiles.fileSystemKey)).count == attachmentNames.count else { throw SyncProtocolError.invalidPayload }
            for (id, filename) in attachmentNames {
                try AttachmentFiles.validate(filename)
                guard !isLocked || filename == id + ".bch" else { throw SyncProtocolError.invalidPayload }
            }
        }
        if let attachmentSnapshots {
            guard Set(attachmentSnapshots.keys).isSubset(of: Set(attachmentIds)) else { throw SyncProtocolError.invalidPayload }
            for (id, attachment) in attachmentSnapshots {
                try attachment.validate()
                guard attachment.id == id, attachment.noteId == self.id, attachment.isLocked == isLocked,
                      attachmentNames?[id] == attachment.filename else { throw SyncProtocolError.invalidPayload }
            }
        }
        if let conflict { try SyncWire.validateID(conflict.originalNoteId); try SyncWire.validateID(conflict.rejectedMutationId) }
    }
    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func capture(id: String, includeRetained: Bool = false, in db: Database) throws -> SyncNotePayload? {
        guard let note = try Note.fetchOne(db, key: id) else { return nil }
        let tags = try String.fetchAll(db, sql: "SELECT t.displayPath FROM tag t JOIN note_tag nt ON t.id=nt.tagId WHERE nt.noteId=? AND nt.isDirect=1 ORDER BY t.pathKey", arguments: [id])
        let pins = try String.fetchAll(db, sql: "SELECT t.displayPath FROM tag t JOIN note_pin p ON t.id=p.tagId WHERE p.noteId=? ORDER BY t.pathKey", arguments: [id])
        // Retained files support undo and relative links that are not indexed as image
        // attachments. Sync carries those identities too, for both privacy states.
        let attachmentRows = try Row.fetchAll(db, sql: "SELECT id,filename FROM attachment WHERE noteId=? AND (deletedAt IS NULL OR ?) ORDER BY id", arguments: [id, includeRetained])
        let attachments = attachmentRows.map { $0["id"] as String }
        let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_conflict WHERE noteId=?", arguments: [id])
        let conflict = row.map { SyncConflictInfo(originalNoteId: $0["originalNoteId"], rejectedMutationId: $0["rejectedMutationId"], remoteRevision: $0["remoteRevision"]) }
        var result = SyncNotePayload(note: note, directTags: tags, pinnedTags: pins, attachmentIds: attachments, conflict: conflict)
        result.attachmentNames = Dictionary(uniqueKeysWithValues: attachmentRows.map { ($0["id"] as String, $0["filename"] as String) })
        return result
    }
}

struct SyncTagPreferencePayload: Codable, Equatable, Sendable {
    var version = 1
    let path: String
    let iconName: String?
    let isPinned: Bool
    let sortIndex: Int?
}
struct SyncSettingPayload: Codable, Equatable, Sendable {
    var version = 1
    let key: String
    let value: String

    func validate() throws {
        guard version == 1, SyncPayloadCodec.portableSettings.contains(key) else { throw SyncProtocolError.invalidPayload }
        let data = Data(value.utf8), decoder = JSONDecoder()
        switch key {
        case "hideMarkdown", "showNoteCounts", "autoSortTodos", "showHeadingLevels", "autocomplete": _ = try decoder.decode(Bool.self, from: data)
        case "noteSort": _ = try decoder.decode(NoteSort.self, from: data)
        case "tagPosition": _ = try decoder.decode(TagPosition.self, from: data)
        case "startNoteTemplate":
            let id = try decoder.decode(String.self, from: data)
            if !id.isEmpty { try SyncWire.validateID(id) }
        default: throw SyncProtocolError.invalidPayload
        }
    }
}
struct SyncExternalRefPayload: Codable, Equatable, Sendable {
    var version = 1
    let source: String
    let externalId: String
    let noteId: String?
    let lastSeenModified: Int64?
    let lastSeenHash: String?
    let lastSeenTextHash: String?
    let lastSeenMeta: String?
    let importedTextHash: String?
    // importedRevision is a local optimistic version, never a portable sync base.
}
struct SyncLockEnvelopePayload: Codable, Equatable, Sendable {
    var version = 1
    let envelope: Data
}

enum SyncPayloadCodec {
    static let portableSettings: Set<String> = ["hideMarkdown", "showNoteCounts", "autoSortTodos", "showHeadingLevels", "autocomplete", "startNoteTemplate", "tagPosition", "noteSort"]

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .custom { data, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SyncWire.base64(data))
        }
        return encoder
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return try SyncWire.decode64(container.decode(String.self))
        }
        return try decoder.decode(type, from: data)
    }

    /// Attachments need a staged, verified encrypted blob and are supplied by the blob preparer.
    /// No missing attachment is silently replaced with an empty descriptor or tombstone.
    static func capture(_ dirty: SyncDirty, in db: Database) throws -> SyncContent {
        let encoder = encoder()
        switch dirty.type {
        case .note:
            guard let note = try SyncNotePayload.capture(id: dirty.localID, includeRetained: true, in: db) else { return SyncContent(payload: nil) }
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?) OR EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?)", arguments: [note.id, note.id]) ?? true
            guard !pending else { throw SyncQueueError.snapshotUnavailable }
            try note.validate()
            return SyncContent(payload: try encoder.encode(note))
        case .tagPreference:
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tag WHERE id=?", arguments: [dirty.localID]) else { return SyncContent(payload: nil) }
            return SyncContent(payload: try encoder.encode(SyncTagPreferencePayload(path: row["displayPath"], iconName: row["iconName"], isPinned: row["isPinned"], sortIndex: row["sortIndex"])))
        case .setting:
            guard portableSettings.contains(dirty.localID) else { throw SyncProtocolError.invalidPayload }
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [dirty.localID]) else { return SyncContent(payload: nil) }
            return SyncContent(payload: try encoder.encode(SyncSettingPayload(key: dirty.localID, value: value)))
        case .externalRef:
            let keys = try JSONDecoder().decode([String].self, from: Data(dirty.localID.utf8))
            guard keys.count == 2 else { throw SyncProtocolError.invalidPayload }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM external_ref WHERE source=? AND externalId=?", arguments: [keys[0], keys[1]]) else { return SyncContent(payload: nil) }
            let stamp: Date? = row["lastSeenModified"]
            let payload = SyncExternalRefPayload(source: row["source"], externalId: row["externalId"], noteId: row["noteId"],
                lastSeenModified: stamp.map(SyncNotePayload.milliseconds), lastSeenHash: row["lastSeenHash"], lastSeenTextHash: row["lastSeenTextHash"],
                lastSeenMeta: row["lastSeenMeta"], importedTextHash: row["importedTextHash"])
            return SyncContent(payload: try encoder.encode(payload))
        case .keyBundle:
            guard dirty.localID == "lock-vault" else { throw SyncProtocolError.invalidPayload }
            guard let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") else { return SyncContent(payload: nil) }
            return SyncContent(payload: try encoder.encode(SyncLockEnvelopePayload(envelope: data)))
        case .attachment: throw SyncQueueError.snapshotUnavailable
        }
    }
}
