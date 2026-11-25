// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

struct TestNote {
    var text: String
    var location: NoteLocation = .notes
    var pinned = false
    var locked = false
    var readOnly = false
    var created: Date? = nil
    var modified: Date? = nil
}

/// A throw-away library in a temporary folder; never the real one.
final class TestLibrary: Sendable {
    /// 2026-01-02T03:04:05Z
    static let epoch = Date(timeIntervalSince1970: 1_767_323_045)

    let paths: AppPaths
    let library: AutomationLibrary

    private init(paths: AppPaths, library: AutomationLibrary) {
        self.paths = paths
        self.library = library
    }

    /// An existing, empty folder (no `Baerchen.sqlite`).
    static func emptyFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir.path, isDirectory: true).standardizedFileURL
    }

    /// `bearIds[index]` links `notes[index]` to that Bear id (`external_ref`, source `bear`).
    /// `privacyLock` locks the `locked` notes through `NotePrivacy` (ciphertext payload, purged
    /// index, as the iOS app and sync produce them) instead of the plain `isLocked` flag.
    static func make(_ notes: [TestNote] = [], bearIds: [Int: String] = [:], privacyLock: Bool = false) throws -> TestLibrary {
        let paths = AppPaths(root: try emptyFolder())
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: ChangeNotifier(), paths: paths)
        var toLock: [String] = []
        for (index, spec) in notes.enumerated() {
            let created = spec.created ?? epoch
            let note = try store.create(text: spec.text, now: created)
            switch spec.location {
            case .notes: break
            case .archive: try store.archive([note.id], now: created)
            case .trash: try store.trash([note.id], now: created)
            }
            if spec.pinned { try store.setPinned([note.id], pinned: true) }
            try db.pool.write { db in
                try db.execute(
                    sql: "UPDATE note SET modifiedAt = ?, isReadOnly = ? WHERE id = ?",
                    arguments: [spec.modified ?? created, spec.readOnly, note.id])
                if spec.locked, privacyLock {
                    toLock.append(note.id)
                } else if spec.locked {
                    try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [note.id])
                }
                if let bearId = bearIds[index] {
                    try db.execute(
                        sql: "INSERT INTO external_ref (source, externalId, noteId) VALUES ('bear', ?, ?)",
                        arguments: [bearId, note.id])
                }
            }
        }
        if !toLock.isEmpty {
            try paths.createDirectories()
            let access = try NotePrivacy(store: store).setPassword("test-note-password")
            for id in toLock { try access.lock(noteId: id) }
        }
        let library = try AutomationLibrary.open(dataDir: paths.root.path, environment: [:])
        return TestLibrary(paths: paths, library: library)
    }

    func id(titled title: String) throws -> String {
        let found = try library.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM note WHERE title = ? ORDER BY rowid LIMIT 1", arguments: [title])
        }
        return try #require(found)
    }

    func firstId() throws -> String {
        let found = try library.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM note ORDER BY rowid LIMIT 1")
        }
        return try #require(found)
    }

    func note(_ id: String) throws -> Note {
        try #require(try library.store.note(id: id))
    }

    func text(_ id: String) throws -> String { try note(id).text }
}
