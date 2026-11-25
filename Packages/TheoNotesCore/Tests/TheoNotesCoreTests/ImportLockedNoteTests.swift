// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Pull from Bear and the Apple Notes re-import write through `replaceImported` /
/// `applyImportedMetadata`. A note locked with the Note Password (`NotePrivacy`) refuses both:
/// nothing may be written beside its encrypted payload (integration merge 2026-10-26).
@Suite struct ImportLockedNoteTests {
    @Test func reimportRefusesANoteLockedWithTheNotePassword() throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let draft = ImportedNoteDraft(
            text: "# Bear\nsecret body #bear", createdAt: .now, modifiedAt: .now, tagPins: ["bear"])
        let note = try store.importNote(draft)
        let access = try NotePrivacy(store: store).setPassword("import-test-password")
        try access.lock(noteId: note.id)
        let locked = try #require(try store.note(id: note.id))

        var update = draft
        update.text = "# Bear\nplaintext from Bear"
        #expect(throws: StoreError.noteLocked(id: note.id)) {
            try store.replaceImported(noteID: note.id, draft: update, expectedRevision: locked.revision)
        }
        update.location = .archive
        #expect(throws: StoreError.noteLocked(id: note.id)) {
            try store.applyImportedMetadata(noteID: note.id, draft: update, expectedRevision: locked.revision)
        }
        let after = try #require(try store.note(id: note.id))
        #expect(after.isLocked && after.text.isEmpty && after.location == .notes)
        #expect(after.revision == locked.revision && after.encryptedPayload == locked.encryptedPayload)
        #expect(try access.note(id: note.id)?.text == "# Bear\nsecret body #bear")
    }
}
