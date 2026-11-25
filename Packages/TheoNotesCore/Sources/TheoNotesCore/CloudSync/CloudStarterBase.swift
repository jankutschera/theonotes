// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

/// The merge base of the Getting Started notes at first contact (CK-R13 amended, CK-R130).
///
/// A note the app made for a new library has a fixed id and fixed stamps and, in the first shipped version, fixed texts. When a
/// device meets the cloud copy of such a note for the first time, it has no base pair, so an empty base would turn an
/// untouched copy against an edited one into a conflict copy, and an untouched copy against a deletion into a resurrection.
/// With the first shipped text set as the base, the ordinary three-way rules already do the right thing: an untouched copy
/// follows whatever the other side did (an edit, a deletion), an edited copy against an untouched one wins, and only two
/// different edits, or an edit against a deletion, can make one conflict copy. A later app version with other texts for the
/// same ids is, against this base, an edit like any other (`GettingStartedNotesTests` pins the digest of the first set, so
/// changing a text without freezing the old one here fails loudly).
///
/// The payloads are not hand-written: they are what the real `seedNewLibrary` makes in a throwaway library, captured by the
/// same function the publisher uses, so they cannot drift from what a device really uploads.
public enum CloudStarterBase {
    /// Payload JSON of each starter note of the FIRST shipped set, by note id, built from the FROZEN texts (`Resources/starter-v1-*.md`,
    /// STARTER-R1), never from the bundled ones: a later change of a bundled text must not move the base. Empty if the throwaway
    /// library failed (the base is then empty, which is the plan's old rule: no loss, possibly one conflict copy).
    static let firstShippedPayloads: [String: Data] = {
        do { return try payloads(of: GettingStartedNotes.firstShippedNotes()) } catch { return [:] }
    }()

    /// Payload JSON of each starter note of the SECOND shipped set (`Resources/starter-v2-*.md`, STARTER-R24), by note id.
    static let secondShippedPayloads: [String: Data] = {
        do { return try payloads(of: GettingStartedNotes.secondShippedNotes()) } catch { return [:] }
    }()

    /// What a device uploads for `notes`: they are made in a throwaway library with the product's own insert and captured by the
    /// publisher's own function, so they cannot drift from the real thing.
    static func payloads(of notes: [GettingStartedNote]) throws -> [String: Data] {
        let database = try AppDatabase.inMemory()
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("starter-base-\(UUID().uuidString)", isDirectory: true))
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        try store.write { db in
            for note in notes { _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db) }
        }
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        return try database.pool.write { db in
            var found: [String: Data] = [:]
            for note in notes {
                let content = try SyncNoteSnapshot.capture(SyncDirty(type: .note, localID: note.id, generation: 1, tombstone: false),
                                                           accountID: "starter-base", vaultKey: key, in: db)
                if let payload = content.payload { found[note.id] = payload }
            }
            return found
        }
    }

    /// Whether `id` names a starter note.
    public static func isStarterNote(_ id: String) -> Bool { GettingStartedNotes.ids.contains(id) }

    /// Payload JSON of every shipped version of each starter note, oldest first: the frozen first set, the frozen second set when it differs, then the texts of this build when
    /// they differ (STARTER-R2). When a bundled text changes in a later release, its old text is frozen as one more resource set and
    /// added here before the new one; nothing already in the list ever changes.
    static let shippedPayloads: [String: [Data]] = {
        var versions: [String: [Data]] = firstShippedPayloads.mapValues { [$0] }
        for (id, payload) in secondShippedPayloads where versions[id]?.last != payload { versions[id, default: []].append(payload) }
        if let current = try? payloads(of: GettingStartedNotes.notes()) {
            for (id, payload) in current where versions[id]?.last != payload { versions[id, default: []].append(payload) }
        }
        return versions
    }()

    /// Whether the library's copy of starter note `id` still has the content of a shipped version, exactly: the person never edited,
    /// trashed, archived, pinned, locked or tagged it differently (any such change makes the payload differ).
    static func holdsShippedContent(_ id: String, in db: Database) throws -> Bool {
        try holds(id, oneOf: shippedPayloads[id], in: db)
    }

    /// Whether the library's copy of starter note `id` still has exactly the content of the FIRST shipped version (STARTER-R18).
    static func holdsFirstShippedContent(_ id: String, in db: Database) throws -> Bool {
        try holds(id, oneOf: firstShippedPayloads[id].map { [$0] }, in: db)
    }

    private static func holds(_ id: String, oneOf versions: [Data]?, in db: Database) throws -> Bool {
        guard let versions, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE id=?)", arguments: [id]) == true,
              let local = try SyncNoteSnapshot.capture(SyncDirty(type: .note, localID: id, generation: 1, tombstone: false), accountID: "starter-base",
                                                       vaultKey: SymmetricKey(data: Data(repeating: 0, count: 32)), in: db).payload
        else { return false }
        let mine = try SyncPayloadCodec.decode(SyncNotePayload.self, from: local)
        return try versions.contains { SyncNoteMerge.identical(mine, try SyncPayloadCodec.decode(SyncNotePayload.self, from: $0)) }
    }

    /// For `Reconciler.firstContactVersions`: the shipped versions of a starter note, sealed for this account.
    public static func sealedVersions(sealer: CloudPayloadSealer, payloads versions: [String: [Data]])
        -> @Sendable (SyncEntityType, String) -> [Data] {
        { type, id in
            guard type == .note, let payloads = versions[id] else { return [] }
            return payloads.compactMap { try? sealer.sealLive($0, type: .note, entityID: id) }
        }
    }
}
