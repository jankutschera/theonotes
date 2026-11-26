// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// One of the "getting started" notes a brand-new library starts with.
public struct GettingStartedNote: Sendable, Equatable {
    /// Short stable name, also the stem of the bundled resource.
    public let slug: String
    /// Fixed note id: the same on every device and in every app version.
    public let id: String
    /// The first line of the text, as the note list shows it.
    public let title: String
    public let text: String
    /// Both `createdAt` and `modifiedAt`: fixed, so two devices write identical notes.
    public let stamp: Date
}

public enum GettingStartedError: Error, Equatable {
    /// A bundled text is missing or unreadable: a broken build, not a user problem.
    case resourceMissing(String)
}

/// What `GettingStartedNotes.restoreMissing` did.
public struct GettingStartedRestoration: Sendable, Equatable {
    /// Notes that did not exist (never made, or deleted for good) and were made again.
    public var added: [String]
    /// Notes that were in the Trash and are back in Notes, text untouched.
    public var movedBackFromTrash: [String]
    /// Notes that were already in Notes or in the Archive; left exactly as they are.
    public var alreadyPresent: [String]

    public var changedAnything: Bool { !added.isEmpty || !movedBackFromTrash.isEmpty }
}

extension SettingKey where Value == Bool {
    /// Set, in the same transaction that makes the notes, once a library has been given its getting
    /// started notes. Device-local: not in `Settings.Snapshot`, not synced.
    public static var gettingStartedSeeded: SettingKey<Bool> { .init("gettingStartedSeeded", default: false) }

    /// Set once the first launch of a build with the new texts has looked at the starters. Device-local, not synced.
    public static var gettingStartedUpgraded: SettingKey<Bool> { .init("gettingStartedUpgraded", default: false) }
}

/// The notes a new library contains on first launch, and the menu command that brings back missing
/// ones. Shared by the Mac and iOS apps; the texts are bundled Markdown (`Resources/getting-started-*.md`).
///
/// - Seeded only when the caller says the library was just created AND the library is empty
/// (no note in any place, nothing ever imported) AND it was never seeded.
/// - Never recreated by a launch: only `restoreMissing` (Help ▸ Restore Getting Started Notes) adds
/// missing ones again.
/// - Ordinary notes: editable, unpinned, unlocked, in Notes, with the tag `getting started`.
public enum GettingStartedNotes {
    public static let tag = "getting started"

    struct Entry {
        let slug: String
        let id: String
        let resource: String
    }

    /// Order is the reading order. Ids are literals on purpose: they must never change, so
    /// they are not derived at run time. Each is the SHA-256 of "theonotes-getting-started:1:<slug>",
    /// first 16 bytes, shaped as a version-5 UUID, as `SyncNoteMerge.conflictID` does for copies.
    static let entries: [Entry] = [
        Entry(slug: "welcome", id: "5e9a6e60-abf2-540e-82ef-aaab1a2a77b7", resource: "getting-started-1-welcome"),
        Entry(slug: "write-and-format", id: "f9fd6747-5aac-517f-811e-616b1ed0cb6f", resource: "getting-started-2-write-and-format"),
        Entry(slug: "tags-and-links", id: "aad307cb-32a2-5639-8be0-39cbb28af780", resource: "getting-started-3-tags-and-links"),
        Entry(slug: "find-anything", id: "51b6deb6-bbce-5825-9ec4-519bb427506b", resource: "getting-started-4-find-anything"),
        Entry(slug: "capture-and-next-up", id: "4870293e-d190-5e99-a8d1-81d22e77ab35", resource: "getting-started-5-capture-and-next-up"),
        Entry(slug: "keep-notes-private", id: "4813ad1d-fabd-567a-990d-e99f795342f3", resource: "getting-started-6-keep-notes-private"),
        Entry(slug: "import-export-and-back-up", id: "7b4f0da1-8a33-530f-a081-9d06aeca58de", resource: "getting-started-7-import-export-and-back-up"),
        Entry(slug: "use-with-claude", id: "151e810a-987f-5ae7-a3ec-afd97ea5fa9b", resource: "getting-started-8-use-with-claude"),
        Entry(slug: "ideas-logs-and-references", id: "cbe42bd2-be8f-589a-a3e6-5a7b77d41f51", resource: "getting-started-9-ideas-logs-references"),
        Entry(slug: "example-idea", id: "bfb7c70d-fc6f-5046-b081-b5107afdc3bb", resource: "getting-started-10-example-idea"),
        Entry(slug: "example-log", id: "221557c5-c711-5a1d-b0ba-6347e62da1f4", resource: "getting-started-11-example-log"),
        Entry(slug: "example-reference", id: "f47987a3-ac35-5b16-8fe7-b5650224bdae", resource: "getting-started-12-example-reference"),
    ]

    /// 2026-10-28 12:00:00 UTC, the day the first set was written. A later set of texts keeps these
    /// stamps for notes with the same id.
    static let firstStamp = Date(timeIntervalSince1970: 1_793_188_800)

    /// The ids of all getting started notes, in reading order.
    public static var ids: [String] { entries.map(\.id) }

    /// The texts, read from the bundle. The first note is the newest by stamp (one minute apart), so
    /// the default note list shows them in reading order.
    public static func notes() throws -> [GettingStartedNote] { try load(frozen: nil) }

    /// The texts of the FIRST shipped version, byte for byte (`Resources/starter-v1-*.md`). They are never edited: they are the
    /// oldest merge base of a starter note. A later change of the bundled texts appends a frozen version, it does
    /// not touch this one.
    public static func firstShippedNotes() throws -> [GettingStartedNote] { try load(frozen: 1) }

    /// The texts of the SECOND shipped version (the 1.1 scenario texts, `Resources/starter-v2-*.md`), byte for byte, frozen like the
    /// first set: never edited, a later change of a bundled text appends a v3.
    public static func secondShippedNotes() throws -> [GettingStartedNote] { try load(frozen: 2) }

    private static func load(frozen: Int?) throws -> [GettingStartedNote] {
        try entries.enumerated().map { index, entry in
            let name = frozen.map { "starter-v\($0)-" + entry.resource.dropFirst("getting-started-".count) } ?? entry.resource
            guard let url = Bundle.module.url(forResource: name, withExtension: "md"),
                let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
            else { throw GettingStartedError.resourceMissing(name) }
            let normalized = TextNormalization.normalizeLineEndings(text)
            return GettingStartedNote(
                slug: entry.slug, id: entry.id, title: NoteParser.metadata(for: normalized).title, text: normalized,
                stamp: firstStamp.addingTimeInterval(-Double(index) * 60))
        }
    }

    /// First launch of a brand-new library. Makes all notes and sets `gettingStartedSeeded` in one
    /// transaction, and returns their ids; returns `[]` and changes nothing unless all of these hold:
    /// - `isNewLibrary`: the caller just created the library (Mac: `LibraryLaunch.createsLibraryFolder`;
    ///   never after an import, a restore, a library-folder move or an existing library);
    /// - the library has no note in any place (Notes, Archive, Trash) and no import record;
    /// - the library was not seeded before.
    @discardableResult
    public static func seedNewLibrary(in store: NoteStore, isNewLibrary: Bool) throws -> [String] {
        guard isNewLibrary else { return [] }
        let notes = try notes()
        return try store.write { db in
            guard try !Settings.value(.gettingStartedSeeded, in: db) else { return [] }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") == 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM external_ref") == 0
            else { return [] }
            for note in notes { _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db) }
            try markSeeded(in: db)
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [SettingKey<Bool>.gettingStartedUpgraded.name])
            return notes.map(\.id)
        }
    }

    /// Help ▸ Restore Getting Started Notes. Adds the notes that do not exist (same ids, same stamps),
    /// moves back the ones in the Trash, and leaves every other one exactly as it is: text the person
    /// edited is never overwritten, and Archive counts as present. Safe to run any number of times.
    @discardableResult
    public static func restoreMissing(in store: NoteStore) throws -> GettingStartedRestoration {
        let notes = try notes()
        return try store.write { db in
            var result = GettingStartedRestoration(added: [], movedBackFromTrash: [], alreadyPresent: [])
            for note in notes {
                if let existing = try Note.fetchOne(db, key: note.id) {
                    guard existing.location == .trash else {
                        result.alreadyPresent.append(note.id)
                        continue
                    }
                    try db.execute(
                        sql: "UPDATE note SET location = 'notes', trashedAt = NULL, revision = revision + 1 WHERE id = ?",
                        arguments: [note.id])
                    result.movedBackFromTrash.append(note.id)
                } else {
                    _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db)
                    result.added.append(note.id)
                }
            }
            if result.changedAnything { try markSeeded(in: db) }
            return result
        }
    }

    /// First launch of the build with the new texts: each starter whose content still equals the FIRST shipped text,
    /// exactly (`CloudStarterBase.holdsFirstShippedContent`: an edit, a trash, an archive, a pin, a lock or a tag change makes it
    /// differ), gets the current text, once per library. A deleted starter is not made again, a note that is not a starter is never
    /// looked at, and a starter with edits still in its journal stays. The write is the product's own text write with the note's
    /// fixed stamp, so two devices that upgrade write identical notes and the sync merge collapses them (no conflict copy).
    /// A library bound to an account is left alone unless the coordinator calls with `afterSync`, after a cycle that sent and fetched everything.
    /// Returns the ids replaced; sets the marker in the same transaction, also when nothing was replaced.
    @discardableResult
    public static func upgradeFirstShipped(in store: NoteStore, paths: AppPaths, afterSync: Bool = false) throws -> [String] {
        let pending = Set(ids.filter { (try? paths.hasPendingJournal(noteId: $0)) ?? true })
        let notes = try notes()
        return try store.write { db in
            guard try !Settings.value(.gettingStartedUpgraded, in: db) else { return [] }
            // A library an account owns waits for the coordinator (`afterSync`): at launch nothing was fetched yet, so a write would bring
            // back a starter deleted elsewhere, and before the first-bind guard it would mark the starters as the person's own.
            if !afterSync, try Bool.fetchOne(db, sql: "SELECT accountId IS NOT NULL FROM sync_control WHERE id=1") == true { return [] }
            var replaced: [String] = []
            for note in notes where !pending.contains(note.id) {
                guard let existing = try Note.fetchOne(db, key: note.id), existing.text != note.text,
                    try CloudStarterBase.holdsFirstShippedContent(note.id, in: db)
                else { continue }
                _ = try NoteStore.writeText(id: note.id, text: note.text, expectedRevision: existing.revision, now: note.stamp, in: db)
                replaced.append(note.id)
            }
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [SettingKey<Bool>.gettingStartedUpgraded.name])
            return replaced
        }
    }

    private static func markSeeded(in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [SettingKey<Bool>.gettingStartedSeeded.name])
    }
}
