// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

enum Migrations {
    /// FROZEN: the schema snapshot fixtures pin v1–v7 (`SchemaSnapshotTests` compares each one's
    /// schema with `Fixtures/schema/<id>.sql`). Never edit them; append a new migration instead.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE note (
                    id TEXT PRIMARY KEY,
                    text TEXT,
                    title TEXT NOT NULL DEFAULT '',
                    titleKey TEXT NOT NULL DEFAULT '',
                    subtitle TEXT NOT NULL DEFAULT '',
                    createdAt DATETIME NOT NULL,
                    modifiedAt DATETIME NOT NULL,
                    location TEXT NOT NULL DEFAULT 'notes'
                        CHECK(location IN ('notes','archive','trash')),
                    trashedAt DATETIME,
                    archivedAt DATETIME,
                    isPinnedGlobal BOOLEAN NOT NULL DEFAULT 0,
                    isReadOnly BOOLEAN NOT NULL DEFAULT 0,
                    isLocked BOOLEAN NOT NULL DEFAULT 0,
                    encryptedPayload BLOB,
                    revision INTEGER NOT NULL DEFAULT 1,
                    deletedAt DATETIME
                );
                CREATE INDEX note_on_modifiedAt ON note(modifiedAt);
                CREATE INDEX note_on_titleKey ON note(titleKey);

                CREATE TABLE note_ui_state (
                    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
                    foldState TEXT,
                    selection TEXT,
                    scrollTop DOUBLE
                );

                CREATE TABLE setting (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }

        // Runs with GRDB's default deferred foreign key checks (foreign keys off, full check before
        // commit), as required by the SQLite table-rebuild procedure used for `note`.
        migrator.registerMigration("v2") { db in
            // Rebuild `note` so `text` is NOT NULL DEFAULT '' (ruling R5): create, copy, drop,
            // rename, recreate indexes.
            try db.execute(sql: """
                CREATE TABLE new_note (
                    id TEXT PRIMARY KEY,
                    text TEXT NOT NULL DEFAULT '',
                    title TEXT NOT NULL DEFAULT '',
                    titleKey TEXT NOT NULL DEFAULT '',
                    subtitle TEXT NOT NULL DEFAULT '',
                    createdAt DATETIME NOT NULL,
                    modifiedAt DATETIME NOT NULL,
                    location TEXT NOT NULL DEFAULT 'notes'
                        CHECK(location IN ('notes','archive','trash')),
                    trashedAt DATETIME,
                    archivedAt DATETIME,
                    isPinnedGlobal BOOLEAN NOT NULL DEFAULT 0,
                    isReadOnly BOOLEAN NOT NULL DEFAULT 0,
                    isLocked BOOLEAN NOT NULL DEFAULT 0,
                    encryptedPayload BLOB,
                    revision INTEGER NOT NULL DEFAULT 1,
                    deletedAt DATETIME
                );
                INSERT INTO new_note (id, text, title, titleKey, subtitle, createdAt, modifiedAt, location,
                    trashedAt, archivedAt, isPinnedGlobal, isReadOnly, isLocked, encryptedPayload, revision, deletedAt)
                SELECT id, COALESCE(text, ''), title, titleKey, subtitle, createdAt, modifiedAt, location,
                    trashedAt, archivedAt, isPinnedGlobal, isReadOnly, isLocked, encryptedPayload, revision, deletedAt
                FROM note;
                DROP TABLE note;
                ALTER TABLE new_note RENAME TO note;
                CREATE INDEX note_on_modifiedAt ON note(modifiedAt);
                CREATE INDEX note_on_titleKey ON note(titleKey);

                CREATE TABLE tag (
                    id TEXT PRIMARY KEY,
                    pathKey TEXT NOT NULL UNIQUE,
                    displayPath TEXT NOT NULL,
                    iconName TEXT,
                    isPinned BOOLEAN NOT NULL DEFAULT 0,
                    sortIndex INTEGER
                );

                CREATE TABLE note_tag (
                    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    isDirect BOOLEAN NOT NULL,
                    PRIMARY KEY (noteId, tagId)
                );
                CREATE INDEX note_tag_on_tagId ON note_tag(tagId);

                CREATE TABLE note_pin (
                    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY (noteId, tagId)
                );
                CREATE INDEX note_pin_on_tagId ON note_pin(tagId);

                CREATE TABLE wiki_link (
                    sourceNoteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    targetKey TEXT NOT NULL,
                    targetTitle TEXT NOT NULL,
                    targetHeading TEXT,
                    alias TEXT,
                    PRIMARY KEY (sourceNoteId, ordinal)
                );
                CREATE INDEX wiki_link_on_targetKey ON wiki_link(targetKey);

                CREATE TABLE heading (
                    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    level INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    line INTEGER NOT NULL,
                    PRIMARY KEY (noteId, ordinal)
                );

                CREATE TABLE note_stats (
                    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
                    openTodos INTEGER NOT NULL DEFAULT 0,
                    doneTodos INTEGER NOT NULL DEFAULT 0,
                    hasCode BOOLEAN NOT NULL DEFAULT 0,
                    hasImages BOOLEAN NOT NULL DEFAULT 0,
                    hasFiles BOOLEAN NOT NULL DEFAULT 0,
                    isEmpty BOOLEAN NOT NULL DEFAULT 1,
                    attachmentNames TEXT NOT NULL DEFAULT ''
                );
                """)
        }

        // Adds `note_stats.firstImage` (for list thumbnails) and re-indexes every note, which also
        // fills the derived tables for notes created before v2. Re-indexing lives here, not in v2,
        // because the indexer always writes the newest column set.
        migrator.registerMigration("v2b") { db in
            try db.execute(sql: "ALTER TABLE note_stats ADD COLUMN firstImage TEXT")
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM note")
            for row in rows {
                try NoteIndexer.indexWithoutSearch(noteId: row["id"], text: row["text"], in: db)
            }
        }

        // `external_ref` links imported notes to their source (`source = 'bear'`, Bear's note id)
        // for incremental pulls. Last seen in the source: `lastSeenHash` (whole record),
        // `lastSeenTextHash` (its text) and `lastSeenMeta` (JSON `SourceMetadata`, for per-field
        // merges). `importedTextHash`: the text last written into the note (differs from the
        // source text for conflict copies), so a local text edit is detected and metadata-only
        // revision bumps are not edits. `noteId` becomes NULL when the note is deleted permanently:
        // a tombstone, so it is not re-imported.
        //
        // `staging_batch`: one row per attachment batch, written in the transaction that references
        // the staged files and deleted once they are in place (see `AttachmentFiles`).
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE external_ref (
                    source TEXT NOT NULL,
                    externalId TEXT NOT NULL,
                    noteId TEXT REFERENCES note(id) ON DELETE SET NULL,
                    lastSeenModified DATETIME,
                    lastSeenHash TEXT,
                    lastSeenTextHash TEXT,
                    lastSeenMeta TEXT,
                    importedRevision INTEGER,
                    importedTextHash TEXT,
                    PRIMARY KEY (source, externalId)
                );
                CREATE INDEX external_ref_on_noteId ON external_ref(noteId);

                CREATE TABLE staging_batch (
                    id TEXT PRIMARY KEY,
                    noteId TEXT NOT NULL,
                    replacing BOOLEAN NOT NULL,
                    filenames TEXT NOT NULL,
                    createdAt DATETIME NOT NULL
                );
                """)
        }

        // Search content + FTS5 (spec §3.4, §6). `note_search_content` holds one row per unlocked
        // note; two external-content FTS5 tables index it: `note_fts` (words, diacritic- and
        // case-insensitive, prefix indexes for 2/3-character as-you-type prefixes) and
        // `note_fts_trigram` (substrings, incl. CJK; case- and diacritic-insensitive). Triggers on
        // the content table keep both in sync, so rows removed by `ON DELETE CASCADE` (permanent
        // note deletion) leave the indexes too — indexer-managed 'delete' commands would miss those.
        //
        // The backfill is self-contained: it reads the stored title and `note_stats.attachmentNames`
        // and computes the body with `NoteParser.searchBody(for:)`, a pure text → text function
        // that touches no tables, so later schema changes cannot break this migration (the M1
        // lesson about calling the live indexer). A later change to the stripping rules needs its
        // own re-backfill migration.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE note_search_content (
                    rowid INTEGER PRIMARY KEY,
                    noteId TEXT NOT NULL UNIQUE REFERENCES note(id) ON DELETE CASCADE,
                    title TEXT NOT NULL DEFAULT '',
                    body TEXT NOT NULL DEFAULT '',
                    attachmentNames TEXT NOT NULL DEFAULT '',
                    ocrText TEXT NOT NULL DEFAULT ''
                );
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    title, body, attachmentNames, ocrText,
                    content='note_search_content', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2', prefix='2 3'
                );
                CREATE VIRTUAL TABLE note_fts_trigram USING fts5(
                    title, body, attachmentNames, ocrText,
                    content='note_search_content', content_rowid='rowid',
                    tokenize='trigram case_sensitive 0 remove_diacritics 1'
                );
                CREATE TRIGGER note_search_content_ai AFTER INSERT ON note_search_content BEGIN
                    INSERT INTO note_fts (rowid, title, body, attachmentNames, ocrText)
                        VALUES (new.rowid, new.title, new.body, new.attachmentNames, new.ocrText);
                    INSERT INTO note_fts_trigram (rowid, title, body, attachmentNames, ocrText)
                        VALUES (new.rowid, new.title, new.body, new.attachmentNames, new.ocrText);
                END;
                CREATE TRIGGER note_search_content_ad AFTER DELETE ON note_search_content BEGIN
                    INSERT INTO note_fts (note_fts, rowid, title, body, attachmentNames, ocrText)
                        VALUES ('delete', old.rowid, old.title, old.body, old.attachmentNames, old.ocrText);
                    INSERT INTO note_fts_trigram (note_fts_trigram, rowid, title, body, attachmentNames, ocrText)
                        VALUES ('delete', old.rowid, old.title, old.body, old.attachmentNames, old.ocrText);
                END;
                CREATE TRIGGER note_search_content_au AFTER UPDATE ON note_search_content BEGIN
                    INSERT INTO note_fts (note_fts, rowid, title, body, attachmentNames, ocrText)
                        VALUES ('delete', old.rowid, old.title, old.body, old.attachmentNames, old.ocrText);
                    INSERT INTO note_fts_trigram (note_fts_trigram, rowid, title, body, attachmentNames, ocrText)
                        VALUES ('delete', old.rowid, old.title, old.body, old.attachmentNames, old.ocrText);
                    INSERT INTO note_fts (rowid, title, body, attachmentNames, ocrText)
                        VALUES (new.rowid, new.title, new.body, new.attachmentNames, new.ocrText);
                    INSERT INTO note_fts_trigram (rowid, title, body, attachmentNames, ocrText)
                        VALUES (new.rowid, new.title, new.body, new.attachmentNames, new.ocrText);
                END;
                """)
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.text, COALESCE(s.attachmentNames, '') AS attachmentNames
                FROM note n LEFT JOIN note_stats s ON s.noteId = n.id
                WHERE n.isLocked = 0
                """)
            let insert = try db.makeStatement(sql: """
                INSERT INTO note_search_content (noteId, title, body, attachmentNames)
                VALUES (?, ?, ?, REPLACE(?, char(10), ' '))
                """)
            for row in rows {
                let text: String = row["text"]
                try insert.execute(arguments: [
                    row["id"] as String, row["title"] as String, NoteParser.searchBody(for: text),
                    row["attachmentNames"] as String,
                ])
            }
        }

        // The search content becomes `SearchText.fold` of the title, the raw note text and the
        // attachment names: the Bear search oracle (docs/oracle/m4-search.md) showed Bear matches
        // substrings of the Markdown source (markup and link URLs included) and folds `ß` to `ss`.
        // Self-contained like v4 (`SearchText.fold` is a pure text → text function); the UPDATE
        // trigger re-indexes both FTS tables.
        migrator.registerMigration("v5") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id, n.title, n.text, COALESCE(s.attachmentNames, '') AS attachmentNames
                FROM note_search_content c JOIN note n ON n.id = c.noteId
                LEFT JOIN note_stats s ON s.noteId = n.id
                """)
            let update = try db.makeStatement(sql: """
                UPDATE note_search_content SET title = ?, body = ?, attachmentNames = ? WHERE noteId = ?
                """)
            for row in rows {
                let names: String = row["attachmentNames"]
                try update.execute(arguments: [
                    SearchText.fold(row["title"]), SearchText.fold(row["text"]),
                    SearchText.fold(names.replacingOccurrences(of: "\n", with: " ")), row["id"] as String,
                ])
            }
        }

        // Recently used workspaces (spec §3.5, §4.2), keyed by the tag's canonical key rather than
        // its id so an entry outlives the tag row (orphan tags are deleted) and comes back with it.
        // `displayPath`: the spelling chosen. `Workspace.recordUse` keeps the newest five.
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                CREATE TABLE workspace (
                    pathKey TEXT PRIMARY KEY,
                    displayPath TEXT NOT NULL,
                    lastUsedAt DATETIME NOT NULL
                );
                """)
        }

        // Attachment rows (spec §3.4, ruling X6): one per (note, file) with a stable UUIDv7 `id`
        // (M9 encryption binds it into the AAD; sync carries it). A file is identified by
        // `filenameKey` (`AttachmentFiles.fileSystemKey`: NFC + lowercased, like the file system),
        // so `Foto.png` / `foto.png` / NFC / NFD are one row; `filename` is the spelling in the
        // text. `deletedAt` is a tombstone set when the link leaves the text: a re-link revives the
        // row (same `id`, OCR text kept); the app-only attachment cleanup (R23) purges it once the
        // file is removed. `updatedAt` marks every row write. File facts: `uti`, `width`, `height`,
        // `byteSize`, `fileModifiedAt`, `sha256`. `ocrState`: pending (to do), done (`ocrText` set),
        // none (no text found), failed, skipped (not recognized on purpose), locked (the note is
        // locked: all plaintext facts are NULL), missing (the file is not there yet; retried after
        // a backoff). `ocrVersion`: the recognizer that produced `ocrText`, so an upgrade can
        // re-queue rows. Self-contained backfill like v4/v5: a pending row for every attachment
        // link of every unlocked note, `createdAt` = the note's, from the pure
        // `NoteParser.metadata(for:)`, never from the live indexer.
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
                CREATE TABLE attachment (
                    id TEXT NOT NULL PRIMARY KEY,
                    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    filename TEXT NOT NULL,
                    filenameKey TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    deletedAt DATETIME,
                    uti TEXT,
                    width INTEGER,
                    height INTEGER,
                    byteSize INTEGER,
                    fileModifiedAt DATETIME,
                    sha256 TEXT,
                    ocrState TEXT NOT NULL DEFAULT 'pending'
                        CHECK(ocrState IN ('pending','done','none','failed','skipped','locked','missing')),
                    ocrText TEXT,
                    ocrAt DATETIME,
                    ocrVersion INTEGER,
                    UNIQUE (noteId, filenameKey)
                );
                CREATE INDEX attachment_on_state ON attachment(ocrState);
                CREATE INDEX attachment_on_sha256 ON attachment(sha256);
                """)
            let now = Date()
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, text, createdAt FROM note WHERE isLocked = 0 ORDER BY createdAt, id
                """)
            let insert = try db.makeStatement(sql: """
                INSERT INTO attachment (id, noteId, filename, filenameKey, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(noteId, filenameKey) DO NOTHING
                """)
            for row in rows {
                let text: String = row["text"]
                for ref in NoteParser.metadata(for: text).attachments {
                    try insert.execute(arguments: [
                        UUIDv7.make(now: now), row["id"] as String, ref.filename,
                        AttachmentFiles.fileSystemKey(ref.filename), row["createdAt"] as Date, now,
                    ])
                }
            }
        }

        // Password-wrapped lock-vault key is data, so backup and sync preserve decryptability.
        migrator.registerMigration("v7-privacy") { db in
            try db.execute(sql: """
                CREATE TABLE crypto_envelope (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    envelope BLOB NOT NULL
                );
                CREATE TABLE privacy_transition (
                    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
                    targetLocked BOOLEAN NOT NULL,
                    filenames TEXT NOT NULL
                );
                INSERT INTO note_fts(note_fts, rank) VALUES('secure-delete', 1);
                INSERT INTO note_fts_trigram(note_fts_trigram, rank) VALUES('secure-delete', 1);
                """)
        }

        migrator.registerMigration("v8-sync") { db in try SyncSchemaV1.install(db) }
        migrator.registerMigration("v9-sync-content") { db in
            try db.execute(sql: """
                CREATE TABLE sync_attachment_cache (
                    attachmentId TEXT PRIMARY KEY,
                    generation INTEGER NOT NULL,
                    fingerprint TEXT NOT NULL,
                    encryptedDescriptor BLOB NOT NULL,
                    blobHash TEXT NOT NULL REFERENCES sync_blob_state(hash)
                );
                CREATE TABLE sync_inbox (
                    sequence INTEGER PRIMARY KEY,
                    entityType TEXT NOT NULL, entityId TEXT NOT NULL,
                    serverRevision INTEGER NOT NULL, wireEntity BLOB NOT NULL,
                    waitingForUnlock BOOLEAN NOT NULL DEFAULT 0
                );
                CREATE INDEX sync_inbox_entity ON sync_inbox(entityType,entityId,serverRevision);
                CREATE TABLE sync_conflict (
                    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
                    originalNoteId TEXT NOT NULL, rejectedMutationId TEXT NOT NULL,
                    remoteRevision INTEGER NOT NULL
                );
                CREATE TRIGGER sync_staged_attachment AFTER INSERT ON staging_batch
                WHEN (SELECT enabled=1 AND applying=0 FROM sync_control WHERE id=1) BEGIN
                    INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
                    SELECT 'attachment',id,1,0 FROM attachment WHERE noteId=new.noteId
                    ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0;
                END;
                """)
        }
        migrator.registerMigration("v10-backup") { db in
            try db.execute(sql: """
                CREATE TABLE backup_catalog (
                    id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE, createdAt DATETIME NOT NULL,
                    plaintextNoteIds TEXT NOT NULL
                );
                """)
        }

        migrator.registerMigration("v11-sync-receipts") { db in
            try db.execute(sql: "CREATE TABLE sync_receipt(mutationId TEXT PRIMARY KEY,receiptHash TEXT NOT NULL)")
        }
        migrator.registerMigration("v12-sync-import-cleanup") { db in
            try db.execute(sql: "CREATE TABLE sync_import_cleanup(noteId TEXT PRIMARY KEY)")
        }
        migrator.registerMigration("v13-sync-attachment-purge") { db in
            // A note pins retained attachment versions in its encrypted snapshot. Purging the
            // local tombstone must publish a new note snapshot too, or its old blob reference
            // survives indefinitely even after the attachment entity has been deleted.
            try db.execute(sql: """
                CREATE TRIGGER sync_attachment_purge_note AFTER DELETE ON attachment
                WHEN (SELECT enabled=1 AND applying=0 FROM sync_control WHERE id=1)
                  AND EXISTS(SELECT 1 FROM note WHERE id=old.noteId) BEGIN
                    INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
                    VALUES('note',old.noteId,1,0)
                    ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0;
                END;
                INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
                SELECT 'note',id,1,0 FROM note
                WHERE (SELECT enabled=1 AND applying=0 FROM sync_control WHERE id=1)
                ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0;
                """)
        }

        migrator.registerMigration("v14-sync-capture-before-upload") { db in
            try SyncCaptureSchemaV2.install(db)
        }

        // Capture & Next Up. Device-local state: nothing here
        // is in the sync payload. `notification_ledger` has no foreign key on purpose: its rows
        // outlive a deleted note, so a cold launch can still remove that note's notifications.
        migrator.registerMigration("v15-focus") { db in
            try db.execute(sql: """
                ALTER TABLE note ADD COLUMN captureSource TEXT
                  CHECK(captureSource IN ('share','voice','lockscreen','shortcut','command','mcp'));
                ALTER TABLE note_ui_state ADD COLUMN lastOpenedAt DATETIME;
                CREATE TABLE focus_hide (
                  candidateKey TEXT PRIMARY KEY,
                  noteId TEXT REFERENCES note(id) ON DELETE CASCADE,
                  hiddenUntil DATETIME NOT NULL);
                CREATE TABLE note_ping (
                  id TEXT PRIMARY KEY,
                  noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  anchorLine INTEGER, anchorHash TEXT,
                  fireAt DATETIME NOT NULL, firedAt DATETIME, createdAt DATETIME NOT NULL,
                  CHECK ((anchorLine IS NULL) = (anchorHash IS NULL)));
                CREATE UNIQUE INDEX note_ping_target ON note_ping(noteId, COALESCE(anchorLine, 0), COALESCE(anchorHash, ''));
                CREATE INDEX note_ping_on_fireAt ON note_ping(fireAt);
                CREATE TABLE note_snapshot (
                  id TEXT PRIMARY KEY,
                  noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                  takenAt DATETIME NOT NULL,
                  text TEXT, sealedText BLOB,
                  CHECK ((text IS NULL) != (sealedText IS NULL)));
                CREATE INDEX note_snapshot_on_note ON note_snapshot(noteId, takenAt);
                CREATE TABLE capture_receipt (
                  itemId TEXT PRIMARY KEY, noteId TEXT, processedAt DATETIME NOT NULL);
                CREATE TABLE notification_ledger (
                  identifier TEXT PRIMARY KEY,
                  kind TEXT NOT NULL CHECK(kind IN ('reminder','timer')),
                  pingId TEXT, noteId TEXT,
                  contentHash TEXT,
                  recordedAt DATETIME NOT NULL);
                CREATE INDEX notification_ledger_on_note ON notification_ledger(noteId);
                """)
        }

        // CloudKit-native sync state. Additive: a library that
        // never syncs gains one column (`backend`, default 'none'), empty tables and one trigger.
        // `sync_dirty`, `sync_entity_state`, `sync_blob_state` and `sync_control` are reused as they are.
        // The trigger keeps `backend` truthful for the Cloudflare engine, which is not edited: it
        // sets `accountId` and never learns about `backend`.
        migrator.registerMigration("v16-cloudkit-native") { db in
            try db.execute(sql: """
                ALTER TABLE sync_control ADD COLUMN backend TEXT NOT NULL DEFAULT 'none'
                  CHECK(backend IN ('none','cloudflare','cloudkit'));
                UPDATE sync_control SET backend='cloudflare' WHERE accountId IS NOT NULL;
                CREATE TRIGGER sync_control_backend_binding AFTER UPDATE OF accountId ON sync_control
                WHEN new.accountId IS NOT NULL AND new.backend='none' BEGIN
                    UPDATE sync_control SET backend='cloudflare' WHERE id=new.id;
                END;
                CREATE TABLE ck_state (
                  id INTEGER PRIMARY KEY CHECK(id=1),
                  containerId TEXT, zoneName TEXT, accountId TEXT, cloudUserHash TEXT,
                  generation INTEGER NOT NULL DEFAULT 0,
                  zoneState TEXT NOT NULL DEFAULT 'unknown' CHECK(zoneState IN ('unknown','created','removed')),
                  zoneRemovedReason TEXT, fenced BOOLEAN NOT NULL DEFAULT 0,
                  engineState BLOB, bundleRevision INTEGER NOT NULL DEFAULT 0,
                  recoveryState TEXT NOT NULL DEFAULT 'none' CHECK(recoveryState IN ('none','pending','saved','acknowledgedSkip')),
                  lastAppBuild TEXT, fetchEpoch INTEGER NOT NULL DEFAULT 0);
                INSERT INTO ck_state(id) VALUES(1);
                CREATE TABLE ck_record (
                  entityType TEXT NOT NULL, entityId TEXT NOT NULL,
                  systemFields BLOB NOT NULL, ancestor BLOB NOT NULL, ver INTEGER NOT NULL,
                  inc TEXT NOT NULL, supersededIncs TEXT NOT NULL DEFAULT '[]',
                  PRIMARY KEY(entityType, entityId));
                CREATE TABLE ck_inflight (
                  entityType TEXT NOT NULL, entityId TEXT NOT NULL, localId TEXT NOT NULL,
                  generation INTEGER NOT NULL, attemptId TEXT NOT NULL UNIQUE,
                  baseSystemFields BLOB, baseAncestor BLOB, baseVer INTEGER NOT NULL DEFAULT 0, inc TEXT NOT NULL,
                  sealed BLOB NOT NULL, blobRefs TEXT NOT NULL DEFAULT '[]',
                  state TEXT NOT NULL DEFAULT 'prepared' CHECK(state IN ('prepared','sending','unknown')),
                  generationOfAccount INTEGER NOT NULL, preparedAt DATETIME NOT NULL,
                  PRIMARY KEY(entityType, entityId));
                CREATE TABLE ck_send_result (
                  attemptId TEXT PRIMARY KEY, accountGeneration INTEGER NOT NULL, outcome BLOB NOT NULL, recordedAt DATETIME NOT NULL);
                CREATE TABLE ck_remote (
                  recordName TEXT PRIMARY KEY, entityType TEXT NOT NULL, entityId TEXT NOT NULL,
                  inc TEXT NOT NULL, incs TEXT NOT NULL DEFAULT '[]', ver INTEGER NOT NULL, sid TEXT NOT NULL, sids TEXT NOT NULL, systemFields BLOB NOT NULL,
                  sealed BLOB, sealedPath TEXT, sealedSha256 TEXT, blobRefs TEXT NOT NULL DEFAULT '[]', receivedAt DATETIME NOT NULL,
                  waitingFor TEXT CHECK(waitingFor IN ('unlock','dependency')));
                CREATE TABLE ck_quarantine (
                  recordName TEXT PRIMARY KEY, entityType TEXT, entityId TEXT, reason TEXT NOT NULL, v INTEGER, rawFields BLOB NOT NULL,
                  pinnedAssets TEXT NOT NULL DEFAULT '[]', ignoredByUser BOOLEAN NOT NULL DEFAULT 0,
                  firstSeen DATETIME NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE ck_missing (
                  entityType TEXT NOT NULL, entityId TEXT NOT NULL, lastVer INTEGER NOT NULL, lastInc TEXT NOT NULL,
                  detectedAt DATETIME NOT NULL, reason TEXT NOT NULL, PRIMARY KEY(entityType, entityId));
                CREATE TABLE ck_blob_part (
                  hash TEXT NOT NULL, part INTEGER NOT NULL, parts INTEGER NOT NULL, partBytes INTEGER NOT NULL,
                  totalBytes INTEGER NOT NULL, partSha256 TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('uploaded','verified')), verifiedAt DATETIME,
                  PRIMARY KEY(hash, part));
                """)
        }

        // The attempt-id chain of a version (`sids`, ambiguous-outcome table). The base pair must carry
        // the chain of the version it was built on, or the next saver cannot extend it and a lost response could
        // never be proven by it; `ck_inflight` keeps the chain exactly as it was sent. Additive, empty by default.
        migrator.registerMigration("v17-cloudkit-attempt-chain") { db in
            try db.execute(sql: """
                ALTER TABLE ck_record ADD COLUMN sids TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE ck_inflight ADD COLUMN sids TEXT NOT NULL DEFAULT '[]';
                UPDATE ck_inflight SET sids = json_array(attemptId);
                """)
        }

        // The verified key bundle: a library that verified the account's `KeyBundle` once keeps the record's content
        // (account id, revision, the public envelope and the canary: public keys and ciphertext only) so that an offline launch
        // can rebuild its keys from the device's keychain seed without the network. `switchedOn` is the person's switch (a blocked first sync goes on by itself); `deletedStarters` lists fixed-id Getting Started notes deleted before the first binding. Additive, empty by default.
        migrator.registerMigration("v18-cloudkit-key-bundle-cache") { db in
            try db.execute(sql: """
                ALTER TABLE ck_state ADD COLUMN keyBundleCache BLOB;
                ALTER TABLE ck_state ADD COLUMN switchedOn BOOLEAN NOT NULL DEFAULT 0;
                ALTER TABLE ck_state ADD COLUMN deletedStarters TEXT;
                """)
        }

        // The note type (`NoteType`): the first reserved direct tag in text order, derived by the indexer and kept on the row
        // so the list can show it without joins. Backfill: every readable note is re-parsed here, so the rule holds for it
        // from the start; a locked note's text is not readable, so its direct reserved tag rows decide (`MIN(pathKey)` when
        // there are several, NULL when it has none; its next edit while unlocked re-derives it by the text-order rule). Additive, NULL = no type.
        migrator.registerMigration("v19-note-type") { db in
            try db.execute(sql: """
                ALTER TABLE note ADD COLUMN noteType TEXT;
                CREATE INDEX note_on_noteType ON note(noteType);
                """)
            // A cursor streams the texts; only the (id, type) pairs are kept, so the UPDATEs never touch rows being read.
            var typed: [(id: String, type: NoteType)] = []
            let cursor = try Row.fetchCursor(db, sql: "SELECT id, text FROM note WHERE isLocked = 0")
            while let row = try cursor.next() {
                guard let type = NoteType.of(directTags: NoteParser.metadata(for: row["text"] as String).tags) else { continue }
                typed.append((row["id"] as String, type))
            }
            for (id, type) in typed {
                try db.execute(sql: "UPDATE note SET noteType = ? WHERE id = ?", arguments: [type.rawValue, id])
            }
            try db.execute(sql: """
                UPDATE note SET noteType = (
                    SELECT CASE MIN(t.pathKey) WHEN 'idea' THEN 'idea' WHEN 'log' THEN 'log' WHEN 'ref' THEN 'reference' END
                    FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                    WHERE nt.noteId = note.id AND nt.isDirect = 1 AND t.pathKey IN ('idea', 'log', 'ref'))
                WHERE isLocked = 1
                """)
        }

        migrator.registerMigration("v20-watch-capture") { db in
            try db.execute(sql: """
                CREATE TABLE watch_command_receipt (
                    epoch TEXT NOT NULL, commandID TEXT NOT NULL, requestMetadata TEXT NOT NULL, result BLOB NOT NULL,
                    recordedAt DATETIME NOT NULL,
                    PRIMARY KEY(epoch,commandID));
                """)
        }

        // Future migrations: keep the index name `note_on_modifiedAt`. NoteTitleIndex reads the
        // completion fingerprint `INDEXED BY note_on_modifiedAt`, so a migration that rebuilds
        // `note` must recreate the index under that name (or every note completion fails with
        // "no such index"). CompletionProviderTests checks it after all migrations.

        return migrator
    }
}
