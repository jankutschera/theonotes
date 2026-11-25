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

-- index wiki_link_on_targetKey
CREATE INDEX wiki_link_on_targetKey ON wiki_link(targetKey);

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

-- table note_pin
CREATE TABLE note_pin (
    noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
    tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (noteId, tagId)
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
