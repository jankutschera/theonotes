// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M8 Task 14: Edit ▸ Copy As ▸ Markdown / HTML / Rich Text. Every test writes to a private
/// pasteboard, never the general one. R34: HTML and Rich Text use the hidden export `WKWebView`;
/// check the screen lock before reading a failure
/// (`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`).
@MainActor
@Suite(.serialized) final class CopyAsTests {
    let root: URL
    let environment: AppEnvironment
    let pasteboard: NSPasteboard

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesCopyAs-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        pasteboard = NSPasteboard(name: .init("test.\(UUID().uuidString)"))
    }

    isolated deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func copyAs(
        renderer: NoteRenderer? = nil, beep: (@MainActor () -> Void)? = nil,
        notify: (@MainActor (Int) -> Void)? = nil, keepTags: @escaping @MainActor () -> Bool = { true }
    ) -> CopyAs {
        CopyAs(
            environment: environment, renderer: renderer ?? NoteRenderer(environment: environment),
            pasteboard: pasteboard, beep: beep ?? {}, notifyLocked: notify ?? { _ in }, keepTags: keepTags)
    }

    private func add(_ text: String) throws -> Note {
        try environment.store.create(text: text)
    }

    private func lock(_ note: Note) throws {
        try environment.database.pool.write { db in
            try db.execute(
                sql: "UPDATE note SET isLocked = 1, text = '', encryptedPayload = x'0102' WHERE id = ?", arguments: [note.id])
        }
    }

    /// The flavours that were written. The pasteboard also lists names and encodings it derives for the
    /// same text (pre-UTI names, UTF-16), so only the types Copy As decides on are compared.
    private var types: Set<NSPasteboard.PasteboardType> {
        Set(pasteboard.types ?? []).intersection([.string, .html, .rtf, .rtfd, .pdf, .tiff, .png])
    }

    private static let sample = "Copy Me\n\nSome **bold** words and a #project/tag here.\n\n- one\n- two\n"

    // MARK: - Formats

    @Test func markdownWritesTheTextOnly() async throws {
        let note = try add(Self.sample)
        let wrote = await copyAs().copy(.markdown, target: .notes([note.id]))
        #expect(wrote)
        #expect(types == [.string], "\(types)")
        #expect(pasteboard.string(forType: .string) == Self.sample)
    }

    @Test func htmlWritesSourceAsStringAndHTMLType() async throws {
        let note = try add(Self.sample)
        let wrote = await copyAs().copy(.html, target: .notes([note.id]))
        #expect(wrote)
        #expect(types == [.string, .html], "\(types)")
        let source = try #require(pasteboard.string(forType: .string))
        #expect(pasteboard.string(forType: .html) == source)
        // The body fragment of the document page: classes stay, the page wrapper and style go.
        #expect(source.contains("<strong>bold</strong>"))
        #expect(source.contains("bc-tag"))
        #expect(source.contains("<li"))
        for wrapper in ["<style", "<html", "<head", "<body", "<main", "<!doctype", "</main>"] {
            #expect(!source.lowercased().contains(wrapper), "\(wrapper) is not part of the fragment")
        }
    }

    @Test func richTextWritesRTFHTMLAndPlainText() async throws {
        let note = try add(Self.sample)
        let wrote = await copyAs().copy(.richText, target: .notes([note.id]))
        #expect(wrote)
        #expect(types == [.rtf, .html, .string], "\(types)")
        let rtf = try #require(pasteboard.data(forType: .rtf))
        #expect(String(decoding: rtf.prefix(5), as: UTF8.self) == "{\\rtf")
        let attributed = try NSAttributedString(
            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(attributed.string.contains("Copy Me"))
        #expect(attributed.string.contains("bold"))
        let html = try #require(pasteboard.string(forType: .html))
        #expect(html.contains("<strong") || html.contains("<b"))
        #expect(html.contains("charset"))
        // Plain text per emphasis delimiters are gone, tags stay.
        let plain = try #require(pasteboard.string(forType: .string))
        #expect(plain == PlainTextExport.text(Self.sample))
        #expect(!plain.contains("**"))
        #expect(plain.contains("#project/tag"))
    }

    // MARK: - Plain Text and Keep Tags (A10)

    @Test func plainTextWritesTheStringOnly() async throws {
        let note = try add(Self.sample)
        let other = try add("Second\n\n**x** here\n")
        #expect(await copyAs().copy(.plainText, target: .notes([note.id, other.id])))
        #expect(types == [.string], "\(types)")
        let plain = try #require(pasteboard.string(forType: .string))
        #expect(plain == PlainTextExport.text(Self.sample) + "\n\n" + PlainTextExport.text("Second\n\n**x** here\n"))
        #expect(!plain.contains("**") && plain.contains("#project/tag"))
    }

    @Test func plainTextOfASelectionCopiesTheSelectionOnly() async throws {
        let note = try add(Self.sample)
        #expect(await copyAs().copy(.plainText, target: .selection(noteId: note.id, text: "Some **bold** words")))
        #expect(pasteboard.string(forType: .string) == "Some bold words")
    }

    @Test(arguments: CopyAsFormat.allCases)
    func keepTagsOffLeavesTagsOutOfEveryFormat(_ format: CopyAsFormat) async throws {
        let note = try add(Self.sample)
        #expect(await copyAs(keepTags: { false }).copy(format, target: .notes([note.id])), "\(format)")
        let everything = [NSPasteboard.PasteboardType.string, .html].compactMap { pasteboard.string(forType: $0) }
            + [pasteboard.data(forType: .rtf).map { String(decoding: $0, as: UTF8.self) } ?? ""]
        for text in everything { #expect(!text.contains("project/tag"), "\(format)") }
        #expect(pasteboard.string(forType: .string)?.contains("bold") == true)
        // The default keeps them.
        #expect(await copyAs().copy(format, target: .notes([note.id])))
        let kept = [NSPasteboard.PasteboardType.string, .html].compactMap { pasteboard.string(forType: $0) }.joined()
        #expect(kept.contains("project/tag"), "\(format)")
    }

    @Test func theSelectionLosesItsTagsToo() async throws {
        let note = try add(Self.sample)
        #expect(await copyAs(keepTags: { false }).copy(.markdown, target: .selection(noteId: note.id, text: "words and a #project/tag here.")))
        #expect(pasteboard.string(forType: .string) == "words and a here.")
    }

    // MARK: - Targets

    @Test func selectionWinsWhenTheEditorIsFocused() async throws {
        let text = "Other Title\n\nFirst **bold** part.\n\nSecond part.\n"
        let note = try add(text)
        let other = try add("Elsewhere\n")
        let ns = text as NSString
        let range = ns.range(of: "First **bold** part.")
        let selection = SelectionRange(anchor: range.upperBound, head: range.location)

        // Focused editor with a selection: the selection (a backwards range too).
        let focused = CopyAs.target(
            editorFocused: true, shown: (note.id, text), selection: selection, selectedNoteIDs: [other.id])
        #expect(focused == .selection(noteId: note.id, text: "First **bold** part."))
        // Empty selection, or an editor that is not focused: the selected notes.
        #expect(
            CopyAs.target(
                editorFocused: true, shown: (note.id, text), selection: SelectionRange(anchor: 4, head: 4),
                selectedNoteIDs: [other.id]) == .notes([other.id]))
        #expect(
            CopyAs.target(
                editorFocused: false, shown: (note.id, text), selection: selection, selectedNoteIDs: [other.id])
                == .notes([other.id]))
        #expect(
            CopyAs.target(editorFocused: false, shown: nil, selection: nil, selectedNoteIDs: []) == nil)
        // An offset past the end is clamped.
        #expect(
            CopyAs.target(
                editorFocused: true, shown: (note.id, text), selection: SelectionRange(anchor: ns.length - 3, head: 9_999),
                selectedNoteIDs: []) == .selection(noteId: note.id, text: "t.\n"))

        // Markdown copies the selected source; HTML and Rich Text render only the selection.
        let target = try #require(focused)
        #expect(await copyAs().copy(.markdown, target: target))
        #expect(pasteboard.string(forType: .string) == "First **bold** part.")
        #expect(await copyAs().copy(.html, target: target))
        let html = try #require(pasteboard.string(forType: .string))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(!html.contains("Second part"))
        #expect(!html.contains("Other Title"))
        #expect(await copyAs().copy(.richText, target: target))
        #expect(pasteboard.string(forType: .string) == "First bold part.")
    }

    @Test func multipleNotesAreJoined() async throws {
        let a = try add("Alpha\n\nfirst **note**\n")
        let b = try add("Beta\n\nsecond note\n")
        #expect(await copyAs().copy(.markdown, target: .notes([b.id, a.id])))
        #expect(pasteboard.string(forType: .string) == "Beta\n\nsecond note\n\n\nAlpha\n\nfirst **note**\n")

        #expect(await copyAs().copy(.html, target: .notes([a.id, b.id])))
        let html = try #require(pasteboard.string(forType: .string))
        let parts = html.components(separatedBy: "<hr>")
        #expect(parts.count == 2)
        #expect(parts[0].contains("Alpha") && !parts[0].contains("Beta"))
        #expect(parts[1].contains("Beta") && !parts[1].contains("Alpha"))

        #expect(await copyAs().copy(.richText, target: .notes([a.id, b.id])))
        let plain = try #require(pasteboard.string(forType: .string))
        #expect(plain == PlainTextExport.text("Alpha\n\nfirst **note**\n") + "\n\n" + PlainTextExport.text("Beta\n\nsecond note\n"))
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(
            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(attributed.string.contains("Alpha") && attributed.string.contains("Beta"))
    }

    @Test func lockedNotesAreSkippedAndNothingLeftBeeps() async throws {
        let open = try add("Open Note\n\nVisible.\n")
        let locked = try add("Secret Note\n\nHidden.\n")
        try lock(locked)

        for format in CopyAsFormat.allCases {
            var beeps = 0
            let wrote = await copyAs(beep: { beeps += 1 }).copy(format, target: .notes([locked.id, open.id]))
            #expect(wrote, "\(format)")
            #expect(beeps == 0, "\(format)")
            let all = [
                pasteboard.string(forType: .string), pasteboard.string(forType: .html),
                pasteboard.data(forType: .rtf).map { String(decoding: $0, as: UTF8.self) },
            ].compactMap { $0 }.joined()
            #expect(all.contains("Visible"), "\(format)")
            #expect(!all.contains("Secret") && !all.contains("Hidden"), "\(format)")
        }

        // Nothing left: the pasteboard keeps what it had, and the app beeps.
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        for format in CopyAsFormat.allCases {
            var beeps = 0
            let wrote = await copyAs(beep: { beeps += 1 }).copy(format, target: .notes([locked.id]))
            #expect(!wrote, "\(format)")
            #expect(beeps == 1, "\(format)")
            #expect(pasteboard.string(forType: .string) == "before", "\(format)")
            #expect(types == [.string], "\(format)")
        }
        var beeps = 0
        #expect(await !copyAs(beep: { beeps += 1 }).copy(.markdown, target: .notes([])))
        #expect(await !copyAs(beep: { beeps += 1 }).copy(.markdown, target: .notes(["no-such-note"])))
        #expect(beeps == 2)
    }

    @Test func skippedLockedNotesAreCountedAndANoticeIsRequested() async throws {
        let first = try add("First\n\none\n")
        let locked = try add("Secret\n\nHidden\n")
        try lock(locked)
        let third = try add("Third\n\nthree\n")
        for format in CopyAsFormat.allCases {
            var notices: [Int] = []
            var beeps = 0
            let outcome = await copyAs(beep: { beeps += 1 }, notify: { notices.append($0) })
                .perform(format, target: .notes([first.id, locked.id, third.id]))
            #expect(outcome == CopyAs.Outcome(wrote: true, skippedLocked: 1), "\(format)")
            #expect(notices == [1], "\(format)")
            #expect(beeps == 0, "\(format)")
            let text = pasteboard.string(forType: .string) ?? ""
            #expect(text.contains("First") && text.contains("Third") && !text.contains("Secret"), "\(format)")
        }
        // Nothing left: it beeps and the notice still says why.
        var notices: [Int] = []
        var beeps = 0
        let none = await copyAs(beep: { beeps += 1 }, notify: { notices.append($0) })
            .perform(.markdown, target: .notes([locked.id]))
        #expect(none == CopyAs.Outcome(wrote: false, skippedLocked: 1))
        #expect(notices == [1] && beeps == 1)
        // No locked note: no notice.
        notices = []
        _ = await copyAs(notify: { notices.append($0) }).perform(.markdown, target: .notes([first.id]))
        #expect(notices.isEmpty)
    }

    // MARK: - Menu bar

    private func editMenu() throws -> NSMenu {
        let mainMenu = try #require(NSApp.mainMenu)
        return try #require(mainMenu.items.first { $0.title == "Edit" }?.submenu)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    @Test func placementMovesCopyAsAfterCopyAndIsIdempotent() throws {
        func menu(_ names: [String]) -> NSMenu {
            let menu = NSMenu(title: "Edit")
            for name in names {
                switch name {
                case "-": menu.addItem(.separator())
                case "Copy": menu.addItem(withTitle: name, action: NSSelectorFromString("copy:"), keyEquivalent: "c")
                case "Copy As":
                    let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                    item.submenu = NSMenu(title: name)
                    menu.addItem(item)
                default: menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
                }
            }
            return menu
        }
        let after = menu(["Undo", "-", "Cut", "Copy", "Paste", "Select All", "Copy As", "Paste From"])
        #expect(CopyAsMenuPlacement.apply(to: after))
        #expect(titles(after) == ["Undo", "-", "Cut", "Copy", "Copy As", "Paste", "Select All", "Paste From"])
        #expect(!CopyAsMenuPlacement.apply(to: after))
        #expect(titles(after) == ["Undo", "-", "Cut", "Copy", "Copy As", "Paste", "Select All", "Paste From"])

        let before = menu(["Copy As", "Cut", "Copy", "Paste"])
        #expect(CopyAsMenuPlacement.apply(to: before))
        #expect(titles(before) == ["Cut", "Copy", "Copy As", "Paste"])

        // Nothing to do without a Copy item or without a Copy As submenu.
        let noCopy = menu(["Cut", "Copy As"])
        #expect(!CopyAsMenuPlacement.apply(to: noCopy))
        #expect(titles(noCopy) == ["Cut", "Copy As"])
        #expect(!CopyAsMenuPlacement.apply(to: menu(["Copy", "Paste"])))
    }

    private func expectCopyAsAfterCopy(_ edit: NSMenu, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let copy = try #require(
            edit.items.firstIndex { $0.action == NSSelectorFromString("copy:") }, "\(titles(edit))",
            sourceLocation: sourceLocation)
        let copyAs = try #require(
            edit.items.firstIndex { $0.title == "Copy As" }, "\(titles(edit))", sourceLocation: sourceLocation)
        #expect(copyAs == copy + 1, "\(titles(edit))", sourceLocation: sourceLocation)
        let submenu = try #require(edit.items[copyAs].submenu, sourceLocation: sourceLocation)
        #expect(titles(submenu).filter { $0 != "-" } == ["Markdown", "Plain Text", "HTML", "Rich Text", "Keep Tags"], sourceLocation: sourceLocation)
    }

    /// The menu bar SwiftUI builds from the commands, as the launch hook leaves it; and after SwiftUI
    /// puts the item back where its command group is (simulated by moving it to the end), the
    /// observers restore the order.
    @Test func editMenuHasCopyAsRightAfterCopy() throws {
        let edit = try editMenu()
        try expectCopyAsAfterCopy(edit)

        let item = try #require(edit.items.first { $0.title == "Copy As" })
        edit.removeItem(item)
        edit.addItem(item)
        try expectCopyAsAfterCopy(edit)
    }

    // MARK: - Superseding

    /// The page waits before it renders, so a copy stays in flight while later ones start.
    private static let slowScript = "await new Promise(r => setTimeout(r, 700)); return await window.baerchenExport.render(request)"

    private func slowRenderer() -> NoteRenderer {
        let renderer = NoteRenderer(environment: environment)
        renderer.renderScript = Self.slowScript
        return renderer
    }

    @Test func aNewCopySupersedesTheOnesStillRendering() async throws {
        let a = try add("Alpha\n\nfirst\n")
        let b = try add("Beta\n\nsecond\n")
        let c = try add("Gamma\n\nthird\n")
        let slowA = slowRenderer()
        let slowB = slowRenderer()
        var beeps = 0
        var notices = 0
        let taskA = Task { await copyAs(renderer: slowA, beep: { beeps += 1 }, notify: { _ in notices += 1 })
            .perform(.html, target: .notes([a.id])) }
        let taskB = Task { await copyAs(renderer: slowB, beep: { beeps += 1 }, notify: { _ in notices += 1 })
            .perform(.richText, target: .notes([b.id])) }
        while !(slowA.isBusy && slowB.isBusy) { await Task.yield() }

        let third = await copyAs(beep: { beeps += 1 }).perform(.markdown, target: .notes([c.id]))
        #expect(third == CopyAs.Outcome(wrote: true, skippedLocked: 0))
        let first = await taskA.value
        let second = await taskB.value
        #expect(first == CopyAs.Outcome(wrote: false, skippedLocked: 0))
        #expect(second == CopyAs.Outcome(wrote: false, skippedLocked: 0))
        // Only the newest copy reached the pasteboard, and the older ones neither beeped nor reported.
        #expect(pasteboard.string(forType: .string) == "Gamma\n\nthird\n")
        #expect(types == [.string])
        #expect(beeps == 0 && notices == 0)
    }

    @Test func theRunnerCancelsTheCopyItReplaces() async throws {
        let a = try add("Alpha\n\nfirst\n")
        let c = try add("Gamma\n\nthird\n")
        let slowA = slowRenderer()
        var beeps = 0
        let first = CopyAsRunner.start(copyAs(renderer: slowA, beep: { beeps += 1 }), .html, target: .notes([a.id]))
        while !slowA.isBusy { await Task.yield() }
        let second = CopyAsRunner.start(copyAs(beep: { beeps += 1 }), .markdown, target: .notes([c.id]))
        #expect(await second.value.wrote)
        #expect(await first.value == CopyAs.Outcome(wrote: false, skippedLocked: 0))
        #expect(first.isCancelled)
        #expect(pasteboard.string(forType: .string) == "Gamma\n\nthird\n")
        #expect(beeps == 0)
        // The renderer gave the turn up when the copy was cancelled.
        #expect(!slowA.isBusy)
    }

    @Test func theNoticeUsesTheExportReportWording() {
        #expect(LibraryBanner.notesNotCopied(locked: 1).message == "1 locked note was not copied")
        #expect(LibraryBanner.notesNotCopied(locked: 3).message == "3 locked notes were not copied")
    }

    @Test func noFlavourPointsAtAnAssetURLOrALocalPath() async throws {
        let png = try #require(NoteRendererTests.redPNG())
        let note = try environment.store.importNote(ImportedNoteDraft(
            text: "Pics\n\nBefore ![](photo.png) after\n\n[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->\n",
            createdAt: .now, modifiedAt: .now,
            attachments: [ImportedAttachment(filename: "photo.png", data: png),
                          ImportedAttachment(filename: "a.pdf", data: Data("%PDF-1.4".utf8))]))
        let library = environment.paths.root.path
        for format in CopyAsFormat.allCases {
            #expect(await copyAs().copy(format, target: .notes([note.id])), "\(format)")
            let flavours: [(String, String)] = [
                ("string", pasteboard.string(forType: .string) ?? ""),
                ("html", pasteboard.string(forType: .html) ?? ""),
                ("rtf", pasteboard.data(forType: .rtf).map { String(decoding: $0, as: UTF8.self) } ?? ""),
            ]
            for (name, text) in flavours {
                for needle in ["baerchen-asset:", "file:", library, "Application Support"] {
                    #expect(!text.contains(needle), "\(format) \(name) contains \(needle)")
                }
            }
            if format != .markdown, format != .plainText {
                // The attachments are in the copy as names, not as links to files.
                let all = flavours.map(\.1).joined()
                #expect(all.contains("photo.png") && all.contains("a.pdf"), "\(format)")
                #expect(!all.contains("<img"), "\(format)")
            }
        }
    }

    @Test func tagsAreKeptRegardlessOfTheExportSetting() async throws {
        Settings(db: environment.database).keepTagsOnExport = false
        #expect(!Settings(db: environment.database).keepTagsOnExport)
        let note = try add("Tagged\n\nBody text #project/tag inline.\n\n#other\n")

        #expect(await copyAs().copy(.markdown, target: .notes([note.id])))
        let markdown = try #require(pasteboard.string(forType: .string))
        #expect(markdown.contains("#project/tag") && markdown.contains("#other"))

        #expect(await copyAs().copy(.html, target: .notes([note.id])))
        let html = try #require(pasteboard.string(forType: .string))
        #expect(html.contains("#project/tag") && html.contains("#other"))

        #expect(await copyAs().copy(.richText, target: .notes([note.id])))
        let plain = try #require(pasteboard.string(forType: .string))
        #expect(plain.contains("#project/tag") && plain.contains("#other"))
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(
            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(attributed.string.contains("#project/tag") && attributed.string.contains("#other"))
    }

    // MARK: - Fragment

    @Test func theFragmentIsWhatSitsInsideTheMainElement() {
        let page = "<!doctype html>\n<html>\n<head>\n<style>p{}</style>\n</head>\n<body>\n"
            + "<main class=\"bc-export\">\n<h1>T</h1>\n<p>x &lt;/main&gt;</p>\n</main>\n</body>\n</html>\n"
        #expect(CopyAs.bodyFragment(ofDocument: page) == "<h1>T</h1>\n<p>x &lt;/main&gt;</p>")
        #expect(CopyAs.bodyFragment(ofDocument: "<p>no wrapper</p>") == nil)
    }
}
