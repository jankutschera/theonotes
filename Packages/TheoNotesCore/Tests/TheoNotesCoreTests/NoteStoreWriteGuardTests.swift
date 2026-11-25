// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// `NoteStore.guarded(by:)`: a check inside the write transaction (M5 Task 11), and the
/// multi-tag writes that give such a check one transaction to cover.
@Suite struct NoteStoreWriteGuardTests {
    struct Refused: Error, Equatable { let stage: String }

    let tmp: TempPaths
    let store: NoteStore
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        tmp = try TempPaths()
        store = NoteStore(db: try AppDatabase.inMemory(), notifier: nil, paths: tmp.paths)
    }

    @Test func throwingBeforeCommitRollsBackTheWholeWrite() throws {
        let note = try store.create(text: "# A\nbody", now: t0)
        let guarded = store.guarded { _, stage in
            if stage == .beforeCommit { throw Refused(stage: "commit") }
        }
        #expect(throws: Refused(stage: "commit")) {
            try guarded.updateText(id: note.id, text: "changed", expectedRevision: note.revision, now: t0)
        }
        let after = try #require(try store.note(id: note.id))
        #expect(after.text == "# A\nbody" && after.revision == note.revision)
        #expect(throws: Refused(stage: "commit")) { try guarded.create(text: "new", now: t0) }
        #expect(try store.allNotes().count == 1)
    }

    @Test func throwingAtTheBeginStopsBeforeTheChange() throws {
        let note = try store.create(text: "# A", now: t0)
        let guarded = store.guarded { _, stage in
            if stage == .begin { throw Refused(stage: "begin") }
        }
        #expect(throws: Refused(stage: "begin")) { try guarded.trash([note.id], now: t0) }
        #expect(try store.note(id: note.id)?.location == .notes)
    }

    @Test func theGuardSeesTheStateTheWriteLeaves() throws {
        let note = try store.create(text: "# A", now: t0)
        let seen = Seen()
        let guarded = store.guarded { db, stage in
            let text = try String.fetchOne(db, sql: "SELECT text FROM note WHERE id = ?", arguments: [note.id]) ?? ""
            seen.add("\(stage):\(text)")
        }
        _ = try guarded.updateText(id: note.id, text: "# A\nmore", expectedRevision: note.revision, now: t0)
        #expect(seen.values == ["begin:# A", "beforeCommit:# A\nmore"])
        // The plain store is not guarded.
        _ = try store.updateText(id: note.id, text: "x", expectedRevision: note.revision + 1, now: t0)
        #expect(seen.values.count == 2)
    }

    @Test func guardingAGuardedStoreKeepsTheFirstGuard() throws {
        let note = try store.create(text: "# A", now: t0)
        let seen = Seen()
        let first = store.guarded { _, stage in
            seen.add("first:\(stage)")
            if stage == .beforeCommit { throw Refused(stage: "first") }
        }
        let second = first.guarded { _, stage in seen.add("second:\(stage)") }
        #expect(throws: Refused(stage: "first")) { try second.trash([note.id], now: t0) }
        // Both ran at the start, the first one in front; the first one stopped the commit.
        #expect(seen.values == ["first:begin", "second:begin", "first:beforeCommit"])
        #expect(try store.note(id: note.id)?.location == .notes)
        // The inner store keeps only its own guard.
        #expect(throws: Refused(stage: "first")) { try first.trash([note.id], now: t0) }
        #expect(seen.values.filter { $0.hasPrefix("second") }.count == 1)
    }

    @Test func severalTagsLandInOneTransactionOrNotAtAll() throws {
        let note = try store.create(text: "# A\nbody", now: t0)
        try store.addTags(["one", "two"], to: [note.id], position: .bottom, now: t0)
        #expect(try store.note(id: note.id)?.text == "# A\nbody\n#one\n#two")

        let other = try store.create(text: "# B\nbody", now: t0)
        let guarded = store.guarded { _, stage in
            if stage == .beforeCommit { throw Refused(stage: "commit") }
        }
        #expect(throws: Refused(stage: "commit")) {
            try guarded.addTags(["x", "y"], to: [other.id], position: .bottom, now: t0)
        }
        #expect(try store.note(id: other.id)?.text == "# B\nbody")
        #expect(try store.note(id: other.id)?.revision == other.revision)

        try store.removeTags(["one", "two"], from: [note.id], now: t0)
        #expect(try store.note(id: note.id)?.text == "# A\nbody")
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var values: [String] { lock.withLock { items } }
}
