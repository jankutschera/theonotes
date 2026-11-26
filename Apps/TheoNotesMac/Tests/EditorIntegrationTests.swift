// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CoreText
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import TheoNotes

/// A real `WKWebView` running the bundled editor through the real `AssetSchemeHandler`,
/// `EditorBridgeController` and `AppEnvironment` on a temp data directory, in an offscreen window.
@MainActor
final class LiveEditor {
    let root: URL
    let environment: AppEnvironment
    let controller: EditorBridgeController
    let window: NSWindow
    let noteId: String

    /// `rawStoredText` overwrites the row bypassing NoteStore (e.g. "\r\n" from an older build).
    init(text: String, rawStoredText: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesLive-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        let noteId = try environment.store.create(text: text).id
        if let rawStoredText {
            try environment.database.pool.write { db in
                try db.execute(sql: "UPDATE note SET text = ? WHERE id = ?", arguments: [rawStoredText, noteId])
            }
        }
        self.noteId = noteId
        controller = EditorBridgeController(environment: environment)
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let webView = controller.webView
        webView.frame = window.contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)
        window.orderFront(nil)
        try controller.open(noteId: noteId)
    }

    func close() {
        environment.flushAll()
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    var session: NoteSession { environment.existingSession(for: noteId)! }

    /// Runs `body` in the page with `hooks` (the test's own hooks) in scope.
    @discardableResult
    func js(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await controller.webView.callAsyncJavaScript(Self.hooks + body, arguments: arguments, contentWorld: .page)
    }

    /// Test hooks, injected by the test: production bundles have none (the editor's debug hooks
    /// are dev-build only; `web/editor/test/production-bundle.test.ts`). They reach the EditorView
    /// through the DOM: `@codemirror/view` (pinned 6.43.15) keeps it on `.cm-content`'s tile, as
    /// `EditorView.findFromDOM` does. Undo / redo go through CodeMirror's `beforeinput` handling
    /// (`historyUndo` / `historyRedo`), like the Edit menu; they report whether the state changed.
    static let hooks = """
        const hooks = (() => {
          const view = () => document.querySelector(".cm-content")?.cmTile?.root?.view ?? null;
          const history = (inputType) => {
            const v = view(), before = v.state;
            v.contentDOM.dispatchEvent(new InputEvent("beforeinput", { inputType, bubbles: true, cancelable: true }));
            return v.state !== before;
          };
          return {
            view,
            text: () => view()?.state.doc.toString() ?? null,
            selection: () => { const m = view().state.selection.main; return [m.anchor, m.head]; },
            insert: (t) => { const v = view(); v.dispatch(v.state.replaceSelection(t), { userEvent: "input.type" }); },
            undo: () => history("historyUndo"),
            redo: () => history("historyRedo"),
          };
        })();

        """

    /// The CodeMirror document as JS sees it.
    func editorText() async -> String? {
        (try? await js("return hooks.text()")) as? String
    }

    func isEditable() async -> Bool {
        let value = try? await js("return document.querySelector('.cm-content')?.getAttribute('contenteditable') ?? null")
        return (value as? String) == "true"
    }

    /// [anchor, head] of the editor's main selection.
    func selection() async throws -> [Int] {
        let value = try await js("return hooks.selection()")
        return (value as? [NSNumber])?.map(\.intValue) ?? []
    }

    func insert(_ text: String) async throws {
        try await js("hooks.insert(text)", ["text": text])
    }

    /// The note text read through a separate connection, as the next launch would see it.
    func storeText() throws -> String? {
        try NoteStore(db: AppDatabase(path: environment.paths.database), notifier: nil, paths: environment.paths).note(id: noteId)?.text
    }

    /// Waits until the editor booted, received `loadNote` and shows `text`.
    func waitUntilLoaded(_ text: String) async throws {
        try await waitUntil("editor loaded with \(text.debugDescription)") {
            guard controller.isEditorReady, await isEditable() else { return false }
            return await editorText() == text
        }
    }

    /// Waits until Swift acknowledged everything the editor shows.
    func waitUntilAcked(_ text: String) async throws {
        try await waitUntil("session acked \(text.debugDescription)") {
            guard session.text == text else { return false }
            return await editorText() == text
        }
    }

    func checksum() async -> (noteId: String?, sha256: String?) {
        await withCheckedContinuation { continuation in
            controller.requestChecksum { continuation.resume(returning: ($0, $1)) }
        }
    }

    var webContentPID: pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard controller.webView.responds(to: selector) else { return nil }
        return (controller.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
    }
}

struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func waitUntil(
    _ what: String, timeout: Duration = .seconds(15), _ condition: () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while try await !condition() {
        guard clock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw WaitTimeout(description: "timed out waiting for \(what)")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Serialized: the Darwin change notification is process-wide, so parallel environments would
/// all react to each other's writes.
@MainActor
@Suite(.serialized) struct EditorIntegrationTests {
    static let typed = ["Hello ", "👩‍👩‍👧", " 漢字かな", " **bold**", "\n", "日本語 ✓ 🇩🇪"]

    @Test func typedEmojiAndCJKReachSQLiteWithEqualChecksums() async throws {
        let live = try LiveEditor(text: "")
        defer { live.close() }
        try await live.waitUntilLoaded("")

        for piece in Self.typed { try await live.insert(piece) }
        let expected = Self.typed.joined()
        try await live.waitUntilAcked(expected)
        #expect(live.session.revision == Self.typed.count)

        // The debounced commit (400 ms) lands without an explicit flush.
        try await waitUntil("debounced commit") { try live.storeText() == expected }

        let (noteId, sha) = await live.checksum()
        #expect(noteId == live.noteId)
        #expect(sha == sha256Hex(live.session.text))
        #expect(sha == sha256Hex(try #require(try live.storeText())))
    }

    /// Q3: a remote delete while an editor holds unsaved plain text saves that text as a recovery
    /// note (the same path iOS uses) before the session closes.
    @Test func remoteDeleteSavesTheOpenEditorsUnsavedPlainText() async throws {
        let live = try LiveEditor(text: "Start")
        defer { live.close() }
        try await live.waitUntilLoaded("Start")
        try await live.insert(" unsaved")
        try await waitUntil("acked") { live.session.revision == 1 }
        let id = live.noteId, unsaved = live.session.text
        // Synchronously, before the debounced commit: the row goes, as a sync delete does it.
        let deleteRow: () throws -> Void = { try live.environment.database.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) } }
        try deleteRow()
        #expect(live.session.text != live.session.committedText)
        live.environment.databaseDidChange()
        let copies = try live.environment.store.allNotes().filter { $0.text == unsaved }
        #expect(copies.count == 1 && copies.first?.isLocked == false)
        #expect(live.environment.existingSession(for: id) == nil)
        // S7: the journal pass finds that copy for the left-behind journal; no second copy. While the
        // editor still holds the closed session (for unacked browser text) the pass waits for it.
        live.environment.refreshJournalRecovery()
        #expect(try live.environment.store.allNotes().filter { $0.text == unsaved }.count == 1)
        let other = try live.environment.store.create(text: "Other")
        try live.controller.open(noteId: other.id)  // the editor moves on and lets the session go
        try await waitUntil("editor released the closed session") {
            !NoteSession.liveSessionIDs(journalDirectory: live.environment.paths.journal).contains(id)
        }
        live.environment.refreshJournalRecovery()
        let after = try live.environment.store.allNotes().filter { $0.text == unsaved }
        #expect(after.count == 1, "copies: \(after.map(\.id))")
        let notices = live.environment.recoveredSingleJournals.map(\.note.id)
        #expect(notices == copies.map(\.id), "notices \(notices) copies \(copies.map(\.id))")
    }

    /// The bundle exposes only the bridge and production export renderer: no debug hooks or mock host.
    /// `preserveForPrivacy` is a production bridge call (e3268f62): the iOS host invokes it to save
    /// unsaved text before a privacy close (`MobileEditor.preserveBrowserTextBeforePrivacyClose`).
    @Test func bundledEditorHasNoDebugHooks() async throws {
        let live = try LiveEditor(text: "x")
        defer { live.close() }
        try await live.waitUntilLoaded("x")
        let keys = try await live.js("return Object.keys(window.__baerchen ?? {}).sort()") as? [String]
        #expect(keys == ["preserveForPrivacy", "receive", "renderNote"])
    }

    /// Settings ▸ General ▸ Hide Markdown reaches the open editor in place: the markup shows (dimmed)
    /// and hides again, the text and the caret stay, no reload.
    @Test func hideMarkdownSettingAppliesToTheOpenEditor() async throws {
        let live = try LiveEditor(text: "some **bold** text")
        defer { live.close() }
        try await live.waitUntilLoaded("some **bold** text")
        let hiddenCount = { (try? await live.js("return document.querySelectorAll('.cm-bc-hidden').length")) as? Int }
        try await waitUntil("markup hidden") { await hiddenCount() == 2 }
        let selection = try await live.selection()
        let settings = TheoNotesCore.Settings(db: live.environment.database)
        settings.hideMarkdown = false
        try await waitUntil("markup shown") { await hiddenCount() == 0 }
        let dimmed = try await live.js("return [...document.querySelectorAll('.cm-bc-markup')].map((e) => e.textContent)") as? [String]
        #expect(dimmed == ["**", "**"])
        settings.hideMarkdown = true
        try await waitUntil("markup hidden again") { await hiddenCount() == 2 }
        #expect(try await live.selection() == selection)
        #expect(await live.editorText() == "some **bold** text")
    }

    /// The 40-character line the font tests measure.
    static let fontLine = EditorIntegrationTestsFontLine.text

    /// Settings ▸ Typography ▸ Text font: a system family renders in the editor (the line is measurably
    /// different from the default stack's). The user-installed half is the next test.
    @Test func systemFontFamilyRendersInTheEditor() async throws {
        try await assertFamilyRenders("Georgia")
    }

    /// A family installed under `~/Library/Fonts` or `/Library/Fonts` renders too, so the editor needs no
    /// `@font-face` fallback. Skipped (not failed) on a machine with no such font.
    @Test(.enabled(if: UserFonts.renderableFamily() != nil, "no usable font under ~/Library/Fonts or /Library/Fonts"))
    func userInstalledFontFamilyRendersInTheEditor() async throws {
        try await assertFamilyRenders(try #require(UserFonts.renderableFamily()))
    }

    private func assertFamilyRenders(_ family: String) async throws {
        let line = Self.fontLine
        #expect(line.count == 40)
        let live = try LiveEditor(text: line)
        defer { live.close() }
        try await live.waitUntilLoaded(line)
        let width = { (try? await live.js("""
            const el = document.querySelector('.cm-line');
            const range = document.createRange();
            range.selectNodeContents(el);
            return range.getBoundingClientRect().width;
            """)) as? Double }
        let baseline = try #require(await width())
        #expect(baseline > 0)
        let settings = TheoNotesCore.Settings(db: live.environment.database)
        settings.typography = TypographySettings(fontText: family)
        try await waitUntil("\(family) renders") {
            guard let now = await width() else { return false }
            return abs(now - baseline) > 0.5
        }
        settings.typography = .default
        try await waitUntil("default stack again after \(family)") {
            guard let now = await width() else { return false }
            return abs(now - baseline) < 0.01
        }
    }

    /// The DOM input path (contenteditable → CodeMirror's DOM observer), not a dispatched
    /// transaction; closer to real typing than `hooks.insert`, still no key events or IME.
    @Test func domInsertTextReachesSQLite() async throws {
        let live = try LiveEditor(text: "")
        defer { live.close() }
        try await live.waitUntilLoaded("")
        let inserted = try await live.js("""
            const content = document.querySelector(".cm-content");
            content.focus();
            return document.execCommand("insertText", false, text);
            """, ["text": "dom 👩‍👩‍👧 漢字"]) as? Bool
        #expect(inserted == true)
        try await live.waitUntilAcked("dom 👩‍👩‍👧 漢字")
        live.environment.flushAll()
        #expect(try live.storeText() == "dom 👩‍👩‍👧 漢字")
    }

    /// Jan's report: "1." typed into an empty note vanished on Enter (CodeMirror's markdown
    /// keymap took the bare marker for an empty list item). Enter goes through the keymap here.
    @Test func enterAfterBareOrderedMarkerInEmptyNoteKeepsIt() async throws {
        let live = try LiveEditor(text: "")
        defer { live.close() }
        try await live.waitUntilLoaded("")
        try await live.js("""
            const content = document.querySelector(".cm-content");
            content.focus();
            document.execCommand("insertText", false, "1");
            document.execCommand("insertText", false, ".");
            content.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true, cancelable: true }));
            """)
        try await live.waitUntilAcked("1.\n")
        try await waitUntil("debounced commit") { try live.storeText() == "1.\n" }
        #expect(await live.editorText() == "1.\n")
    }

    @Test func killedWebContentProcessRestoresAckedText() async throws {
        let live = try LiveEditor(text: "# Kill test\n")
        defer { live.close() }
        try await live.waitUntilLoaded("# Kill test\n")
        try await live.insert("acked before kill 👩‍👩‍👧 漢字")
        let expected = "acked before kill 👩‍👩‍👧 漢字# Kill test\n"
        try await live.waitUntilAcked(expected)
        let caret = "acked before kill 👩‍👩‍👧 漢字".utf16.count
        #expect(try await live.selection() == [caret, caret])

        let oldPID = try #require(live.webContentPID, "no WebContent pid (private _webProcessIdentifier missing)")
        #expect(oldPID > 0)
        #expect(kill(oldPID, SIGKILL) == 0)
        try await waitUntil("old WebContent pid \(oldPID) gone") { kill(oldPID, 0) != 0 }

        try await live.waitUntilLoaded(expected)
        let newPID = try #require(live.webContentPID)
        #expect(newPID != oldPID && newPID > 0)

        // F1: the caret comes back where it was, and the restored editor keeps working: a new
        // keystroke lands there, is acked and persisted.
        #expect(try await live.selection() == [caret, caret])
        try await live.insert("!")
        let typed = "acked before kill 👩‍👩‍👧 漢字!# Kill test\n"
        try await live.waitUntilAcked(typed)
        let (_, sha) = await live.checksum()
        #expect(sha == sha256Hex(typed))
        live.environment.flushAll()
        #expect(try live.storeText() == typed)
    }

    @Test func externalWriteFromSecondStoreReachesEditor() async throws {
        let live = try LiveEditor(text: "line one\n")
        defer { live.close() }
        try await live.waitUntilLoaded("line one\n")
        try await live.insert("typed ")
        try await live.waitUntilAcked("typed line one\n")
        live.environment.flushAll()
        #expect(try live.storeText() == "typed line one\n")

        // A CLI-style writer: its own pool, store and notifier (Darwin notification on commit).
        let otherStore = NoteStore(db: try AppDatabase(path: live.environment.paths.database), notifier: ChangeNotifier(), paths: live.environment.paths)
        let note = try #require(try otherStore.note(id: live.noteId))
        let external = "typed line one\nexternal line 漢字\n"
        _ = try otherStore.updateText(id: live.noteId, text: external, expectedRevision: note.revision)

        try await waitUntil("external change shown in editor") { await live.editorText() == external }
        #expect(live.session.text == external)

        // The bridge stays consistent after the R1 revision bump; the caret (after "typed ")
        // was mapped through the external change.
        try await live.insert(">")
        let typedAfter = "typed >line one\nexternal line 漢字\n"
        try await live.waitUntilAcked(typedAfter)
        live.environment.flushAll()
        #expect(try live.storeText() == typedAfter)
        let (_, sha) = await live.checksum()
        #expect(sha == sha256Hex(typedAfter))
    }

    @Test func undoRedoAfterExternalWriteStayInSync() async throws {
        let live = try LiveEditor(text: "base")
        defer { live.close() }
        try await live.waitUntilLoaded("base")
        try await live.insert("one two ")
        try await live.waitUntilAcked("one two base")
        live.environment.flushAll()

        let otherStore = NoteStore(db: try AppDatabase(path: live.environment.paths.database), notifier: ChangeNotifier(), paths: live.environment.paths)
        let note = try #require(try otherStore.note(id: live.noteId))
        _ = try otherStore.updateText(id: live.noteId, text: "one two base\next", expectedRevision: note.revision)
        try await waitUntil("external change shown") { await live.editorText() == "one two base\next" }

        // Ruling R9: an external edit is never a CodeMirror undo step (store rewrites are undone
        // through app-level undo records); undo reverts the earlier local edit, mapped through
        // it. Every undo/redo goes through the bridge like typing, so Swift stays in sync.
        let undo = "return hooks.undo()", redo = "return hooks.redo()"
        #expect(try await live.js(undo) as? Bool == true)
        try await live.waitUntilAcked("base\next")
        #expect(try await live.js(undo) as? Bool == false)
        #expect(try await live.js(redo) as? Bool == true)
        try await live.waitUntilAcked("one two base\next")
        live.environment.flushAll()
        #expect(try live.storeText() == "one two base\next")
    }

    @Test func quitFlushPersistsTextTypedInsideDebounceWindow() async throws {
        let live = try LiveEditor(text: "")
        defer { live.close() }
        try await live.waitUntilLoaded("")
        try await live.insert("typed right before ⌘Q 漢字")
        try await live.waitUntilAcked("typed right before ⌘Q 漢字")
        // Still inside the 400 ms debounce: SQLite does not have it yet.
        #expect(try live.storeText() == "")

        live.environment.flushAll() // what applicationShouldTerminate does
        #expect(try live.storeText() == "typed right before ⌘Q 漢字")

        // Next launch: a fresh environment on the same data directory sees the text, journal empty.
        let relaunched = try AppEnvironment(paths: AppPaths(root: live.root))
        let session = try relaunched.session(for: live.noteId)
        #expect(session.text == "typed right before ⌘Q 漢字")
        #expect(session.revision == 0)
    }

    @Test func crlfStoredNoteOpensAndEditsRoundTrip() async throws {
        let live = try LiveEditor(text: "", rawStoredText: "a\r\nb\rc")
        defer { live.close() }
        #expect(try live.storeText() == "a\r\nb\rc")
        try await live.waitUntilLoaded("a\nb\nc")
        try await live.insert("X")
        try await live.insert("\r\nY")
        try await live.waitUntilAcked("X\nYa\nb\nc")
        #expect(await live.isEditable())
        live.environment.flushAll()
        #expect(try live.storeText() == "X\nYa\nb\nc")
        let (_, sha) = await live.checksum()
        #expect(sha == sha256Hex("X\nYa\nb\nc"))
        #expect(sha == sha256Hex(live.session.text))
    }

    /// Format ▸ commands go through `applyCommand` into the real editor, come back as ordinary
    /// changes (acked, persisted), report their format state and are one undo step each.
    @Test func applyCommandRunsInTheEditorAndReachesSQLite() async throws {
        let live = try LiveEditor(text: "say hello")
        defer { live.close() }
        try await live.waitUntilLoaded("say hello")
        live.controller.apply(.selectAll)
        live.controller.apply(.bold)
        try await live.waitUntilAcked("**say hello**")
        try await waitUntil("format state with bold") { live.controller.status.formatState?.active.contains(.bold) == true }

        live.controller.apply(.heading, args: ["level": .int(1)])
        try await live.waitUntilAcked("# **say hello**")
        try await waitUntil("format state with heading 1") { live.controller.status.formatState?.headingLevel == 1 }

        #expect(try await live.js("return hooks.undo()") as? Bool == true)
        try await live.waitUntilAcked("**say hello**")
        live.environment.flushAll()
        #expect(try live.storeText() == "**say hello**")
    }

    /// Code blocks in the bundled editor: the Swift mode is its own chunk of the bundle, loaded on
    /// demand under the strict CSP (no network); Copy Code reaches the pasteboard through
    /// `copyText` without moving the caret; Paste as Code runs in the real editor.
    @Test func codeBlocksHighlightFromTheBundleAndCopyCodeReachesThePasteboard() async throws {
        let text = "Intro\n```swift\nlet greeting = \"hi\"\n```\nOutro"
        let live = try LiveEditor(text: text)
        defer { live.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TheoNotesLive-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        live.controller.pasteboard = pasteboard
        try await live.waitUntilLoaded(text)
        try await waitUntil("swift keyword highlighted") {
            (try await live.js("return document.querySelector('.cm-bc-tok-keyword')?.textContent ?? null")) as? String == "let"
        }
        // WebKit keeps no resource timing for the custom scheme; the bundle itself shows the split:
        // the Swift mode is its own chunk, not part of the entry script.
        let assets = Bundle.main.resourceURL!.appendingPathComponent("Editor/assets")
        let files = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        let swiftChunks = files.filter { $0.hasPrefix("swift-") && $0.hasSuffix(".js") }
        #expect(swiftChunks.count == 1)
        let entry = try #require(files.first { $0.hasPrefix("index-") && $0.hasSuffix(".js") })
        let entryScript = try String(contentsOf: assets.appendingPathComponent(entry), encoding: .utf8)
        #expect(!entryScript.contains("fallthrough"), "the Swift mode's keywords are in the entry script")

        let caret = try await live.selection()
        try await live.js("document.querySelector('.cm-bc-copy').click()")
        try await waitUntil("code on the pasteboard") { pasteboard.string(forType: .string) == "let greeting = \"hi\"" }
        #expect(try await live.selection() == caret)

        // Caret at the start of the note: the block goes on lines of its own before "Intro".
        #expect(caret == [0, 0])
        pasteboard.clearContents()
        pasteboard.setString("a\nb", forType: .string)
        live.controller.pasteAsCode(pasteboard)
        try await live.waitUntilAcked("```\na\nb\n```\n" + text)
    }

    /// The bundled editor's link messages decode in Swift: ⌘K's `editLinkRequest`, ⇧⌘K's `openLink`;
    /// `setLink` and `scrollToHeading` run in the real editor.
    @Test func linkPanelAndOpenLinkRoundTripThroughTheBundle() async throws {
        let live = try LiveEditor(text: "[Bear](https://example.com)")
        defer { live.close() }
        var edits: [EditLinkRequest] = []
        var opened: [OpenLinkRequest] = []
        live.controller.onEditLink = { edits.append($0) }
        live.controller.onOpenLink = { opened.append($0) }
        try await live.waitUntilLoaded("[Bear](https://example.com)")
        live.controller.apply(.selectAll)
        live.controller.apply(.link)
        try await waitUntil("editLinkRequest") { !edits.isEmpty }
        #expect(edits.first.map { [$0.from, $0.to] } == [0, 27])
        #expect(edits.first?.title == "Bear")
        #expect(edits.first?.url == "https://example.com")
        #expect((edits.first?.caretRect.height ?? 0) > 5)
        #expect(edits.first?.editing == true)
        let requestId = try #require(edits.first?.requestId)

        live.controller.apply(.openLink, args: ["window": .string("new")])
        try await waitUntil("openLink") { !opened.isEmpty }
        #expect(opened == [OpenLinkRequest(noteId: live.noteId, kind: .url, target: "https://example.com", heading: nil, newWindow: true)])

        live.controller.apply(.setLink, args: ["requestId": .string(requestId), "title": .string("Bär"), "url": .string("https://example.com/a b")])
        try await live.waitUntilAcked("[Bär](https://example.com/a%20b)")
        try await live.insert("\n# Head")
        let end = "[Bär](https://example.com/a%20b)\n# Head".utf16.count
        live.controller.apply(.selectAll)
        try await waitUntil("all selected") { try await live.selection() == [0, end] }
        live.controller.scrollToHeading(0)
        try await waitUntil("caret on the heading") { try await live.selection() == [end, end] }
    }

    /// In the app the editor leaves the Format shortcuts to the native menu: a ⌘B/⌘I/⌘U keydown
    /// reaches no CodeMirror binding (⌘I and ⌘U would select the parent node / undo the selection)
    /// and is not default-prevented, so WebKit returns it to AppKit. Other keys stay the editor's.
    @Test func formatShortcutsPassThroughTheEditorToTheMenu() async throws {
        let live = try LiveEditor(text: "text")
        defer { live.close() }
        try await live.waitUntilLoaded("text")
        for (key, shift) in [("b", false), ("i", false), ("u", false), ("u", true), ("7", true), ("1", false), ("t", false)] {
            let result = try await live.js(Self.keyDown, ["key": key, "shift": shift]) as? [String: Any]
            #expect(result?["defaultPrevented"] as? Bool == false, "⌘\(shift ? "⇧" : "")\(key)")
            #expect(result?["text"] as? String == "text")
        }
        let undo = try await live.js(Self.keyDown, ["key": "z", "shift": false]) as? [String: Any]
        #expect(undo?["defaultPrevented"] as? Bool == true)
        let selectAll = try await live.js(Self.keyDown, ["key": "a", "shift": false]) as? [String: Any]
        #expect(selectAll?["defaultPrevented"] as? Bool == true)
    }

    /// Injected by the test (no hook in the bundle): a ⌘-keydown on the editor content, whether
    /// something default-prevented it, and the text after it.
    static let keyDown = """
        const event = new KeyboardEvent("keydown", { key, metaKey: true, shiftKey: shift, bubbles: true, cancelable: true });
        document.querySelector(".cm-content").dispatchEvent(event);
        return { defaultPrevented: event.defaultPrevented, text: hooks.text() };
        """

    @Test func contentSecurityPolicyBlocksNetworkAndEval() async throws {
        let live = try LiveEditor(text: "csp")
        defer { live.close() }
        try await live.waitUntilLoaded("csp")
        let result = try await live.js("""
            const violations = [];
            document.addEventListener("securitypolicyviolation", (e) =>
              violations.push(e.effectiveDirective + " " + e.blockedURI));
            let fetchResult;
            try {
              const response = await fetch("https://example.com/");
              fetchResult = "allowed " + response.status;
            } catch (e) {
              fetchResult = "rejected " + e;
            }
            const img = new Image();
            img.src = "https://example.com/pixel.png";
            let evalResult;
            try { evalResult = "allowed " + (0, eval)("1 + 1"); } catch (e) { evalResult = "blocked " + e; }
            for (let i = 0; i < 50 && violations.length < 2; i++) await new Promise((r) => setTimeout(r, 20));
            return JSON.stringify({ fetchResult, evalResult, violations });
            """) as? String
        let json = try #require(result)
        print("CSP probe: \(json)")
        let probe = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fetchResult = try #require(probe["fetchResult"] as? String)
        let violations = try #require(probe["violations"] as? [String])
        #expect(fetchResult.hasPrefix("rejected"))
        #expect(violations.contains { $0.hasPrefix("connect-src") && $0.contains("example.com") }, "\(violations)")
        #expect(violations.contains { $0.hasPrefix("img-src") && $0.contains("example.com") }, "\(violations)")
        #expect((probe["evalResult"] as? String)?.hasPrefix("blocked") == true, "\(probe)")
    }

    /// M6 Task 11: MathJax loads from the bundle on demand and renders under the strict CSP (no
    /// network, no eval): inline, display, a glyph from a dynamic font file (`\\mathbb`).
    @Test func mathRendersUnderTheStrictCSP() async throws {
        let live = try LiveEditor(text: "math")
        defer { live.close() }
        try await live.waitUntilLoaded("math")
        try await live.js("""
            window.__mathViolations = [];
            document.addEventListener("securitypolicyviolation", (e) =>
              window.__mathViolations.push(e.effectiveDirective + " " + e.blockedURI));
            """)
        try await live.insert(" $E = mc^2$ and $\\mathbb{R}$\n\n$$\n\\frac{1}{2}\n$$\n\nend")
        try await waitUntil("formulas rendered", timeout: .seconds(30)) {
            (try await live.js("""
                const svgs = (selector) => [...document.querySelectorAll(selector)]
                  .filter((h) => h.shadowRoot?.querySelector("svg path")).length;
                return svgs(".cm-bc-math-inline") * 10 + svgs(".cm-bc-block-rendered");
                """)) as? Int == 21
        }
        let violations = try await live.js("return JSON.stringify(window.__mathViolations)") as? String
        #expect(violations == "[]")
        // MathJax and its font files are chunks of their own, not part of the entry script.
        let assets = Bundle.main.resourceURL!.appendingPathComponent("Editor/assets")
        let files = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        #expect(files.contains { $0.hasPrefix("double-struck-") && $0.hasSuffix(".js") })
        let entry = try #require(files.first { $0.hasPrefix("index-") && $0.hasSuffix(".js") })
        let entryScript = try String(contentsOf: assets.appendingPathComponent(entry), encoding: .utf8)
        #expect(!entryScript.contains("Misplaced"), "MathJax's TeX parser is in the entry script")
    }

    /// M6 Task 12: Mermaid loads from the bundle on demand and renders under the strict CSP (no
    /// network, no eval); the diagram is an `<img>` of its SVG, no live SVG in the page.
    @Test func mermaidRendersUnderTheStrictCSP() async throws {
        let live = try LiveEditor(text: "diagram")
        defer { live.close() }
        try await live.waitUntilLoaded("diagram")
        try await live.js("""
            window.__mermaidViolations = [];
            document.addEventListener("securitypolicyviolation", (e) =>
              window.__mermaidViolations.push(e.effectiveDirective + " " + e.blockedURI));
            """)
        try await live.insert("\n\n```mermaid\nflowchart LR\n  A[Start] --> B{Choice}\n  B --> C[Done]\n```\n\nend")
        try await waitUntil("diagram rendered", timeout: .seconds(30)) {
            (try await live.js("""
                return [...document.querySelectorAll(".cm-bc-block-rendered.cm-bc-block-mermaid")]
                  .flatMap((h) => [...(h.shadowRoot?.querySelectorAll("img") ?? [])])
                  .filter((img) => img.complete && img.naturalWidth > 0).length;
                """)) as? Int == 1
        }
        let violations = try await live.js("return JSON.stringify(window.__mermaidViolations)") as? String
        #expect(violations == "[]")
        let liveSVG = try await live.js("""
            return [...document.querySelectorAll(".cm-bc-block-mermaid")]
              .flatMap((h) => [...(h.shadowRoot?.querySelectorAll("svg") ?? [])]).length;
            """) as? Int
        #expect(liveSVG == 0)
    }

    /// M3 Task 7 through the real bundle and bridge: `#wo` asks Swift, the popup lists `work` with
    /// its TagCon (loaded through `baerchen-asset://tagcon/v2/`), Enter inserts `#work `, and the
    /// tag pill gets its icon (aria-hidden, no text).
    @Test func tagCompletionRoundTripsThroughTheBundle() async throws {
        let live = try LiveEditor(text: "")
        defer { live.close() }
        _ = try live.environment.store.create(text: "Work\n#work")
        try await live.waitUntilLoaded("")
        let size = try await live.js("""
            const img = new Image();
            img.src = "baerchen-asset://tagcon/v2/briefcase.png";
            await img.decode();
            return img.naturalWidth;
            """) as? Int
        #expect(size == AssetSchemeHandler.tagconPixels)

        try await live.js("document.querySelector('.cm-content').focus()")
        try await live.insert("#wo")
        try await waitUntil("completion popup") {
            let label = try await live.js("return document.querySelector('.cm-tooltip-autocomplete li')?.textContent ?? ''") as? String
            return label?.contains("work") == true
        }
        let icons = try await live.js(
            "return document.querySelectorAll('.cm-tooltip-autocomplete .cm-bc-tagcon[aria-hidden=true]').length"
        ) as? Int
        #expect(icons == 1)
        try await Task.sleep(for: .milliseconds(150)) // the popup's interaction delay
        try await live.js("""
            document.querySelector(".cm-content").dispatchEvent(
              new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true, cancelable: true }));
            """)
        try await live.waitUntilAcked("#work ")
        try await waitUntil("tag pill icon") {
            let count = try await live.js("return document.querySelectorAll('.cm-content .cm-bc-tagcon[aria-hidden=true]').length") as? Int
            return count == 1
        }
        let innerText = try await live.js("return document.querySelector('.cm-content').innerText") as? String
        #expect(innerText == "#work ")
    }
}

/// The line the font tests measure (outside the `@MainActor` suite, so `UserFonts` can read it).
enum EditorIntegrationTestsFontLine {
    static let text = "Hamburgefonstiv quick brown fox jumps 12"
}

/// Font families installed by the user or system-wide, for the test that needs one.
enum UserFonts {
    /// The first family whose font file (`.ttf`, `.otf`, `.ttc`, `.dfont`) sits under `~/Library/Fonts` or
    /// `/Library/Fonts`, that is installed, has a name the editor accepts and has a glyph for every letter of
    /// the test line (an icon or symbol font would fall back and show no width change).
    static func renderableFamily() -> String? {
        let files = FileManager.default
        let folders = [files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts"), URL(fileURLWithPath: "/Library/Fonts")]
        let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        let characters = Array(EditorIntegrationTestsFontLine.text.utf16).filter { $0 != 0x20 }
        for folder in folders {
            let urls = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["ttf", "otf", "ttc", "dfont"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
            for url in urls {
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                for descriptor in descriptors {
                    guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                        installed.contains(family), EditorTypography.isValidFontFamily(family)
                    else { continue }
                    let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
                    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                    if CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) { return family }
                }
            }
        }
        return nil
    }
}
