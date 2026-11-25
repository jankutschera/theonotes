// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Jan's decision (2026-10-26, review I4): a locked note keeps its title and tags visible, like
/// Bear: in the sidebar's tag counts and in an MCP tag scope. Only the body is hidden.
@Suite struct LockedNoteTagsTests {
    @Test func aNoteLockedWithTheNotePasswordKeepsItsTagsInCountsAndMCPScope() async throws {
        let f = try ToolFixture(
            [TestNote(text: "# Secret\n#work/plans", locked: true), TestNote(text: "# Open\n#work")],
            scope: NoteScope(onlyTags: ["work"], excludeTags: []), privacyLock: true)
        let store = f.lib.library.store
        let secret = try f.lib.id(titled: "Secret")
        let note = try #require(try store.note(id: secret))
        #expect(note.isLocked && note.text.isEmpty && note.encryptedPayload != nil)
        // Sidebar: the tag and its parent count the locked note.
        let tree = try await f.lib.library.database.pool.read { try LibraryQueries.tagTree(db: $0) }
        let work = try #require(tree.first { $0.path == "work" })
        let plans = try #require(work.children.first { $0.path == "work/plans" })
        #expect(plans.noteCount == 1 && work.noteCount == 2, "work/plans \(plans.noteCount), work \(work.noteCount)")
        // MCP scope `work`: the locked note is in it by title, without content.
        let list = try await f.ok("list_notes")
        let titles = list["metadata"]?.array?.compactMap { $0["title"]?.string } ?? []
        #expect(Set(titles) == ["Secret", "Open"] && list["total"] == 2)
        let error = try await f.fail("read_note_content", ###"{"id":"\###(secret)"}"###)
        #expect(error.code == .noteLocked)
    }
}
