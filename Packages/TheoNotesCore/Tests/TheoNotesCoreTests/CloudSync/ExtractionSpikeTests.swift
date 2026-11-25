// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

// Throw-away prototype of the CloudKit extraction spike E0 (Task 2 of
// docs/superpowers/plans/2026-10-28-cloudkit-sync.md). It answers one question: can the
// existing capture, seal, merge and writer code under Sync/ carry every entity type between
// two libraries with no SyncEntity, no SyncEngine, no sync_shadow, sync_inbox or sync_outbox?
// The "cloud" is a dictionary; the base pair (ck_record) is an in-memory map per device.
// Decision record: docs/superpowers/specs/2026-10-28-cloudkit-extraction.md. Task 6 replaces
// this file with the real CloudApplier; nothing here is product code.

/// One `Entity` record as CK-R3 describes it, minus the CloudKit system fields.
struct SpikeRecord: Sendable, Equatable {
    var entityType: SyncEntityType
    var entityId: String
    var ver: Int64
    var sid: String
    var sealed: Data
    var blobRefs: [String]
    var name: String { SpikeRecord.name(entityType, entityId) }
    static func name(_ type: SyncEntityType, _ id: String) -> String { "e.\(type.rawValue).\(id)" }
}

/// The shared cloud of one person: records saved with a change-tag stand-in (`ver` must equal
/// the saver's base), and content-addressed blob ciphertext.
final class SpikeCloud: @unchecked Sendable {
    var records: [String: SpikeRecord] = [:]
    var blobs: [String: Data] = [:]
    private(set) var saves = 0

    enum Outcome: Equatable { case saved, stale }
    func save(_ record: SpikeRecord, baseVer: Int64) -> Outcome {
        guard (records[record.name]?.ver ?? 0) == baseVer, record.ver == baseVer + 1 else { return .stale }
        records[record.name] = record; saves += 1
        return .saved
    }
    func remove(_ name: String) { records[name] = nil }
}

/// Serves blob ciphertext to the reused `SyncMaterializer.preparedAttachmentCipher`.
struct SpikeBlobs: SyncBlobTransport {
    let blobs: [String: Data]
    let directory: URL
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL {
        guard let data = blobs[hash] else { throw SyncProtocolError.invalidPayload }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}

final class SpikeDevice: @unchecked Sendable {
    let paths: AppPaths
    let db: AppDatabase
    let accountID: String
    let key: SymmetricKey
    /// Stand-in for `ck_record`: the base pair per record name (version and sealed ancestor).
    var pairs: [String: (ver: Int64, sealed: Data)] = [:]
    /// Only for the CK-R13 characterization: the payload shipped with this build for a fixed id.
    var seedBase: [String: SyncNotePayload] = [:]
    /// true: the materializer's `note != remote` echo rule, for characterizing today's behaviour.
    var strictEcho = false
    var store: NoteStore { NoteStore(db: db, notifier: nil, paths: paths) }

    init(_ name: String, key: SymmetricKey, seed: Bool = false) throws {
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ck-spike-\(name)-\(UUID())"))
        try paths.createDirectories()
        db = try AppDatabase(path: paths.database)
        accountID = "ck-spike-account"
        self.key = key
        if seed { try GettingStartedNotes.seedNewLibrary(in: store, isNewLibrary: true) }
    }
    func configure() throws { try SyncQueue(database: db).configure(accountID: accountID) }
    func enable() throws { try SyncQueue(database: db).enable(accountID: accountID) }
    /// `SyncQueue.enable` (reused) marks every row dirty. A first run that downloaded first then
    /// drops the rows enable added for entities that already hold a base pair: they equal the
    /// cloud, or were deliberately not echoed (a remote tombstone moved to Trash).
    func enableKeepingAppliedEntitiesClean() throws {
        let before = Set(try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT entityType,localId FROM sync_dirty").map { "\($0["entityType"] as String)|\($0["localId"] as String)" }
        })
        try enable()
        try db.pool.write { db in
            for row in try Row.fetchAll(db, sql: """
                SELECT d.entityType,d.localId,s.entityId FROM sync_dirty d
                JOIN sync_entity_state s ON s.entityType=d.entityType AND s.localId=d.localId
                """) {
                let type: String = row["entityType"], local: String = row["localId"], entity: String = row["entityId"]
                guard !before.contains("\(type)|\(local)"), pairs["e.\(type).\(entity)"] != nil else { continue }
                try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType=? AND localId=?", arguments: [type, local])
            }
        }
    }
    func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }

    func materializer(_ cloud: SpikeCloud) -> SyncMaterializer {
        SyncMaterializer(database: db, paths: paths, accountID: accountID, vaultKey: key,
                         blobs: SpikeBlobs(blobs: cloud.blobs, directory: paths.root.appendingPathComponent("SpikeStaging")))
    }

    // MARK: capture -> seal (publisher side)

    /// Copy (c) of the entity-id rule inside `SyncQueue.prepareNext` (lines 168-184).
    func entityID(_ type: SyncEntityType, localID: String, in db: Database) throws -> String {
        if let prior = try String.fetchOne(db, sql: "SELECT entityId FROM sync_entity_state WHERE entityType=? AND localId=?",
                                           arguments: [type.rawValue, localID]) { return prior }
        let id: String
        if type == .note || type == .attachment { id = localID } else {
            let semantic = type == .tagPreference
                ? (try String.fetchOne(db, sql: "SELECT pathKey FROM tag WHERE id=?", arguments: [localID]) ?? localID) : localID
            let input = Data("baerchen-semantic-id:1:\(type.rawValue):\(semantic)".utf8)
            id = "m-" + HMAC<SHA256>.authenticationCode(for: input, using: key).map { String(format: "%02x", $0) }.joined()
        }
        try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES(?,?,?)", arguments: [type.rawValue, localID, id])
        return id
    }

    /// CK-R17 framing: kind byte, then the unchanged payload JSON or a deletion stamp.
    func seal(_ payload: Data?, type: SyncEntityType, entityId: String) throws -> Data {
        let plaintext = payload.map { Data([0x01]) + $0 } ?? (Data([0x02]) + Data("{\"at\":1793188800000}".utf8))
        return try NoteCipher.seal(plaintext, vaultKey: key,
                                   context: SyncWire.cipherContext(accountID: accountID, type: type, entityID: entityId))
    }

    /// Publishes every dirty entity; returns the record names whose save was stale.
    @discardableResult
    func publish(to cloud: SpikeCloud) async throws -> [String] {
        _ = try await SyncAttachmentPreparer(database: db, paths: paths, accountID: accountID, vaultKey: key).preparePending(limit: 1000)
        return try publishPrepared(to: cloud)
    }

    func publishPrepared(to cloud: SpikeCloud) throws -> [String] {
        let rows = try db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM sync_dirty ORDER BY CASE entityType WHEN 'keyBundle' THEN 0 WHEN 'attachment' THEN 1 ELSE 2 END,entityType,localId
                """).map { ($0["entityType"] as String, $0["localId"] as String) }
        }
        var stale: [String] = []
        for (rawType, localID) in rows {
            guard let type = SyncEntityType(rawValue: rawType) else { throw SyncProtocolError.unsupportedVersion }
            let prepared: (record: SpikeRecord, generation: Int64, baseVer: Int64)? = try db.pool.write { db in
                guard let current = try Row.fetchOne(db, sql: "SELECT * FROM sync_dirty WHERE entityType=? AND localId=?",
                                                     arguments: [type.rawValue, localID]) else { return nil }
                let dirty = SyncDirty(type: type, localID: localID, generation: current["generation"], tombstone: current["tombstone"])
                let content: SyncContent
                do {
                    if dirty.tombstone { content = SyncContent(payload: nil) }
                    else {
                        switch type {   // the reused capture functions, called as they are (a)
                        case .attachment: content = try SyncAttachmentPreparer.capture(dirty, accountID: accountID, vaultKey: key, in: db)
                        case .note: content = try SyncNoteSnapshot.capture(dirty, accountID: accountID, vaultKey: key, in: db)
                        default: content = try SyncPayloadCodec.capture(dirty, in: db)
                        }
                    }
                } catch SyncQueueError.snapshotUnavailable { return nil }
                let id = try entityID(type, localID: localID, in: db)
                let base = pairs[SpikeRecord.name(type, id)]
                let record = SpikeRecord(entityType: type, entityId: id, ver: (base?.ver ?? 0) + 1, sid: UUIDv7.make(),
                                         sealed: try seal(content.payload, type: type, entityId: id), blobRefs: content.blobRefs)
                return (record, dirty.generation, base?.ver ?? 0)
            }
            guard let prepared else { continue }
            for hash in prepared.record.blobRefs where cloud.blobs[hash] == nil {
                let stored = try db.pool.read { db -> (String?, Int64)? in
                    try Row.fetchOne(db, sql: "SELECT localPath,byteSize FROM sync_blob_state WHERE hash=?", arguments: [hash])
                        .map { ($0["localPath"], $0["byteSize"]) }
                }
                guard let stored, let path = stored.0 else { throw SyncQueueError.snapshotUnavailable }
                let file = try SyncBlobLocation.verified(path, paths: paths, hash: hash, size: stored.1)
                cloud.blobs[hash] = try Data(contentsOf: file.url)
            }
            switch cloud.save(prepared.record, baseVer: prepared.baseVer) {
            case .saved:
                // ck_record := (new tag, ancestor = sealed); clear dirty only for the generation covered (I3).
                pairs[prepared.record.name] = (prepared.record.ver, prepared.record.sealed)
                try db.pool.write { db in
                    try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType=? AND localId=? AND generation=?",
                                   arguments: [type.rawValue, localID, prepared.generation])
                }
            case .stale: stale.append(prepared.record.name)
            }
        }
        return stale
    }

    // MARK: open -> merge -> write (receiver side)

    /// Copy (c) of the decode-and-validate switch of `SyncPayloadReader.read`, fed from the
    /// sealed record instead of a `SyncEntity`, with the CK-R17 kind byte.
    func open(_ record: SpikeRecord) throws -> SyncRemoteValue { try open(record.sealed, record.entityType, record.entityId, record.blobRefs) }
    func open(_ sealed: Data, _ type: SyncEntityType, _ entityId: String, _ blobRefs: [String]) throws -> SyncRemoteValue {
        let context = try SyncWire.cipherContext(accountID: accountID, type: type, entityID: entityId)
        let plain = try NoteCipher.open(sealed, vaultKey: key, context: context)
        guard let kind = plain.first, plain.count <= 4_194_305 else { throw SyncProtocolError.invalidPayload }
        if kind == 0x02 { return .deleted }
        guard kind == 0x01 else { throw SyncProtocolError.unsupportedVersion }
        let body = Data(plain.dropFirst())
        switch type {
        case .note:
            let value = try SyncPayloadCodec.decode(SyncNotePayload.self, from: body)
            try value.validate()
            guard value.id == entityId,
                  (value.attachmentSnapshots ?? [:]).values.allSatisfy({ blobRefs.contains($0.blobHash) }) else { throw SyncProtocolError.invalidPayload }
            for tag in value.directTags + value.pinnedTags { _ = try NoteStore.tagToken(tag) }
            return .note(value)
        case .attachment:
            let value = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: body)
            try value.validate()
            guard value.id == entityId, blobRefs.contains(value.blobHash) else { throw SyncProtocolError.invalidPayload }
            return .attachment(value)
        case .tagPreference:
            let value = try SyncPayloadCodec.decode(SyncTagPreferencePayload.self, from: body)
            guard value.version == 1 else { throw SyncProtocolError.unsupportedVersion }
            _ = try NoteStore.tagToken(value.path)
            return .tag(value)
        case .setting:
            let value = try SyncPayloadCodec.decode(SyncSettingPayload.self, from: body)
            try value.validate()
            return .setting(value)
        case .externalRef:
            let value = try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: body)
            guard value.version == 1, !value.source.isEmpty, !value.externalId.isEmpty else { throw SyncProtocolError.invalidPayload }
            if let id = value.noteId { try SyncWire.validateID(id) }
            return .externalRef(value)
        case .keyBundle:
            let value = try SyncPayloadCodec.decode(SyncLockEnvelopePayload.self, from: body)
            _ = try JSONDecoder().decode(CryptoEnvelope.self, from: value.envelope)
            return .lockEnvelope(value.envelope)
        }
    }

    /// Applies every record newer than its pair, in dependency order, to a fixpoint.
    @discardableResult
    func pull(from cloud: SpikeCloud, noteAccess: LockedNoteAccess? = nil) async throws -> [String: SyncApplyResult] {
        var outcomes: [String: SyncApplyResult] = [:]
        var progressed = true
        while progressed {
            progressed = false
            let pending = cloud.records.values.filter { $0.ver > (pairs[$0.name]?.ver ?? 0) }.sorted {
                func rank(_ r: SpikeRecord) -> Int { r.entityType == .keyBundle ? 0 : r.entityType == .note ? 1 : 2 }
                return (rank($0), $0.name) < (rank($1), $1.name)
            }
            for record in pending where record.ver > (pairs[record.name]?.ver ?? 0) {
                let result = try await apply(record, cloud: cloud, noteAccess: noteAccess)
                outcomes[record.name] = result
                if result == .applied || result == .unchanged { progressed = true }
            }
        }
        return outcomes
    }

    func apply(_ record: SpikeRecord, cloud: SpikeCloud, noteAccess: LockedNoteAccess?) async throws -> SyncApplyResult {
        let value = try open(record)
        let base = try pairs[record.name].map { try open($0.sealed, record.entityType, record.entityId, record.blobRefs) }
        switch record.entityType {
        case .note: return try await applyNote(record, value: value, base: base, cloud: cloud, noteAccess: noteAccess)
        case .attachment: return try await applyAttachment(record, value: value, cloud: cloud)
        default:
            let result = try applyMetadata(record, value: value, materializer: materializer(cloud))
            if result == .applied { pairs[record.name] = (record.ver, record.sealed) }
            return result
        }
    }

    /// Copy (c) of `applyNote` + `commitNoteTransaction` with the shadow, inbox and outbox
    /// parts removed. Everything that touches the library is the reused code (a).
    func applyNote(_ record: SpikeRecord, value: SyncRemoteValue, base: SyncRemoteValue?, cloud: SpikeCloud,
                   noteAccess: LockedNoteAccess?) async throws -> SyncApplyResult {
        let remote: SyncNotePayload?
        switch value { case .note(let note): remote = note; case .deleted: remote = nil; default: throw SyncProtocolError.invalidPayload }
        var old: SyncNotePayload?
        switch base { case .note(let note): old = note; case nil, .deleted: old = nil; default: throw SyncProtocolError.invalidPayload }
        let hasPair = pairs[record.name] != nil
        if !hasPair, let seeded = seedBase[record.entityId] { old = seeded }   // CK-R13 option, characterization only
        let materializer = materializer(cloud)
        var downloads: [SyncMaterializer.DownloadedAttachment] = []
        var consumed: [SpikeRecord] = []
        for id in remote?.attachmentIds ?? [] {
            let entity = cloud.records[SpikeRecord.name(.attachment, id)]
            var selected: SyncAttachmentPayload?
            if let entity, case .attachment(let attachment) = try open(entity), attachment.noteId == record.entityId,
               attachment.isLocked == remote?.isLocked, remote?.attachmentNames?[id].map({ $0 == attachment.filename }) ?? true {
                selected = attachment; consumed.append(entity)
            }
            if selected == nil, let pinned = remote?.attachmentSnapshots?[id] { selected = pinned }
            guard let attachment = selected else {
                if entity == nil, remote?.attachmentNames?[id] != nil { continue }
                if let entity, case .deleted = try open(entity), remote?.attachmentNames?[id] != nil { continue }
                return .waitingForDependencies
            }
            downloads.append(.init(entity: nil, payload: attachment, cipher: try await materializer.preparedAttachmentCipher(attachment)))
        }
        let result = try commitNote(record, remote: remote, old: old, hasPair: hasPair, downloads: downloads,
                                    fromEntities: Set(consumed.map(\.entityId)), materializer: materializer, noteAccess: noteAccess)
        if result == .applied { for entity in consumed { pairs[entity.name] = (entity.ver, entity.sealed) } }
        return result
    }

    func commitNote(_ record: SpikeRecord, remote: SyncNotePayload?, old: SyncNotePayload?, hasPair: Bool,
                    downloads: [SyncMaterializer.DownloadedAttachment], fromEntities: Set<String>,
                    materializer: SyncMaterializer, noteAccess: LockedNoteAccess?) throws -> SyncApplyResult {
        let id = record.entityId
        let files = AttachmentFiles(paths: paths, database: db)
        var staged: [AttachmentFiles.Staged] = [], committed = false
        defer { if !committed { for batch in staged { files.discard(batch) } } }
        let result: SyncApplyResult
        do {
            result = try db.pool.write { db -> SyncApplyResult in
                guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") == accountID else { throw SyncQueueError.accountMismatch }
                let journal = paths.journal.appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: journal.path),
                   (try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 { return .waitingForDependencies }
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) OR EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)",
                                        arguments: [id, id]) == false else { return .waitingForDependencies }
                if remote?.isLocked == true, try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") == nil { return .waitingForUnlock }
                let local = try SyncNotePayload.capture(id: id, includeRetained: true, in: db)
                let dirty = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=?)", arguments: [id]) == true
                var merged: SyncNoteMergeResult
                var noteKey: SymmetricKey?
                if dirty || (!hasPair && local != nil) {
                    merged = try SyncNoteMerge.reconcile(base: old, local: local, remote: remote, entityID: id,
                                                         rejectedMutationID: record.sid, remoteRevision: record.ver)
                } else { merged = .merged(remote) }
                if case .needsUnlock = merged, let noteAccess {
                    let key = try noteAccess.journalKey()
                    merged = try SyncLockedNoteMerge.reconcile(base: old, local: local, remote: remote, entityID: id,
                                                               mutationID: record.sid, revision: record.ver, key: key)
                    noteKey = key
                }
                if case .needsUnlock = merged { return .waitingForUnlock }
                if case .merged(let note) = merged, let note, let local, local.isLocked != note.isLocked {
                    let ready = downloads.filter { note.attachmentIds.contains($0.payload.id) && $0.payload.isLocked == note.isLocked }
                    if ready.count < note.attachmentIds.count { return .waitingForDependencies }
                }
                for download in downloads {
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=?)",
                                         arguments: [download.payload.id]) == true { return .waitingForUpload }
                }
                try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                switch merged {
                case .merged(let note):
                    if let note {
                        let selected = downloads.filter { download in
                            note.attachmentIds.contains(download.payload.id) && download.payload.isLocked == note.isLocked &&
                                (note.attachmentNames == nil || note.attachmentNames?[download.payload.id] == download.payload.filename)
                        }
                        try materializer.writeNote(note, downloads: selected, copying: false, noteKey: noteKey, files: files, staged: &staged, in: db)
                        // writeNote reads `download.entity == nil` as "pinned snapshot: publish this file again".
                        // A file applied from its own cloud entity is not new local work.
                        for download in selected where fromEntities.contains(download.payload.id) {
                            try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [download.payload.id])
                        }
                    } else {
                        try db.execute(sql: "UPDATE note SET location='trash', trashedAt=?, revision=revision+1 WHERE id=? AND location!='trash'",
                                       arguments: [NoteStore.roundedToMillis(.now), id])
                    }
                    // The materializer compares with `!=`; attachment pins ([:] vs nil) then make a
                    // collapsed identical note dirty. The merge's own equality avoids that echo.
                    let differs = strictEcho ? note != remote : !SyncNoteMerge.identical(note, remote)
                    if differs { try SyncMaterializer.markNote(id, deleted: note == nil, in: db) }
                    else { try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [id]) }
                case .conflict(let mine, let copy):
                    if let mine { try SyncMaterializer.recordConflict(mine, in: db) }
                    if let copy, try Note.fetchOne(db, key: copy.id) == nil {
                        try materializer.writeNote(copy, downloads: downloads, copying: true, noteKey: noteKey, files: files, staged: &staged, in: db)
                        try SyncMaterializer.markNote(copy.id, deleted: false, in: db)
                    }
                    try SyncMaterializer.markNote(id, deleted: mine == nil, in: db)
                case .needsUnlock: preconditionFailure("handled above")
                }
                try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES('note',?,?) ON CONFLICT DO NOTHING", arguments: [id, id])
                try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
                return .applied
            }
        } catch SyncApplyError.waitingForCapture { return .waitingForDependencies }
        committed = true
        for batch in staged { files.install(batch) }
        if result == .applied {
            pairs[record.name] = (record.ver, record.sealed)
            try NotePrivacy(store: store).finishPendingCleanup()
        }
        return result
    }

    /// Copy (c) of the clean (not dirty) path of `commitAttachment`: a file changed without its note.
    func applyAttachment(_ record: SpikeRecord, value: SyncRemoteValue, cloud: SpikeCloud) async throws -> SyncApplyResult {
        guard case .attachment(let payload) = value else { return try commitAttachment(record, download: nil, materializer: materializer(cloud)) }
        let materializer = materializer(cloud)
        let download = SyncMaterializer.DownloadedAttachment(entity: nil, payload: payload, cipher: try await materializer.preparedAttachmentCipher(payload))
        return try commitAttachment(record, download: download, materializer: materializer)
    }

    func commitAttachment(_ record: SpikeRecord, download: SyncMaterializer.DownloadedAttachment?, materializer: SyncMaterializer) throws -> SyncApplyResult {
        guard let download else {
            try db.pool.write { db in
                try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                try db.execute(sql: "UPDATE attachment SET deletedAt=? WHERE id=? AND NOT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=?)",
                               arguments: [Date(), record.entityId, record.entityId])
                try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            }
            pairs[record.name] = (record.ver, record.sealed)
            return .applied
        }
        let payload = download.payload
        let files = AttachmentFiles(paths: paths, database: db)
        var staged: [AttachmentFiles.Staged] = [], committed = false
        defer { if !committed { for batch in staged { files.discard(batch) } } }
        let result = try db.pool.write { db -> SyncApplyResult in
            guard let note = try Note.fetchOne(db, key: payload.noteId), note.isLocked == payload.isLocked else { return .waitingForDependencies }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=?)", arguments: [payload.id]) == true {
                return .waitingForUpload   // the attachment conflict note of commitAttachment is Task 6's copy
            }
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            let batch = try files.stageTransformed([payload.filename], noteId: note.id) { _, output in
                try materializer.reader.writeAttachment(payload, cipher: download.cipher, to: output)
            }
            staged.append(batch)
            try AttachmentFiles.record(batch, in: db)
            try db.execute(sql: """
                INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt,uti,width,height,ocrText,ocrState,sha256,byteSize)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                  updatedAt=excluded.updatedAt,uti=excluded.uti,width=excluded.width,height=excluded.height,
                  ocrText=excluded.ocrText,ocrState=excluded.ocrState,deletedAt=NULL,
                  sha256=excluded.sha256,byteSize=excluded.byteSize,fileModifiedAt=NULL
                """, arguments: [payload.id, note.id, payload.filename, AttachmentFiles.fileSystemKey(payload.filename),
                                  SyncMaterializer.date(payload.createdAt), SyncMaterializer.date(payload.updatedAt), payload.uti, payload.width,
                                  payload.height, payload.ocrText, payload.isLocked ? "locked" : (payload.ocrText == nil ? "pending" : "done"),
                                  payload.isLocked ? nil : payload.fileHash, payload.isLocked ? nil : payload.fileBytes])
            try NoteIndexer.index(noteId: note.id, text: note.text, in: db)
            try materializer.cacheDownloadedAttachment(download, in: db)
            try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES('attachment',?,?) ON CONFLICT DO NOTHING", arguments: [payload.id, payload.id])
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            return .applied
        }
        committed = true
        for batch in staged { files.install(batch) }
        if result == .applied { pairs[record.name] = (record.ver, record.sealed) }
        return result
    }

    /// Copy (c) of the plain path of `applyMetadata`; `localID` and `writeMetadata` are reused (a).
    func applyMetadata(_ record: SpikeRecord, value: SyncRemoteValue, materializer: SyncMaterializer) throws -> SyncApplyResult {
        let type = record.entityType
        return try db.pool.write { db -> SyncApplyResult in
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") == accountID else { throw SyncQueueError.accountMismatch }
            let mapped = try String.fetchOne(db, sql: "SELECT localId FROM sync_entity_state WHERE entityType=? AND entityId=?",
                                             arguments: [type.rawValue, record.entityId])
            let localID = try SyncMaterializer.localID(value, mapped: mapped, in: db) ?? (type == .keyBundle ? "lock-vault" : nil)
            let dirty = try localID.map { try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType=? AND localId=?)",
                                                            arguments: [type.rawValue, $0]) == true } ?? false
            if case .lockEnvelope(let remote) = value,
               let local = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"), local != remote,
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == true { return .waitingForUnlock }
            var reconcileReference = false
            if case .externalRef(let ref) = value, let note = ref.noteId {
                guard try Note.fetchOne(db, key: note) != nil else { return .waitingForDependencies }
                if let existing = try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source=? AND externalId=?",
                                                      arguments: [ref.source, ref.externalId]), existing != note { reconcileReference = true }
            }
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            if reconcileReference, case .externalRef(let ref) = value, let localID {
                let resolved = try reconcileImport(ref, sid: record.sid, ver: record.ver, materializer: materializer, in: db)
                try SyncMaterializer.writeMetadata(.externalRef(resolved), type: type, localID: localID, in: db)
                if resolved == ref { try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='externalRef' AND localId=?", arguments: [localID]) }
                else {
                    try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('externalRef',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0", arguments: [localID])
                }
            } else if !dirty { try SyncMaterializer.writeMetadata(value, type: type, localID: localID, in: db) }
            if let localID {
                try db.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId) VALUES(?,?,?) ON CONFLICT DO NOTHING",
                               arguments: [type.rawValue, localID, record.entityId])
            }
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            return .applied
        }
    }

    /// Copy (c) of `SyncMaterializer.reconcileImport`: the original takes a `SyncEntity` only for
    /// its mutation id and revision; here they are the record's attempt id and version.
    /// `importedFilesMatch` is reused (b, widened to internal).
    func reconcileImport(_ remote: SyncExternalRefPayload, sid: String, ver: Int64, materializer: SyncMaterializer,
                         in db: Database) throws -> SyncExternalRefPayload {
        guard let remoteID = remote.noteId,
              let localID = try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source=? AND externalId=?", arguments: [remote.source, remote.externalId]), localID != remoteID,
              var local = try SyncNotePayload.capture(id: localID, in: db),
              let received = try SyncNotePayload.capture(id: remoteID, in: db) else { return remote }
        let enabled = try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true
        let journal = paths.journal.appendingPathComponent(localID + ".jsonl")
        let journalEmpty = try !FileManager.default.fileExists(atPath: journal.path) || (journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == 0
        let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: paths.journal.path)
            .contains { $0.hasPrefix(localID + ".") && $0.contains(".unreplayed") }
        // "Unpublished" in CloudKit terms: no base pair for the local note (the Cloudflare
        // original asks sync_entity_state and sync_outbox).
        let settled = try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) AND NOT EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)
            """, arguments: [localID, localID]) == true
        let unpublished = pairs[SpikeRecord.name(.note, localID)] == nil && settled
        var comparable = local
        comparable.id = remoteID; comparable.attachmentIds = received.attachmentIds
        comparable.attachmentNames = received.attachmentNames
        comparable.attachmentSnapshots = received.attachmentSnapshots
        let equal = !local.isLocked && !received.isLocked && comparable == received && TextNormalization.identical(comparable.text, received.text)
        if !enabled && unpublished && journalEmpty && !recoveryFiles && equal, try materializer.importedFilesMatch(localID, remoteID, in: db) {
            try db.execute(sql: "INSERT OR IGNORE INTO note_ui_state(noteId,foldState,selection,scrollTop) SELECT ?,foldState,selection,scrollTop FROM note_ui_state WHERE noteId=?", arguments: [remoteID, localID])
            try db.execute(sql: "UPDATE external_ref SET noteId=?,importedRevision=NULL WHERE noteId=?", arguments: [remoteID, localID])
            try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [localID])
            try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [localID])
            try db.execute(sql: "INSERT OR IGNORE INTO sync_import_cleanup(noteId) VALUES(?)", arguments: [localID])
            return remote   // (the backup_catalog bookkeeping of the original is part of Task 6's copy)
        }
        let canonical = enabled ? min(localID, remoteID) : remoteID
        local.conflict = SyncConflictInfo(originalNoteId: canonical == localID ? remoteID : canonical, rejectedMutationId: sid, remoteRevision: ver)
        try SyncMaterializer.recordConflict(local, in: db)
        try SyncMaterializer.markNote(localID, deleted: false, in: db)
        if canonical == remoteID { return remote }
        let localRef = try SyncPayloadCodec.capture(SyncDirty(type: .externalRef,
            localID: String.fetchOne(db, sql: "SELECT json_array(?,?)", arguments: [remote.source, remote.externalId])!, generation: 1, tombstone: false), in: db)
        guard let bytes = localRef.payload else { throw SyncProtocolError.invalidPayload }
        return try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: bytes)
    }

    // MARK: inspection

    func cloudflareTablesAreEmpty() throws -> Bool {
        try db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM sync_shadow)+(SELECT COUNT(*) FROM sync_inbox)+(SELECT COUNT(*) FROM sync_outbox)+(SELECT COUNT(*) FROM sync_receipt)") == 0
        }
    }
    func dirtyCount() throws -> Int { try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") ?? 0 } }
    func notes() throws -> [Note] { try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY id") } }
    func payload(_ id: String) throws -> SyncNotePayload? { try db.pool.read { try SyncNotePayload.capture(id: id, includeRetained: true, in: $0) } }
    func setting(_ key: String) throws -> String? { try text("SELECT value FROM setting WHERE key=?", [key]) }
    func text(_ sql: String, _ arguments: StatementArguments = []) throws -> String? {
        try db.pool.read { try String.fetchOne($0, sql: sql, arguments: arguments) }
    }
    func execute(_ sql: String, _ arguments: StatementArguments = []) throws {
        try db.pool.write { try $0.execute(sql: sql, arguments: arguments) }
    }
}

/// Two devices that publish and pull until nothing is dirty and the cloud is fully applied.
func spikeConverge(_ devices: [SpikeDevice], _ cloud: SpikeCloud, access: [LockedNoteAccess?] = [], rounds: Int = 6) async throws {
    for _ in 0..<rounds {
        for (index, device) in devices.enumerated() {
            let noteAccess = index < access.count ? access[index] : nil
            try await device.pull(from: cloud, noteAccess: noteAccess)
            try await device.publish(to: cloud)
            try await device.pull(from: cloud, noteAccess: noteAccess)
        }
    }
}

@Suite struct ExtractionSpikeTests {
    let key = SymmetricKey(size: .bits256)

    func pair(seed: Bool = false) throws -> (SpikeDevice, SpikeDevice, SpikeCloud) {
        (try SpikeDevice("a", key: key, seed: seed), try SpikeDevice("b", key: key, seed: seed), SpikeCloud())
    }

    @Test func notesTagsSettingsAndExternalReferencesRoundTripWithoutTheCloudflareTables() async throws {
        let (a, b, cloud) = try pair(); defer { a.cleanup(); b.cleanup() }
        try a.configure(); try a.enable(); try b.configure(); try b.enable()
        let note = try a.store.create(text: "# Groceries\nmilk e\u{301}\r\n#home/kitchen\n")
        try a.execute("UPDATE tag SET iconName='star', isPinned=1, sortIndex=3 WHERE pathKey=?", [CanonicalKey.make("home/kitchen")])
        try a.execute("INSERT INTO setting(key,value) VALUES('hideMarkdown','false') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        try a.execute("INSERT INTO external_ref(source,externalId,noteId,lastSeenHash) VALUES('bear','EXT-1',?, 'abc')", [note.id])
        try await a.publish(to: cloud)
        #expect(Set(cloud.records.values.map(\.entityType)) == [.note, .tagPreference, .setting, .externalRef])
        let outcomes = try await b.pull(from: cloud)
        #expect(outcomes.values.allSatisfy { $0 == .applied })
        #expect(try b.store.note(id: note.id).map { Data($0.text.utf8) } == Data(note.text.utf8))
        #expect(try b.payload(note.id) == a.payload(note.id))
        #expect(try b.text("SELECT iconName || ':' || isPinned || ':' || sortIndex FROM tag WHERE pathKey=?", [CanonicalKey.make("home/kitchen")]) == "star:1:3")
        #expect(try b.setting("hideMarkdown") == "false")
        #expect(try b.text("SELECT noteId FROM external_ref WHERE source='bear' AND externalId='EXT-1'") == note.id)
        // Nothing echoes back: applying does not mark the received entities dirty.
        #expect(try b.dirtyCount() == 0)
        #expect(try await b.publish(to: cloud).isEmpty && cloud.saves == cloud.records.count)
        // Edits and a deletion travel back the other way.
        let current = try #require(try b.store.note(id: note.id))
        _ = try b.store.updateText(id: note.id, text: "# Groceries\nmilk and bread\n#home/kitchen\n", expectedRevision: current.revision)
        try Settings(db: b.db).set(.hideMarkdown, to: true)
        try b.execute("DELETE FROM external_ref WHERE source='bear'")
        try await b.publish(to: cloud)
        try await a.pull(from: cloud)
        #expect(try a.store.note(id: note.id)?.text == "# Groceries\nmilk and bread\n#home/kitchen\n")
        #expect(try a.setting("hideMarkdown") == "true")
        #expect(try a.text("SELECT COUNT(*) FROM external_ref") == "0")
        #expect(try a.dirtyCount() == 0 && b.dirtyCount() == 0)
        #expect(try a.cloudflareTablesAreEmpty() && b.cloudflareTablesAreEmpty())
    }

    @Test func anAttachmentTravelsAsAnEntityAndABlobAndArrivesByteIdentical() async throws {
        let (a, b, cloud) = try pair(); defer { a.cleanup(); b.cleanup() }
        try a.configure(); try a.enable(); try b.configure(); try b.enable()
        let note = try a.store.create(text: "# Scan\n![Receipt](receipt.png)\n")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "receipt.png", to: note.id)
        try await a.publish(to: cloud)
        let attachmentRecord = try #require(cloud.records.values.first { $0.entityType == .attachment })
        #expect(attachmentRecord.blobRefs.count == 1 && cloud.blobs[attachmentRecord.blobRefs[0]] != nil)
        // The blob is ciphertext: the file bytes are not in it.
        #expect(cloud.blobs.values.allSatisfy { $0.range(of: bytes.prefix(64)) == nil })
        let outcomes = try await b.pull(from: cloud)
        #expect(outcomes.values.allSatisfy { $0 == .applied })
        let file = AttachmentFiles(paths: b.paths, database: b.db).directory(for: note.id).appendingPathComponent("receipt.png")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try b.payload(note.id)?.attachmentIds == a.payload(note.id)?.attachmentIds)
        #expect(try b.dirtyCount() == 0)
        #expect(try await b.publish(to: cloud).isEmpty)
        // A second device that prepares a note snapshot later can pin the received file (cache reuse).
        let current = try #require(try b.store.note(id: note.id))
        _ = try b.store.updateText(id: note.id, text: "# Scan\n![Receipt](receipt.png)\nPaid.\n", expectedRevision: current.revision)
        try await b.publish(to: cloud)
        try await a.pull(from: cloud)
        #expect(try a.store.note(id: note.id)?.text.hasSuffix("Paid.\n") == true)
        #expect(try a.dirtyCount() == 0 && b.dirtyCount() == 0)
        #expect(try a.cloudflareTablesAreEmpty() && b.cloudflareTablesAreEmpty())
    }

    @Test func theLockEnvelopeAndALockedNoteArriveAndOpenWithThePassword() async throws {
        let (a, b, cloud) = try pair(); defer { a.cleanup(); b.cleanup() }
        try a.configure(); try a.enable(); try b.configure(); try b.enable()
        let access = try NotePrivacy(store: a.store).setPassword("correct horse"); defer { access.revoke() }
        let note = try a.store.create(text: "# Secret\nthe code is 4711\n")
        try access.lock(noteId: note.id)
        try await a.publish(to: cloud)
        #expect(cloud.records[SpikeRecord.name(.note, note.id)] != nil)
        #expect(cloud.records.values.contains { $0.entityType == .keyBundle })
        // Neither the outer seal nor the note record shows the body.
        #expect(cloud.records.values.allSatisfy { $0.sealed.range(of: Data("4711".utf8)) == nil })
        let outcomes = try await b.pull(from: cloud)
        #expect(outcomes.values.allSatisfy { $0 == .applied })
        #expect(try b.store.note(id: note.id)?.isLocked == true)
        let opened = try NotePrivacy(store: b.store).unlock(password: "correct horse"); defer { opened.revoke() }
        #expect(try opened.note(id: note.id)?.text == "# Secret\nthe code is 4711\n")
        #expect(try b.dirtyCount() == 0)
        // Concurrent edits of different lines of the locked note merge through SyncLockedNoteMerge.
        let mineBefore = try #require(try access.note(id: note.id))
        _ = try access.updateText(id: note.id, text: "# Secret\nthe code is 4711\nfrom A\n", expectedRevision: mineBefore.revision)
        let theirsBefore = try #require(try opened.note(id: note.id))
        _ = try opened.updateText(id: note.id, text: "# Secret B\nthe code is 4711\n", expectedRevision: theirsBefore.revision)
        try await a.publish(to: cloud)
        #expect(try await b.publish(to: cloud) == [SpikeRecord.name(.note, note.id)])
        #expect(try await b.pull(from: cloud)[SpikeRecord.name(.note, note.id)] == .waitingForUnlock)
        #expect(try await b.pull(from: cloud, noteAccess: opened)[SpikeRecord.name(.note, note.id)] == .applied)
        try await spikeConverge([a, b], cloud, access: [access, opened])
        #expect(try opened.note(id: note.id)?.text == "# Secret B\nthe code is 4711\nfrom A\n")
        #expect(try access.note(id: note.id)?.text == "# Secret B\nthe code is 4711\nfrom A\n")
        #expect(try a.dirtyCount() == 0 && b.dirtyCount() == 0)
        #expect(try a.cloudflareTablesAreEmpty() && b.cloudflareTablesAreEmpty())
    }

    @Test func concurrentEditsOfTheSameLineMakeTheExistingDeterministicConflictCopy() async throws {
        let (a, b, cloud) = try pair(); defer { a.cleanup(); b.cleanup() }
        try a.configure(); try a.enable(); try b.configure(); try b.enable()
        let note = try a.store.create(text: "# Plan\nmeet at 9\n")
        try await a.publish(to: cloud); try await b.pull(from: cloud)
        let mine = try #require(try a.store.note(id: note.id)), theirs = try #require(try b.store.note(id: note.id))
        _ = try a.store.updateText(id: note.id, text: "# Plan\nmeet at 10\n", expectedRevision: mine.revision)
        _ = try b.store.updateText(id: note.id, text: "# Plan\nmeet at 11\n", expectedRevision: theirs.revision)
        try await a.publish(to: cloud)
        let winner = try #require(cloud.records[SpikeRecord.name(.note, note.id)])
        // B's save is stale (serverRecordChanged); B merges the server version and keeps its own text.
        #expect(try await b.publish(to: cloud) == [SpikeRecord.name(.note, note.id)])
        #expect(try await b.pull(from: cloud)[SpikeRecord.name(.note, note.id)] == .applied)
        let copyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: winner.sid, remoteRevision: winner.ver)
        #expect(try b.store.note(id: note.id)?.text == "# Plan\nmeet at 11\n")
        #expect(try b.store.note(id: copyID)?.text == "# Plan\nmeet at 10\n")
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            #expect(try device.store.note(id: note.id)?.text == "# Plan\nmeet at 11\n")
            #expect(try device.store.note(id: copyID)?.text == "# Plan\nmeet at 10\n")
            #expect(try device.payload(copyID)?.conflict?.originalNoteId == note.id)
            #expect(try device.notes().count == 2 && device.dirtyCount() == 0)
        }
        // Disjoint edits merge without a copy.
        let a2 = try #require(try a.store.note(id: note.id)), b2 = try #require(try b.store.note(id: note.id))
        _ = try a.store.updateText(id: note.id, text: "# Plan A\nmeet at 11\n", expectedRevision: a2.revision)
        _ = try b.store.updateText(id: note.id, text: "# Plan\nmeet at 11\nbring tea\n", expectedRevision: b2.revision)
        try await spikeConverge([a, b], cloud)
        #expect(try a.store.note(id: note.id)?.text == "# Plan A\nmeet at 11\nbring tea\n")
        #expect(try b.store.note(id: note.id)?.text == "# Plan A\nmeet at 11\nbring tea\n")
        #expect(try a.notes().count == 2 && b.notes().count == 2)
        #expect(try a.cloudflareTablesAreEmpty() && b.cloudflareTablesAreEmpty())
    }

    @Test func twoIndependentImportsOfTheSameExternalNoteCollapseThroughTheReference() async throws {
        let (a, b, cloud) = try pair(); defer { a.cleanup(); b.cleanup() }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try a.configure(); try a.enable()
        let imported = try a.store.create(text: "# Imported\nsame body\n", now: stamp)
        try a.execute("INSERT INTO external_ref(source,externalId,noteId) VALUES('bear','EXT-9',?)", [imported.id])
        try await a.publish(to: cloud)
        // B imported the same source note before it enabled sync: another local id, same content.
        let duplicate = try b.store.create(text: "# Imported\nsame body\n", now: stamp)
        try b.execute("INSERT INTO external_ref(source,externalId,noteId) VALUES('bear','EXT-9',?)", [duplicate.id])
        try b.configure()
        let outcomes = try await b.pull(from: cloud)
        #expect(outcomes.values.allSatisfy { $0 == .applied })
        #expect(try b.store.note(id: duplicate.id) == nil)
        #expect(try b.text("SELECT noteId FROM external_ref WHERE source='bear' AND externalId='EXT-9'") == imported.id)
        #expect(try b.notes().map(\.id) == [imported.id])
        #expect(try b.cloudflareTablesAreEmpty())
    }
}

/// CK-R13 characterization: never-synced entities with the same id on two devices, with the
/// real `GettingStartedNotes`. "Today" tests pin what the existing rules do (the nil-base rule of
/// `SyncNoteMerge`, the materializer's `!=` echo check, `SyncQueue.enable` marking every row);
/// "proposed" tests show the CloudSync-side options the decision record names for Task 10.
@Suite struct ExtractionSpikeFirstContactTests {
    let key = SymmetricKey(size: .bits256)
    let welcome = GettingStartedNotes.ids[0]

    /// A seeds, enables and publishes; B seeds and configures (download first, as Task 10 orders it).
    func seeded(useSeedBase: Bool = false, strictEcho: Bool = false, beforeA: (SpikeDevice) throws -> Void = { _ in },
                beforeB: (SpikeDevice) throws -> Void = { _ in }) async throws -> (SpikeDevice, SpikeDevice, SpikeCloud) {
        let a = try SpikeDevice("a", key: key, seed: true), b = try SpikeDevice("b", key: key, seed: true), cloud = SpikeCloud()
        a.strictEcho = strictEcho; b.strictEcho = strictEcho
        if useSeedBase {
            // The payload this build ships for each fixed id, captured from a fresh seeded library.
            let reference = try SpikeDevice("seed", key: key, seed: true); defer { reference.cleanup() }
            for id in GettingStartedNotes.ids { b.seedBase[id] = try reference.payload(id); a.seedBase[id] = try reference.payload(id) }
        }
        try beforeA(a); try a.configure(); try a.enable()
        try await a.publish(to: cloud)
        try beforeB(b); try b.configure()
        return (a, b, cloud)
    }
    func edit(_ device: SpikeDevice, _ id: String, _ text: (String) -> String) throws {
        let note = try #require(try device.store.note(id: id))
        _ = try device.store.updateText(id: id, text: text(note.text), expectedRevision: note.revision)
    }
    func copies(_ device: SpikeDevice) throws -> [Note] { try device.notes().filter { !GettingStartedNotes.ids.contains($0.id) } }

    @Test func todayIdenticalUntouchedCopiesCollapseButEveryEntityIsRepublishedOnce() async throws {
        let (a, b, cloud) = try await seeded(strictEcho: true); defer { a.cleanup(); b.cleanup() }
        #expect(cloud.records.count == 16)   // twelve notes and the tag preferences of "getting started", "ref", "idea" and "log"
        let outcomes = try await b.pull(from: cloud)
        #expect(outcomes.count == 16)
        #expect(outcomes.values.allSatisfy { $0 == .applied })
        let notesAfterPull = try b.notes().count, dirtyAfterPull = try b.dirtyCount()
        #expect(notesAfterPull == 12)
        #expect(dirtyAfterPull == 12)   // `note != remote`: the pins differ ([:] vs nil), the content does not
        try b.enable()
        let dirtyAfterEnable = try b.dirtyCount()
        #expect(dirtyAfterEnable == 16)
        let before = cloud.saves
        try await b.publish(to: cloud)
        #expect(cloud.saves - before == 16)   // content-identical republish of everything
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            let titles = try device.notes().map(\.title)
            #expect(titles.count == 12 && Set(titles).count == 12)
        }
    }

    @Test func proposedIdenticalUntouchedCopiesCollapseWithNothingToRepublish() async throws {
        let (a, b, cloud) = try await seeded(); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud)
        let dirtyAfterPull = try b.dirtyCount()
        #expect(dirtyAfterPull == 0)
        try b.enableKeepingAppliedEntitiesClean()
        let dirtyAfterEnable = try b.dirtyCount()
        #expect(dirtyAfterEnable == 0)
        let before = cloud.saves
        try await spikeConverge([a, b], cloud)
        #expect(cloud.saves == before)
        #expect(try a.notes().count == 12 && b.notes().count == 12)
    }

    @Test func oneEditedOneUntouchedMakesAConflictCopyWithTheNilBaseRule() async throws {
        let (a, b, cloud) = try await seeded(beforeA: { try edit($0, welcome) { $0 + "\nMy own line.\n" } }); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            let extra = try copies(device)
            #expect(extra.count == 1)
            #expect(try device.payload(extra[0].id)?.conflict?.originalNoteId == welcome)
            // Nothing lost: the edited text exists (B kept its untouched text at the id).
            #expect(try device.notes().contains { $0.text.hasSuffix("My own line.\n") })
            #expect(try device.store.note(id: welcome)?.text.hasSuffix("My own line.\n") == false)
        }
    }

    @Test func proposedOneEditedOneUntouchedWithTheShippedTextAsBaseMergesCleanly() async throws {
        let (a, b, cloud) = try await seeded(useSeedBase: true, beforeA: { try edit($0, welcome) { $0 + "\nMy own line.\n" } })
        defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            #expect(try copies(device).isEmpty)
            #expect(try device.store.note(id: welcome)?.text.hasSuffix("My own line.\n") == true)
        }
    }

    @Test func bothEditedDifferentlyKeepTheLocalVersionAndOneCopy() async throws {
        let (a, b, cloud) = try await seeded(beforeA: { try edit($0, welcome) { _ in "# Welcome from A\n" } },
                                             beforeB: { try edit($0, welcome) { _ in "# Welcome from B\n" } })
        defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud)
        #expect(try b.store.note(id: welcome)?.text == "# Welcome from B\n")
        try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        try await spikeConverge([a, b], cloud, rounds: 5)   // stable: no further copy
        for device in [a, b] {
            let texts = try device.notes().map(\.text)
            #expect(texts.contains("# Welcome from A\n") && texts.contains("# Welcome from B\n"))
            #expect(try copies(device).count == 1)
            #expect(try device.store.note(id: welcome)?.text == "# Welcome from B\n")
        }
    }

    @Test func todayOneTrashedOneUntouchedKeepsTheNoteAndPutsTheTrashedVersionInACopy() async throws {
        let (a, b, cloud) = try await seeded(beforeA: { try $0.store.trash([welcome]) }); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            #expect(try device.store.note(id: welcome)?.location == .notes)
            let extra = try copies(device)
            #expect(extra.count == 1)
            #expect(extra.first?.location == .trash)
        }
    }

    @Test func proposedOneTrashedOneUntouchedWithTheShippedTextAsBaseStaysTrashed() async throws {
        let (a, b, cloud) = try await seeded(useSeedBase: true, beforeA: { try $0.store.trash([welcome]) }); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            #expect(try device.store.note(id: welcome)?.location == .trash)
            #expect(try copies(device).isEmpty)
        }
    }

    @Test func todayOneHardDeletedAfterPublishingComesBackOnBothDevices() async throws {
        let (a, b, cloud) = try await seeded(); defer { a.cleanup(); b.cleanup() }
        try a.store.deletePermanently([welcome])
        try await a.publish(to: cloud)
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        // reconcile(base: nil, local: untouched, remote: deleted) keeps local: the deletion is undone.
        #expect(try a.store.note(id: welcome)?.location == .notes)
        #expect(try b.store.note(id: welcome)?.location == .notes)
    }

    @Test func todayHardDeletedWithTheShippedBaseButPlainEnableReturnsToTheDeletersTrash() async throws {
        let (a, b, cloud) = try await seeded(useSeedBase: true); defer { a.cleanup(); b.cleanup() }
        try a.store.deletePermanently([welcome])
        try await a.publish(to: cloud)
        try await b.pull(from: cloud)
        #expect(try b.store.note(id: welcome)?.location == .trash)
        try b.enable()   // marks the trashed copy dirty: the "not echoed" recovery copy is published
        try await spikeConverge([a, b], cloud)
        #expect(try a.store.note(id: welcome)?.location == .trash)
        #expect(try b.store.note(id: welcome)?.location == .trash)
    }

    @Test func proposedHardDeletedWithTheShippedBaseStaysDeletedAndTheOtherKeepsItInTrash() async throws {
        let (a, b, cloud) = try await seeded(useSeedBase: true); defer { a.cleanup(); b.cleanup() }
        try a.store.deletePermanently([welcome])
        try await a.publish(to: cloud)
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        #expect(try a.store.note(id: welcome) == nil)
        #expect(try b.store.note(id: welcome)?.location == .trash)
    }

    @Test func deletedOnAThenRestoreMissingOnBRestoreWins() async throws {
        let (a, b, cloud) = try await seeded(); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        try a.store.deletePermanently([welcome])
        try await spikeConverge([a, b], cloud)
        #expect(try a.store.note(id: welcome) == nil)
        #expect(try b.store.note(id: welcome)?.location == .trash)
        let restored = try GettingStartedNotes.restoreMissing(in: b.store)
        #expect(restored.movedBackFromTrash == [welcome])
        try await spikeConverge([a, b], cloud)
        for device in [a, b] { #expect(try device.store.note(id: welcome)?.location == .notes) }
        #expect(try a.store.note(id: welcome)?.text == b.store.note(id: welcome)?.text)
        // B purges it and, before anyone syncs, restores it from nothing: same id and stamps on
        // top of its own tombstone.
        try b.store.deletePermanently([welcome]); try await b.publish(to: cloud)
        #expect(try GettingStartedNotes.restoreMissing(in: b.store).added == [welcome])
        try await spikeConverge([a, b], cloud, rounds: 5)
        for device in [a, b] { #expect(try device.store.note(id: welcome)?.location == .notes) }
        #expect(try a.notes().count == 12 && b.notes().count == 12)
    }

    /// A later app version: different text, same id and stamps (REL-R74).
    func laterVersion(_ b: SpikeDevice) throws {
        try b.execute("UPDATE note SET text = text || ? WHERE id=?", ["\nNew in version 2.\n", welcome])
    }

    @Test func todayALaterVersionTextForTheSameIdMakesOneConflictCopyOnce() async throws {
        let (a, b, cloud) = try await seeded(beforeB: laterVersion); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        try await spikeConverge([a, b], cloud, rounds: 5)
        for device in [a, b] {
            #expect(try copies(device).count == 1)
            #expect(try device.notes().contains { $0.text.hasSuffix("New in version 2.\n") })
        }
    }

    @Test func proposedALaterVersionTextWithTheFirstSetAsBaseWinsWithoutACopy() async throws {
        let (a, b, cloud) = try await seeded(useSeedBase: true, beforeB: laterVersion); defer { a.cleanup(); b.cleanup() }
        try await b.pull(from: cloud); try b.enableKeepingAppliedEntitiesClean()
        try await spikeConverge([a, b], cloud)
        for device in [a, b] {
            #expect(try copies(device).isEmpty)
            #expect(try device.store.note(id: welcome)?.text.hasSuffix("New in version 2.\n") == true)
        }
    }
}
