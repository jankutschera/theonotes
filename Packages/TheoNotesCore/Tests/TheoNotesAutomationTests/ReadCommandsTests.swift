// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

@Suite struct ReadCommandsTests {
    private func lines(_ result: CLIResult) -> [String] {
        result.out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func titles(_ lib: TestLibrary, _ args: String...) throws -> [String] {
        let rows = try run(lib, args + ["--fields", "title", "--format", "json"]).json().array ?? []
        return rows.compactMap { $0["title"]?.string }
    }

    private func run(_ lib: TestLibrary, _ args: [String]) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
    }

    // MARK: list

    @Test func listJsonShapeOrderAndTypes() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Ä — 😀\n- [ ] a\n- [x] b\n#work/x #multi word#", pinned: true)
        ])
        let row = try #require(cli(lib, "list", "--fields", "all", "--format", "json").json().array?.first)
        #expect(
            row.keys == [
                "id", "title", "locked", "tags", "length", "created", "modified", "pins", "location", "todos", "done",
                "attachments",
            ])
        #expect(row["locked"] == .string("no") && row["pins"] == .array([.string("global")]) && row["todos"] == .int(1))
        #expect(row["done"] == .int(1) && row["location"] == .string("notes") && row["attachments"] == .array([]))
        #expect(row["tags"] == .array([.string("#multi word#"), .string("#work"), .string("#work/x")]))
        #expect(row["title"] == .string("Ä — 😀"))
        #expect(row["created"] == .string("2026-01-02T03:04:05Z") && row["modified"] == .string("2026-01-02T03:04:05Z"))
        #expect(row["length"] == .int(try lib.text(row["id"]!.string!).utf8.count))
    }

    @Test func defaultFieldsAndOrderOfFields() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One\n#a")])
        let id = try lib.firstId()
        #expect(cli(lib, "list").out == "\(id)\tOne\t#a\t\(try lib.text(id).utf8.count)\n")
        #expect(cli(lib, "list", "--fields", "title,id").out == "One\t\(id)\n")
        #expect(cli(lib, "list", "--format", "csv", "--fields", "id,title").out == "id,title\n\(id),One\n")
        #expect(cli(lib, "list", "--fields", "content").out == "# One\\n#a\n")
        #expect(try cli(lib, "list", "--fields", "all,content", "--format", "json").json().array?.first?.keys.last == "content")
    }

    @Test func countLimitZeroAndEmptyResults() throws {
        let lib = try TestLibrary.make([TestNote(text: "a"), TestNote(text: "b")])
        #expect(cli(lib, "list", "--count").out == "2\n")
        #expect(cli(lib, "list", "--count", "--format", "csv").out == "count\n2\n")
        #expect(cli(lib, "list", "--count", "--format", "json").out == #"{"count":2}"# + "\n")
        #expect(cli(lib, "list", "--count", "--fields", "bogus").out == "2\n")
        #expect(cli(lib, "list", "-n", "0", "--format", "json").out == "" && cli(lib, "list", "-n", "0").exit == 0)
        #expect(cli(lib, "list", "-n", "0").out == "" && cli(lib, "list", "-n", "0").err == "")
        #expect(cli(lib, "list", "--tag", "nothing").err == "No notes found.\n")
        #expect(cli(lib, "list", "--tag", "nothing", "--format", "json").out == "[]\n")
        #expect(cli(lib, "search", "--query", "zzqq").err == "No notes found.\n")
        #expect(cli(lib, "search", "--query", "zzqq", "--format", "json").out == "[]\n")
        #expect(cli(lib, "search", "zzqq", "--count").out == "0\n")
    }

    @Test func limitOffsetAndLocation() throws {
        let t = { (n: Int) in Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 100) }
        let lib = try TestLibrary.make([
            TestNote(text: "# A", modified: t(1)), TestNote(text: "# B", modified: t(2)),
            TestNote(text: "# C", modified: t(3)), TestNote(text: "# T", location: .trash, modified: t(4)),
            TestNote(text: "# R", location: .archive, modified: t(5)),
        ])
        #expect(try titles(lib, "list") == ["C", "B", "A"])
        #expect(try titles(lib, "list", "-n", "2") == ["C", "B"])
        #expect(try titles(lib, "list", "-n", "2", "-o", "1") == ["B", "A"])
        #expect(try titles(lib, "list", "--offset", "5") == [])
        #expect(try titles(lib, "list", "-l", "trash") == ["T"])
        #expect(try titles(lib, "list", "--location", "archive") == ["R"])
        #expect(try titles(lib, "list", "--location", "all") == ["R", "T", "C", "B", "A"])
        #expect(cli(lib, "list", "-l", "all", "--count").out == "5\n")
        #expect(cli(lib, "list", "-n", "1", "--count").out == "3\n")
    }

    @Test func negativeLimitAndOffsetAreCommandUsageErrors() throws {
        let lib = try TestLibrary.make()
        for args in [["list", "--limit=-1"], ["list", "-n=-1"], ["search", "x", "--limit=-1"]] {
            let result = run(lib, args)
            #expect(result.exit == 64 && result.err == "Error: Limit must be non-negative\n" && result.out == "")
        }
        let json = cli(lib, "list", "--limit=-1", "--format", "json")
        #expect(json.exit == 64 && json.out == #"{"error":{"code":"usage","message":"Limit must be non-negative"}}"# + "\n")
        #expect(cli(lib, "list", "--offset=-1").err == "Error: Offset must be non-negative\n")
    }

    @Test func tagFilterMatchesDescendantsAndStripsHashes() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# P\n#work"), TestNote(text: "# C\n#work/sub"), TestNote(text: "# M\n#multi word#"),
            TestNote(text: "# N\n#network"), TestNote(text: "# Z\nnone"),
        ])
        #expect(Set(try titles(lib, "list", "--tag", "work")) == ["P", "C"])
        #expect(Set(try titles(lib, "list", "--tag", "#work")) == ["P", "C"])
        #expect(Set(try titles(lib, "list", "--tag", " #WORK# ")) == ["P", "C"])
        #expect(try titles(lib, "list", "--tag", "work/sub") == ["C"])
        #expect(try titles(lib, "list", "--tag", "multi word") == ["M"])
        #expect(try titles(lib, "list", "--tag", "#multi word#") == ["M"])
    }

    // MARK: sort

    @Test func sortParsingAndDirections() throws {
        let t = { (n: Int) in Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 100) }
        let lib = try TestLibrary.make([
            TestNote(text: "# B", created: t(3), modified: t(1)),
            TestNote(text: "# A", created: t(2), modified: t(2)),
            TestNote(text: "# C", created: t(1), modified: t(3)),
            TestNote(text: "# P", pinned: true, created: t(0), modified: t(0)),
        ])
        #expect(try titles(lib, "list") == ["P", "C", "A", "B"])
        #expect(try titles(lib, "list", "--sort", "modified:asc") == ["P", "B", "A", "C"])
        #expect(try titles(lib, "list", "--sort", "created") == ["B", "A", "C", "P"])
        #expect(try titles(lib, "list", "--sort", "created:asc") == ["P", "C", "A", "B"])
        // A bare title is descending (ruling M5-R28).
        #expect(try titles(lib, "list", "--sort", "title") == ["P", "C", "B", "A"])
        #expect(try titles(lib, "list", "--sort", "title:desc") == ["P", "C", "B", "A"])
        #expect(try titles(lib, "list", "--sort", "title:asc") == ["A", "B", "C", "P"])
        #expect(try titles(lib, "list", "--sort", "pinned:asc,title:asc") == ["A", "B", "C", "P"])
        #expect(try titles(lib, "list", "-s", "created:desc,title:asc") == ["B", "A", "C", "P"])
    }

    @Test func invalidSortMessages() throws {
        let lib = try TestLibrary.make()
        let field = cli(lib, "list", "--sort", "bogus")
        #expect(field.exit == 64 && field.err == "Error: invalid sort field: bogus (valid: pinned, modified, created, title)\n")
        let order = cli(lib, "list", "--sort", "title:sideways", "--format", "json")
        #expect(order.out == #"{"error":{"code":"usage","message":"invalid sort order: sideways (valid: asc, desc)"}}"# + "\n")
        #expect(try SortSpec.parse(nil).orderBy() == "n.isPinnedGlobal DESC, n.modifiedAt DESC, n.id ASC")
        #expect(try SortSpec.parse("title,created:asc").orderBy() == "n.titleKey DESC, n.createdAt ASC, n.id ASC")
    }

    // MARK: search

    @Test func searchMatchesCountsAndLocation() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Eagle\neel"), TestNote(text: "# Todo\n- [ ] open"),
            TestNote(text: "# Gone\neel", location: .trash), TestNote(text: "# Old\neel", location: .archive),
        ])
        let hits = try cli(lib, "search", "e", "--fields", "title,matches", "--format", "json").json().array ?? []
        let counts = Dictionary(uniqueKeysWithValues: hits.map { ($0["title"]!.string!, $0["matches"]!) })
        #expect(counts["Eagle"] == .int(4) && counts["Todo"] == .int(1))
        #expect(counts["Gone"] == nil && counts["Old"] == nil)
        #expect(cli(lib, "search", "@todo", "--fields", "title,matches").out == "Todo\t0\n")
        let all = try cli(lib, "search", "eel", "--location", "all", "--fields", "title", "--format", "json").json().array ?? []
        #expect(Set(all.compactMap { $0["title"]?.string }) == ["Eagle", "Gone", "Old"])
        #expect(cli(lib, "search", "eel", "-l", "trash", "--fields", "title,matches").out == "Gone\t1\n")
        // Default fields end in `matches`.
        #expect(cli(lib, "search", "open").out.hasSuffix("\t1\n"))
    }

    /// Observed against Bear (M5-R232): `tags` has the direct tags and every ancestor of a nested
    /// one, in the library's spelling, in code point order.
    @Test func listedTagsCarryAncestorsInTheTableSpellingSorted() {
        let table = ["work": "Work", "work/sub": "Work/Sub"]
        #expect(NoteRecord.listedTags(direct: ["work/sub/deep", "b", "a b"], spelling: table) == ["Work", "Work/Sub", "a b", "b", "work/sub/deep"])
        #expect(NoteRecord.listedTags(direct: ["x/y", "x"], spelling: [:]) == ["x", "x/y"])
        #expect(NoteRecord.listedTags(direct: [], spelling: table) == [])
    }

    private func count(_ query: String, in text: String) -> Int {
        SearchMatchCounter.count(SearchMatchCounter.needles(SearchParser.parse(query)), in: text)
    }

    /// Observed against Bear on 234 real notes (M5-R234): case ignored, diacritics not, `ß` = `ss`
    /// only for a needle with `ss` or `ß`, a quoted single word counts whole words, other phrases
    /// plain substrings.
    @Test func searchMatchCounterRules() {
        #expect(count("e", in: "Eagle eel") == 4)
        #expect(count("aa", in: "aaaa") == 2)
        #expect(count("cafe", in: "Café CAFE cafe") == 2)
        #expect(count("fur für", in: "für fur FÜR") == 1 + 2)
        #expect(count("a b", in: "abab") == 4)
        #expect(count("#tag x", in: "#tag x") == 2)
        #expect(count("@todo", in: "text") == 0)
        // Tags count their occurrences: with descendants, exact, subtags only; a negated one not.
        #expect(count("#type", in: "#type #type/ref #typed #other/type") == 2)
        #expect(count("!#type", in: "#type #type/ref #type") == 2)
        #expect(count("#*/ref", in: "#a/ref #ref #a/b/ref #a/reference x/Ref") == 4)
        #expect(count("#type -#other", in: "#type #other #type") == 2)
        #expect(count("\"build\"", in: "build_x build-x x_build 5build build") == 2)
        #expect(count("x", in: "") == 0)
        #expect(count("s", in: "Straße strasse") == 4)
        #expect(count("ß", in: "Straße strasse") == 2)
        #expect(count("strasse", in: "Straße strasse") == 2)
        #expect(count("\"build\"", in: "build building Build, builds rebuild") == 2)
        #expect(count("\"in a\"", in: "in a pin a In A") == 3)
        #expect(count("\"adhd-founder\"", in: "adhd-founder, ADHD-Founder-x") == 2)
        #expect(count("build", in: "build building") == 2)
    }

    @Test func searchQueryArgumentRules() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Dash\n-draft here"), TestNote(text: "# Other\nplain")])
        #expect(cli(lib, "search").err == "Error: Query is required\n")
        #expect(cli(lib, "search", "a", "--query", "b").err == "Error: Specify the query as a positional argument or --query, not both\n")
        // A leading dash is a negation: notes without "draft".
        #expect(cli(lib, "search", "--query", "-draft", "--fields", "title").out == "Other\n")
        #expect(cli(lib, "search", "--query=-draft", "--fields", "title").out == "Other\n")
    }

    @Test func searchKeepsOcrAndTitleModifiers() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Invoice\nbody words"), TestNote(text: "# Other\ninvoice inside")])
        #expect(Set(try titles(lib, "search", "invoice")) == ["Invoice", "Other"])
        #expect(try titles(lib, "search", "@title invoice") == ["Invoice"])
        #expect(try titles(lib, "search", "@ocr invoice") == [])
    }

    // MARK: show, tags, pins

    @Test func showOutputFormats() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One\n#a #b c")])
        let id = try lib.firstId()
        #expect(cli(lib, "show", id).out == "\(id)\tOne\t#a,#b\n")
        #expect(cli(lib, "show", id, "--format", "csv").out == "id,title,tags\n\(id),One,\"#a,#b\"\n")
        #expect(cli(lib, "show", id, "--format", "json").out == ##"{"id":"\##(id)","title":"One","tags":["#a","#b"]}"## + "\n")
        #expect(cli(lib, "show", "--title", "one", "--fields", "content").out == "# One\\n#a #b c\n")
        let both = cli(lib, "show", id, "--title", "One")
        #expect(both.exit == 64 && both.err == "Error: Provide note ID or title, not both\n")
    }

    @Test func tagsListAndPinList() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# One\n#work/x #multi word#", pinned: true), TestNote(text: "# Two\n#alpha"),
            TestNote(text: "# Three"), TestNote(text: "# Trashed\n#gone", location: .trash),
        ])
        let one = try lib.id(titled: "One")
        let three = try lib.id(titled: "Three")
        #expect(cli(lib, "tags", "list").out == "#alpha\n#multi word#\n#work\n#work/x\n")
        #expect(cli(lib, "tags", "list", "--format", "json").out == ##"[{"tag":"#alpha"},{"tag":"#multi word#"},{"tag":"#work"},{"tag":"#work/x"}]"## + "\n")
        #expect(cli(lib, "tags", "list", "--count").out == "4\n")
        #expect(cli(lib, "tags", "list", one).out == "#multi word#\n#work\n#work/x\n")
        #expect(cli(lib, "tags", "list", "--title", "two", "--count", "--format", "json").out == #"{"count":1}"# + "\n")
        #expect(cli(lib, "tags", "list", three).out == "" && cli(lib, "tags", "list", three).err == "")
        #expect(cli(lib, "tags", "list", three, "--format", "json").out == "[]\n")
        #expect(cli(lib, "tags", one).out == "#multi word#\n#work\n#work/x\n")

        // Pins: the global pin, and one tag pin written the way the app stores it.
        try lib.library.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO note_pin (noteId, tagId) SELECT ?, id FROM tag WHERE pathKey = 'multi word'",
                arguments: [one])
        }
        #expect(cli(lib, "pin", "list").out == "global\n#multi word#\n")
        #expect(cli(lib, "pin", "list", "--format", "json").out == ##"[{"pin":"global"},{"pin":"#multi word#"}]"## + "\n")
        #expect(cli(lib, "pin", "list", one).out == "global\n#multi word#\n")
        #expect(cli(lib, "pin").out == "global\n#multi word#\n")
        let unpinned = cli(lib, "pin", "list", three)
        #expect(unpinned.exit == 0 && unpinned.out == "" && unpinned.err == "")
        #expect(cli(lib, "pin", "list", three, "--format", "json").out == "[]\n")
        #expect(cli(lib, "pin", "list", "--fields", "bogus").err == "Error: Unknown field: bogus (valid: pin)\n")
    }

    /// The global pin and a pin in a tag that happens to be called `global` are different contexts.
    @Test func aTagNamedGlobalIsNotTheGlobalPin() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One\n#global", pinned: true), TestNote(text: "# Two\n#global")])
        let one = try lib.id(titled: "One")
        let two = try lib.id(titled: "Two")
        try lib.library.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO note_pin (noteId, tagId) SELECT ?, id FROM tag WHERE pathKey = 'global'",
                arguments: [two])
        }
        #expect(cli(lib, "pin", "list", two).out == "#global\n")
        #expect(cli(lib, "pin", "list", one).out == "global\n")
        #expect(cli(lib, "pin", "list").out == "global\n#global\n")
        #expect(cli(lib, "show", two, "--fields", "pins").out == "#global\n")
        let record = try lib.library.database.pool.read { db in
            try NoteRecord.load(
                try Note.fetchOne(db, key: two)!, db: db,
                attachments: AttachmentStore(paths: lib.paths, database: lib.library.database))
        }
        #expect(record.pins == [.tag("global")] && record.pins != [.global])
        #expect(record.mcpMetadata()["pins"] == .array([.string("global")]))
    }

    @Test func countAndZeroLimitDoNoRowWork() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One\neel"), TestNote(text: "# Two\neel")])
        try lib.library.database.pool.read { db in
            let list = try AutomationQueries.list(
                location: .notes, tag: nil, sort: SortSpec.parse(nil), limit: 0, offset: 0, scope: .unrestricted, db: db)
            #expect(list.ids.isEmpty && list.total == 2)
            let search = try AutomationQueries.search(
                "eel", location: .notes, sort: SortSpec.parse(nil), limit: 0, offset: 0, scope: .unrestricted,
                now: TestLibrary.epoch, calendar: Calendar(identifier: .gregorian), db: db)
            #expect(search.hits.isEmpty && search.total == 2)
            // Without the total, the rows alone come back.
            let rows = try AutomationQueries.search(
                "eel", location: .notes, sort: SortSpec.parse(nil), limit: 1, offset: 0, scope: .unrestricted,
                now: TestLibrary.epoch, calendar: Calendar(identifier: .gregorian), countTotal: false, db: db)
            #expect(rows.hits.count == 1 && rows.hits[0].matches == 1 && rows.total == 1)
        }
        #expect(cli(lib, "search", "eel", "--count", "-n", "1").out == "2\n")
        #expect(cli(lib, "list", "--count", "-n", "1").out == "2\n")
        #expect(cli(lib, "search", "eel", "-n", "0").out == "")
    }

    @Test func pinListIsEmptyWhenNothingIsPinned() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One")])
        let result = cli(lib, "pin", "list")
        #expect(result.exit == 0 && result.out == "" && result.err == "")
    }

    // MARK: locked notes

    @Test func lockedNoteIsListedButEveryReadAndWriteFails() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Secret\nx", locked: true)])
        let id = try lib.firstId()
        #expect(cli(lib, "list", "--fields", "id,locked").out == "\(id)\tyes\n")
        let content = cli(lib, "show", id, "--fields", "all,content", "--format", "json")
        #expect(content.exit == 1 && content.out.contains(#""code":"note_locked""#))
        #expect(content.out.contains("Note is locked: \(id)"))
        #expect(cli(lib, "list", "--fields", "id,content").out == "\(id)\t\n")
        #expect(try cli(lib, "list", "--fields", "id,content", "--format", "json").json().array?.first?["content"] == .null)
        #expect(throws: AutomationError.self) { try NoteAccess.requireWritable(lib.note(id)) }
        // Metadata of a locked note is readable.
        #expect(cli(lib, "show", id, "--fields", "id,locked,length").out == "\(id)\tyes\t0\n")
        let note = try lib.note(id)
        let record = try lib.library.database.pool.read { db in
            try NoteRecord.load(
                note, db: db, attachments: AttachmentStore(paths: lib.paths, database: lib.library.database))
        }
        #expect(record.content == nil && record.locked)
    }

    // MARK: records

    @Test func recordFormatsForCliAndMcp() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Note\n- [ ] a\n#work/x #multi word#", pinned: true)])
        let note = try lib.note(try lib.firstId())
        let record = try lib.library.database.pool.read { db in
            try NoteRecord.load(
                note, db: db, attachments: AttachmentStore(paths: lib.paths, database: lib.library.database))
        }
        #expect(record.cliValue("tags") == .list(["#multi word#", "#work", "#work/x"]))
        #expect(record.cliValue("pins") == .list(["global"]))
        #expect(record.cliValue("locked") == .flag(false))
        let meta = record.mcpMetadata()
        #expect(
            meta.keys == [
                "attachments", "created", "done", "id", "length", "location", "locked", "modified", "pins", "tags",
                "title", "todos",
            ])
        #expect(meta["tags"] == .array([.string("multi word"), .string("work"), .string("work/x")]))
        #expect(meta["locked"] == .bool(false) && meta["pins"] == .array([.string("global")]))
    }

    @Test func timestampFormatIsUtcSecondsAndSurvivesOddDates() {
        #expect(NoteRecord.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        #expect(NoteRecord.timestamp(Date(timeIntervalSince1970: 1_767_323_045.9)) == "2026-01-02T03:04:05Z")
        #expect(NoteRecord.timestamp(Date(timeIntervalSince1970: 951_782_400)) == "2000-02-29T00:00:00Z")
        #expect(NoteRecord.timestamp(Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59Z")
    }

    @Test func attachmentsAreTheLinkedFilesThatExist() throws {
        let links = ["pic.png", "gone.png", "doc.pdf", "pic.png"].map(AttachmentMarkdown.link(for:)).joined(separator: "\n")
        let lib = try TestLibrary.make([TestNote(text: "# A\n" + links)])
        let id = try lib.firstId()
        let files = AttachmentStore(paths: lib.paths, database: lib.library.database)
        _ = try files.add(data: Data("x".utf8), filename: "pic.png", to: id)
        _ = try files.add(data: Data("y".utf8), filename: "doc.pdf", to: id)
        let row = cli(lib, "show", id, "--fields", "attachments", "--format", "json")
        #expect(try row.json()["attachments"] == .array([.string("pic.png"), .string("doc.pdf")]))
    }
}
