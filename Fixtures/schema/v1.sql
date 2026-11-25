-- index note_on_modifiedAt
CREATE INDEX note_on_modifiedAt ON note(modifiedAt);

-- index note_on_titleKey
CREATE INDEX note_on_titleKey ON note(titleKey);

-- table note
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
