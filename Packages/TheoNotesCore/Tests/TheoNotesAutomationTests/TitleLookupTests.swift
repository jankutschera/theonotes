// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A title given exactly as it was typed (or as `list` prints it) finds its note on every surface:
/// the lookup uses the index's own key, `TitleKey` (Fix B1, R38), not a second spelling of it.
@Suite struct TitleLookupTests {
    static let doubleSpace = "Big  Title"
    static let noBreakSpace = "Meeting\u{00A0}Notes"
    static let tab = "Tab\tTitle"

    private func library() throws -> TestLibrary {
        try TestLibrary.make([
            TestNote(text: "# \(Self.doubleSpace)\nbig"), TestNote(text: "# \(Self.noBreakSpace)\nmeeting"),
            TestNote(text: "# \(Self.tab)\ntab"),
        ])
    }

    private func notes(titled title: String, _ lib: TestLibrary) throws -> Int {
        try lib.library.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE title = ? AND deletedAt IS NULL", arguments: [title]) ?? 0
        }
    }

    @Test func showFindsTitlesWithWhitespaceRunsNoBreakSpacesAndTabsExactlyAsTyped() throws {
        let lib = try library()
        for title in [Self.doubleSpace, Self.noBreakSpace, Self.tab] {
            let id = try lib.id(titled: title)
            let shown = cli(lib, "show", "--title", title, "--fields", "id")
            #expect(shown.exit == 0 && shown.out == id + "\n", "\(title.unicodeScalars.map(\.value))")
        }
        // The collapsed spelling (what a wiki link can say) still finds them.
        #expect(cli(lib, "show", "--title", "Big Title", "--fields", "id").out == (try lib.id(titled: Self.doubleSpace)) + "\n")
        #expect(cli(lib, "show", "--title", "meeting notes", "--fields", "id").out == (try lib.id(titled: Self.noBreakSpace)) + "\n")
    }

    @Test func createIfNotExistsTwiceMakesOneNote() throws {
        let lib = try TestLibrary.make()
        for _ in 0..<2 {
            #expect(cli(lib, "create", Self.doubleSpace, "--if-not-exists", "--fields", "id").exit == 0)
            #expect(cli(lib, "create", Self.noBreakSpace, "--if-not-exists", "--fields", "id").exit == 0)
        }
        #expect(try notes(titled: Self.doubleSpace, lib) == 1)
        #expect(try notes(titled: Self.noBreakSpace, lib) == 1)
    }

    @Test func mcpGetNoteAndAppendFindTheExactTitle() async throws {
        let f = try ToolFixture([TestNote(text: "# \(Self.doubleSpace)\nbig"), TestNote(text: "# \(Self.noBreakSpace)\nm")])
        let got = try await f.ok("get_note", ###"{"title":"Big  Title"}"###)
        #expect(got["metadata"]?["id"]?.string == (try f.lib.id(titled: Self.doubleSpace)))
        let nbsp = try await f.ok("get_note", "{\"title\":\"Meeting\u{00A0}Notes\"}")
        #expect(nbsp["metadata"]?["id"]?.string == (try f.lib.id(titled: Self.noBreakSpace)))
        _ = try await f.ok("append_to_note", ###"{"title":"Big  Title","content":"more"}"###)
        #expect(try f.lib.text(try f.lib.id(titled: Self.doubleSpace)).contains("big\nmore"))
        _ = try await f.ok("create_note", ###"{"title":"Big  Title","ifNotExists":true}"###)
        #expect(try notes(titled: Self.doubleSpace, f.lib) == 1)
    }

    @Test func xCallbackAddTextFindsTheExactTitle() throws {
        let lib = try library()
        let executor = XCallbackExecutor(
            library: lib.library, context: .fixed(TestLibrary.epoch), selectedNoteId: { nil }, clipboard: { nil })
        let url = URL(string: "baerchen://x-callback-url/add-text?title=Big%20%20Title&text=tail&mode=append")!
        let outcome = executor.execute(try XCallbackRequest.parse(url))
        #expect(outcome.success != nil)
        #expect(try lib.text(try lib.id(titled: Self.doubleSpace)).hasSuffix("tail"))
    }

    @Test func templatesAreFoundByTheirExactTitleLockedOnesIncluded() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Daily  Plan\nplan body\n#template"),
            TestNote(text: "# Secret\u{00A0}Plan\n#template", locked: true),
        ])
        let made = cli(lib, "create", "Monday", "--template", "Daily  Plan", "--fields", "content", "--format", "json")
        #expect(made.exit == 0 && made.out.contains("plan body"), "\(made.err)")
        let locked = cli(lib, "create", "Tuesday", "--template", "Secret\u{00A0}Plan")
        #expect(locked.exit == 1 && locked.err.hasPrefix("Error: Note is locked: "), "\(locked.err)")
    }

    /// A row indexed before Fix B1 still carries the uncollapsed key until its text is next saved;
    /// the exact title must find it too.
    @Test func aRowIndexedBeforeFixB1IsFoundByItsExactTitle() throws {
        let lib = try library()
        let id = try lib.id(titled: Self.doubleSpace)
        try lib.library.database.pool.write { db in
            try db.execute(
                sql: "UPDATE note SET titleKey = ? WHERE id = ?", arguments: [CanonicalKey.make(Self.doubleSpace), id])
        }
        #expect(cli(lib, "show", "--title", Self.doubleSpace, "--fields", "id").out == id + "\n")
        #expect(cli(lib, "create", Self.doubleSpace, "--if-not-exists").exit == 0)
        #expect(try notes(titled: Self.doubleSpace, lib) == 1)
    }
}
