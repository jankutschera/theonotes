// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// MCP tag scoping: `--only-tags` / `--exclude-tags` narrow what the
/// tools see and what a write may leave behind.
private struct ScopedFixture {
    let f: ToolFixture

    init(notes: [String], only: [String] = [], exclude: [String] = []) throws {
        f = try ToolFixture(
            notes.map { TestNote(text: $0) }, scope: NoteScope(onlyTags: only, excludeTags: exclude))
    }

    /// Titles in the order the tool lists them, oldest id first so the order is stable.
    func titles(_ tool: String, _ arguments: String = "{}") async throws -> [String] {
        let result = try await f.ok(tool, arguments)
        let rows = result["metadata"]?.array ?? result["results"]?.array?.compactMap { $0["metadata"] } ?? []
        return rows.compactMap { $0["title"]?.string }.sorted()
    }

    func total(_ tool: String, _ arguments: String = "{}") async throws -> Int? {
        if case .int(let n)? = try await f.ok(tool, arguments)["total"] { return n }
        return nil
    }

    func tags() async throws -> [String] {
        try await f.ok("list_tags")["tags"]?.array?.compactMap(\.string) ?? []
    }

    func error(_ tool: String, _ arguments: String = "{}") async throws -> ErrorCode {
        try await f.fail(tool, arguments).code
    }

    func id(_ title: String) throws -> String { try f.lib.id(titled: title) }

    func text(_ title: String) throws -> String { try f.lib.text(try id(title)) }

    func revision(_ title: String) throws -> Int { try f.lib.note(try id(title)).revision }

    func noteCount() throws -> Int {
        try f.lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") ?? 0 }
    }

    func quoted(_ text: String) -> String { JSONValue.string(text).serialized(sortedKeys: true) }
}

private let moved = "The change would move the note out of this server's scope"

@Suite struct MCPScopeTests {
    // MARK: Reads

    @Test func outOfScopeNotesAreInvisibleToListsSearchTagsAndTitles() async throws {
        let t = try ScopedFixture(
            notes: ["# W\n#work", "# P\n#work #private", "# H\n#home"], only: ["work"], exclude: ["private"])
        #expect(try await t.titles("list_notes") == ["W"])
        #expect(try await t.total("list_notes") == 1)
        #expect(try await t.total("list_notes", ###"{"limit":0}"###) == 1)
        #expect(try await t.titles("search_notes", ###"{"query":"#work"}"###) == ["W"])
        #expect(try await t.total("search_notes", ###"{"query":"#work"}"###) == 1)
        #expect(try await t.total("search_notes", ###"{"query":"#home"}"###) == 0)
        #expect(try await t.tags() == ["work"])
        #expect(try await t.error("get_note", ###"{"title":"P"}"###) == .noteNotFound)
        #expect(try await t.error("get_note", ###"{"id":\###(t.quoted(try t.id("P")))}"###) == .outOfScope)
        let hidden = try await t.f.fail("read_note_content", ###"{"id":\###(t.quoted(try t.id("H")))}"###)
        #expect(hidden.message == "Note is outside this server's scope: \(try t.id("H"))")
    }

    @Test func nestedTagsOfAnOnlyTagAreInScopeAndExcludeWins() async throws {
        let t = try ScopedFixture(
            notes: ["# A\n#work/sub", "# B\n#work/sub #private/deep", "# C\n#other"], only: ["#work "], exclude: [" #private "])
        #expect(try await t.titles("list_notes") == ["A"])
        #expect(try await t.tags() == ["work", "work/sub"])
    }

    @Test func listPinsWithoutANoteOnlyReportsInScopeNotes() async throws {
        let f = try ToolFixture(
            [
                TestNote(text: "# W\n#work", pinned: true), TestNote(text: "# H\n#home", pinned: true),
            ],
            scope: NoteScope(onlyTags: ["work"], excludeTags: []))
        let w = try f.lib.id(titled: "W")
        _ = try await f.ok("add_pins", ###"{"id":"\###(w)","targets":["work"]}"###)
        let h = try f.lib.id(titled: "H")
        try f.lib.library.store.setPinned([h], pinned: true, inTag: "home")
        #expect(try await f.ok("list_pins")["pins"] == .array(["global", "work"]))
    }

    @Test func noScopeSeesEverything() async throws {
        let t = try ScopedFixture(notes: ["# W\n#work", "# H\n#home"])
        #expect(try await t.titles("list_notes") == ["H", "W"])
    }

    // MARK: Writes

    @Test func writesCannotLeaveTheScope() async throws {
        let t = try ScopedFixture(
            notes: ["# W\n#work\nbody", "# V\n#work #keep\nbody"], only: ["work"], exclude: ["private"])
        let w = t.quoted(try t.id("W"))
        let before = try t.text("W")
        let revision = try t.revision("W")

        // A tag that excludes the note.
        #expect(try await t.f.fail("add_tags", ###"{"id":\###(w),"tags":["private"]}"###).message == moved)
        // Several tags: none of them lands when one of them leaves the scope.
        #expect(try await t.f.fail("add_tags", ###"{"id":\###(w),"tags":["extra","private"]}"###).code == .outOfScope)
        // Several tags removed, the last of them the only qualifying one: the first stays too.
        #expect(try await t.f.fail("remove_tags", ###"{"id":\###(w),"tags":["work","nothing"]}"###).code == .outOfScope)
        // The only qualifying tag removed.
        #expect(try await t.f.fail("remove_tags", ###"{"id":\###(w),"tags":["work"]}"###).code == .outOfScope)
        // Text writes that drop or replace the qualifying tag.
        let hash = try await t.f.ok("read_note_content", ###"{"id":\###(w)}"###)["hash"]?.string ?? ""
        #expect(
            try await t.f.fail(
                "overwrite_note", ###"{"id":\###(w),"content":"# W\nno tag","baseHash":"\###(hash)"}"###
            ).message == moved)
        #expect(
            try await t.f.fail("edit_note", ###"{"id":\###(w),"edits":[{"find":"#work","replace":"#home"}]}"###).code
                == .outOfScope)
        #expect(
            try await t.f.fail("append_to_note", ###"{"id":\###(w),"content":"#private"}"###).code == .outOfScope)
        // Nothing was written, not even a write that was reverted afterwards.
        #expect(try t.text("W") == before)
        #expect(try t.revision("W") == revision)

        // Writes that stay inside the scope still work: a second qualifying tag may be dropped.
        let v = t.quoted(try t.id("V"))
        _ = try await t.f.ok("remove_tags", ###"{"id":\###(v),"tags":["keep"]}"###)
        _ = try await t.f.ok("append_to_note", ###"{"id":\###(v),"content":"more"}"###)
        #expect(try t.text("V") == "# V\n#work\nbody\nmore\n")
    }

    @Test func ifNotExistsOnlyFindsInScopeNotes() async throws {
        let t = try ScopedFixture(notes: ["# Same\n#work", "# Same\n#home"], only: ["work"])
        let found = try await t.f.ok("create_note", ###"{"title":"Same","ifNotExists":true}"###)
        #expect(found["tags"] == .array(["work"]))
        #expect(try t.noteCount() == 2)
        let other = try ScopedFixture(notes: ["# Same\n#home", "# W\n#work"], only: ["work"])
        let made = try await other.f.ok("create_note", ###"{"title":"Same","ifNotExists":true}"###)
        #expect(made["tags"] == .array(["work"]))
        #expect(try other.noteCount() == 3)
    }

    @Test func writesToOutOfScopeNotesAreRefused() async throws {
        let t = try ScopedFixture(notes: ["# W\n#work", "# H\n#home"], only: ["work"])
        let h = t.quoted(try t.id("H"))
        for (tool, arguments) in [
            ("append_to_note", ###"{"id":\###(h),"content":"x"}"###), ("trash_note", ###"{"id":\###(h)}"###),
            ("add_tags", ###"{"id":\###(h),"tags":["work"]}"###),
            ("add_pins", ###"{"id":\###(h),"targets":["global"]}"###),
        ] {
            #expect(try await t.error(tool, arguments) == .outOfScope, "\(tool)")
        }
        #expect(try await t.error("append_to_note", ###"{"title":"H","content":"x"}"###) == .noteNotFound)
        #expect(try t.text("H") == "# H\n#home")
    }

    @Test func createInjectsSingleOnlyTagAndRequiresOneOfSeveral() async throws {
        let one = try ScopedFixture(notes: ["# W\n#work"], only: ["work"])
        let made = try await one.f.ok("create_note", ###"{"title":"New","content":"body"}"###)
        #expect(made["tags"] == .array(["work"]))
        #expect(try await one.titles("list_notes") == ["New", "W"])
        // A note that already carries a qualifying tag (a nested one) gets no second tag.
        let nested = try await one.f.ok("create_note", ###"{"content":"# Deep\n#work/sub"}"###)
        #expect(nested["tags"] == .array(["work", "work/sub"]))
        // A note with extra tags keeps them and gains the scope tag.
        let extra = try await one.f.ok("create_note", ###"{"title":"Extra","tags":["x"]}"###)
        #expect(extra["tags"]?.array?.compactMap(\.string).sorted() == ["work", "x"])

        let many = try ScopedFixture(notes: ["# W\n#a"], only: ["a", "b"])
        let refused = try await many.f.fail("create_note", ###"{"title":"New","content":"body"}"###)
        #expect(refused.code == .outOfScope && refused.message == "Include one of the scope tags: #a, #b")
        #expect(try many.noteCount() == 1)
        _ = try await many.f.ok("create_note", ###"{"title":"ViaTag","tags":["b"]}"###)
        _ = try await many.f.ok("create_note", ###"{"title":"ViaText","content":"#a/child here"}"###)
        #expect(try many.noteCount() == 3)
    }

    @Test func createCannotMakeANoteThatIsOutOfScope() async throws {
        let t = try ScopedFixture(notes: ["# W\n#work"], only: ["work"], exclude: ["private"])
        let error = try await t.f.fail("create_note", ###"{"title":"Bad","tags":["private"]}"###)
        #expect(error.code == .outOfScope)
        #expect(try t.noteCount() == 1)

        let excludeOnly = try ScopedFixture(notes: ["# W\n#work"], exclude: ["private"])
        #expect(try await excludeOnly.error("create_note", ###"{"title":"Bad","content":"#private"}"###) == .outOfScope)
        #expect(try excludeOnly.noteCount() == 1)
        _ = try await excludeOnly.f.ok("create_note", ###"{"title":"Fine"}"###)
        #expect(try excludeOnly.noteCount() == 2)
    }

    @Test func captureThoughtGetsTheSingleScopeTag() async throws {
        let one = try ScopedFixture(notes: ["# W\n#work"], only: ["work"])
        let made = try await one.f.ok("capture_thought", ###"{"text":"Call Ana"}"###)
        #expect(made["tags"] == .array(["work"]))
        let id = try #require(made["id"]?.string)
        #expect(try one.f.lib.text(id) == "Call Ana\n#work")
        #expect(try one.f.lib.library.store.captureSource(noteId: id) == .mcp)
        #expect(try await one.titles("list_notes") == ["Call Ana", "W"])
        // A thought that already carries a qualifying tag is stored as given.
        let nested = try await one.f.ok("capture_thought", ###"{"text":"Deep\n#work/sub"}"###)
        #expect(nested["tags"] == .array(["work", "work/sub"]))
        #expect(try one.f.lib.text(try #require(nested["id"]?.string)) == "Deep\n#work/sub")
    }

    @Test func captureThoughtPlacesTheScopeTagAtTheTagPosition() async throws {
        let top = try ScopedFixture(notes: ["# W\n#work"], only: ["work"])
        Settings(db: top.f.lib.library.database).tagPosition = .top
        let made = try await top.f.ok("capture_thought", ###"{"text":"Call Ana\nabout the visa"}"###)
        #expect(try top.f.lib.text(try #require(made["id"]?.string)) == "Call Ana\n#work\nabout the visa")
        #expect(made["tags"] == .array(["work"]))
    }

    @Test func captureThoughtFailsLikeCreateNoteUnderSeveralScopeTags() async throws {
        let many = try ScopedFixture(notes: ["# W\n#a"], only: ["a", "b"])
        let refused = try await many.f.fail("capture_thought", ###"{"text":"Call Ana"}"###)
        #expect(refused.code == .outOfScope && refused.message == "Include one of the scope tags: #a, #b")
        let same = try await many.f.fail("create_note", ###"{"title":"New","content":"body"}"###)
        #expect(refused.code == same.code && refused.message == same.message)
        #expect(try many.noteCount() == 1)
        // Naming one of the tags in the text is the way through, as it is for create_note.
        let made = try await many.f.ok("capture_thought", ###"{"text":"Call Ana #a/child"}"###)
        #expect(try many.f.lib.text(try #require(made["id"]?.string)) == "Call Ana #a/child")
        #expect(made["tags"]?.array?.contains("a/child") == true)
        #expect(try many.noteCount() == 2)
        // A thought that would land outside the scope is refused and nothing is stored.
        let hidden = try ScopedFixture(notes: ["# W\n#work"], only: ["work"], exclude: ["private"])
        #expect(try await hidden.error("capture_thought", ###"{"text":"Secret #private"}"###) == .outOfScope)
        #expect(try hidden.noteCount() == 1)
    }

    @Test func templatesOutsideTheScopeCannotBeCopied() async throws {
        let t = try ScopedFixture(
            notes: [
                "# Mine\n#template #work\nmine body", "# Theirs\n#template #private\nsecret body",
                "# Loose\n#template\nloose body",
            ],
            only: ["work"], exclude: ["private"])
        let made = try await t.f.ok("create_note_from_template", ###"{"template":"Mine","title":"Copy"}"###)
        #expect(made["tags"] == .array(["work"]))
        #expect(made["content"]?.string?.contains("mine body") == true)
        // By title an out-of-scope template does not exist; by id it is out of scope.
        #expect(try await t.error("create_note_from_template", ###"{"template":"Theirs"}"###) == .noteNotFound)
        #expect(try await t.error("create_note_from_template", ###"{"template":"Loose"}"###) == .noteNotFound)
        let byId = try await t.f.fail("create_note_from_template", ###"{"template":\###(t.quoted(try t.id("Theirs")))}"###)
        #expect(byId.code == .outOfScope)
        #expect(!byId.message.contains("secret"))
        let count = try t.noteCount()
        #expect(count == 4)
        // The tags argument cannot take a copy of an in-scope template out of the scope either.
        let leaving = try await t.f.fail("create_note_from_template", ###"{"template":"Mine","tags":["private"]}"###)
        #expect(leaving.code == .outOfScope)
        #expect(try t.noteCount() == count)
    }

    @Test func templateInjectionFollowsTheSameRulesAsCreate() async throws {
        let t = try ScopedFixture(
            notes: ["# Tpl\n#template #a\nbody", "# Both\n#template #a #b\nbody"], only: ["a", "b"])
        #expect(try await t.f.ok("create_note_from_template", ###"{"template":"Tpl"}"###)["tags"] == .array(["a"]))
    }

    // MARK: Tags

    @Test func renameAndDeleteOfScopeTagsBlocked() async throws {
        let t = try ScopedFixture(
            notes: ["# W\n#work #mine", "# P\n#work #private", "# H\n#home #ideas", "# Q\n#work #ideas"],
            only: ["work"], exclude: ["private"])
        let outside = ["# P\n#work #private", "# H\n#home #ideas"]
        for (tool, arguments) in [
            ("rename_tag", ###"{"old":"work","new":"job"}"###),  // a scope tag
            ("delete_tag", ###"{"tag":"private"}"###),  // an exclude tag
            ("rename_tag", ###"{"old":"work/sub","new":"x"}"###),  // a descendant of a scope tag
            ("delete_tag", ###"{"tag":"work/sub"}"###),
            ("rename_tag", ###"{"old":"#private/deep","new":"x"}"###),  // a descendant of an exclude tag
            ("rename_tag", ###"{"old":"mine","new":"work"}"###),  // into a scope tag
            ("rename_tag", ###"{"old":"mine","new":"work/sub"}"###),  // into a descendant of one
            ("rename_tag", ###"{"old":"ideas","new":"thoughts"}"###),  // carried by an out-of-scope note
            ("delete_tag", ###"{"tag":"ideas"}"###),
            ("rename_tag", ###"{"old":"mine","new":"home"}"###),  // into a tag only out-of-scope notes carry
            ("rename_tag", ###"{"old":"mine","new":"ideas","force":true}"###),  // merge into outside state
            ("rename_tag", ###"{"old":"home","new":"house"}"###),  // carried only outside the scope
            ("delete_tag", ###"{"tag":"home"}"###),
        ] {
            let error = try await t.f.fail(tool, arguments)
            #expect(error.code == .outOfScope, "\(tool) \(arguments): \(error.code) \(error.message)")
        }
        #expect(try t.text("P") == outside[0] && t.text("H") == outside[1])
        #expect(try t.text("W") == "# W\n#work #mine" && t.text("Q") == "# Q\n#work #ideas")

        // A tag that only in-scope notes carry may be renamed and deleted.
        #expect(try await t.f.ok("rename_tag", ###"{"old":"mine","new":"own"}"###)["notesUpdated"] == 1)
        #expect(try t.text("W") == "# W\n#work #own")
        #expect(try await t.f.ok("delete_tag", ###"{"tag":"own"}"###)["notesUpdated"] == 1)
        #expect(try t.text("W") == "# W\n#work")
    }

    @Test func tagChangesAreUnrestrictedWithoutAScope() async throws {
        let t = try ScopedFixture(notes: ["# W\n#work", "# H\n#home"])
        #expect(try await t.f.ok("rename_tag", ###"{"old":"home","new":"house"}"###)["notesUpdated"] == 1)
    }

    // MARK: Server flags

    @Test func flagsOverrideEnvironmentPerKind() throws {
        func scope(_ args: [String], _ environment: [String: String]) throws -> NoteScope {
            guard case .command(let parsed) = try ArgvParser.parse(["baerchen", "mcp-server"] + args) else {
                throw AutomationError(code: .internal, message: "not a command")
            }
            return try NoteScope.fromMCPServer(flags: parsed, environment: environment)
        }
        let env = ["BAERCHEN_MCP_ONLY_TAGS": "env1, #env2", "BAERCHEN_MCP_EXCLUDE_TAGS": "envx"]
        let neither = try scope([], env)
        #expect(neither == NoteScope(onlyTags: ["env1", "env2"], excludeTags: ["envx"]))
        // A flag replaces the variable of its own kind and leaves the other alone.
        let onlyFlag = try scope(["--only-tags", " #flag ,Other"], env)
        #expect(onlyFlag == NoteScope(onlyTags: ["flag", "Other"], excludeTags: ["envx"]))
        let excludeFlag = try scope(["--exclude-tags=flagx"], env)
        #expect(excludeFlag == NoteScope(onlyTags: ["env1", "env2"], excludeTags: ["flagx"]))
        let both = try scope(["--only-tags", "a", "--exclude-tags", "b"], env)
        #expect(both == NoteScope(onlyTags: ["a"], excludeTags: ["b"]))
        #expect(try scope([], [:]) == .unrestricted)
    }

    /// THEONOTES_MCP_* are the variables of the renamed product; BAERCHEN_MCP_* still work and lose when both are set.
    @Test func theRenamedVariablesWinAndTheOldOnesStillWork() throws {
        func scope(_ environment: [String: String]) throws -> NoteScope {
            guard case .command(let parsed) = try ArgvParser.parse(["theonotes", "mcp-server"]) else {
                throw AutomationError(code: .internal, message: "not a command")
            }
            return try NoteScope.fromMCPServer(flags: parsed, environment: environment)
        }
        #expect(try scope(["THEONOTES_MCP_ONLY_TAGS": "new", "THEONOTES_MCP_EXCLUDE_TAGS": "newx"]) == NoteScope(onlyTags: ["new"], excludeTags: ["newx"]))
        #expect(try scope(["BAERCHEN_MCP_ONLY_TAGS": "old"]) == NoteScope(onlyTags: ["old"], excludeTags: []))
        #expect(try scope(["THEONOTES_MCP_ONLY_TAGS": "new", "BAERCHEN_MCP_ONLY_TAGS": "old"]) == NoteScope(onlyTags: ["new"], excludeTags: []))
        #expect(throws: AutomationError.self) { try scope(["THEONOTES_MCP_ONLY_TAGS": " # "]) }
    }

    /// Fail closed (final review M1): a flag or variable that is present but names no tag (`""`,
    /// `"#"`, `","`) is a start-up error, never an unrestricted server.
    @Test func aScopeThatNamesNoTagIsAStartUpError() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work"), TestNote(text: "# H\n#home")])
        let initialize = MCPProtocolTests.initialize
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#
        let stdin = Data((initialize + "\n" + list + "\n").utf8)
        for degenerate in ["", "#", ",", " , # ,"] {
            for (flag, variable) in [("--only-tags", "BAERCHEN_MCP_ONLY_TAGS"), ("--exclude-tags", "BAERCHEN_MCP_EXCLUDE_TAGS")] {
                let byFlag = runCLI(
                    ["baerchen", "mcp-server", "--data-dir", lib.paths.root.path, flag, degenerate], stdin: stdin,
                    environment: ["BAERCHEN_MCP_ONLY_TAGS": "work"])
                #expect(byFlag.exit == 64 && byFlag.out.isEmpty, "\(flag) \(degenerate)")
                #expect(byFlag.err == "Error: \(flag) names no tag; name at least one tag or leave it out\n", "\(byFlag.err)")
                let byVariable = runCLI(
                    ["baerchen", "mcp-server", "--data-dir", lib.paths.root.path], stdin: stdin,
                    environment: [variable: degenerate])
                #expect(byVariable.exit == 64 && byVariable.out.isEmpty, "\(variable) \(degenerate)")
                #expect(byVariable.err == "Error: \(variable) names no tag; name at least one tag or leave it out\n")
            }
        }
        // A degenerate variable is irrelevant when the flag of its kind replaces it.
        let replaced = runCLI(
            ["baerchen", "mcp-server", "--data-dir", lib.paths.root.path, "--only-tags", "work"], stdin: stdin,
            environment: ["BAERCHEN_MCP_ONLY_TAGS": ""])
        #expect(replaced.exit == 0 && replaced.out.contains(#""title":"W""#) && !replaced.out.contains(#""title":"H""#))
    }

    @Test func theRunningServerAppliesFlagsAndEnvironment() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work"), TestNote(text: "# H\n#home")])
        let initialize = MCPProtocolTests.initialize
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#
        func titles(_ args: [String], environment: [String: String] = [:]) throws -> [String] {
            let r = runCLI(
                ["baerchen", "mcp-server", "--data-dir", lib.paths.root.path] + args,
                stdin: Data((initialize + "\n" + list + "\n").utf8), environment: environment)
            let replies = try r.out.split(separator: "\n").map { try JSONValue(parsing: Data($0.utf8)) }
            let notes = replies.last?["result"]?["structuredContent"]?["metadata"]?.array ?? []
            return notes.compactMap { $0["title"]?.string }.sorted()
        }
        #expect(try titles([]) == ["H", "W"])
        #expect(try titles(["--only-tags", "work"]) == ["W"])
        #expect(try titles(["--exclude-tags", "work"]) == ["H"])
        #expect(try titles([], environment: ["BAERCHEN_MCP_ONLY_TAGS": "home"]) == ["H"])
        // The flag of a kind replaces the variable of that kind; the other kind still applies.
        #expect(try titles(["--only-tags", "work"], environment: ["BAERCHEN_MCP_ONLY_TAGS": "home"]) == ["W"])
        #expect(
            try titles(["--only-tags", "work"], environment: ["BAERCHEN_MCP_EXCLUDE_TAGS": "work"]) == [])
    }

    @Test func scopeTagsAreNormalizedToCanonicalKeys() {
        let scope = NoteScope(onlyTags: ["#Work/Sub ", "work/sub", "  "], excludeTags: ["#Private#"])
        #expect(scope.onlyKeys == ["work/sub"] && scope.excludeKeys == ["private"])
        #expect(scope.onlyNames == ["Work/Sub"])
    }
}
