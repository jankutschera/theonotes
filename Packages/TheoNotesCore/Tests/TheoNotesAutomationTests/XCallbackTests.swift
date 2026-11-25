// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

@Suite struct XCallbackTests {
    // MARK: Helpers

    static func request(_ action: String, _ query: String = "") throws -> XCallbackRequest {
        try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/\(action)" + (query.isEmpty ? "" : "?" + query))!)
    }

    final class Box: @unchecked Sendable {
        var selected: String?
        var clipboard: String?
    }

    func executor(_ lib: TestLibrary, _ box: Box = Box()) -> XCallbackExecutor {
        XCallbackExecutor(
            library: lib.library, context: .fixed(TestLibrary.epoch), selectedNoteId: { box.selected },
            clipboard: { box.clipboard })
    }

    func run(_ lib: TestLibrary, _ action: String, _ query: String = "", box: Box = Box()) throws -> XCallbackOutcome {
        executor(lib, box).execute(try Self.request(action, query))
    }

    func token(_ lib: TestLibrary) throws -> String {
        try AutomationToken.ensure(Settings(db: lib.library.database))
    }

    func value(_ outcome: XCallbackOutcome, _ key: String) -> String? {
        outcome.success?.first { $0.0 == key }?.1
    }

    func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    func json(_ text: String?) throws -> JSONValue {
        try JSONValue(parsing: Data(try #require(text).utf8))
    }

    // MARK: Parsing

    @Test func parsesActionsParamsAndCallbacks() throws {
        let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/create?title=My%20Note&text=a+b&tags=home,home%2Fgroceries&x-success=shortcuts://ok")!)
        #expect(r.action == .create && r.params["text"] == "a+b" && r.params["tags"] == "home,home/groceries" && r.success?.scheme == "shortcuts")
        #expect(r.params["title"] == "My Note" && r.params["x-success"] == nil)
        #expect(throws: XCallbackFailure.self) { try XCallbackRequest.parse(URL(string: "baerchen://other/create")!) }
        #expect(throws: XCallbackFailure.self) { try XCallbackRequest.parse(URL(string: "bear://x-callback-url/create")!) }
    }

    /// The renamed product (REN-R5): `theonotes://` is what the app emits, `baerchen://` links
    /// copied before the rename keep working.
    @Test func parsesBothSchemes() throws {
        #expect(XCallbackRequest.scheme == "theonotes")
        for scheme in ["theonotes", "baerchen", "THEONOTES", "Baerchen"] {
            let r = try XCallbackRequest.parse(URL(string: "\(scheme)://x-callback-url/open-note?id=X&x-success=shortcuts://ok")!)
            #expect(r.action == .openNote && r.params["id"] == "X" && r.success?.scheme == "shortcuts", "\(scheme)")
        }
        #expect(throws: XCallbackFailure.self) { try XCallbackRequest.parse(URL(string: "theonotes://other/create")!) }
        #expect(throws: XCallbackFailure.self) { try XCallbackRequest.parse(URL(string: "theonotes://x-callback-url/nope")!) }
        #expect(throws: XCallbackFailure(code: 5, message: "Action not supported: nope")) {
            try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/nope")!)
        }
    }

    /// FOC-R360: the dev build registers `theonotes-dev` / `baerchen-dev`; its links parse, and no
    /// callback may point back into either build.
    @Test func parsesTheDevIdentitysSchemesAndNeverCallsBackIntoAnyBuild() throws {
        for scheme in AppIdentity.dev.urlSchemes {
            let r = try XCallbackRequest.parse(URL(string: "\(scheme)://x-callback-url/open-note?id=X")!)
            #expect(r.action == .openNote && r.params["id"] == "X", "\(scheme)")
        }
        for scheme in AppIdentity.allCases.flatMap(\.urlSchemes) {
            #expect(!XCallbackOutcome.isAllowedScheme(scheme), "\(scheme) must not be a callback target")
        }
        #expect(XCallbackOutcome.isAllowedScheme("shortcuts"))
    }

    @Test func flagReadsYesNo() throws {
        let r = try Self.request("open-note", "a=yes&b=NO&c=maybe")
        #expect(r.flag("a") == true && r.flag("b") == false && r.flag("c") == nil && r.flag("d") == nil)
    }

    // MARK: Token

    @Test func tokenFormatAndRules() throws {
        let lib = try TestLibrary.make()
        let settings = Settings(db: lib.library.database)
        #expect(try settings.value(.automationToken) == "")
        let first = try AutomationToken.ensure(settings)
        #expect(first.range(of: "^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", options: .regularExpression) != nil)
        #expect(try AutomationToken.ensure(settings) == first)
        let second = try AutomationToken.regenerate(settings)
        let storedNow = try settings.value(.automationToken)
        #expect(second != first && storedNow == second)
        #expect(AutomationToken.matches(second, second) && !AutomationToken.matches(first, second))
        // A length difference of 256 must not wrap to "equal" (fix round 1).
        #expect(!AutomationToken.matches(second + String(repeating: "\0", count: 256), second))
        #expect(!AutomationToken.matches(second + String(repeating: "\0", count: 1), second))
        #expect(!AutomationToken.matches(String(second.dropLast()), second))
        #expect(!AutomationToken.matches(nil, second) && !AutomationToken.matches("", ""))
        #expect(!AutomationToken.matches("", "") && !AutomationToken.matches("x", ""))
    }

    @Test func tokenRulesForDataReturningActions() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Work\n#work"), TestNote(text: "# Loose"), TestNote(text: "# Task\n- [ ] a\n#home"),
            TestNote(text: "", locked: true),
        ])
        let token = try token(lib)
        // tags always needs a token
        #expect(try run(lib, "tags").failure?.code == 4)
        #expect(try run(lib, "tags", "token=WRONG").failure?.code == 4)
        let tags = try run(lib, "tags", "token=\(token)")
        #expect(tags.failure == nil)
        #expect(try json(value(tags, "tags")).array?.compactMap { $0["name"]?.string }.sorted() == ["home", "work"])
        // open-tag: UI without a token, no notes
        let bare = try run(lib, "open-tag", "name=work")
        #expect(bare.failure == nil && bare.ui == .select(.tag("work"), search: nil, showWindow: true))
        #expect(value(bare, "notes") == nil)
        let withToken = try run(lib, "open-tag", "name=work&token=\(token)")
        let notes = try #require(try json(value(withToken, "notes")).array)
        #expect(notes.count == 1 && notes[0]["title"]?.string == "Work" && notes[0]["pin"]?.string == "no")
        #expect(notes[0].keys == ["title", "identifier", "modificationDate", "creationDate", "pin"])
        // a wrong token is refused outright
        #expect(try run(lib, "open-tag", "name=work&token=WRONG").failure?.code == 4)
        // untagged returns tags; the locked note never appears
        let untagged = try run(lib, "untagged", "token=\(token)")
        #expect(untagged.ui == .select(.untagged, search: nil, showWindow: true))
        let loose = try #require(try json(value(untagged, "notes")).array)
        #expect(loose.map { $0["title"]?.string } == ["Loose"] && loose[0]["tags"]?.array?.isEmpty == true)
        let todo = try run(lib, "todo", "token=\(token)")
        #expect(try json(value(todo, "notes")).array?.first?["tags"]?.array == [.string("home")])
        let found = try run(lib, "search", "term=Loose&token=\(token)")
        #expect(found.ui == .select(.notes, search: "Loose", showWindow: true))
        #expect(try json(value(found, "notes")).array?.count == 1)
        let inTag = try run(lib, "search", "tag=work&show_window=no")
        #expect(inTag.ui == .select(.tag("work"), search: nil, showWindow: false) && value(inTag, "notes") == nil)
        // selected=yes needs the token
        let box = Box()
        box.selected = try lib.id(titled: "Loose")
        #expect(try run(lib, "open-note", "selected=yes", box: box).failure?.code == 4)
        #expect(try value(run(lib, "open-note", "selected=yes&token=\(token)", box: box), "title") == "Loose")
    }

    // MARK: open-note

    @Test func openNoteReturnsContentButNeverForLockedNotes() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Hello\nbody\n#a/b", created: Date(timeIntervalSince1970: 1_000_000_000), modified: Date(timeIntervalSince1970: 1_000_000_060)),
            TestNote(text: "", locked: true), TestNote(text: "# Gone", location: .trash),
        ])
        let token = try token(lib)
        let id = try lib.id(titled: "Hello")
        let open = try run(lib, "open-note", "id=\(id)&header=Part&new_window=yes&float=yes&edit=yes&search=body&show_window=no&token=\(token)")
        #expect(open.failure == nil)
        #expect(open.ui == .openNote(id: id, header: "Part", newWindow: true, float: true, edit: true, find: "body", showWindow: false))
        #expect(value(open, "note") == "# Hello\nbody\n#a/b")
        #expect(value(open, "identifier") == id && value(open, "title") == "Hello")
        #expect(try json(value(open, "tags")) == .array([.string("a"), .string("a/b")]))
        #expect(value(open, "is_trashed") == "no")
        #expect(value(open, "modificationDate") == "2001-09-09T01:47:40Z" && value(open, "creationDate") == "2001-09-09T01:46:40Z")
        #expect(try run(lib, "open-note", "id=\(id)&open_note=no&token=\(token)").ui == .none)
        // by title
        #expect(try value(run(lib, "open-note", "title=hello&token=\(token)"), "identifier") == id)
        // trashed
        let gone = try lib.id(titled: "Gone")
        #expect(try value(run(lib, "open-note", "id=\(gone)&token=\(token)"), "is_trashed") == "yes")
        #expect(try run(lib, "open-note", "id=\(gone)&exclude_trashed=yes&token=\(token)").failure?.code == 2)
        // locked: failure 3, no note
        let locked = try lib.firstIdLocked()
        let refused = try run(lib, "open-note", "id=\(locked)&token=\(token)")
        #expect(refused.failure?.code == 3 && value(refused, "note") == nil && refused.success == nil)
        // not found / missing params
        #expect(try run(lib, "open-note", "id=NOPE&token=\(token)").failure == XCallbackFailure(code: 2, message: "Note not found: NOPE"))
        #expect(try run(lib, "open-note").failure?.code == 1)
        // pin
        _ = try run(lib, "open-note", "id=\(id)&pin=yes&token=\(token)")
        #expect(try lib.note(id).isPinnedGlobal)
    }

    // MARK: create

    @Test func createWritesTitleTextTagsAndPin() throws {
        let lib = try TestLibrary.make()
        let token = try token(lib)
        let out = try run(lib, "create", "title=My%20Note&text=First%20line&tags=home,home%2Fgroceries&pin=yes&token=\(token)")
        #expect(out.failure == nil && value(out, "title") == "My Note")
        let id = try #require(value(out, "identifier"))
        let note = try lib.note(id)
        #expect(note.text.hasPrefix("# My Note\nFirst line") && note.isPinnedGlobal)
        #expect(NoteParser.metadata(for: note.text).tags.sorted() == ["home", "home/groceries"])
        #expect(out.ui == .openNote(id: id, header: nil, newWindow: false, float: false, edit: false, find: nil, showWindow: true))
        #expect(try run(lib, "create", "text=x&open_note=no&token=\(token)").ui == .none)
    }

    @Test func createClipboardTimestampAndEmptyNotes() throws {
        let lib = try TestLibrary.make()
        let token = try token(lib)
        let box = Box()
        box.clipboard = "from the clipboard"
        let out = try run(lib, "create", "clipboard=yes&timestamp=yes&token=\(token)", box: box)
        let text = try lib.text(try #require(value(out, "identifier")))
        #expect(text == "2026-01-02 03:04\nfrom the clipboard")
        let empty = try run(lib, "create", "text=&tags=a&token=\(token)")
        #expect(empty.failure == XCallbackFailure(code: 1, message: "Empty notes are not allowed"))
        #expect(try run(lib, "create").failure?.code == 1)
        #expect(try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") } == 1)
    }

    /// `url` is the base for relative `<img src>`: resolved as text, never fetched (final review M7).
    @Test func createFromHTMLResolvesRelativeImagesAgainstURL() throws {
        let lib = try TestLibrary.make()
        let html = encoded(#"<h1>Page</h1><p>body</p><img src="pics/a.png"><img src="javascript:x">"#)
        let base = encoded("https://example.com/blog/post.html")
        let out = try run(lib, "create", "type=html&text=\(html)&url=\(base)")
        let text = try lib.text(try #require(value(out, "identifier")))
        #expect(text.contains("![](https://example.com/blog/pics/a.png)"), "\(text)")
        #expect(!text.contains("javascript"))
        let without = try run(lib, "create", "type=html&text=\(html)")
        #expect(!(try lib.text(try #require(value(without, "identifier")))).contains("!["))
    }

    @Test func createFromHTMLAndWithFile() throws {
        let lib = try TestLibrary.make()
        let token = try token(lib)
        let html = encoded("<h2>Head</h2><p>Some <b>bold</b> text</p>")
        let out = try run(lib, "create", "type=html&text=\(html)&token=\(token)")
        let text = try lib.text(try #require(value(out, "identifier")))
        #expect(text.contains("## Head") && text.contains("**bold**") && !text.contains("<"))
        // file + filename (base64, `+` stays literal when unescaped)
        let data = Data("hello file".utf8).base64EncodedString()
        let withFile = try run(lib, "create", "title=F&file=\(encoded(data))&filename=hello.txt&token=\(token)")
        let id = try #require(value(withFile, "identifier"))
        #expect(try lib.text(id).contains("hello.txt"))
        #expect(NoteParser.metadata(for: try lib.text(id)).attachments.map(\.filename) == ["hello.txt"])
        // only one of file / filename is a parameter error
        #expect(try run(lib, "create", "text=x&file=\(encoded(data))&token=\(token)").failure?.code == 1)
        #expect(try run(lib, "create", "text=x&file=%21%21&filename=a.txt&token=\(token)").failure?.code == 1)
    }

    // MARK: add-text

    @Test func createAddTextModesAndHeader() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# Title\nline one\n\n#tag"),
            TestNote(text: "# Doc\nintro\n## Part\nbody\n## Other\nmore\n"),
            TestNote(text: "# Only Title"),
        ])
        let token = try token(lib)
        let id = try lib.id(titled: "Title")
        // append concatenates to the last line (M5-R22), before the bottom tag
        var out = try run(lib, "add-text", "id=\(id)&text=%20more&mode=append&token=\(token)")
        #expect(out.failure == nil && value(out, "title") == "Title")
        #expect(try lib.text(id) == "# Title\nline one more\n\n#tag")
        #expect(value(out, "note") == "# Title\nline one more\n\n#tag")
        // default mode is append
        _ = try run(lib, "add-text", "id=\(id)&text=!&token=\(token)")
        #expect(try lib.text(id) == "# Title\nline one more!\n\n#tag")
        // new_line=yes puts it on its own line
        _ = try run(lib, "add-text", "id=\(id)&text=next&new_line=yes&token=\(token)")
        #expect(try lib.text(id) == "# Title\nline one more!\nnext\n\n#tag")
        // prepend goes after the title
        _ = try run(lib, "add-text", "id=\(id)&text=first&mode=prepend&token=\(token)")
        #expect(try lib.text(id) == "# Title\nfirst\nline one more!\nnext\n\n#tag")
        // timestamp
        _ = try run(lib, "add-text", "id=\(id)&text=t&mode=prepend&timestamp=yes&token=\(token)")
        #expect(try lib.text(id).hasPrefix("# Title\n2026-01-02 03:04\nt\nfirst\n"))
        // replace keeps the title; replace_all does not
        _ = try run(lib, "add-text", "id=\(id)&text=fresh&mode=replace&token=\(token)")
        #expect(try lib.text(id) == "# Title\nfresh")
        _ = try run(lib, "add-text", "title=Title&text=%23%20Other&mode=replace_all&token=\(token)")
        #expect(try lib.text(id) == "# Other")
        // title-only note: append never glues onto the title line
        let only = try lib.id(titled: "Only Title")
        _ = try run(lib, "add-text", "id=\(only)&text=body&token=\(token)")
        #expect(try lib.text(only) == "# Only Title\nbody\n")
        // header sections
        let doc = try lib.id(titled: "Doc")
        _ = try run(lib, "add-text", "id=\(doc)&header=part&text=%21&mode=append&token=\(token)")
        #expect(try lib.text(doc) == "# Doc\nintro\n## Part\nbody!\n## Other\nmore\n")
        _ = try run(lib, "add-text", "id=\(doc)&header=Part&text=top&mode=prepend&token=\(token)")
        #expect(try lib.text(doc) == "# Doc\nintro\n## Part\ntop\nbody!\n## Other\nmore\n")
        _ = try run(lib, "add-text", "id=\(doc)&header=Part&text=new&mode=replace&token=\(token)")
        #expect(try lib.text(doc) == "# Doc\nintro\n## Part\nnew\n## Other\nmore\n")
        let missing = try run(lib, "add-text", "id=\(doc)&header=Nope&text=x&token=\(token)")
        #expect(missing.failure?.code == 1)
        #expect(try lib.text(doc) == "# Doc\nintro\n## Part\nnew\n## Other\nmore\n")
        // tags
        out = try run(lib, "add-text", "id=\(doc)&text=x&tags=one,two%2Fthree&token=\(token)")
        #expect(NoteParser.metadata(for: try lib.text(doc)).tags.sorted() == ["one", "two/three"])
        // errors
        #expect(try run(lib, "add-text", "id=\(doc)&mode=sideways&text=x&token=\(token)").failure?.code == 1)
        #expect(try run(lib, "add-text", "id=\(doc)&token=\(token)").failure?.code == 1)
        #expect(try run(lib, "add-text", "id=NOPE&text=x&token=\(token)").failure?.code == 2)
    }

    @Test func addTextRefusesLockedReadOnlyAndAttachmentLoss() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "", locked: true), TestNote(text: "# RO\nbody", readOnly: true),
        ])
        let token = try token(lib)
        #expect(try run(lib, "add-text", "id=\(try lib.firstIdLocked())&text=x&token=\(token)").failure?.code == 3)
        let ro = try lib.id(titled: "RO")
        #expect(try run(lib, "add-text", "id=\(ro)&text=x&token=\(token)").failure?.code == 3)
        #expect(try lib.text(ro) == "# RO\nbody")
        // replacing text that links an attachment is refused (the gate)
        let note = try run(lib, "create", "title=A&text=body&token=\(token)")
        let id = try #require(value(note, "identifier"))
        _ = try run(lib, "add-file", "id=\(id)&filename=a.txt&file=\(encoded(Data("x".utf8).base64EncodedString()))")
        let refused = try run(lib, "add-text", "id=\(id)&text=gone&mode=replace_all&token=\(token)")
        let kept = try lib.text(id)
        #expect(refused.failure?.code == 6 && kept.contains("a.txt"))
    }

    // MARK: add-file

    @Test func addFileAppendsAttachmentLink() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nintro\n## Part\nbody\n## Other\nmore\n\n#t")])
        let token = try token(lib)
        let id = try lib.id(titled: "Doc")
        let file = encoded(Data("one".utf8).base64EncodedString())
        let out = try run(lib, "add-file", "id=\(id)&filename=one.txt&file=\(file)&token=\(token)")
        let written = try lib.text(id)
        #expect(out.failure == nil && value(out, "note") == written)
        #expect(try lib.text(id) == "# Doc\nintro\n## Part\nbody\n## Other\nmore\n[one.txt](one.txt)\n\n#t".replacingOccurrences(of: "[one.txt](one.txt)", with: AttachmentMarkdown.link(for: "one.txt")))
        let header = try run(lib, "add-file", "id=\(id)&filename=two.txt&file=\(file)&header=Part&mode=prepend&token=\(token)")
        #expect(header.failure == nil)
        let text = try lib.text(id)
        #expect(text.contains("## Part\n" + AttachmentMarkdown.link(for: "two.txt") + "\nbody"))
        #expect(try run(lib, "add-file", "id=\(id)&filename=x.txt&token=\(token)").failure?.code == 1)
        #expect(try run(lib, "add-file", "id=\(id)&file=\(file)&token=\(token)").failure?.code == 1)
        #expect(try run(lib, "add-file", "id=NOPE&filename=x.txt&file=\(file)&token=\(token)").failure?.code == 2)
    }

    // MARK: tags, trash, archive, rename, delete

    @Test func tagLocationAndWorkspaceActions() throws {
        let lib = try TestLibrary.make([TestNote(text: "# A\n#old/x"), TestNote(text: "# B\n#old")])
        let token = try token(lib)
        let a = try lib.id(titled: "A")
        let renamed = try run(lib, "rename-tag", "name=old&new_name=new&token=\(token)")
        #expect(renamed.failure == nil && renamed.success?.isEmpty == true)
        #expect(try lib.text(a).contains("#new/x"))
        #expect(try run(lib, "rename-tag", "name=new&token=\(token)").failure?.code == 1)
        let deleted = try run(lib, "delete-tag", "name=new&token=\(token)")
        let afterDelete = try lib.text(a)
        #expect(deleted.failure == nil && !afterDelete.contains("#new"))
        #expect(try run(lib, "delete-tag", "token=\(token)").failure?.code == 1)

        let trashed = try run(lib, "trash", "id=\(a)&token=\(token)")
        let trashedLocation = try lib.note(a).location
        #expect(trashed.ui == .select(.trash, search: nil, showWindow: true) && trashedLocation == .trash)
        let searched = try run(lib, "archive", "search=B&show_window=no&token=\(token)")
        #expect(searched.ui == .select(.archive, search: "B", showWindow: false))
        #expect(try lib.note(try lib.id(titled: "B")).location == .notes)
        #expect(try run(lib, "archive", "id=\(try lib.id(titled: "B"))&token=\(token)").failure == nil)
        #expect(try lib.note(try lib.id(titled: "B")).location == .archive)
        #expect(try run(lib, "trash").failure?.code == 1)
        #expect(try run(lib, "trash", "id=NOPE&token=\(token)").failure?.code == 2)

        #expect(try run(lib, "locked", "search=x").ui == .select(.locked, search: "x", showWindow: true))
        #expect(try run(lib, "open-workspace", "name=work").ui == .openWorkspace("work"))
        #expect(try run(lib, "open-workspace").failure?.code == 1)
        #expect(try run(lib, "close-workspace").ui == .closeWorkspace)
    }

    @Test func lockedNotesBlockTagRename() throws {
        let lib = try TestLibrary.make([TestNote(text: "# A\n#x")])
        let token = try token(lib)
        let id = try lib.id(titled: "A")
        try lib.library.database.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [id]) }
        #expect(try run(lib, "rename-tag", "name=x&new_name=y&token=\(token)").failure?.code == 3)
    }

    // MARK: callbacks

    @Test func callbacksNeverOpenWebSchemes() throws {
        let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-success=https://evil.example/c")!)
        #expect(XCallbackOutcome(ui: .none, success: [("note", "secret")], failure: nil).callbackURL(for: r) == nil)
        for scheme in ["http", "file", "ftp", "data", "javascript", "about", "baerchen", "theonotes", "HTTPS"] {
            let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-success=\(scheme):x&x-error=\(scheme):y")!)
            #expect(XCallbackOutcome(ui: .none, success: [], failure: nil).callbackURL(for: r) == nil)
            #expect(XCallbackOutcome(ui: .none, success: nil, failure: XCallbackFailure(code: 6, message: "m")).callbackURL(for: r) == nil)
        }
    }

    @Test func successCallbackAppendsEncodedParams() throws {
        let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-success=shortcuts://run?name=a")!)
        let url = XCallbackOutcome(ui: .none, success: [("note", "a b&c+d"), ("title", "T")], failure: nil).callbackURL(for: r)
        #expect(url?.absoluteString == "shortcuts://run?name=a&note=a%20b%26c%2Bd&title=T")
        let bare = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-success=drafts://ok")!)
        #expect(XCallbackOutcome(ui: .none, success: [], failure: nil).callbackURL(for: bare)?.absoluteString == "drafts://ok")
        // no x-success: nothing to call
        let none = try Self.request("open-note", "id=X")
        #expect(XCallbackOutcome(ui: .none, success: [], failure: nil).callbackURL(for: none) == nil)
        // a failure never goes to x-success
        #expect(XCallbackOutcome(ui: .none, success: nil, failure: XCallbackFailure(code: 2, message: "m")).callbackURL(for: bare) == nil)
    }

    @Test func errorCallbackCarriesCodeAndMessage() throws {
        let lib = try TestLibrary.make()
        let token = try token(lib)
        let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-error=drafts://e&x-success=drafts://ok&token=\(token)")!)
        let outcome = executor(lib).execute(r)
        #expect(outcome.callbackURL(for: r)?.absoluteString == "drafts://e?errorCode=2&errorMessage=Note%20not%20found%3A%20X")
        // without a valid token only the code and its generic text go out; the app still has the detail
        let bare = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-error=drafts://e")!)
        let plain = executor(lib).execute(bare)
        #expect(plain.callbackURL(for: bare)?.absoluteString == "drafts://e?errorCode=2&errorMessage=Note%20not%20found")
        #expect(plain.failure?.message == "Note not found: X")
    }

    // MARK: Fix round 1

    func attachmentFiles(_ lib: TestLibrary, _ id: String) -> [String] {
        let dir = AttachmentFiles(paths: lib.paths, database: lib.library.database).directory(for: id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func noteCount(_ lib: TestLibrary) throws -> Int {
        try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") ?? 0 }
    }

    @Test func dataInCallbacksNeedsTheToken() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody\n#t")])
        let id = try lib.id(titled: "Doc")
        let token = try token(lib)
        let file = encoded(Data("x".utf8).base64EncodedString())
        // open-note: opens and pins, returns nothing
        let open = try run(lib, "open-note", "id=\(id)&pin=yes")
        #expect(open.failure == nil && open.success?.isEmpty == true)
        #expect(open.ui == .openNote(id: id, header: nil, newWindow: false, float: false, edit: false, find: nil, showWindow: true))
        #expect(try lib.note(id).isPinnedGlobal)
        // add-text append and prepend: written, only the identifier comes back
        let append = try run(lib, "add-text", "id=\(id)&text=more")
        #expect(append.failure == nil && append.success?.map(\.0) == ["identifier"] && value(append, "identifier") == id)
        #expect(append.ui != .none)
        let prepend = try run(lib, "add-text", "title=Doc&text=first&mode=prepend")
        #expect(prepend.success?.map(\.0) == ["identifier"])
        let written = try lib.text(id)
        #expect(written.contains("more") && written.contains("first"))
        // add-file append
        let added = try run(lib, "add-file", "id=\(id)&filename=a.txt&file=\(file)")
        #expect(added.failure == nil && added.success?.map(\.0) == ["identifier"])
        #expect(attachmentFiles(lib, id) == ["a.txt"])
        // create: written, identifier only
        let created = try run(lib, "create", "title=Fresh&text=body")
        #expect(created.failure == nil && created.success?.map(\.0) == ["identifier"])
        #expect(try lib.text(try #require(value(created, "identifier"))).hasPrefix("# Fresh"))
        // with the token the data is back
        #expect(value(try run(lib, "add-text", "id=\(id)&text=x&token=\(token)"), "note") != nil)
        #expect(value(try run(lib, "open-note", "id=\(id)&token=\(token)"), "title") == "Doc")
        #expect(value(try run(lib, "create", "title=T2&token=\(token)"), "title") == "T2")
        // a wrong token stops everything before anything is written
        let before = try noteCount(lib)
        #expect(try run(lib, "create", "text=x&token=WRONG").failure?.code == 4)
        #expect(try run(lib, "add-text", "id=\(id)&text=zzz&token=WRONG").failure?.code == 4)
        let afterWrong = try lib.text(id)
        #expect(try noteCount(lib) == before && !afterWrong.contains("zzz"))
    }

    @Test func destructiveActionsNeedTheToken() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody\n#old/x"), TestNote(text: "# Other\n#old")])
        let id = try lib.id(titled: "Doc")
        let original = try lib.text(id)
        let file = encoded(Data("x".utf8).base64EncodedString())
        for (action, query) in [
            ("trash", "id=\(id)"), ("archive", "id=\(id)"), ("rename-tag", "name=old&new_name=new"),
            ("delete-tag", "name=old"), ("add-text", "id=\(id)&text=gone&mode=replace"),
            ("add-text", "id=\(id)&text=gone&mode=replace_all"),
            ("add-file", "id=\(id)&filename=a.txt&file=\(file)&mode=replace"),
            ("add-file", "id=\(id)&filename=a.txt&file=\(file)&mode=replace_all"),
        ] {
            let out = try run(lib, action, query)
            #expect(out.failure?.code == 4 && out.ui == .none, "\(action) \(query)")
        }
        let unchanged = try lib.text(id)
        let location = try lib.note(id).location
        #expect(unchanged == original && location == .notes)
        #expect(attachmentFiles(lib, id).isEmpty)
        #expect(try lib.text(try lib.id(titled: "Other")).contains("#old"))
        // archive / trash by search only select; nothing is written, so no token
        #expect(try run(lib, "trash", "search=x").failure == nil)
        // append, prepend and create stay open
        #expect(try run(lib, "add-text", "id=\(id)&text=a&mode=append").failure == nil)
        #expect(try run(lib, "add-text", "id=\(id)&text=b&mode=prepend").failure == nil)
        #expect(try run(lib, "create", "text=c").failure == nil)
    }

    @Test func callbackSchemesFollowTheAllowlistRule() throws {
        for scheme in [
            "http", "https", "file", "ftp", "data", "javascript", "about", "baerchen", "blob", "ws", "wss", "ssh",
            "sftp", "smb", "afp", "vnc", "tel", "sms", "mailto", "facetime", "x-apple-reminder", "x-apple-helpbasic",
            "itms", "itms-apps", "itms-services", "ms-word", "ms-excel", "googlechrome", "googlechromes", "firefox",
            "firefox-focus", "opera-http", "opera", "microsoft-edge", "microsoft-edge-https", "brave", "bravehttp",
            "HTTPS", "Mailto", "1abc", "a_b", "a b", "", "-x", ".x", "é",
        ] {
            #expect(!XCallbackOutcome.isAllowedScheme(scheme), "\(scheme)")
        }
        for scheme in ["shortcuts", "drafts", "things", "ulysses", "x-bear", "x-callback.app", "a+b-c.d", "obsidian", "Shortcuts"] {
            #expect(XCallbackOutcome.isAllowedScheme(scheme), "\(scheme)")
        }
        for scheme in ["blob", "ws", "wss", "ssh", "sftp", "smb", "afp", "vnc", "tel", "sms", "mailto", "facetime", "x-apple-reminder", "itms-apps", "ms-word", "googlechromes", "firefox-focus", "opera-http", "microsoft-edge-https", "brave"] {
            let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/open-note?id=X&x-success=\(scheme):x&x-error=\(scheme):y")!)
            #expect(XCallbackOutcome(ui: .none, success: [], failure: nil).callbackURL(for: r) == nil, "\(scheme)")
            #expect(XCallbackOutcome(ui: .none, success: nil, failure: XCallbackFailure(code: 6, message: "m")).callbackURL(for: r) == nil)
        }
    }

    @Test func rejectedAddFileLeavesNoFile() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
        let id = try lib.id(titled: "Doc")
        let token = try token(lib)
        let file = encoded(Data("one".utf8).base64EncodedString())
        #expect(try run(lib, "add-file", "id=\(id)&filename=one.txt&file=\(file)&token=\(token)").failure == nil)
        let text = try lib.text(id)
        let files = attachmentFiles(lib, id)
        #expect(files == ["one.txt"])
        // replace_all would drop the link to one.txt: refused by the gate, the new file is not kept
        let other = encoded(Data("two".utf8).base64EncodedString())
        for mode in ["replace_all", "replace"] {
            let refused = try run(lib, "add-file", "id=\(id)&filename=two.txt&file=\(other)&mode=\(mode)&token=\(token)")
            #expect(refused.failure?.code == 6)
            let now = try lib.text(id)
            #expect(attachmentFiles(lib, id) == files && now == text)
        }
    }

    @Test func serviceRemovesAFilePlacedForAFailedWrite() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
        let id = try lib.id(titled: "Doc")
        let service = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch))
        struct Boom: Error {}
        #expect(throws: AutomationError.self) {
            _ = try service.addAttachment(.id(id), data: Data("x".utf8), filename: "x.txt", preservingModifiedDate: false) {
                _, _, _ throws(AutomationError) in throw AutomationError(code: .internal, message: "no")
            }
        }
        #expect(attachmentFiles(lib, id).isEmpty)
    }

    @Test func oversizedFilesAndImagesAreRefusedBeforeAnythingIsCreated() throws {
        let lib = try TestLibrary.make()
        var small = AutomationContext.fixed(TestLibrary.epoch)
        small.maxAttachmentBytes = 10
        let limited = XCallbackExecutor(library: lib.library, context: small, selectedNoteId: { nil }, clipboard: { nil })
        func go(_ action: String, _ query: String) throws -> XCallbackOutcome { limited.execute(try Self.request(action, query)) }
        let big = Data(repeating: 0x41, count: 30).base64EncodedString()
        #expect(try go("create", "text=x&filename=a.txt&file=\(encoded(big))").failure?.code == 1)
        // a base64 string far over the cap is refused on its length, with whitespace padding too
        let huge = String(repeating: "QUFB", count: 10_000)
        #expect(try go("create", "text=x&filename=a.txt&file=\(huge)").failure?.code == 1)
        #expect(try go("create", "text=x&filename=a.txt&file=\(encoded(huge + " " + huge))").failure?.code == 1)
        // an HTML image over the cap
        let png = Data(repeating: 0x41, count: 30).base64EncodedString()
        let html = encoded("<p>hi</p><img src=\"data:image/png;base64,\(png)\">")
        #expect(try go("create", "type=html&text=\(html)").failure?.code == 1)
        // the same image fits the default cap and is stored with the note
        let ok = try run(lib, "create", "type=html&text=\(html)")
        let created = try #require(value(ok, "identifier"))
        #expect(ok.failure == nil && attachmentFiles(lib, created).count == 1)
        // a bad name is refused before the note exists
        #expect(try noteCount(lib) == 1)
        #expect(try run(lib, "create", "text=x&filename=..&file=\(encoded(Data("x".utf8).base64EncodedString()))").failure?.code == 1)
        #expect(try noteCount(lib) == 1)
    }

    @Test func failedAttachmentRollsTheNewNoteBack() throws {
        let lib = try TestLibrary.make()
        let root = AttachmentFiles(paths: lib.paths, database: lib.library.database).root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let out = try run(lib, "create", "title=X&filename=a.txt&file=\(encoded(Data("x".utf8).base64EncodedString()))")
        #expect(out.failure != nil)
        #expect(try noteCount(lib) == 0)
    }

    @Test func missingHeaderWritesNothingNotEvenTags() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
        let id = try lib.id(titled: "Doc")
        let before = try lib.text(id)
        for query in ["id=\(id)&header=Missing&tags=one", "id=\(id)&header=Missing&text=x&tags=one", "id=\(id)&header=Missing&text=x"] {
            let out = try run(lib, "add-text", query)
            #expect(out.failure?.code == 1, "\(query)")
        }
        #expect(try lib.text(id) == before)
    }

    // MARK: Fix round 2

    @Test func untokenedErrorsCarryNoLibraryDetail() throws {
        let lib = try TestLibrary.make([TestNote(text: "", locked: true), TestNote(text: "# Secret title\nbody")])
        let locked = try lib.firstIdLocked()
        let token = try token(lib)
        func callback(_ query: String, token given: String?, action: String = "add-text") throws -> String? {
            let r = try XCallbackRequest.parse(URL(string: "baerchen://x-callback-url/\(action)?\(query)&x-error=drafts://e" + (given.map { "&token=\($0)" } ?? ""))!)
            return executor(lib).execute(r).callbackURL(for: r)?.absoluteString
        }
        #expect(try callback("id=\(locked)&text=x", token: nil) == "drafts://e?errorCode=3&errorMessage=Note%20is%20locked%20or%20read-only")
        #expect(try callback("title=Secret%20title&header=Nope&text=x", token: nil) == "drafts://e?errorCode=1&errorMessage=Invalid%20parameter")
        #expect(try callback("id=NOPE&text=x", token: nil) == "drafts://e?errorCode=2&errorMessage=Note%20not%20found")
        #expect(try callback("", token: nil, action: "grab-url") == "drafts://e?errorCode=5&errorMessage=Action%20not%20supported")
        #expect(try callback("id=NOPE&text=x", token: "WRONG") == "drafts://e?errorCode=4&errorMessage=Invalid%20or%20missing%20token")
        // with the token the messages are the detailed ones
        #expect(try callback("id=\(locked)&text=x", token: token) == "drafts://e?errorCode=3&errorMessage=Note%20is%20locked%3A%20\(encoded(locked))")
        #expect(try callback("title=Secret%20title&header=Nope&text=x", token: token)?.contains("Header%20not%20found") == true)
        // no message ever carries the note id or title without the token
        for q in ["id=\(locked)&text=x", "id=\(try lib.id(titled: "Secret title"))&header=Nope&text=x"] {
            let url = try #require(try callback(q, token: nil))
            #expect(!url.contains(locked) && !url.contains("Secret"))
        }
    }

    @Test func aGivenTokenMustBeRightEverywhere() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
        let id = try lib.id(titled: "Doc")
        let token = try token(lib)
        let before = try noteCount(lib)
        for (action, query) in [
            ("open-note", "id=\(id)&token="), ("create", "text=x&token="), ("trash", "search=x&token="),
            ("trash", "search=x&token=WRONG"), ("archive", "search=x&token=WRONG"), ("locked", "token=WRONG"),
            ("untagged", "token="), ("open-workspace", "name=w&token=WRONG"), ("close-workspace", "token=WRONG"),
            ("grab-url", "url=x&token=WRONG"), ("add-text", "id=\(id)&text=x&token="),
            ("rename-tag", "name=a&new_name=b&token="), ("tags", "token="),
        ] {
            let out = try run(lib, action, query)
            #expect(out.failure?.code == 4 && out.ui == .none && out.success == nil, "\(action) \(query)")
        }
        #expect(try noteCount(lib) == before && (try lib.text(id)) == "# Doc\nbody")
        // a right token on a search-only trash still works
        #expect(try run(lib, "trash", "search=x&token=\(token)").failure == nil)
        // open-note by title without a token opens the note and returns nothing, not even the id
        let open = try run(lib, "open-note", "title=Doc")
        #expect(open.failure == nil && open.success?.isEmpty == true)
        if case .openNote(let opened, _, _, _, _, _, _) = open.ui { #expect(opened == id) } else { Issue.record("no open intent") }
    }

    @Test func htmlImageLimitsApplyBeforeDecoding() throws {
        func img(_ byte: UInt8, count: Int) -> String {
            "<img src=\"data:image/png;base64,\(Data(repeating: byte, count: count).base64EncodedString())\">"
        }
        let limits = HTMLToMarkdown.ImageLimits(each: 10, total: 20)
        // over the per-image cap: skipped, never decoded, so not even an "undecodable" warning
        let big = HTMLToMarkdown.convert("<p>x</p>" + img(1, count: 30), imageLimits: limits)
        #expect(big.oversizedImages == 1 && big.images.isEmpty && big.warnings.isEmpty)
        // not valid base64 at all, but over the cap: still counted as oversized, proof nothing was decoded
        let junk = HTMLToMarkdown.convert("<p>x</p><img src=\"data:image/png;base64," + String(repeating: "!", count: 400) + "\">", imageLimits: limits)
        #expect(junk.oversizedImages == 1 && junk.warnings.isEmpty)
        // three distinct images that each fit: the running total stops the third
        let three = HTMLToMarkdown.convert("<p>x</p>" + img(1, count: 6) + img(2, count: 6) + img(3, count: 6), imageLimits: limits)
        #expect(three.images.count == 2 && three.oversizedImages == 1)
        // no limits: unchanged behaviour
        let free = HTMLToMarkdown.convert("<p>x</p>" + img(1, count: 6))
        #expect(free.images.count == 1 && free.oversizedImages == 0)
        // and through the action
        let lib = try TestLibrary.make()
        var small = AutomationContext.fixed(TestLibrary.epoch)
        small.maxAttachmentBytes = 10
        let limited = XCallbackExecutor(library: lib.library, context: small, selectedNoteId: { nil }, clipboard: { nil })
        let html = encoded("<p>hi</p>" + img(1, count: 30))
        #expect(limited.execute(try Self.request("create", "type=html&text=\(html)")).failure?.code == 1)
        #expect(try noteCount(lib) == 0)
    }

    @Test func createUndoesItselfWhateverFailsAfterTheCommit() throws {
        let lib = try TestLibrary.make()
        let token = try token(lib)
        let first = executor(lib)
        // the note is stored, then loading its record "fails"
        first.afterCreateHook = { _ throws(AutomationError) in throw AutomationError(code: .internal, message: "read failed") }
        let out = first.execute(try Self.request("create", "title=A&text=x&token=\(token)"))
        #expect(out.failure?.code == 6)
        #expect(try noteCount(lib) == 0)
        // and when the undo itself fails, the request fails with that, and says so
        let second = executor(lib)
        second.afterCreateHook = { _ throws(AutomationError) in throw AutomationError(code: .internal, message: "read failed") }
        struct Stuck: Error {}
        second.deleteNotes = { _ in throw Stuck() }
        let stuck = second.execute(try Self.request("create", "title=B&text=x&token=\(token)"))
        #expect(stuck.failure?.code == 6 && stuck.failure?.message.contains("could not be removed") == true)
        #expect(try noteCount(lib) == 1)
        #expect(stuck.failure?.message.contains("read failed") == true)
    }

    @Test func aCommittedWriteKeepsItsFileWhenLoadingTheResultFails() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
        let id = try lib.id(titled: "Doc")
        let db = lib.library.database
        // after the text is stored but before the result is loaded, the table the record needs goes away
        let service = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch), scope: .unrestricted)
        var commits = 0
        let outcome = Result { () throws(AutomationError) -> Void in
            _ = try service.mutate(.id(id), preservingModifiedDate: false, didCommit: {
                commits += 1
                try? db.pool.write { try $0.execute(sql: "DROP TABLE note_pin") }
            }) { note, _ throws(AutomationError) in note.text + "\nmore" }
        }
        #expect(commits == 1)
        if case .success = outcome { Issue.record("the result load was expected to fail") }
        #expect(try lib.text(id) == "# Doc\nbody\nmore")
    }

    @Test func addAttachmentKeepsItsFileWhenOnlyTheResultLoadFails() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
        let id = try lib.id(titled: "Doc")
        let db = lib.library.database
        // the text commits, then the record cannot be loaded: the link is stored, so the file must stay
        let service = AutomationService(
            library: lib.library, context: .fixed(TestLibrary.epoch),
            afterCommit: { try? db.pool.write { try $0.execute(sql: "DROP TABLE note_pin") } })
        #expect(throws: AutomationError.self) {
            _ = try service.addAttachment(.id(id), data: Data("x".utf8), filename: "kept.txt", preservingModifiedDate: false)
        }
        let text = try lib.text(id)
        #expect(text.contains(AttachmentMarkdown.link(for: "kept.txt")))
        #expect(attachmentFiles(lib, id) == ["kept.txt"])
    }

    // MARK: Every action

    @Test func everyActionIsHandled() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One\nbody")])
        let id = try lib.firstId()
        let queries: [XCallbackAction: String] = [
            .openNote: "id=\(id)", .create: "text=hi", .addText: "id=\(id)&text=x", .addFile: "id=\(id)",
            .tags: "", .openTag: "name=a", .renameTag: "name=a&new_name=b", .deleteTag: "name=a", .trash: "search=x",
            .archive: "search=x", .untagged: "", .todo: "", .today: "", .locked: "", .search: "term=x",
            .grabURL: "url=https%3A%2F%2Fexample.com", .openWorkspace: "name=a", .closeWorkspace: "",
        ]
        #expect(Set(queries.keys) == Set(XCallbackAction.allCases))
        for action in XCallbackAction.allCases {
            let out = try run(lib, action.rawValue, queries[action] ?? "")
            #expect(out.failure != nil || out.success != nil)
            if action == .grabURL { #expect(out.failure?.code == 5) }
        }
    }
}

extension TestLibrary {
    func firstIdLocked() throws -> String {
        let found = try library.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM note WHERE isLocked ORDER BY rowid LIMIT 1")
        }
        return try #require(found)
    }
}
