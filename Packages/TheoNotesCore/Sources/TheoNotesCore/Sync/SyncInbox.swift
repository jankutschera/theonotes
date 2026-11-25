// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public enum SyncInboxError: Error, Equatable { case cursorChanged, invalidPage, sequenceCollision }

/// Received ciphertext and the download cursor commit together. Acknowledging this cursor is
/// safe even when note-password authentication or missing attachment downloads defer applying
/// a record: the encrypted inbox survives restart and is never cleared by backup restoration.
public struct SyncInbox: Sendable {
    let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func cursor() throws -> Int64 {
        try database.pool.read { try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_cursor WHERE id=1") ?? 0 }
    }

    public func persist(_ page: SyncPullResult, requestedAfter: Int64) throws {
        guard requestedAfter >= 0, page.cursor >= requestedAfter, page.cursor <= SyncWire.maximumRevision,
              page.changes.count <= 500, !page.hasMore || !page.changes.isEmpty else { throw SyncInboxError.invalidPage }
        var previous = requestedAfter
        var encoded: [(SyncEntity, Data)] = []
        for entity in page.changes {
            let data = try JSONEncoder().encode(entity)
            // The public memberwise initializer is useful in tests; decoding enforces the same
            // wire constraints for those instances as for network responses.
            _ = try JSONDecoder().decode(SyncEntity.self, from: data)
            guard entity.sequence > previous, entity.sequence <= page.cursor else { throw SyncInboxError.invalidPage }
            previous = entity.sequence
            encoded.append((entity, data))
        }
        guard previous == page.cursor else { throw SyncInboxError.invalidPage }
        try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") != nil else { throw SyncQueueError.notEnabled }
            guard try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_cursor WHERE id=1") == requestedAfter else { throw SyncInboxError.cursorChanged }
            for (entity, data) in encoded {
                if let prior = try Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_inbox WHERE sequence=?", arguments: [entity.sequence]) {
                    guard try JSONDecoder().decode(SyncEntity.self, from: prior) == entity else { throw SyncInboxError.sequenceCollision }
                } else {
                    try db.execute(sql: "INSERT INTO sync_inbox(sequence,entityType,entityId,serverRevision,wireEntity) VALUES(?,?,?,?,?)",
                                   arguments: [entity.sequence, entity.mutation.entityType.rawValue, entity.mutation.entityId, entity.revision, data])
                }
            }
            try db.execute(sql: "UPDATE sync_cursor SET sequence=? WHERE id=1", arguments: [page.cursor])
        }
    }

    public func pending(limit: Int = 500, includingLocked: Bool = true) throws -> [SyncEntity] {
        try database.pool.read { db in
            try Data.fetchAll(db, sql: "SELECT wireEntity FROM sync_inbox WHERE (? OR waitingForUnlock=0) ORDER BY sequence LIMIT ?",
                              arguments: [includingLocked, max(1, min(limit, 500))]).map { try JSONDecoder().decode(SyncEntity.self, from: $0) }
        }
    }

    public func waitingForUnlockCount() throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_inbox WHERE waitingForUnlock=1") ?? 0 }
    }

    /// A CAS rejection may reveal a revision ahead of the pull cursor. Keep it durably without
    /// advancing that cursor; the later ordered pull will verify the same immutable record.
    func retainConflict(_ entity: SyncEntity) throws {
        let wire = try JSONEncoder().encode(entity)
        _ = try JSONDecoder().decode(SyncEntity.self, from: wire)
        try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") != nil else { throw SyncQueueError.notEnabled }
            if let prior = try Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_inbox WHERE sequence=?", arguments: [entity.sequence]) {
                guard try JSONDecoder().decode(SyncEntity.self, from: prior) == entity else { throw SyncInboxError.sequenceCollision }
            } else {
                try db.execute(sql: "INSERT INTO sync_inbox(sequence,entityType,entityId,serverRevision,wireEntity) VALUES(?,?,?,?,?)",
                               arguments: [entity.sequence, entity.mutation.entityType.rawValue, entity.mutation.entityId, entity.revision, wire])
            }
        }
    }

    func waitForUnlock(_ entity: SyncEntity) throws {
        try database.pool.write { db in
            guard let wire = try Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_inbox WHERE sequence=?", arguments: [entity.sequence]),
                  try JSONDecoder().decode(SyncEntity.self, from: wire) == entity else { throw SyncInboxError.sequenceCollision }
            try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
        }
    }
}
