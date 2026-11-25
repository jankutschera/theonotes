// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// The write commands end to end, against temporary libraries.
@Suite struct WriteCommandsTests {
    private static let old = Date(timeIntervalSince1970: 1_000)

    private func run(_ lib: TestLibrary, _ args: [String], stdin: Data = Data(), tty: Bool = false) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args, stdin: stdin, stdinIsTTY: tty)
    }

    private func modified(_ lib: TestLibrary, _ id: String) throws -> Date { try lib.note(id).modifiedAt }

    private func addAttachment(_ lib: TestLibrary, _ id: String, _ name: String) throws {
        let store = AttachmentStore(paths: lib.paths, database: lib.library.database)
        #expect(try store.add(data: Data("x".utf8), filename: name, to: id) == name)
    }

    private func attachmentExists(_ lib: TestLibrary, _ id: String, _ name: String) -> Bool {
        AttachmentStore(paths: lib.paths, database: lib.library.database).url(for: name, noteId: id) != nil
    }

    // MARK: create

    @Test func createWritesTitleHeadingAfterFrontMatterAndTags() throws {
        let lib = try TestLibrary.make()
        let r = cli(
            lib, "create", "My Note", "--content", #"---\nk: v\n---\nBody"#, "--tags", "work, #a b#", "--format",
            "json")
        #expect(r.exit == 0)
        let id = try #require(try r.json()["id"]?.string)
        #expect(try lib.text(id) == "---\nk: v\n---\n# My Note\nBody\n#work #a b#")  // tagPosition default .bottom
        #expect(try r.json()["title"] == .string("My Note"))
        #expect(try r.json()["tags"] == .array([.string("#a b#"), .string("#work")]))
    }

    @Test func createPutsTagsAtTheConfiguredTopPosition() throws {
        let lib = try TestLibrary.make()
        Settings(db: lib.library.database).tagPosition = .top
        let r = cli(lib, "create", "T", "--content", "Body", "--tags", "x", "--fields", "id,title", "--format", "json")
        let id = try #require(try r.json()["id"]?.string)
        // The tag line goes below the title line, never above it (M5-R95): the title stays "T".
        #expect(try lib.text(id) == "# T\n#x\nBody")
        #expect(try r.json()["title"] == .string("T"))
        let again = cli(lib, "create", "T", "--if-not-exists", "--fields", "id")
        #expect(again.out.trimmingCharacters(in: .whitespacesAndNewlines) == id)
        // A title and nothing else; front matter; a BOM; nothing at all (M5-R94).
        let titleOnly = cli(lib, "create", "U", "--tags", "x", "--fields", "id")
        #expect(try lib.text(titleOnly.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "# U\n#x")
        let front = cli(lib, "create", "F", "--content", #"---\nk: v\n---\nBody"#, "--tags", "x", "--fields", "id")
        #expect(try lib.text(front.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "---\nk: v\n---\n# F\n#x\nBody")
        let bom = cli(lib, "create", "B", "--content", "\u{FEFF}Body", "--tags", "x", "--fields", "id")
        #expect(try lib.text(bom.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "\u{FEFF}# B\n#x\nBody")
        let bare = cli(lib, "create", "--tags", "x", "--fields", "id")
        #expect(try lib.text(bare.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "#x\n\n")
        Settings(db: lib.library.database).tagPosition = .bottom
        let bottom = cli(lib, "create", "--tags", "x", "--fields", "id")
        #expect(try lib.text(bottom.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "\n\n#x")
    }

    @Test func createKeepsExistingTitleLineAndIfNotExists() throws {
        let lib = try TestLibrary.make()
        let first = cli(lib, "create", "My Note", "--content", #"# my note\nx"#, "--fields", "id")
        #expect(first.exit == 0)
        let id = first.out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try lib.text(id) == "# my note\nx")  // the title line is already there
        let again = cli(lib, "create", "MY NOTE", "--if-not-exists", "--content", "ignored", "--fields", "id")
        #expect(again.exit == 0 && again.out.trimmingCharacters(in: .whitespacesAndNewlines) == id)
        let count = try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") }
        #expect(count == 1)
        #expect(try lib.text(id) == "# my note\nx")
        let other = cli(lib, "create", "Other", "--if-not-exists", "--fields", "id")
        #expect(other.exit == 0 && other.out.trimmingCharacters(in: .whitespacesAndNewlines) != id)
        #expect(try lib.text(other.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "# Other")
    }

    @Test func createFromTemplate() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# {{title}}\n{{date}}\n#template"), TestNote(text: "# Daily\n{{title}} on {{date}}\n#template/work"),
        ])
        let byId = try lib.firstId()
        let r = cli(lib, "create", "Standup", "--template", byId, "--fields", "id,tags", "--format", "json")
        #expect(r.exit == 0)
        let id = try #require(try r.json()["id"]?.string)
        #expect(try lib.text(id) == "# Standup\n2026-01-02")
        #expect(try r.json()["tags"] == .array([]))  // no #template tag on the new note
        // By title (case-insensitive), with --tags added after the template's own text.
        let byTitle = cli(lib, "create", "Retro", "--template", "daily", "--tags", "team", "--fields", "id,tags", "--format", "json")
        #expect(byTitle.exit == 0)
        #expect(try lib.text(try #require(try byTitle.json()["id"]?.string)) == "# Daily\nRetro on 2026-01-02\n#team")
        // The title is only used where the template says {{title}}; no heading is added.
        let plain = cli(lib, "create", "--template", "Daily", "--fields", "id")
        #expect(try lib.text(plain.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "# Daily\n on 2026-01-02")
    }

    @Test func createUsageAndTemplateErrors() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Secret\n#template", locked: true), TestNote(text: "# Plain"),
        ])
        let noTitle = cli(lib, "create", "--if-not-exists", "--content", "x")
        #expect(noTitle.exit == 64 && noTitle.err == "Error: --if-not-exists requires a title\n")
        let both = cli(lib, "create", "T", "--template", "Daily", "--content", "x")
        #expect(both.exit == 64 && both.err == "Error: Provide content or a template, not both\n")
        let missing = cli(lib, "create", "T", "--template", "Nope", "--format", "json")
        #expect(missing.exit == 1)
        #expect(missing.out == #"{"error":{"code":"note_not_found","message":"No template with title: Nope"}}"# + "\n")
        // A note that is not tagged #template is no template.
        #expect(cli(lib, "create", "T", "--template", "Plain").exit == 1)
        let locked = cli(lib, "create", "T", "--template", "Secret")
        let lockedId = try lib.firstId()
        #expect(locked.exit == 1 && locked.err == "Error: Note is locked: \(lockedId)\n")
        let badField = cli(lib, "create", "T", "--fields", "bogus")
        #expect(badField.exit == 64)
        // Arguments come before the library.
        let noLibrary = runCLI(["baerchen", "--data-dir", try TestLibrary.emptyFolder().path, "create", "--if-not-exists"])
        #expect(noLibrary.exit == 64)
        #expect(cli(lib, "create", "T", "--tags", "a b c#d#e").exit == 0)
    }

    @Test func stdinContentIsNotUnescapedAndTTYIsEmpty() throws {
        let lib = try TestLibrary.make()
        let r = run(lib, ["create", "S", "--fields", "id"], stdin: Data(#"a\nb"#.utf8))
        #expect(try lib.text(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) == #"# S"# + "\n" + #"a\nb"#)
        let tty = run(lib, ["create", "OnlyTitle", "--fields", "id"], stdin: Data("never read".utf8), tty: true)
        #expect(try lib.text(tty.out.trimmingCharacters(in: .whitespacesAndNewlines)) == "# OnlyTitle")
        // With a template stdin is not read at all.
        let lib2 = try TestLibrary.make([TestNote(text: "# Tpl\nbody\n#template")])
        let t = run(lib2, ["create", "--template", "Tpl", "--fields", "id"], stdin: Data("ignored".utf8))
        #expect(t.exit == 0)
    }

    // MARK: append, edit, overwrite

    @Test func appendEditOverwriteAndNoUpdateModified() throws {
        let doc = "# T\n## A\na\n## B\nb\n"
        let lib = try TestLibrary.make([TestNote(text: doc, modified: Self.old)])
        let id = try lib.firstId()
        #expect(cli(lib, "append", id, "--section", "## B", "--content", "b2", "--no-update-modified").exit == 0)
        #expect(try lib.text(id) == "# T\n## A\na\n## B\nb\nb2\n")
        #expect(try modified(lib, id) == Self.old)
        #expect(cli(lib, "append", id, "--content", "top", "--position", "beginning").exit == 0)
        #expect(try lib.text(id) == "# T\ntop\n## A\na\n## B\nb\nb2\n")
        #expect(try modified(lib, id) == TestLibrary.epoch)

        let edit = cli(
            lib, "edit", id, "--find", "top", "--replace", "TOP", "--find", "b2\\n", "--delete", "--no-update-modified")
        #expect(edit.exit == 0 && edit.out == "" && edit.err == "")
        #expect(try lib.text(id) == "# T\nTOP\n## A\na\n## B\nb\n")

        let hash = try cli(lib, "cat", id, "--format", "json").json()["hash"]!.string!
        let over = cli(lib, "overwrite", id, "--base", hash, "--content", #"# T\nnew"#)
        #expect(over.exit == 0 && over.out == "")
        #expect(try lib.text(id) == "# T\nnew")
        #expect(cli(lib, "overwrite", id, "--title", "T", "--content", "x").exit == 64)
    }

    @Test func editBatchWithAMissWritesNothing() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\nfoo bar\n")])
        let id = try lib.firstId()
        let r = cli(lib, "edit", id, "--find", "foo", "--replace", "x", "--find", "nope", "--delete")
        #expect(r.exit == 1 && r.err.hasPrefix("Error: No match for 1 of 2 edits; nothing was written."))
        #expect(try lib.text(id) == "# T\nfoo bar\n")
        #expect(try lib.note(id).revision == 1)
        // Usage errors come first and need no library.
        let noLibrary = runCLI(["baerchen", "--data-dir", try TestLibrary.emptyFolder().path, "edit", "X", "--find", "a"])
        #expect(noLibrary.exit == 64 && noLibrary.err.hasPrefix("Error: Every --find must be followed by exactly one action"))
    }

    @Test func staleBaseHashRejectedAfterConcurrentWrite() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n## B\nb\n")])
        let id = try lib.firstId()
        let noteHash = try cli(lib, "cat", id, "--format", "json").json()["hash"]!.string!
        let aHash = try cli(lib, "cat", id, "--section", "## A", "--format", "json").json()["hash"]!.string!
        _ = cli(lib, "append", id, "--section", "## B", "--content", "b2")  // another writer touches B only
        let stale = cli(lib, "overwrite", id, "--base", noteHash, "--content", "# T", "--format", "json")
        #expect(stale.exit == 64)  // --format is not an option of overwrite
        let plain = cli(lib, "overwrite", id, "--base", noteHash, "--content", "# T")
        #expect(plain.exit == 1 && plain.err.hasPrefix("Error: The note changed since it was read."))
        #expect(try lib.text(id) == "# T\n## A\na\n## B\nb\nb2\n")
        #expect(cli(lib, "overwrite", id, "--section", "## A", "--base", aHash, "--content", "## A\nnew").exit == 0)  // B's change does not matter
        #expect(try lib.text(id) == "# T\n## A\nnew\n## B\nb\nb2\n")
        // The whole-note hash is also accepted with an address when nothing changed.
        let fresh = try cli(lib, "cat", id, "--format", "json").json()["hash"]!.string!
        #expect(cli(lib, "overwrite", id, "--section", "## B", "--base", fresh, "--content", "## B\nz").exit == 0)
    }

    @Test func staleHashErrorCarriesTheCurrentHashOfTheSameUnit() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n")])
        let id = try lib.firstId()
        let service = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch))
        let error = #expect(throws: AutomationError.self) {
            try service.overwrite(
                .id(id), content: "# T", base: "0000000", address: nil, gate: .cli(force: false),
                preservingModifiedDate: false)
        }
        #expect(error?.code == .staleHash)
        #expect(error?.details == .object([("hash", .string(ContentHash.of("# T\n## A\na\n")))]))
        let section = #expect(throws: AutomationError.self) {
            try service.overwrite(
                .id(id), content: "## A", base: "0000000", address: "## A", gate: .cli(force: false),
                preservingModifiedDate: false)
        }
        #expect(section?.details == .object([("hash", .string(ContentHash.of("## A\na\n")))]))
    }

    @Test func attachmentGateOnCLI() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](a.jpg)\nkeep")])
        let id = try lib.firstId()
        try addAttachment(lib, id, "a.jpg")
        let gated = cli(lib, "overwrite", id, "--content", "# T")
        #expect(gated.exit == 1)
        #expect(gated.err.hasPrefix("Error: Attachments would be dropped: a.jpg."))
        #expect(try lib.text(id) == "# T\n![](a.jpg)\nkeep")
        let editGated = cli(lib, "edit", id, "--find", "![](a.jpg)\n", "--delete")
        #expect(editGated.exit == 1 && editGated.err.contains("a.jpg"))
        #expect(cli(lib, "overwrite", id, "--content", "# T", "--force").exit == 0)
        #expect(try lib.text(id) == "# T")
        #expect(attachmentExists(lib, id, "a.jpg"))  // R23: the CLI never deletes the file
    }

    @Test func theGateCountsALinkWithALiveRowEvenWithoutItsFile() throws {
        // The bytes may still be arriving (M5-R80): the indexer made a row for the link.
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](later.jpg)\nkeep")])
        let id = try lib.firstId()
        let live = cli(lib, "edit", id, "--find", "![](later.jpg)\n", "--delete")
        #expect(live.exit == 1 && live.err.hasPrefix("Error: Attachments would be dropped: later.jpg."))
        #expect(try lib.text(id) == "# T\n![](later.jpg)\nkeep")
        #expect(cli(lib, "edit", id, "--find", "![](later.jpg)\n", "--delete", "--force").exit == 0)
    }

    @Test func removingALinkWithNeitherFileNorRowIsNotGated() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](dead.jpg)\nkeep")])
        let id = try lib.firstId()
        try lib.library.database.pool.write { try $0.execute(sql: "DELETE FROM attachment WHERE noteId = ?", arguments: [id]) }
        #expect(cli(lib, "edit", id, "--find", "![](dead.jpg)\n", "--delete").exit == 0)
        #expect(try lib.text(id) == "# T\nkeep")
        // A tombstoned row does not count either.
        let other = try TestLibrary.make([TestNote(text: "# T\n![](old.jpg)")])
        let otherId = try other.firstId()
        try other.library.database.pool.write {
            try $0.execute(sql: "UPDATE attachment SET deletedAt = ? WHERE noteId = ?", arguments: [Date(), otherId])
        }
        #expect(cli(other, "overwrite", otherId, "--content", "# T").exit == 0)
    }

    @Test func overwriteAndAppendNeedContent() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n")])
        let id = try lib.firstId()
        for args in [["overwrite", id], ["overwrite", id, "--section", "## A"], ["append", id], ["append", id, "--section", "## A"]] {
            let r = run(lib, args, stdin: Data("ignored on a terminal".utf8), tty: true)
            #expect(r.exit == 64 && r.err == "Error: Content is required\n", "\(args)")
        }
        // Piped text is content.
        #expect(run(lib, ["append", id], stdin: Data("piped".utf8)).exit == 0)
        #expect(try lib.text(id) == "# T\n## A\na\npiped\n")
        // Nothing piped is no content either.
        let empty = run(lib, ["overwrite", id], stdin: Data())
        #expect(empty.exit == 64 && empty.err == "Error: Content is required\n")
        #expect(run(lib, ["append", id]).err == "Error: Content is required\n")
        let note = try lib.text(id)
        #expect(!note.isEmpty)
        // An explicit empty --content still empties the note or deletes the section.
        let fresh = try TestLibrary.make([TestNote(text: "# T\n## A\na\n## B\nb\n")])
        let freshId = try fresh.firstId()
        #expect(cli(fresh, "overwrite", freshId, "--section", "## A", "--content", "").exit == 0)
        #expect(try fresh.text(freshId) == "# T\n## B\nb\n")
        #expect(cli(fresh, "overwrite", freshId, "--content", "").exit == 0)
        #expect(try fresh.text(freshId) == "")
        // Arguments come before the library.
        let noLibrary = runCLI(["baerchen", "--data-dir", try TestLibrary.emptyFolder().path, "overwrite", "X"], stdinIsTTY: true)
        #expect(noLibrary.exit == 64)
    }

    @Test func trashAndArchiveOfANoteAlreadyThereChangeNothing() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One", location: .trash), TestNote(text: "# Two", location: .archive)])
        let one = try lib.id(titled: "One")
        let two = try lib.id(titled: "Two")
        let trashedAt = try lib.note(one).trashedAt
        let archivedAt = try lib.note(two).archivedAt
        let revisions = try (lib.note(one).revision, lib.note(two).revision)
        #expect(cli(lib, "trash", one, now: TestLibrary.epoch.addingTimeInterval(500)).exit == 0)
        #expect(cli(lib, "archive", two, now: TestLibrary.epoch.addingTimeInterval(500)).exit == 0)
        #expect(try lib.note(one).trashedAt == trashedAt && lib.note(one).revision == revisions.0)
        #expect(try lib.note(two).archivedAt == archivedAt && lib.note(two).revision == revisions.1)
    }

    @Test func tagNamesAreCheckedBeforeTheLibraryOpens() throws {
        let empty = try TestLibrary.emptyFolder().path
        for args in [["tags", "add", "X", "#"], ["tags", "remove", "X", "##"], ["tags", "rename", "a", "a/b"],
            ["tags", "rename", "#", "b"], ["tags", "delete", "#"]]
        {
            let r = runCLI(["baerchen", "--data-dir", empty] + args)
            #expect(r.exit == 64, "\(args)")
        }
    }

    @Test func createChecksArgumentsBeforeTheLibrary() throws {
        let empty = try TestLibrary.emptyFolder().path
        func run(_ args: String...) -> CLIResult {
            runCLI(["baerchen", "--data-dir", empty, "create"] + args, stdinIsTTY: true)
        }
        // Order: stdin/content, if-not-exists/template, tags, fields; the library comes last.
        #expect(run("--if-not-exists", "--template", "T", "--content", "x").err == "Error: --if-not-exists requires a title\n")
        #expect(run("T", "--template", "Daily", "--content", "x", "--tags", "#").err == "Error: Provide content or a template, not both\n")
        #expect(run("T", "--tags", "#, ,", "--fields", "bogus").err.hasPrefix("Error: Unknown field: bogus"))  // empty entries are dropped
        #expect(run("T", "--tags", "a", "--fields", "bogus").err.hasPrefix("Error: Unknown field: bogus"))
        let last = run("T", "--tags", "a", "--fields", "id")
        #expect(last.exit == 1 && last.err.hasPrefix("Error: "))
        #expect(!last.err.contains("Unknown field"))
    }

    @Test func lockedAndReadOnlyRefused() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# L\n## S", locked: true), TestNote(text: "# R\n#t", readOnly: true),
        ])
        let locked = try lib.id(titled: "L")
        let readOnly = try lib.id(titled: "R")
        #expect(cli(lib, "append", locked, "--content", "x").err == "Error: Note is locked: \(locked)\n")
        #expect(cli(lib, "append", readOnly, "--content", "x").err == "Error: Note is read-only: \(readOnly)\n")
        #expect(cli(lib, "overwrite", readOnly, "--content", "x").exit == 1)
        #expect(cli(lib, "edit", readOnly, "--find", "R", "--replace", "S").exit == 1)
        for args in [["tags", "add", locked, "x"], ["tags", "remove", locked, "x"], ["pin", "add", locked, "global"],
            ["trash", locked], ["archive", locked], ["restore", locked]]
        {
            let r = run(lib, args)
            #expect(r.exit == 1 && r.err == "Error: Note is locked: \(locked)\n", "\(args)")
        }
        #expect(cli(lib, "tags", "add", readOnly, "x").err == "Error: Note is read-only: \(readOnly)\n")
        // A bad address on a locked note is note_locked, never not_found (M5-R59).
        #expect(cli(lib, "append", locked, "--section", "## Nope", "--content", "x").err.contains("locked"))
        // The note resolves before the address syntax is looked at.
        let missing = cli(lib, "append", "NOPE", "--section", "", "--content", "x")
        #expect(missing.exit == 1 && missing.err == "Error: Note not found: NOPE\n")
        let syntax = cli(lib, "append", readOnly, "--section", "", "--content", "x")
        #expect(syntax.exit == 64 && syntax.err == "Error: Address must not be empty\n")
        // Pins and moves are allowed on a read-only note.
        #expect(cli(lib, "pin", "add", readOnly, "global").exit == 0)
        #expect(cli(lib, "archive", readOnly).exit == 0)
    }

    @Test func appendIntoSectionsAndErrors() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n## A\nb\n")])
        let id = try lib.firstId()
        let ambiguous = cli(lib, "append", id, "--section", "## A", "--content", "x")
        #expect(ambiguous.exit == 1 && ambiguous.err.hasPrefix("Error: 2 sections match that address;"))
        #expect(cli(lib, "append", id, "--section", "## A\\n2", "--content", "x").exit == 0)
        #expect(try lib.text(id) == "# T\n## A\na\n## A\nb\nx\n")
        #expect(cli(lib, "append", id, "--section", "## Nope", "--content", "x").err == "Error: No section matched the address.\n")
        let position = cli(lib, "append", id, "--position", "middle", "--content", "x")
        #expect(position.exit == 64)
        // Empty content writes nothing.
        let before = try lib.note(id).revision
        #expect(cli(lib, "append", id, "--content", "", "--no-update-modified").exit == 0)
        #expect(try lib.note(id).revision == before)
        // By title.
        #expect(cli(lib, "append", "--title", "t", "--content", "y").exit == 0)
        #expect(try lib.text(id).hasSuffix("x\ny\n"))
    }

    @Test func appendHonoursTheTagPositionSetting() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n#a\n")])
        let id = try lib.firstId()
        #expect(cli(lib, "append", id, "--content", "X", "--position", "beginning").exit == 0)
        #expect(try lib.text(id) == "# T\nX\n#a\n")  // .bottom: the tag line is a bottom tag
        let top = try TestLibrary.make([TestNote(text: "# T\n#a\n")])
        Settings(db: top.library.database).tagPosition = .top
        let topId = try top.firstId()
        #expect(cli(top, "append", topId, "--content", "X", "--position", "beginning").exit == 0)
        #expect(try top.text(topId) == "# T\n#a\nX\n")
    }

    // MARK: tags

    @Test func tagCommandsPreserveModifiedDate() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n#a #b", modified: Self.old)])
        let id = try lib.firstId()
        #expect(cli(lib, "tags", "add", id, "c", "#d e#").exit == 0)
        #expect(try modified(lib, id) == Self.old)
        #expect(try lib.text(id).hasSuffix("\n#c\n#d e#") || lib.text(id).contains("#c"))
        #expect(cli(lib, "tags", "remove", id, "b", "nothere").exit == 0)
        #expect(try modified(lib, id) == Self.old)
        #expect(cli(lib, "tags", "rename", "a", "z").exit == 0)
        #expect(try modified(lib, id) == Self.old)
        #expect(cli(lib, "tags", "delete", "c").exit == 0)
        #expect(try modified(lib, id) == Self.old)
        let tags = try cli(lib, "tags", "list", id, "--format", "json").json()
        #expect(tags.array?.compactMap { $0["tag"]?.string }.sorted() == ["#d e#", "#z"])
        let note = try lib.note(id)
        #expect(note.revision == 6)  // 1 + two tags added + one removed + rename + delete
    }

    @Test func tagsAddByTitleTakesEveryPositionalAsATag() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Mars")])
        #expect(cli(lib, "tags", "add", "--title", "mars", "favorite").exit == 0)
        #expect(try lib.text(try lib.firstId()) == "# Mars\n#favorite")
        #expect(cli(lib, "tags", "add", try lib.firstId()).err == "Error: <tags> is required\n")
        #expect(cli(lib, "tags", "add").err == "Error: Note ID or title is required\n")
    }

    @Test func cliRenameIntoReservedIsRefused() throws {
        let lib = try TestLibrary.make([TestNote(text: "# A\n#work"), TestNote(text: "# B\n#ref")])
        for target in ["idea", "Log", "ref"] {
            let r = cli(lib, "tags", "rename", "work", target, "--force")
            #expect(r.exit == 64 && r.err == "Error: #\(target) is a reserved tag name\n", "\(target)")
        }
        #expect(try lib.text(try lib.id(titled: "A")) == "# A\n#work")
        #expect(try lib.text(try lib.id(titled: "B")) == "# B\n#ref")
    }

    @Test func tagRenameRefusalsAndMerge() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# A\n#old #keep"), TestNote(text: "# B\n#new"), TestNote(text: "# C\n#old/child"),
        ])
        let exists = cli(lib, "tags", "rename", "old", "new")
        #expect(exists.exit == 1 && exists.err == "Error: Tag already exists: #new. Use --force to merge.\n")
        #expect(try lib.text(try lib.id(titled: "A")) == "# A\n#old #keep")
        let json = cli(lib, "tags", "rename", "--from", "old", "--to", "new", "--force")
        #expect(json.exit == 0 && json.out == "")
        #expect(try lib.text(try lib.id(titled: "A")) == "# A\n#new #keep")
        #expect(try lib.text(try lib.id(titled: "C")) == "# C\n#new/child")
        // Missing old tag: silent success.
        let none = cli(lib, "tags", "rename", "ghost", "other")
        #expect(none.exit == 0 && none.out == "" && none.err == "")
        // Argument forms.
        #expect(cli(lib, "tags", "rename", "a", "--from", "b").err == "Error: Provide the tag as an argument or option, not both\n")
        #expect(cli(lib, "tags", "rename").err == "Error: <old> is required\n")
        #expect(cli(lib, "tags", "rename", "a").err == "Error: <new> is required\n")
        #expect(cli(lib, "tags", "delete").err == "Error: <tag> is required\n")
        #expect(cli(lib, "tags", "delete", "x", "--name", "y").err == "Error: Provide the tag as an argument or option, not both\n")
        #expect(cli(lib, "tags", "rename", "keep", "keep/sub").exit == 64)
        // A locked note carrying the tag (or a child) refuses rename and delete, and nothing changes.
        let locked = try TestLibrary.make([TestNote(text: "# A\n#shared"), TestNote(text: "# L\n#shared/deep", locked: true)])
        for args in [["tags", "rename", "shared", "other"], ["tags", "delete", "shared"]] {
            let r = run(locked, args)
            #expect(r.exit == 1 && r.err == "Error: A locked note uses this tag. Unlock it in Theo Notes first.\n", "\(args)")
        }
        #expect(try locked.text(try locked.id(titled: "A")) == "# A\n#shared")
    }

    @Test func tagDeleteRemovesTagAndChildrenAndSkipsReadOnly() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# A\n#gone #stay"), TestNote(text: "# B\n#gone/child"),
            TestNote(text: "# R\n#gone", readOnly: true),
        ])
        #expect(cli(lib, "tags", "delete", "#gone").exit == 0)
        #expect(try lib.text(try lib.id(titled: "A")) == "# A\n#stay")
        #expect(try lib.text(try lib.id(titled: "B")) == "# B")
        #expect(try lib.text(try lib.id(titled: "R")) == "# R\n#gone")  // R10: read-only notes are skipped
        #expect(cli(lib, "tags", "delete", "never-existed").exit == 0)
        let service = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch))
        #expect(try service.renameTag(old: "stay", new: "stayed", force: false) == 1)
        #expect(try service.deleteTag("nothing") == 0)
    }

    // MARK: pins, locations

    @Test func pinsAreAtomic() throws {
        let lib = try TestLibrary.make([TestNote(text: "# P\n#work")])
        let id = try lib.firstId()
        let missing = cli(lib, "pin", "add", id, "global", "nope")
        #expect(missing.exit == 1 && missing.err == "Error: Tag not found: #nope\n")
        #expect(try lib.note(id).isPinnedGlobal == false)
        let untagged = try TestLibrary.make([TestNote(text: "# Q"), TestNote(text: "# O\n#other")])
        let q = try untagged.id(titled: "Q")
        let notTagged = cli(untagged, "pin", "add", q, "global", "other")
        #expect(notTagged.exit == 1 && notTagged.err == "Error: Note is not tagged #other\n")
        #expect(try untagged.note(q).isPinnedGlobal == false)

        #expect(cli(lib, "pin", "add", id, "global", "#work").exit == 0)
        #expect(try lib.note(id).isPinnedGlobal)
        #expect(try cli(lib, "pin", "list", id, "--format", "json").json().array?.compactMap { $0["pin"]?.string } == ["global", "#work"])
        #expect(cli(lib, "pin", "add", id, "global", "work").exit == 0)  // already applied: silent
        #expect(cli(lib, "pin", "remove", id, "global", "work").exit == 0)
        #expect(try lib.note(id).isPinnedGlobal == false)
        #expect(cli(lib, "pin", "list", id).out == "")
        #expect(cli(lib, "pin", "remove", id, "global", "nope").err == "Error: Tag not found: #nope\n")
        #expect(cli(lib, "pin", "add", id).err == "Error: <targets> is required\n")
        #expect(try modified(lib, id) == TestLibrary.epoch)
    }

    @Test func trashArchiveRestore() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One")])
        let id = try lib.firstId()
        #expect(cli(lib, "restore", id).exit == 0)  // already in Notes
        #expect(cli(lib, "trash", id).exit == 0)
        #expect(try lib.note(id).location == .trash)
        #expect(cli(lib, "trash", "--title", "One").err.contains("No active note has the title One."))  // titles see Notes only
        #expect(cli(lib, "archive", id).exit == 0)
        #expect(try lib.note(id).location == .archive)
        #expect(cli(lib, "restore", id).exit == 0)
        #expect(try lib.note(id).location == .notes)
        #expect(cli(lib, "trash", "--title", "One").exit == 0)
        #expect(cli(lib, "trash", "NOPE").err == "Error: Note not found: NOPE\n")
        #expect(cli(lib, "trash").exit == 64)
    }

    @Test func stateChangingCommandsHaveNoFormatOption() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One")])
        let id = try lib.firstId()
        for args in [["append", id, "--format", "json"], ["trash", id, "--format", "json"], ["tags", "add", id, "a", "--format", "json"],
            ["edit", id, "--format", "json"], ["overwrite", id, "--format", "json"], ["pin", "add", id, "global", "--format", "json"]]
        {
            #expect(run(lib, args).exit == 64, "\(args)")
        }
        #expect(try lib.note(id).revision == 1)
    }

    // MARK: notification

    @Test func writesPostTheDarwinNotification() throws {
        let lib = try TestLibrary.make([TestNote(text: "a")])
        let fired = Mutex(false)
        let token = ChangeNotifier().observe { fired.withLock { $0 = true } }
        _ = cli(lib, "append", try lib.firstId(), "--content", "b")
        #expect(try waitUntil(seconds: 2) { fired.withLock { $0 } })
        token.cancel()
    }
}
