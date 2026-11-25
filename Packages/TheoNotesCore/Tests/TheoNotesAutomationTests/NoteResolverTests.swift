// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

@Suite struct NoteResolverTests {
    private func resolve(_ lib: TestLibrary, _ selector: NoteSelector) throws -> Note {
        try lib.library.database.pool.read { db in
            try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
        }
    }

    private func failure(_ lib: TestLibrary, _ selector: NoteSelector) -> AutomationError? {
        do {
            _ = try resolve(lib, selector)
            return nil
        } catch {
            return error as? AutomationError
        }
    }

    @Test func resolvesTheoNotesIdBearIdAndTitle() throws {
        let lib = try TestLibrary.make(
            [TestNote(text: "# Mars\nred")], bearIds: [0: "55F9B083-2D6B-420A-AAFF-115C332B18E6"])
        let id = try lib.id(titled: "Mars")
        #expect(cli(lib, "show", "55f9b083-2d6b-420a-aaff-115c332b18e6", "--fields", "id").out == id + "\n")
        #expect(cli(lib, "show", "55F9B083-2D6B-420A-AAFF-115C332B18E6", "--fields", "id").out == id + "\n")
        #expect(cli(lib, "show", id, "--fields", "id").out == id + "\n")
        #expect(cli(lib, "show", id.uppercased(), "--fields", "id").out == id + "\n")
        #expect(cli(lib, "show", "--title", "MARS", "--fields", "id").out == id + "\n")
    }

    @Test func idReachesEveryLocationButTitleSeesNotesOnly() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Gone", location: .trash), TestNote(text: "# Old", location: .archive),
        ])
        for title in ["Gone", "Old"] {
            let id = try lib.id(titled: title)
            #expect(try resolve(lib, .id(id)).id == id)
            #expect(failure(lib, .title(title))?.message == "No active note has the title \(title). Trashed and archived notes can only be named by ID.")
        }
    }

    @Test func titleLookupPrefersTheMostRecentlyModified() throws {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let lib = try TestLibrary.make([
            TestNote(text: "# Same\nold", modified: older), TestNote(text: "# Same\nnew", modified: newer),
        ])
        #expect(try resolve(lib, .title("same")).text == "# Same\nnew")
    }

    @Test func notFoundMessages() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One")])
        #expect(failure(lib, .id("nope")) == AutomationError(code: .noteNotFound, message: "Note not found: nope"))
        #expect(failure(lib, .title(""))?.code == .noteNotFound)
    }

    @Test func selectorRequiresExactlyOne() throws {
        #expect(try NoteSelector.parse(id: "a", title: nil) == .id("a"))
        #expect(try NoteSelector.parse(id: nil, title: "t") == .title("t"))
        #expect(throws: AutomationError(code: .usage, message: "Note ID or title is required")) {
            try NoteSelector.parse(id: nil, title: nil)
        }
        #expect(throws: AutomationError(code: .usage, message: "Provide note ID or title, not both")) {
            try NoteSelector.parse(id: "a", title: "t")
        }
    }

    @Test func errorsMatchObservedBearcli() throws {
        let lib = try TestLibrary.make()
        #expect(
            cli(lib, "show", "ZZZ-NOPE", "--format", "json").out
                == #"{"error":{"code":"note_not_found","message":"Note not found: ZZZ-NOPE"}}"# + "\n")
        #expect(cli(lib, "show", "ZZZ-NOPE").err == "Error: Note not found: ZZZ-NOPE\n")
        #expect(cli(lib, "show", "--format", "json").exit == 64)
        #expect(cli(lib, "list", "--location", "bogus", "--format", "json").out.contains("Invalid location: bogus"))
        #expect(
            cli(lib, "list", "--fields", "bogus").err
                == "Error: Unknown field: bogus (valid: id, title, locked, tags, length, created, modified, pins, location, todos, done, attachments)\n"
        )
    }

    @Test func usageErrorsComeBeforeLibraryErrors() throws {
        let empty = try TestLibrary.emptyFolder().path
        let usage = runCLI(["baerchen", "--data-dir", empty, "show"])
        #expect(usage.exit == 64 && usage.err == "Error: Note ID or title is required\n")
        let limit = runCLI(["baerchen", "--data-dir", empty, "list", "--limit=-1"])
        #expect(limit.exit == 64 && limit.err == "Error: Limit must be non-negative\n")
        let library = runCLI(["baerchen", "--data-dir", empty, "show", "x"])
        #expect(library.exit == 1 && library.err.hasPrefix("Error: "))
        #expect(runCLI(["baerchen", "--data-dir", empty, "list"]).exit == 1)
        // tags list / pin list: no note named, so the fields are checked before the library.
        for command in ["tags", "pin"] {
            let fields = runCLI(["baerchen", "--data-dir", empty, command, "list", "--fields", "bogus"])
            let valid = command == "tags" ? "tag" : "pin"
            #expect(fields.exit == 64 && fields.err == "Error: Unknown field: bogus (valid: \(valid))\n", "\(command)")
            // The group's default subcommand takes the same path.
            #expect(runCLI(["baerchen", "--data-dir", empty, command, "--fields", "bogus"]).exit == 64, "\(command)")
            // A named note comes first: the library is needed to look it up.
            let named = runCLI(["baerchen", "--data-dir", empty, command, "list", "x", "--fields", "bogus"])
            #expect(named.exit == 1 && named.err.hasPrefix("Error: "), "\(command)")
            #expect(!named.err.contains("Unknown field"), "\(command)")
            let both = runCLI(["baerchen", "--data-dir", empty, command, "list", "x", "--title", "y"])
            #expect(both.exit == 64 && both.err == "Error: Provide note ID or title, not both\n", "\(command)")
        }
        // With a library, a named note that does not exist is reported before a bad field.
        let lib = try TestLibrary.make()
        for command in ["tags", "pin"] {
            let missing = runCLI(["baerchen", "--data-dir", lib.paths.root.path, command, "list", "ZZZ", "--fields", "bogus"])
            #expect(missing.err == "Error: Note not found: ZZZ\n", "\(command)")
        }
    }

    @Test func equalTitlesAndModifiedDatesResolveToTheSmallestId() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Twin\na"), TestNote(text: "# Twin\nb"), TestNote(text: "# Twin\nc")])
        let ids = try lib.library.database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note WHERE title = 'Twin'")
        }
        #expect(ids.count == 3)
        #expect(try resolve(lib, .title("twin")).id == ids.min())
        #expect(cli(lib, "show", "--title", "Twin", "--fields", "id").out == (ids.min() ?? "") + "\n")
    }

    @Test func titlesMatchUnderUnicodeCaseFoldingAndNormalization() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Caf\u{E9}\nx")])
        let id = try lib.firstId()
        for title in ["CAF\u{C9}", "Cafe\u{301}", "cafe\u{301}", "caf\u{E9}"] {
            #expect(try resolve(lib, .title(title)).id == id, "\(title.unicodeScalars.map(\.value))")
        }
        #expect(failure(lib, .title("Cafe"))?.code == .noteNotFound)
    }

    @Test func accessRules() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Secret", locked: true), TestNote(text: "# Fixed", readOnly: true),
            TestNote(text: "# Free"),
        ])
        let locked = try lib.note(try lib.id(titled: "Secret"))
        let readOnly = try lib.note(try lib.id(titled: "Fixed"))
        let free = try lib.note(try lib.id(titled: "Free"))
        #expect(throws: AutomationError(code: .noteLocked, message: "Note is locked: \(locked.id)")) {
            try NoteAccess.requireReadable(locked)
        }
        #expect(throws: AutomationError(code: .noteLocked, message: "Note is locked: \(locked.id)")) {
            try NoteAccess.requireWritable(locked)
        }
        #expect(throws: AutomationError(code: .readOnly, message: "Note is read-only: \(readOnly.id)")) {
            try NoteAccess.requireWritable(readOnly)
        }
        try NoteAccess.requireReadable(readOnly)
        try NoteAccess.requireWritable(free)
    }
}
