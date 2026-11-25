// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import GRDB

/// Frozen schema for v8-sync. Future changes need a new migration, not changes here.
enum SyncSchemaV1 {
    static func install(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE sync_control (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                enabled BOOLEAN NOT NULL DEFAULT 0,
                applying BOOLEAN NOT NULL DEFAULT 0,
                accountId TEXT
            );
            INSERT INTO sync_control(id) VALUES(1);
            CREATE TABLE sync_dirty (
                entityType TEXT NOT NULL, localId TEXT NOT NULL,
                generation INTEGER NOT NULL DEFAULT 1, tombstone BOOLEAN NOT NULL DEFAULT 0,
                PRIMARY KEY(entityType, localId)
            );
            CREATE TABLE sync_entity_state (
                entityType TEXT NOT NULL, localId TEXT NOT NULL, entityId TEXT NOT NULL,
                serverRevision INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(entityType, localId), UNIQUE(entityType, entityId)
            );
            CREATE TABLE sync_outbox (
                ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                mutationId TEXT NOT NULL UNIQUE, entityType TEXT NOT NULL, localId TEXT NOT NULL,
                generation INTEGER NOT NULL, wireMutation BLOB NOT NULL,
                UNIQUE(entityType, localId)
            );
            CREATE TABLE sync_shadow (
                entityType TEXT NOT NULL, entityId TEXT NOT NULL,
                serverRevision INTEGER NOT NULL, sequence INTEGER NOT NULL, wireEntity BLOB NOT NULL,
                PRIMARY KEY(entityType, entityId)
            );
            CREATE TABLE sync_cursor (
                id INTEGER PRIMARY KEY CHECK(id = 1), sequence INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO sync_cursor(id) VALUES(1);
            CREATE TABLE sync_device (
                id INTEGER PRIMARY KEY CHECK(id = 1), deviceId TEXT NOT NULL, accountId TEXT NOT NULL,
                endpoint TEXT NOT NULL, envelope BLOB NOT NULL, wrappedMasterKey TEXT NOT NULL
            );
            CREATE TABLE sync_blob_state (
                hash TEXT PRIMARY KEY, data BLOB, localPath TEXT,
                byteSize INTEGER NOT NULL, uploaded BOOLEAN NOT NULL DEFAULT 0,
                multipartId TEXT, completedParts TEXT,
                CHECK((data IS NULL) != (localPath IS NULL))
            );
            """)
        // SQLite triggers capture ALL semantic writes, including CLI, imports, OCR, password
        // operations and Settings. An observer after commit could lose a change on a crash.
        let active = "(SELECT enabled = 1 AND applying = 0 FROM sync_control WHERE id = 1)"
        func mark(_ type: String, _ localID: String, deleted: Bool = false) -> String {
            """
            INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('\(type)',\(localID),1,\(deleted ? 1 : 0))
            ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
            """
        }
        func triggers(_ table: String, type: String, localID: String, updateColumns: String? = nil,
                      extra: String = "1", updateWhen: String = "1") throws {
            for (operation, row) in [("INSERT", "new"), ("UPDATE", "new"), ("DELETE", "old")] {
                let columns = operation == "UPDATE" ? updateColumns.map { " OF \($0)" } ?? "" : ""
                let condition = operation == "UPDATE" ? " AND (\(updateWhen))" : ""
                try db.execute(sql: """
                    CREATE TRIGGER sync_\(table)_\(operation.lowercased()) AFTER \(operation)\(columns) ON \(table)
                    WHEN \(active) AND (\(extra.replacingOccurrences(of: "$row", with: row)))\(condition) BEGIN
                    \(mark(type, localID.replacingOccurrences(of: "$row", with: row), deleted: operation == "DELETE"))
                    END;
                    """)
            }
        }
        try triggers("note", type: "note", localID: "$row.id",
            updateColumns: "text,title,createdAt,modifiedAt,location,trashedAt,archivedAt,isPinnedGlobal,isReadOnly,isLocked,encryptedPayload,deletedAt",
            updateWhen: "new.text IS NOT old.text OR new.title IS NOT old.title OR new.createdAt IS NOT old.createdAt OR new.modifiedAt IS NOT old.modifiedAt OR new.location IS NOT old.location OR new.trashedAt IS NOT old.trashedAt OR new.archivedAt IS NOT old.archivedAt OR new.isPinnedGlobal IS NOT old.isPinnedGlobal OR new.isReadOnly IS NOT old.isReadOnly OR new.isLocked IS NOT old.isLocked OR new.encryptedPayload IS NOT old.encryptedPayload OR new.deletedAt IS NOT old.deletedAt")
        try triggers("attachment", type: "attachment", localID: "$row.id",
            updateColumns: "filename,noteId,deletedAt,uti,width,height,byteSize,sha256,ocrText",
            updateWhen: "new.filename IS NOT old.filename OR new.noteId IS NOT old.noteId OR new.deletedAt IS NOT old.deletedAt OR new.uti IS NOT old.uti OR new.width IS NOT old.width OR new.height IS NOT old.height OR new.byteSize IS NOT old.byteSize OR new.sha256 IS NOT old.sha256 OR new.ocrText IS NOT old.ocrText")
        try triggers("tag", type: "tagPreference", localID: "$row.id",
            updateColumns: "displayPath,iconName,isPinned,sortIndex",
            updateWhen: "new.displayPath IS NOT old.displayPath OR new.iconName IS NOT old.iconName OR new.isPinned IS NOT old.isPinned OR new.sortIndex IS NOT old.sortIndex")
        // Explicit allowlist: paths, biometrics, editor position, workspaces, recents, window
        // state, device appearance and other local preferences never become portable by accident.
        try triggers("setting", type: "setting", localID: "$row.key",
            extra: "$row.key IN ('hideMarkdown','showNoteCounts','autoSortTodos','showHeadingLevels','autocomplete','startNoteTemplate','tagPosition','noteSort')",
            updateWhen: "new.value IS NOT old.value")
        try triggers("external_ref", type: "externalRef", localID: "json_array($row.source,$row.externalId)")
        try triggers("crypto_envelope", type: "keyBundle", localID: "'lock-vault'")
        // Per-tag pin membership belongs to the encrypted note payload. Deleting a pin is an
        // update of that note, never a tombstone of the note itself.
        for operation in ["INSERT", "DELETE"] {
            let row = operation == "INSERT" ? "new" : "old"
            try db.execute(sql: """
                CREATE TRIGGER sync_note_pin_\(operation.lowercased()) AFTER \(operation) ON note_pin
                WHEN \(active) AND EXISTS(SELECT 1 FROM note WHERE id=\(row).noteId) BEGIN
                \(mark("note", "\(row).noteId"))
                END;
                """)
        }
    }
}
