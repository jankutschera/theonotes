// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// `cat`, `outline` and `search-in` end to end, against temporary libraries.
@Suite struct SectionCommandsTests {
    private let doc = NoteSectionsTests.doc

    // MARK: cat

    @Test func byteSliceNeverSplitsAScalar() throws {
        let lib = try TestLibrary.make([TestNote(text: "😀ab")])
        let id = try lib.firstId()
        // 😀 is 4 bytes: 1..<3 lies inside it.
        #expect(cli(lib, "cat", id, "--offset", "1", "--limit", "2", "--format", "json").out == #"{"content":""}"# + "\n")
        #expect(cli(lib, "cat", id, "--offset", "1", "--limit", "4").out == "a")
        #expect(cli(lib, "cat", id, "--offset", "0", "--limit", "5").out == "😀a")
        #expect(cli(lib, "cat", id, "--limit", "3").out == "")
        #expect(cli(lib, "cat", id, "-o", "4").out == "ab")
    }

    @Test func catJsonCarriesHashAndSection() throws {
        let lib = try TestLibrary.make([TestNote(text: doc)])
        let id = try lib.firstId()
        let whole = try cli(lib, "cat", id, "--format", "json").json()
        #expect(whole["hash"] == .string(ContentHash.of(doc)) && whole.keys == ["content", "hash"])
        #expect(whole["content"] == .string(doc))
        let sec = try cli(lib, "cat", id, "--section", "### Mac", "--format", "json").json()
        #expect(sec.keys == ["content", "section", "hash"] && sec["content"] == .string("### Mac\nm\n"))
        #expect(
            sec["section"]
                == .object([("address", .string("### Mac")), ("offset", .int(29)), ("length", .int(10))]))
        #expect(sec["hash"] == .string(ContentHash.of("### Mac\nm\n")))
        #expect(cli(lib, "cat", id).outData == Data(doc.utf8))  // raw, no added newline
        #expect(cli(lib, "cat", id, "--section", "### Mac").out == "### Mac\nm\n")
        #expect(cli(lib, "cat", id, "--section", "# Guide\\npreamble").out == "\nIntro\n\n")  // \n is interpreted
        #expect(cli(lib, "cat", id, "--section=## Install\\n2").out == "## Install\nB\n")
        let range = try cli(lib, "cat", id, "--offset", "2", "--limit", "5", "--format", "json").json()
        #expect(range == .object([("content", .string("Guide"))]))
        #expect(cli(lib, "cat", id, "-n", "7").out == "# Guide")
        #expect(cli(lib, "cat", id, "--format", "csv").out == RecordWriter.csv(header: ["content"], [[.string(doc)]]))
        #expect(cli(lib, "cat", id, "--format", "csv").out.hasPrefix("content\n\"# Guide\n"))
        #expect(
            cli(lib, "cat", id, "--offset", "0", "--section", "## a", "--format", "json").out.contains(
                "Provide address or offset/limit, not both"))
        #expect(cli(lib, "cat", id, "--offset", "99999", "--format", "json").out == #"{"content":""}"# + "\n")
    }

    @Test func catArgumentAndSectionErrors() throws {
        let lib = try TestLibrary.make([TestNote(text: doc)])
        let id = try lib.firstId()
        let missing = cli(lib, "cat", id, "--section", "## Nope", "--format", "json")
        #expect(missing.exit == 1)
        #expect(missing.out == #"{"error":{"code":"not_found","message":"No section matched the address."}}"# + "\n")
        let missingTSV = cli(lib, "cat", id, "--section", "## Nope")
        #expect(missingTSV.exit == 1 && missingTSV.out == "" && missingTSV.err == "Error: No section matched the address.\n")
        let ambiguous = cli(lib, "cat", id, "--section", "## Install")
        #expect(ambiguous.exit == 1 && ambiguous.out == "")
        #expect(
            ambiguous.err
                == "Error: 3 sections match that address; repeat the call with one of the candidates.\n"
                + "  ## Install\\n1\n  ## Install\\n2\n  # Build\\n## Install\n")
        let ambiguousJSON = try cli(lib, "cat", id, "--section", "## Install", "--format", "json").json()
        #expect(ambiguousJSON["error"]?["code"] == .string("ambiguous"))
        #expect(ambiguousJSON["error"]?.keys == ["code", "message", "details"])
        #expect(ambiguousJSON["error"]?["details"]?["candidates"]?.array?.count == 3)
        let empty = cli(lib, "cat", id, "--section", "", "--format", "json")
        #expect(empty.exit == 64 && empty.out.contains("Address must not be empty"))
        let offset = cli(lib, "cat", id, "--offset=-1", "--format", "json")
        #expect(offset.exit == 64 && offset.out.contains("Offset must be non-negative"))
        let limit = cli(lib, "cat", id, "-n=-1", "--offset=-1", "--format", "json")
        #expect(limit.exit == 64 && limit.out.contains("Limit must be non-negative"))
        // Argument errors come before the library: no library at all, still a usage error.
        let noLibrary = runCLI(["baerchen", "--data-dir", try TestLibrary.emptyFolder().path, "cat", "X", "--section", "# a", "-n", "1"])
        #expect(noLibrary.exit == 64 && noLibrary.err.contains("Provide address or offset/limit, not both"))
        // The note resolves before the address is looked at (observed for a bogus id).
        #expect(cli(lib, "cat", "NOPE", "--section", "", "--format", "json").out.contains("note_not_found"))
        #expect(cli(lib, "cat", "--title", "guide", "-n", "1").out == "#")
    }

    // MARK: outline

    @Test func outlineTsvEscapesNewlinesInAddresses() throws {
        let lib = try TestLibrary.make([TestNote(text: doc)])
        let id = try lib.firstId()
        #expect(
            cli(lib, "outline", id).out
                == "# Guide\t0\t52\n# Guide\\npreamble\t8\t8\n## Install\\n1\t16\t23\n## Install\\n1\\npreamble\t27\t2\n"
                + "### Mac\t29\t10\n## Install\\n2\t39\t13\n# Build\t52\t45\n# Build\\n## Install\t60\t37\n")
        #expect(
            cli(lib, "outline", id, "--section", "## Install\\n1", "--format", "csv").out
                == "address,offset,length\n\"## Install\n1\",16,23\n\"## Install\n1\npreamble\",27,2\n### Mac,29,10\n")
        let rows = try cli(lib, "outline", id, "--section", "# Build", "--format", "json").json()
        #expect(rows.array?.compactMap { $0["address"]?.string } == ["# Build", "# Build\n## Install"])
        #expect(rows.array?.first?.keys == ["address", "offset", "length"])
        #expect(cli(lib, "outline", id, "--fields", "length,address", "--section", "### Mac").out == "10\t### Mac\n")
        #expect(cli(lib, "outline", id, "--fields", "bogus").exit == 64)
        // Pasting an address back (TSV form) reaches the same section.
        #expect(cli(lib, "outline", id, "--section", "# Build\\n## Install").out == "# Build\\n## Install\t60\t37\n")
    }

    @Test func outlineOfANoteWithoutHeadingsIsEmpty() throws {
        let lib = try TestLibrary.make([TestNote(text: "just text\n")])
        let id = try lib.firstId()
        let tsv = cli(lib, "outline", id)
        #expect(tsv.exit == 0 && tsv.out == "" && tsv.err == "")
        #expect(cli(lib, "outline", id, "--format", "json").out == "[]\n")
        #expect(cli(lib, "outline", id, "--section", "# A", "--format", "json").out.contains("not_found"))
    }

    // MARK: search-in

    private let searchDoc = "Foo before\n# Top\nfoo in lead\n## Sub\nxFOOx\n"

    /// Observed against Bear: a snippet carries `\n \t \r \\` as two-character escapes in
    /// JSON and CSV too, not only in TSV; the window is counted on the raw text.
    @Test func snippetsCarryTheirEscapesInEveryFormat() throws {
        let lib = try TestLibrary.make([TestNote(text: searchDoc), TestNote(text: "a\tb\\ foo")])
        let id = try lib.firstId()
        let json = try cli(lib, "search-in", id, "--string", "foo", "--context", "4", "--format", "json", "--fields", "snippet").json()
        #expect(json.array?.map { $0["snippet"] } == [.string("Foo b"), .string("p\\nfoo i"), .string("\\nxFOOx\\n")])
        #expect(
            cli(lib, "search-in", id, "--string", "foo", "--context", "4", "--format", "csv", "--fields", "snippet").out
                == "snippet\nFoo b\np\\nfoo i\n\\nxFOOx\\n\n")
        let other = try lib.id(titled: "a\tb\\ foo")
        #expect(cli(lib, "search-in", other, "--string", "foo", "--fields", "snippet").out == "a\\tb\\\\ foo\n")
    }

    @Test func searchInHitsSnippetsSectionsAndCount() throws {
        let lib = try TestLibrary.make([TestNote(text: searchDoc), TestNote(text: "a foo")])
        let id = try lib.firstId()
        let plain = try lib.id(titled: "a foo")
        // Case-insensitive, byte offsets, innermost section (the preamble in a lead); `preamble` above the first heading.
        #expect(
            cli(lib, "search-in", id, "--string", "foo", "--context", "4").out
                == "0\tFoo b\tpreamble\tbody\n17\tp\\nfoo i\t# Top\\npreamble\tbody\n37\t\\nxFOOx\\n\t## Sub\tbody\n")
        let rows = try cli(lib, "search-in", id, "-s", "foo", "--context", "5", "--format", "json").json()
        #expect(rows.array?.count == 3)
        #expect(
            rows.array?.first
                == .object([
                    ("offset", .int(0)), ("snippet", .string("Foo b")), ("section", .string("preamble")),
                    ("source", .string("body")),
                ]))
        #expect(cli(lib, "search-in", plain, "--find", "FOO").out == "2\ta foo\t\tbody\n")  // whole note within 60 characters
        #expect(cli(lib, "search-in", id, "--string", "foo", "--count").out == "3\n")
        #expect(cli(lib, "search-in", id, "--string", "foo", "--count", "--format", "json").out == #"{"count":3}"# + "\n")
        #expect(cli(lib, "search-in", id, "--string", "foo", "--count", "-n", "1").out == "3\n")
        #expect(cli(lib, "search-in", id, "--string", "foo", "-n", "1", "--fields", "offset").out == "0\n")
        #expect(cli(lib, "search-in", id, "--string", "foo", "-n", "0", "--format", "json").out == "")
        #expect(cli(lib, "search-in", id, "--string", "foo", "--section", "## Sub", "--fields", "offset,section").out == "37\t## Sub\n")
        #expect(cli(lib, "search-in", id, "--string", "foo", "--section", "# Top", "--fields", "offset").out == "17\n37\n")
        #expect(cli(lib, "search-in", id, "--string", "lead\\n##", "--fields", "offset,section").out == "24\t# Top\\npreamble\n")
        let none = cli(lib, "search-in", id, "--string", "zzz")
        #expect(none.exit == 0 && none.out == "" && none.err == "")
        #expect(cli(lib, "search-in", id, "--string", "zzz", "--format", "json").out == "[]\n")
        #expect(cli(lib, "search-in", id, "--string", "", "--format", "json").out == "[]\n")
        #expect(cli(lib, "search-in", id, "--string", "", "--count").out == "0\n")
        let missing = cli(lib, "search-in", id, "--format", "json")
        #expect(missing.exit == 64 && missing.out == #"{"error":{"code":"usage","message":"--string is required"}}"# + "\n")
        let context = cli(lib, "search-in", id, "--string", "x", "--context=-1", "--format", "json")
        #expect(context.exit == 64 && context.out.contains("Context must be non-negative"))
        #expect(cli(lib, "search-in", id, "--string", "x", "--section", "## Nope", "--format", "json").out.contains("not_found"))
    }

    @Test func searchInSnippetsCountCharactersNotBytes() throws {
        let lib = try TestLibrary.make([TestNote(text: "日本語👩‍👩‍👧x日本")])
        let id = try lib.firstId()
        let hit = try cli(lib, "search-in", id, "--string", "x", "--context", "2", "--format", "json").json()
        #expect(hit.array?.first?["snippet"] == .string("👩‍👩‍👧x日"))
        #expect(hit.array?.first?["offset"] == .int("日本語👩‍👩‍👧".utf8.count))
    }

    /// Ruling RO-1: recognized text of a linked image or PDF is searched too; the hit's offset is
    /// its link's, the snippet comes from the recognized text. Only `done` rows with text count.
    @Test func searchInFindsRecognizedAttachmentText() throws {
        let text = "# Doc\nSee ![](scan.png) and ![](b.png)\n## Later\nbody\n"
        let lib = try TestLibrary.make([TestNote(text: text)])
        let id = try lib.firstId()
        let ocr = AttachmentTextStore(database: lib.library.database)
        try ocr.record(
            OCRJob(noteId: id, filename: "scan.png"),
            result: .text("Please see total", sha256: "00", byteSize: 1, modifiedAt: TestLibrary.epoch))
        try ocr.record(OCRJob(noteId: id, filename: "b.png"), result: .failed)
        #expect(
            cli(lib, "search-in", id, "--string", "see", "--context", "6").out
                == "6\toc\\nSee ![\t# Doc\\npreamble\tbody\n10\tse see to\t# Doc\\npreamble\tattachment\n")
        let rows = try cli(lib, "search-in", id, "--string", "TOTAL", "--format", "json").json()
        #expect(
            rows
                == .array([
                    .object([
                        ("offset", .int(10)), ("snippet", .string("Please see total")),
                        ("section", .string("# Doc\npreamble")), ("source", .string("attachment")),
                    ])
                ]))
        #expect(cli(lib, "search-in", id, "--string", "see", "--count").out == "2\n")
        #expect(cli(lib, "search-in", id, "--string", "total", "--section", "## Later", "--format", "json").out == "[]\n")
        #expect(cli(lib, "search-in", id, "--string", "total", "--section", "# Doc\\npreamble", "--fields", "source").out == "attachment\n")
    }

    @Test func searchInIgnoresAttachmentRowsThatAreNotDone() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\n![](scan.png)\n")])
        let id = try lib.firstId()
        // A pending row whose text was written by something other than the recognizer does not count.
        try lib.library.database.pool.write { db in
            try db.execute(
                sql: "UPDATE attachment SET ocrState = 'pending', ocrText = 'hidden' WHERE noteId = ?", arguments: [id])
        }
        #expect(cli(lib, "search-in", id, "--string", "hidden", "--format", "json").out == "[]\n")
        try lib.library.database.pool.write { db in
            try db.execute(
                sql: "UPDATE attachment SET ocrState = 'done', ocrText = 'hidden' WHERE noteId = ?", arguments: [id])
        }
        #expect(cli(lib, "search-in", id, "--string", "hidden", "--fields", "offset,source").out == "6\tattachment\n")
        // A link that was removed from the text no longer counts, even with its row's text kept.
        try lib.library.database.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '# Doc\n' WHERE id = ?", arguments: [id])
        }
        #expect(cli(lib, "search-in", id, "--string", "hidden", "--format", "json").out == "[]\n")
    }

    // MARK: locked notes

    @Test func lockedNoteFailsEveryContentRead() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Secret\nx", locked: true)])
        let id = try lib.firstId()
        for args in [
            ["cat", id], ["cat", id, "-n", "1"], ["cat", id, "--section", "# Secret"], ["outline", id],
            ["outline", id, "--section", "# Secret"], ["search-in", id, "--string", "x"],
            ["search-in", id, "--string", "x", "--count"], ["search-in", id, "--string", "x", "--section", "# Secret"],
        ] {
            let result = run(lib, args + ["--format", "json"])
            #expect(result.exit == 1, "\(args)")
            #expect(result.out == #"{"error":{"code":"note_locked","message":"Note is locked: \#(id)"}}"# + "\n", "\(args)")
        }
        #expect(run(lib, ["cat", id]).err == "Error: Note is locked: \(id)\n")
    }

    @Test func lockedNoteNeverExposesRecognizedText() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\n![](scan.png)\n")])
        let id = try lib.firstId()
        try AttachmentTextStore(database: lib.library.database).record(
            OCRJob(noteId: id, filename: "scan.png"),
            result: .text("secret words", sha256: "00", byteSize: 1, modifiedAt: TestLibrary.epoch))
        #expect(cli(lib, "search-in", id, "--string", "secret", "--count").out == "1\n")
        // Locked behind the store's back: the text and the `done` row stay, the lock still wins.
        try lib.library.database.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [id])
        }
        for extra in [[], ["--count"], ["--section", "# Doc"]] {
            let result = run(lib, ["search-in", id, "--string", "secret", "--format", "json"] + extra)
            #expect(result.exit == 1 && result.out.contains(#""code":"note_locked""#), "\(extra)")
            #expect(!result.out.contains("words") && result.err.isEmpty, "\(extra)")
        }
    }

    // MARK: fix round 1

    /// `\r\n` is one grapheme cluster; a multi-line `--string` must still find it.
    @Test func searchInMatchesMultiLineStringsInCRLFNotes() throws {
        let text = "# T\r\nfoo\r\nbar\r\nFOO\r\nBAR\r\n"
        // `NoteStore.create` normalizes line endings, so the CRLF text is stored the way an external
        // writer (sync, a pre-normalization import) leaves it.
        let lib = try TestLibrary.make([TestNote(text: "# T\nx\n")])
        let id = try lib.firstId()
        try lib.library.database.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = ? WHERE id = ?", arguments: [text, id])
        }
        #expect(cli(lib, "cat", id).out == text)
        #expect(cli(lib, "search-in", id, "--string", "foo\\r\\nbar", "--fields", "offset,section").out == "5\t# T\n15\t# T\n")
        #expect(cli(lib, "search-in", id, "--string", "\\nbar", "--fields", "offset").out == "9\n19\n")
        #expect(cli(lib, "search-in", id, "--string", "bar\\r\\n", "--count").out == "2\n")
        // The finder the edit commands reuse behaves the same, case-sensitively too.
        #expect(NoteFind.occurrences(of: "foo\r\nbar", in: text, within: nil, ignoreCase: false, word: false) == [5..<13])
        #expect(NoteFind.occurrences(of: "\nFOO", in: text, within: nil, ignoreCase: false, word: true) == [14..<18])
    }

    /// A file linked in `# A` and again in `## B` is searched at its first link inside the range.
    @Test func duplicateAttachmentLinkUsesTheFirstLinkInsideTheRange() throws {
        let text = "# A\n![](scan.png)\n## B\n![](scan.png)\n"
        let lib = try TestLibrary.make([TestNote(text: text)])
        let id = try lib.firstId()
        try AttachmentTextStore(database: lib.library.database).record(
            OCRJob(noteId: id, filename: "scan.png"),
            result: .text("total 42", sha256: "00", byteSize: 1, modifiedAt: TestLibrary.epoch))
        #expect(cli(lib, "search-in", id, "--string", "total", "--fields", "offset,section,source").out == "4\t# A\\npreamble\tattachment\n")
        #expect(cli(lib, "search-in", id, "--string", "total", "--section", "## B", "--fields", "offset,section").out == "23\t## B\n")
        #expect(cli(lib, "search-in", id, "--string", "total", "--section", "# A", "--fields", "offset").out == "4\n")
        #expect(cli(lib, "search-in", id, "--string", "total", "--section", "# A\\npreamble", "--fields", "offset").out == "4\n")
    }

    private func run(_ lib: TestLibrary, _ args: [String]) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
    }
}

/// Replays every `cat` / `outline` / `search-in` case of `Fixtures/cli/cli-observed.json`: the
/// errors word for word, the success and section-error shapes by keys and value kinds.
@Suite struct SectionCommandsContractTests {
    private static let commands: Set<String> = ["cat", "outline", "search-in"]

    private static func observed() throws -> JSONValue {
        try JSONValue(parsing: Data(contentsOf: ArgvParserTests.observedURL))
    }

    private static func reworded(_ s: String) -> String {
        s.replacingOccurrences(of: "bearcli", with: "theonotes").replacingOccurrences(of: "Bear ", with: "Theo Notes ")
    }

    private func run(_ lib: TestLibrary, _ args: [String]) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
    }

    @Test func commandLevelErrorsEqualTheObservedBearcliOutput() throws {
        let lib = try TestLibrary.make()
        let parserMarkers = ["Missing value for", "is invalid for", "Unknown option", "Unexpected argument"]
        var checked = 0
        for entry in try Self.observed()["errors"]?.array ?? [] {
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            guard let first = args.first, Self.commands.contains(first) else { continue }
            let stdout = entry["stdout"]?.string ?? ""
            let stderr = entry["stderr"]?.string ?? ""
            if parserMarkers.contains(where: { stdout.contains($0) || stderr.contains($0) }) { continue }
            let result = run(lib, args)
            #expect(result.exit == Int32(entry["exit"]?.intValue ?? -1), "\(args)")
            #expect(result.out == Self.reworded(stdout), "\(args)")
            #expect(result.err == Self.reworded(stderr), "\(args)")
            checked += 1
        }
        #expect(checked >= 16)
    }

    // MARK: Shapes

    private static func kind(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "bool"
        case .int, .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Same keys (in order, or as sets where `sortedKeys`: the fixture sorts error envelopes) and
    /// the same kinds of values; arrays compare their first elements.
    private static func sameShape(_ actual: JSONValue, _ template: JSONValue, sortedKeys: Bool, path: String = "$")
        -> [String]
    {
        let wantedKind = template == .string("int") ? "number" : kind(template)
        guard kind(actual) == wantedKind else { return ["\(path): \(kind(actual)) instead of \(wantedKind)"] }
        switch (actual, template) {
        case (.object, .object):
            let keys = sortedKeys ? actual.keys.sorted() : actual.keys
            guard keys == template.keys else { return ["\(path): keys \(actual.keys) instead of \(template.keys)"] }
            return template.keys.flatMap { key in
                sameShape(actual[key]!, template[key]!, sortedKeys: sortedKeys, path: path + "." + key)
            }
        case (.array(let a), .array(let t)):
            guard let a = a.first, let t = t.first else { return [] }
            return sameShape(a, t, sortedKeys: sortedKeys, path: path + "[0]")
        default:
            return []
        }
    }

    /// A note with sections, an ambiguous heading, a preamble and several `e`s.
    private func shapesLibrary() throws -> (TestLibrary, String) {
        let lib = try TestLibrary.make([TestNote(text: NoteSectionsTests.doc)])
        return (lib, try lib.firstId())
    }

    /// The fixture's placeholders and masked addresses, replaced by values of `shapesLibrary`.
    private static func concrete(_ args: [String], id: String) -> [String] {
        var out: [String] = []
        for (i, arg) in args.enumerated() {
            if arg.hasPrefix("<ID") {
                out.append(id)
            } else if arg == "<ADDRESS-MISSING>" {
                out.append("## Nope")
            } else if arg == "<ADDRESS-AMBIGUOUS>" {
                out.append("## Install")
            } else if i > 0, args[i - 1] == "--section" {
                out.append("# Guide")  // a masked address that resolved in the probe
            } else {
                out.append(arg)
            }
        }
        return out
    }

    @Test func shapesEqualTheObservedOnes() throws {
        let (lib, id) = try shapesLibrary()
        var checked = 0
        var problems: [String] = []
        guard case .object(let shapes)? = try Self.observed()["shapes"] else {
            Issue.record("no shapes")
            return
        }
        for (name, shape) in shapes {
            let raw = (shape["args"]?.array ?? []).compactMap(\.string)
            guard let first = raw.first, Self.commands.contains(first) else { continue }
            let args = Self.concrete(raw, id: id)
            let result = run(lib, args)
            let exit = Int32(shape["exit"]?.intValue ?? -1)
            if result.exit != exit { problems.append("\(name): exit \(result.exit) instead of \(exit) \(result.err)") }
            let isJSON = args.contains("json")
            switch shape["stdout"] {
            case .string(let text)?:
                if text.isEmpty, !result.out.isEmpty { problems.append("\(name): stdout \(result.out)") }
            case .array(let rows)? where !isJSON:
                guard let header = rows.first?.array else { break }
                let firstLine = String(result.out.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
                if args.contains("csv") {
                    if firstLine != header.compactMap(\.string).joined(separator: ",") {
                        problems.append("\(name): header \(firstLine)")
                    }
                } else if firstLine.split(separator: "\t", omittingEmptySubsequences: false).count != header.count {
                    problems.append("\(name): columns of \(firstLine)")
                }
            case let template?:
                let actual = try result.json()
                problems += Self.sameShape(actual, template, sortedKeys: exit != 0).map { "\(name) \($0)" }
                // The message is our own wording: present, and counting the candidates it lists.
                if template["error"]?["message"]?.string != nil {
                    let count = actual["error"]?["details"]?["candidates"]?.array?.count ?? 0
                    let message = actual["error"]?["message"]?.string ?? ""
                    if message.isEmpty || (count > 0 && !message.hasPrefix("\(count) ")) { problems.append("\(name): message") }
                }
            case nil:
                problems.append("\(name): no stdout")
            }
            // TSV errors: the fixture keeps the first line (without `Error: `) and counts the rest.
            if let stderr = shape["stderr"]?.string, !stderr.isEmpty {
                var firstLine = stderr
                var extra = 0
                if let marker = stderr.range(of: " [+") {
                    firstLine = String(stderr[..<marker.lowerBound])
                    extra = Int(String(stderr[marker.upperBound...].prefix { $0.isNumber })) ?? 0
                }
                let lines = result.err.split(separator: "\n").map(String.init)
                let candidates = lines.count - 1
                _ = firstLine
                if lines.first?.hasPrefix("Error: ") != true || (extra > 0 && lines.first?.hasPrefix("Error: \(candidates) ") != true) {
                    problems.append("\(name): stderr \(result.err)")
                }
                // The probe's note had 2 candidates (2 more lines); this one has 3.
                if extra > 0, candidates != 3 { problems.append("\(name): \(candidates) candidate lines") }
            }
            checked += 1
        }
        #expect(problems.isEmpty, "\(problems)")
        #expect(checked >= 22)
    }

    @Test func factsAboutHashesEmptyResultsAndCounts() throws {
        let facts = try #require(try Self.observed()["facts"])
        let (lib, id) = try shapesLibrary()
        #expect(facts["hashAlgorithm"] == .string("sha256-hex-prefix") && facts["hashLength"]?.intValue == 7)
        let whole = try run(lib, ["cat", id, "--format", "json"]).json()
        #expect(whole.keys == facts["wholeNoteCatJSONKeys"]?.array?.compactMap(\.string))
        #expect(whole["hash"]?.string?.utf8.count == 7)
        #expect(facts["catAddsNoNewline"] == .bool(true))
        #expect(run(lib, ["cat", id]).out == NoteSectionsTests.doc)
        func expected(_ key: String) -> String? { facts[key]?["expected"]?.string }
        #expect(run(lib, ["cat", id, "--offset", "999999", "--format", "json"]).out == expected("catOffsetPastEndJSON"))
        #expect(
            run(lib, ["search-in", id, "--string", "zzqq-nohit-7731", "--format", "json"]).out
                == expected("searchInNoHitJSON"))
        let noHit = run(lib, ["search-in", id, "--string", "zzqq-nohit-7731"])
        #expect(noHit.out == expected("searchInNoHitTSV") && noHit.exit == Int32(facts["searchInNoHitExit"]?.intValue ?? -1))
        #expect(run(lib, ["search-in", id, "--string", "", "--format", "json"]).out == expected("searchInEmptyStringJSON"))
        let count = run(lib, ["search-in", id, "--string", "install", "--count", "--format", "json"]).out
        #expect(count == expected("countSearchInJSON")?.replacingOccurrences(of: "N", with: "3"))
        #expect(facts["sectionMissingCode"] == .string("not_found") && facts["sectionAmbiguousCode"] == .string("ambiguous"))
        #expect(facts["sectionAmbiguousDetailsKeys"] == .array([.string("candidates")]))
    }
}
