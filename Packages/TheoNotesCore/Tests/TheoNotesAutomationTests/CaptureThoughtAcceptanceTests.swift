// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Spec section 9, bullet 7 (C18): `capture_thought` with only `text` stores one note and stops.
/// There is no model and no network: the URL fetcher the automation layer would use for downloads
/// is a recorder that must stay silent.
@Suite struct CaptureThoughtAcceptanceTests {
    private func count(_ f: ToolFixture) throws -> Int {
        try f.lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") ?? 0 }
    }

    @Test func onlyTextCreatesOneNoteWithNoNetworkOrModel() async throws {
        let stub = StubFetcher(Data([1]), name: "x.png")
        let f = try ToolFixture([TestNote(text: "# Existing\nbody")], fetcher: stub)
        let before = try count(f)
        // Words with an unfinished tail, an address and a tag-like word: none of it may be completed,
        // fetched, titled, summarised or filed.
        let text = "ring Ana about https://example.com/page and the #loose-end  "

        let made = try await f.ok("capture_thought", ###"{"text":"\###(text)"}"###)

        let id = try #require(made["id"]?.string)
        #expect(try count(f) == before + 1)
        // Stored byte for byte; the first line is the title; the source is the tool.
        #expect(Array(try f.lib.text(id).utf8) == Array(text.utf8))
        #expect(made["content"] == .string(text))
        #expect(made["title"] == .string("ring Ana about https://example.com/page and the #loose-end"))
        #expect(try f.lib.library.store.captureSource(noteId: id) == .mcp)
        // No network: the link in the text was not fetched, and nothing was attached.
        #expect(stub.urls.isEmpty)
        #expect(made["attachments"] == .array([]))
        // The existing note is untouched.
        let existing = try f.lib.id(titled: "Existing")
        #expect(try f.lib.text(existing) == "# Existing\nbody")
    }
}
