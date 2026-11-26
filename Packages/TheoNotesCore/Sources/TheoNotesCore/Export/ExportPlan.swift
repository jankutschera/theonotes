// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// What the planner needs to know about one note to name and place it.
public struct ExportCandidate: Sendable, Equatable {
    public var noteId: String
    public var title: String
    /// Direct tags without `#`, in the note's spelling and order.
    public var directTags: [String]
    public var location: NoteLocation
    public var isLocked: Bool

    public init(noteId: String, title: String, directTags: [String], location: NoteLocation, isLocked: Bool) {
        self.noteId = noteId
        self.title = title
        self.directTags = directTags
        self.location = location
        self.isLocked = isLocked
    }
}

/// One file to write: the note, the folders below the chosen destination, and the unique stem.
public struct ExportItem: Sendable, Equatable {
    public var noteId: String
    /// Path components below the chosen destination (empty for a flat selection export).
    public var folder: [String]
    public var stem: String

    public init(noteId: String, folder: [String], stem: String) {
        self.noteId = noteId
        self.folder = folder
        self.stem = stem
    }
}

/// Decides where each exported note goes. Pure: no file system access.
public enum ExportPlan {
    public struct Result: Sendable, Equatable {
        public var items: [ExportItem]
        /// Locked notes left out, in input order.
        public var skippedLocked: [String]

        public init(items: [ExportItem] = [], skippedLocked: [String] = []) {
            self.items = items
            self.skippedLocked = skippedLocked
        }
    }

    /// A selection exports flat, in the order given, whatever the notes' locations.
    public static func selection(_ notes: [ExportCandidate]) -> Result {
        var allocator = StemAllocator()
        var result = Result()
        for note in notes {
            if note.isLocked {
                result.skippedLocked.append(note.noteId)
                continue
            }
            let stem = allocator.claim(ExportNaming.stem(forTitle: note.title))
            result.items.append(ExportItem(noteId: note.noteId, folder: [], stem: stem))
        }
        return result
    }

    /// A tag tree exports into `<last component of root>/` with one folder per tag level. A note is
    /// placed under each direct tag inside the subtree that is not an ancestor of another of its
    /// direct tags inside the subtree (`#workout` + `#workout/cardio` → only `workout/cardio`).
    /// The first folder is spelled as `root` is; deeper ones as the note spells its tag. Only
    /// candidates in Notes are planned, whatever the provider returned. Locked notes are
    /// counted, not planned; they reach the planner through their `note_tag` rows (M9 keeps them).
    public static func tagTree(root: String, notes: [ExportCandidate]) -> Result {
        let rootKey = CanonicalKey.make(root)
        let rootComponents = root.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let rootFolder = ExportNaming.stem(forTitle: rootComponents.last ?? root)
        var allocators: [String: StemAllocator] = [:]
        var result = Result()
        for note in notes where note.location == .notes {
            if note.isLocked {
                result.skippedLocked.append(note.noteId)
                continue
            }
            let inTree = note.directTags.filter {
                let key = CanonicalKey.make($0)
                return key == rootKey || key.hasPrefix(rootKey + "/")
            }
            let keys = inTree.map { CanonicalKey.make($0) }
            for (index, tag) in inTree.enumerated() {
                let isAncestor = keys.indices.contains { other in
                    other != index && keys[other].hasPrefix(keys[index] + "/")
                }
                if isAncestor { continue }
                let below = tag.split(separator: "/", omittingEmptySubsequences: false)
                    .dropFirst(rootComponents.count).map { ExportNaming.stem(forTitle: String($0)) }
                let folder = [rootFolder] + below
                let folderKey = folder.map(CanonicalKey.make).joined(separator: "/")
                let stem = allocators[folderKey, default: StemAllocator()]
                    .claim(ExportNaming.stem(forTitle: note.title))
                result.items.append(ExportItem(noteId: note.noteId, folder: folder, stem: stem))
            }
        }
        return result
    }
}

extension NoteStore {
    /// Candidates for the notes with `ids`, in the order given. Throws `StoreError.noteNotFound`
    /// for an unknown or deleted id.
    public func exportCandidates(ids: [String]) throws -> [ExportCandidate] {
        try db.pool.read { db in
            try ids.map { id in
                guard let note = try Note.fetchOne(
                    db, sql: "SELECT * FROM note WHERE id = ? AND deletedAt IS NULL", arguments: [id])
                else { throw StoreError.noteNotFound(id: id) }
                return Self.candidate(note)
            }
        }
    }

    /// Notes in Notes (not Archive or Trash) carrying `root` directly or through a descendant,
    /// newest `modifiedAt` first.
    public func exportCandidates(tagTree root: String) throws -> [ExportCandidate] {
        try db.pool.read { db in
            let notes = try Note.fetchAll(
                db,
                sql: """
                    SELECT n.* FROM note n
                    WHERE n.location = 'notes' AND n.deletedAt IS NULL AND n.id IN (
                        SELECT nt.noteId FROM note_tag nt JOIN tag t ON t.id = nt.tagId WHERE t.pathKey = ?)
                    ORDER BY n.modifiedAt DESC
                    """,
                arguments: [CanonicalKey.make(root)])
            return notes.map(Self.candidate)
        }
    }

    private static func candidate(_ note: Note) -> ExportCandidate {
        ExportCandidate(
            noteId: note.id, title: note.title,
            directTags: note.isLocked ? [] : NoteParser.metadata(for: note.text).tags,
            location: note.location, isLocked: note.isLocked)
    }
}
