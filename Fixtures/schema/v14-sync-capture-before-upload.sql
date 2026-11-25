-- index attachment_on_sha256
CREATE INDEX attachment_on_sha256 ON attachment(sha256);

-- index attachment_on_state
CREATE INDEX attachment_on_state ON attachment(ocrState);

-- index external_ref_on_noteId
CREATE INDEX external_ref_on_noteId ON external_ref(noteId);

-- index note_on_modifiedAt
CREATE INDEX note_on_modifiedAt ON note(modifiedAt);

-- index note_on_titleKey
CREATE INDEX note_on_titleKey ON note(titleKey);

-- index note_pin_on_tagId
CREATE INDEX note_pin_on_tagId ON note_pin(tagId);

-- index note_tag_on_tagId
CREATE INDEX note_tag_on_tagId ON note_tag(tagId);

-- index sync_inbox_entity
CREATE INDEX sync_inbox_entity ON sync_inbox(entityType,entityId,serverRevision);

-- index wiki_link_on_targetKey
CREATE INDEX wiki_link_on_targetKey ON wiki_link(targetKey);

-- table attachment
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

-- table backup_catalog
CREATE TABLE backup_catalog (
    id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE, createdAt DATETIME NOT NULL,
    plaintextNoteIds TEXT NOT NULL
);

-- table crypto_envelope
CREATE TABLE crypto_envelope (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    envelope BLOB NOT NULL
);

-- table external_ref
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

-- table heading
CREATE TABLE heading (
    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    level INTEGER NOT NULL,
    text TEXT NOT NULL,
    line INTEGER NOT NULL,
    PRIMARY KEY (noteId, ordinal)
);

-- table note
CREATE TABLE "note" (
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

-- table note_fts
CREATE VIRTUAL TABLE note_fts USING fts5(
    title, body, attachmentNames, ocrText,
    content='note_search_content', content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2', prefix='2 3'
);

-- table note_fts_trigram
CREATE VIRTUAL TABLE note_fts_trigram USING fts5(
    title, body, attachmentNames, ocrText,
    content='note_search_content', content_rowid='rowid',
    tokenize='trigram case_sensitive 0 remove_diacritics 1'
);

-- table note_pin
CREATE TABLE note_pin (
    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
    tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (noteId, tagId)
);

-- table note_search_content
CREATE TABLE note_search_content (
    rowid INTEGER PRIMARY KEY,
    noteId TEXT NOT NULL UNIQUE REFERENCES note(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    attachmentNames TEXT NOT NULL DEFAULT '',
    ocrText TEXT NOT NULL DEFAULT ''
);

-- table note_stats
CREATE TABLE note_stats (
    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
    openTodos INTEGER NOT NULL DEFAULT 0,
    doneTodos INTEGER NOT NULL DEFAULT 0,
    hasCode BOOLEAN NOT NULL DEFAULT 0,
    hasImages BOOLEAN NOT NULL DEFAULT 0,
    hasFiles BOOLEAN NOT NULL DEFAULT 0,
    isEmpty BOOLEAN NOT NULL DEFAULT 1,
    attachmentNames TEXT NOT NULL DEFAULT ''
, firstImage TEXT);

-- table note_tag
CREATE TABLE note_tag (
    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
    tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    isDirect BOOLEAN NOT NULL,
    PRIMARY KEY (noteId, tagId)
);

-- table note_ui_state
CREATE TABLE note_ui_state (
    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
    foldState TEXT,
    selection TEXT,
    scrollTop DOUBLE
);

-- table privacy_transition
CREATE TABLE privacy_transition (
    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
    targetLocked BOOLEAN NOT NULL,
    filenames TEXT NOT NULL
);

-- table setting
CREATE TABLE setting (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- table staging_batch
CREATE TABLE staging_batch (
    id TEXT PRIMARY KEY,
    noteId TEXT NOT NULL,
    replacing BOOLEAN NOT NULL,
    filenames TEXT NOT NULL,
    createdAt DATETIME NOT NULL
);

-- table sync_attachment_cache
CREATE TABLE sync_attachment_cache (
    attachmentId TEXT PRIMARY KEY,
    generation INTEGER NOT NULL,
    fingerprint TEXT NOT NULL,
    encryptedDescriptor BLOB NOT NULL,
    blobHash TEXT NOT NULL REFERENCES sync_blob_state(hash)
);

-- table sync_blob_state
CREATE TABLE sync_blob_state (
    hash TEXT PRIMARY KEY, data BLOB, localPath TEXT,
    byteSize INTEGER NOT NULL, uploaded BOOLEAN NOT NULL DEFAULT 0,
    multipartId TEXT, completedParts TEXT,
    CHECK((data IS NULL) != (localPath IS NULL))
);

-- table sync_conflict
CREATE TABLE sync_conflict (
    noteId TEXT PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
    originalNoteId TEXT NOT NULL, rejectedMutationId TEXT NOT NULL,
    remoteRevision INTEGER NOT NULL
);

-- table sync_control
CREATE TABLE sync_control (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    enabled BOOLEAN NOT NULL DEFAULT 0,
    applying BOOLEAN NOT NULL DEFAULT 0,
    accountId TEXT
);

-- table sync_cursor
CREATE TABLE sync_cursor (
    id INTEGER PRIMARY KEY CHECK(id = 1), sequence INTEGER NOT NULL DEFAULT 0
);

-- table sync_device
CREATE TABLE sync_device (
    id INTEGER PRIMARY KEY CHECK(id = 1), deviceId TEXT NOT NULL, accountId TEXT NOT NULL,
    endpoint TEXT NOT NULL, envelope BLOB NOT NULL, wrappedMasterKey TEXT NOT NULL
);

-- table sync_dirty
CREATE TABLE sync_dirty (
    entityType TEXT NOT NULL, localId TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 1, tombstone BOOLEAN NOT NULL DEFAULT 0,
    PRIMARY KEY(entityType, localId)
);

-- table sync_entity_state
CREATE TABLE sync_entity_state (
    entityType TEXT NOT NULL, localId TEXT NOT NULL, entityId TEXT NOT NULL,
    serverRevision INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(entityType, localId), UNIQUE(entityType, entityId)
);

-- table sync_import_cleanup
CREATE TABLE sync_import_cleanup(noteId TEXT PRIMARY KEY);

-- table sync_inbox
CREATE TABLE sync_inbox (
    sequence INTEGER PRIMARY KEY,
    entityType TEXT NOT NULL, entityId TEXT NOT NULL,
    serverRevision INTEGER NOT NULL, wireEntity BLOB NOT NULL,
    waitingForUnlock BOOLEAN NOT NULL DEFAULT 0
);

-- table sync_outbox
CREATE TABLE sync_outbox (
    ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
    mutationId TEXT NOT NULL UNIQUE, entityType TEXT NOT NULL, localId TEXT NOT NULL,
    generation INTEGER NOT NULL, wireMutation BLOB NOT NULL,
    UNIQUE(entityType, localId)
);

-- table sync_receipt
CREATE TABLE sync_receipt(mutationId TEXT PRIMARY KEY,receiptHash TEXT NOT NULL);

-- table sync_shadow
CREATE TABLE sync_shadow (
    entityType TEXT NOT NULL, entityId TEXT NOT NULL,
    serverRevision INTEGER NOT NULL, sequence INTEGER NOT NULL, wireEntity BLOB NOT NULL,
    PRIMARY KEY(entityType, entityId)
);

-- table tag
CREATE TABLE tag (
    id TEXT PRIMARY KEY,
    pathKey TEXT NOT NULL UNIQUE,
    displayPath TEXT NOT NULL,
    iconName TEXT,
    isPinned BOOLEAN NOT NULL DEFAULT 0,
    sortIndex INTEGER
);

-- table wiki_link
CREATE TABLE wiki_link (
    sourceNoteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    targetKey TEXT NOT NULL,
    targetTitle TEXT NOT NULL,
    targetHeading TEXT,
    alias TEXT,
    PRIMARY KEY (sourceNoteId, ordinal)
);

-- table workspace
CREATE TABLE workspace (
    pathKey TEXT PRIMARY KEY,
    displayPath TEXT NOT NULL,
    lastUsedAt DATETIME NOT NULL
);

-- trigger note_search_content_ad
CREATE TRIGGER note_search_content_ad AFTER DELETE ON note_search_content BEGIN
    INSERT INTO note_fts (note_fts, rowid, title, body, attachmentNames, ocrText)
        VALUES ('delete', old.rowid, old.title, old.body, old.attachmentNames, old.ocrText);
    INSERT INTO note_fts_trigram (note_fts_trigram, rowid, title, body, attachmentNames, ocrText)
        VALUES ('delete', old.rowid, old.title, old.body, old.attachmentNames, old.ocrText);
END;

-- trigger note_search_content_ai
CREATE TRIGGER note_search_content_ai AFTER INSERT ON note_search_content BEGIN
    INSERT INTO note_fts (rowid, title, body, attachmentNames, ocrText)
        VALUES (new.rowid, new.title, new.body, new.attachmentNames, new.ocrText);
    INSERT INTO note_fts_trigram (rowid, title, body, attachmentNames, ocrText)
        VALUES (new.rowid, new.title, new.body, new.attachmentNames, new.ocrText);
END;

-- trigger note_search_content_au
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

-- trigger sync_attachment_delete
CREATE TRIGGER sync_attachment_delete AFTER DELETE ON attachment
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',old.id,1,1)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_attachment_insert
CREATE TRIGGER sync_attachment_insert AFTER INSERT ON attachment
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',new.id,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_attachment_purge_note
CREATE TRIGGER sync_attachment_purge_note AFTER DELETE ON attachment
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND EXISTS(SELECT 1 FROM note WHERE id=old.noteId) BEGIN
    INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
    VALUES('note',old.noteId,1,0)
    ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0;
END;

-- trigger sync_attachment_update
CREATE TRIGGER sync_attachment_update AFTER UPDATE OF filename,noteId,deletedAt,uti,width,height,byteSize,sha256,ocrText ON attachment
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) AND (new.filename IS NOT old.filename OR new.noteId IS NOT old.noteId OR new.deletedAt IS NOT old.deletedAt OR new.uti IS NOT old.uti OR new.width IS NOT old.width OR new.height IS NOT old.height OR new.byteSize IS NOT old.byteSize OR new.sha256 IS NOT old.sha256 OR new.ocrText IS NOT old.ocrText) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',new.id,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_crypto_envelope_delete
CREATE TRIGGER sync_crypto_envelope_delete AFTER DELETE ON crypto_envelope
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,1)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_crypto_envelope_insert
CREATE TRIGGER sync_crypto_envelope_insert AFTER INSERT ON crypto_envelope
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_crypto_envelope_update
CREATE TRIGGER sync_crypto_envelope_update AFTER UPDATE ON crypto_envelope
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_external_ref_delete
CREATE TRIGGER sync_external_ref_delete AFTER DELETE ON external_ref
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('externalRef',json_array(old.source,old.externalId),1,1)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_external_ref_insert
CREATE TRIGGER sync_external_ref_insert AFTER INSERT ON external_ref
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('externalRef',json_array(new.source,new.externalId),1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_external_ref_update
CREATE TRIGGER sync_external_ref_update AFTER UPDATE ON external_ref
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('externalRef',json_array(new.source,new.externalId),1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_note_delete
CREATE TRIGGER sync_note_delete AFTER DELETE ON note
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',old.id,1,1)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_note_insert
CREATE TRIGGER sync_note_insert AFTER INSERT ON note
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',new.id,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_note_pin_delete
CREATE TRIGGER sync_note_pin_delete AFTER DELETE ON note_pin
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND EXISTS(SELECT 1 FROM note WHERE id=old.noteId) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',old.noteId,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_note_pin_insert
CREATE TRIGGER sync_note_pin_insert AFTER INSERT ON note_pin
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND EXISTS(SELECT 1 FROM note WHERE id=new.noteId) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',new.noteId,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_note_update
CREATE TRIGGER sync_note_update AFTER UPDATE OF text,title,createdAt,modifiedAt,location,trashedAt,archivedAt,isPinnedGlobal,isReadOnly,isLocked,encryptedPayload,deletedAt ON note
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) AND (new.text IS NOT old.text OR new.title IS NOT old.title OR new.createdAt IS NOT old.createdAt OR new.modifiedAt IS NOT old.modifiedAt OR new.location IS NOT old.location OR new.trashedAt IS NOT old.trashedAt OR new.archivedAt IS NOT old.archivedAt OR new.isPinnedGlobal IS NOT old.isPinnedGlobal OR new.isReadOnly IS NOT old.isReadOnly OR new.isLocked IS NOT old.isLocked OR new.encryptedPayload IS NOT old.encryptedPayload OR new.deletedAt IS NOT old.deletedAt) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',new.id,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_setting_delete
CREATE TRIGGER sync_setting_delete AFTER DELETE ON setting
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (old.key IN ('hideMarkdown','showNoteCounts','autoSortTodos','showHeadingLevels','autocomplete','startNoteTemplate','tagPosition','noteSort')) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('setting',old.key,1,1)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_setting_insert
CREATE TRIGGER sync_setting_insert AFTER INSERT ON setting
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (new.key IN ('hideMarkdown','showNoteCounts','autoSortTodos','showHeadingLevels','autocomplete','startNoteTemplate','tagPosition','noteSort')) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('setting',new.key,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_setting_update
CREATE TRIGGER sync_setting_update AFTER UPDATE ON setting
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (new.key IN ('hideMarkdown','showNoteCounts','autoSortTodos','showHeadingLevels','autocomplete','startNoteTemplate','tagPosition','noteSort')) AND (new.value IS NOT old.value) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('setting',new.key,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_staged_attachment
CREATE TRIGGER sync_staged_attachment AFTER INSERT ON staging_batch
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) BEGIN
    INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
    SELECT 'attachment',id,1,0 FROM attachment WHERE noteId=new.noteId
    ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0;
END;

-- trigger sync_tag_delete
CREATE TRIGGER sync_tag_delete AFTER DELETE ON tag
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('tagPreference',old.id,1,1)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_tag_insert
CREATE TRIGGER sync_tag_insert AFTER INSERT ON tag
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('tagPreference',new.id,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;

-- trigger sync_tag_update
CREATE TRIGGER sync_tag_update AFTER UPDATE OF displayPath,iconName,isPinned,sortIndex ON tag
WHEN (SELECT accountId IS NOT NULL AND applying = 0 FROM sync_control WHERE id = 1) AND (1) AND (new.displayPath IS NOT old.displayPath OR new.iconName IS NOT old.iconName OR new.isPinned IS NOT old.isPinned OR new.sortIndex IS NOT old.sortIndex) BEGIN
INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('tagPreference',new.id,1,0)
ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone;
END;
