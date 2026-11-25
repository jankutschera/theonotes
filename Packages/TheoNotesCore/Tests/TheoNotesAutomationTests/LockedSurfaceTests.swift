// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// One locked note across the whole automation surface (rulings M5-R49, M5-R81): reads return
/// `note_locked` or leave the note out, writes return `note_locked`, and the title stays listed.
/// Every test runs twice: with the plain `isLocked` flag and with a note locked through
/// `NotePrivacy` (the iOS app's lock: encrypted payload, purged index; integration merge 2026-10-26).
@Suite struct LockedSurfaceTests {
    private struct Fixture {
        let f: ToolFixture
        let fetcher = StubFetcher(Data([1]), name: "a.png")
        let locked: String
        let open: String

        init(privacyLock: Bool) throws {
            f = try ToolFixture(
                [TestNote(text: "# Secret", locked: true), TestNote(text: "# Open\nbody #t")], fetcher: fetcher,
                privacyLock: privacyLock)
            locked = try f.lib.id(titled: "Secret")
            open = try f.lib.id(titled: "Open")
        }

        func run(_ args: [String]) -> CLIResult {
            runCLI(["baerchen", "--data-dir", f.lib.paths.root.path] + args, stdin: Data([1]), fetcher: fetcher)
        }

        func cli(_ args: String...) -> CLIResult { run(args) }

        func quoted(_ value: String) -> String { JSONValue.string(value).serialized(sortedKeys: true) }

        /// The locked note's row in a JSON listing, if the listing has one.
        func lockedRow(_ result: CLIResult) throws -> JSONValue? {
            try result.json().array?.first { $0["id"]?.string == locked }
        }
    }

    private func expectLocked(_ result: CLIResult, _ what: String, _ id: String) {
        #expect(result.exit == 1 && result.err == "Error: Note is locked: \(id)\n", "\(what): exit \(result.exit) \(result.err)")
        #expect(result.outData.isEmpty, "\(what) wrote to stdout")
    }

    @Test(arguments: [false, true]) func everyCLIReadRefusesTheLockedNote(privacyLock: Bool) throws {
        let t = try Fixture(privacyLock: privacyLock)
        let id = t.locked
        expectLocked(t.cli("cat", id), "cat", id)
        expectLocked(t.cli("show", id, "--fields", "id,content"), "show content", id)
        expectLocked(t.cli("outline", id), "outline", id)
        expectLocked(t.cli("search-in", id, "--string", "x"), "search-in", id)
        expectLocked(t.cli("attachments", "list", id), "attachments list", id)
        expectLocked(t.cli("attachments", "save", id, "--filename", "a.png"), "attachments save", id)
        // Without content, `show` still gives the metadata.
        let plain = t.cli("show", id, "--fields", "id,title,locked,length", "--format", "json")
        #expect(plain.exit == 0)
        let json = try plain.json()
        #expect(json["title"] == "Secret" && json["locked"] == "yes" && json["length"] == 0)
    }

    @Test(arguments: [false, true]) func cliListingsKeepTheTitleAndNeverCarryContent(privacyLock: Bool) throws {
        let t = try Fixture(privacyLock: privacyLock)
        let list = t.cli("list", "--format", "json", "--fields", "id,title,locked,content")
        #expect(list.exit == 0, "\(list.err)")
        let row = try #require(try t.lockedRow(list))
        #expect(row["title"] == "Secret" && row["locked"] == "yes")
        #expect(row["content"] == nil || row["content"] == .null || row["content"] == "")
        let openRow = try #require(try list.json().array?.first { $0["id"]?.string == t.open })
        #expect(openRow["content"] == "# Open\nbody #t")
        let plain = t.cli("list")
        #expect(plain.exit == 0 && plain.out.contains("Secret"))
        // A search with the content column: the locked note is left out or has no content.
        let search = t.cli("search", "Secret", "--format", "json", "--fields", "id,title,content")
        #expect(search.exit == 0, "\(search.err)")
        if let hit = try t.lockedRow(search) { #expect(hit["content"] == nil || hit["content"] == .null || hit["content"] == "") }
        let everything = t.cli("search", "body", "--format", "json", "--fields", "id,title,content")
        #expect(everything.exit == 0)
        #expect(try t.lockedRow(everything) == nil)
    }

    @Test(arguments: [false, true]) func everyCLIWriteRefusesTheLockedNote(privacyLock: Bool) throws {
        let t = try Fixture(privacyLock: privacyLock)
        let id = t.locked
        let writes: [[String]] = [
            ["append", id, "--content", "x"],
            ["edit", id, "--find", "S", "--replace", "T"],
            ["overwrite", id, "--content", "x", "--force"],
            ["tags", "add", id, "x"],
            ["tags", "remove", id, "x"],
            ["pin", "add", id, "global"],
            ["pin", "remove", id, "global"],
            ["trash", id],
            ["archive", id],
            ["restore", id],
            ["attachments", "add", id, "--filename", "a.png"],
            ["attachments", "add-url", id, "--url", "https://example.com/a.png"],
            ["attachments", "delete", id, "--filename", "a.png"],
        ]
        for args in writes {
            let result = t.run(args)
            expectLocked(result, args.joined(separator: " "), id)
        }
        #expect(t.fetcher.urls.isEmpty)
        let note = try t.f.lib.note(id)
        #expect(note.isLocked && note.text == "" && note.location == .notes)
    }

    @Test(arguments: [false, true]) func everyMCPReadRefusesTheLockedNote(privacyLock: Bool) async throws {
        let t = try Fixture(privacyLock: privacyLock)
        let q = t.quoted(t.locked)
        let reads: [(String, String)] = [
            ("get_note", ###"{"id":\###(q),"includeContent":true}"###),
            ("read_note_content", ###"{"id":\###(q)}"###),
            ("read_note_outline", ###"{"id":\###(q)}"###),
            ("search_in_note", ###"{"id":\###(q),"string":"x"}"###),
            ("list_attachments", ###"{"id":\###(q)}"###),
        ]
        for (tool, arguments) in reads {
            let error = try await t.f.fail(tool, arguments)
            #expect(error.code == .noteLocked && error.message == "Note is locked: \(t.locked)", "\(tool)")
        }
        // Metadata without content is fine.
        let plain = try await t.f.ok("get_note", ###"{"id":\###(q)}"###)
        #expect(plain["metadata"]?["title"] == "Secret" && plain["metadata"]?["locked"] == .bool(true))
        // Listings: counted and titled, never with content.
        let list = try await t.f.ok("list_notes")
        let titles = list["metadata"]?.array?.compactMap { $0["title"]?.string } ?? []
        #expect(titles.contains("Secret") && list["total"] == 2)
        let withContent = try await t.f.ok("list_notes", ###"{"includeContent":true}"###)
        #expect(withContent["total"] == 2)
        let contentTitles = withContent["notes"]?.array?.compactMap { $0["metadata"]?["title"]?.string } ?? []
        #expect(contentTitles == ["Open"])
        let found = try await t.f.ok("search_notes", ###"{"query":"body","includeContent":true}"###)
        let foundTitles = found["resultsWithContent"]?.array?.compactMap { $0["note"]?["metadata"]?["title"]?.string } ?? []
        #expect(foundTitles == ["Open"])
        let plainSearch = try await t.f.ok("search_notes", ###"{"query":"body"}"###)
        #expect(plainSearch["total"] == 1)
    }

    @Test(arguments: [false, true]) func everyMCPWriteRefusesTheLockedNote(privacyLock: Bool) async throws {
        let t = try Fixture(privacyLock: privacyLock)
        let f = t.f
        let id = t.locked
        let own = t.quoted(id)
        let writes: [(String, String)] = [
            ("append_to_note", ###"{"id":\###(own),"content":"x"}"###),
            ("overwrite_note", ###"{"id":\###(own),"content":"x","baseHash":"abcdef0"}"###),
            ("edit_note", ###"{"id":\###(own),"edits":[{"find":"S","replace":"T"}]}"###),
            ("add_pins", ###"{"id":\###(own),"targets":["global"]}"###),
            ("remove_pins", ###"{"id":\###(own),"targets":["global"]}"###),
            ("archive_note", ###"{"id":\###(own)}"###),
            ("trash_note", ###"{"id":\###(own)}"###),
            ("restore_note", ###"{"id":\###(own)}"###),
            ("add_tags", ###"{"id":\###(own),"tags":["x"]}"###),
            ("remove_tags", ###"{"id":\###(own),"tags":["x"]}"###),
            ("add_attachment_from_url", ###"{"id":\###(own),"url":"https://example.com/a.png"}"###),
            ("delete_attachment", ###"{"id":\###(own),"filename":"a.png"}"###),
        ]
        for (tool, arguments) in writes {
            let error = try await f.fail(tool, arguments)
            #expect(error.code == .noteLocked, "\(tool): \(error.code.rawValue) \(error.message)")
        }
        #expect(t.fetcher.urls.isEmpty)
        let note = try f.lib.note(id)
        #expect(note.isLocked && note.text == "" && note.location == .notes)
    }
}
