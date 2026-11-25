// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct InfoPanelModelTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesInfoTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState

        var info: InfoPanelModel { state.info }
        var model: LibraryModel { state.model }
        var store: NoteStore { environment.store }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesInfo-\(UUID().uuidString)")
            environment = try AppEnvironment(paths: AppPaths(root: root))
            editor = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            state = MainWindowState(environment: environment, defaults: UserDefaults(suiteName: suiteName)!, editor: editor)
            _ = editor.handle(.ready(version: EditorBridge.version))
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        /// Selects `id` in the list and shows it in the editor (as `EditorPane` does).
        func show(_ id: String) {
            model.refresh()
            model.selectNotes([id])
            state.showFocusedNote()
        }

        func text(_ id: String) throws -> String {
            try #require(try store.note(id: id)).text
        }
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    // MARK: - Showing

    @Test func testShortcutsShowTheirTabAndToggleIt() throws {
        let env = try Env()
        let info = env.info
        #expect(!info.isPresented)
        info.toggle(.statistics)
        #expect(info.isPresented && info.tab == .statistics)
        info.toggle(.backlinks)
        #expect(info.isPresented && info.tab == .backlinks)
        info.toggle(.backlinks)
        #expect(!info.isPresented)
        info.togglePanel()
        #expect(info.isPresented && info.tab == .backlinks)
        info.togglePanel()
        #expect(!info.isPresented)
    }

    @Test func testInfoShortcutsAreBearsAndFreeInTheFormatMenu() {
        #expect(InfoPanelModel.Tab.allCases.map(\.shortcutKey) == ["i", "a", "b"])
        // The Format menu's table (shared with the editor) has no ⇧⌘I / ⇧⌘A / ⇧⌘B.
        let taken = FormatMenu.items.compactMap(\.shortcutDisplay)
        for display in ["⇧⌘I", "⇧⌘A", "⇧⌘B"] { #expect(!taken.contains(display), "\(display)") }
    }

    // MARK: - Statistics

    @Test func testStatisticsCountTheNoteThenTheSelection() throws {
        let env = try Env()
        let note = try env.store.create(text: "Title\nHello **big** world")
        env.show(note.id)
        env.info.toggle(.statistics)
        #expect(env.info.statistics == NoteStatistics(words: 4, characters: 20, paragraphs: 2))
        #expect(!env.info.isSelection)
        #expect(env.info.lastEdit == note.modifiedAt)

        // The editor reports a selection: "Hello".
        _ = env.editor.handle(.selectionChanged(noteId: note.id, anchor: 11, head: 6))
        env.info.refresh()
        #expect(env.info.isSelection)
        #expect(env.info.statistics.words == 1)

        // A collapsed selection counts the whole note again.
        _ = env.editor.handle(.selectionChanged(noteId: note.id, anchor: 3, head: 3))
        env.info.refresh()
        #expect(!env.info.isSelection)
        #expect(env.info.statistics.words == 4)
    }

    @Test func testStatisticsFollowTypingBeforeItIsCommitted() throws {
        let env = try Env()
        let note = try env.store.create(text: "one")
        env.show(note.id)
        env.info.toggle(.statistics)
        let reply = env.editor.handle(.changes(
            noteId: note.id, txId: "t1", baseRevision: 0, revision: 1,
            changeSet: ChangeSet(sections: [.retain(3), .replace(deleteLength: 0, insert: " two three")])
        ))
        #expect(reply == .acked(revision: 1))
        env.info.refresh()
        #expect(env.info.statistics.words == 3)
    }

    @Test func testSelectedTextUsesUTF16OffsetsAndNeverSplitsAScalar() {
        let text = "a😀b"
        #expect(InfoPanelModel.selectedText(in: text, selection: SelectionRange(anchor: 4, head: 1)) == "😀b")
        #expect(InfoPanelModel.selectedText(in: text, selection: SelectionRange(anchor: 2, head: 4)) == "😀b")
        #expect(InfoPanelModel.selectedText(in: text, selection: SelectionRange(anchor: 0, head: 99)) == "a😀b")
        #expect(InfoPanelModel.selectedText(in: text, selection: SelectionRange(anchor: 1, head: 1)) == nil)
    }

    @Test func testReadTime() {
        #expect(InfoPanelModel.readTimeText(seconds: 30).hasPrefix("< 1"))
        #expect(InfoPanelModel.readTimeText(seconds: 150).contains("3"))
    }

    // MARK: - Table of contents

    @Test func testTableOfContentsIsTheLiveOutlineAndScrollsTheEditor() throws {
        let env = try Env()
        let start = "Doc\n# One\ntext\n## Two"
        let note = try env.store.create(text: start)
        env.show(note.id)
        env.info.toggle(.contents)
        #expect(env.info.headings.map(\.text) == ["One", "Two"])

        _ = env.editor.handle(.changes(
            noteId: note.id, txId: "t1", baseRevision: 0, revision: 1,
            changeSet: ChangeSet(sections: [.retain(start.utf16.count), .replace(deleteLength: 0, insert: "\n### Three")])
        ))
        env.info.refresh()
        #expect(env.info.headings.map(\.text) == ["One", "Two", "Three"])
        #expect(env.info.headings.map(\.level) == [1, 2, 3])

        env.info.scrollToHeading(2)
        #expect(env.page.delivered.last == .scrollToHeading(noteId: note.id, index: 2))
    }

    // MARK: - Backlinks

    @Test func testBacklinksListLinkedAndUnlinkedMentions() async throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic\nbody")
        let linker = try env.store.create(text: "A\nsee [[Topic]]")
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        env.show(target.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        #expect(env.info.backlinks.linked.map(\.noteId) == [linker.id])
        #expect(env.info.backlinks.unlinked.map(\.noteId) == [mentioner.id])
        #expect(env.info.backlinks.unlinked.first?.mentions.first?.snippet == "about Topic here")
    }

    @Test func testLinkIsOneUndoStepWithABanner() async throws {
        let env = try Env()
        let undoManager = makeUndoManager()
        env.model.undoManager = undoManager
        let target = try env.store.create(text: "Topic\nbody")
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        env.show(target.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        let mention = try #require(env.info.backlinks.unlinked.first?.mentions.first)

        env.info.link(mention)
        #expect(try env.text(mentioner.id) == "B\nabout [[Topic]] here")
        // The mention leaves the list at once; the write's reload moves the note to linked.
        #expect(env.info.backlinks.unlinked.isEmpty)
        env.info.writeDebounce = .zero
        env.info.notesDidChange()
        await env.info.settle()
        #expect(env.info.backlinks.linked.map(\.noteId) == [mentioner.id])
        guard case .linksUpdated(1, _)? = env.model.banner else {
            Issue.record("banner \(String(describing: env.model.banner))")
            return
        }
        #expect(undoManager.undoActionName == "Link Mention")

        undoManager.undo()
        #expect(try env.text(mentioner.id) == "B\nabout Topic here")
        #expect(env.model.banner == nil)
        undoManager.redo()
        #expect(try env.text(mentioner.id) == "B\nabout [[Topic]] here")
        #expect(undoManager.undoActionName == "Link Mention")
    }

    @Test func testTheBannersUndoRestoresTheMention() async throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        env.show(target.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        env.info.link(try #require(env.info.backlinks.unlinked.first?.mentions.first))
        guard case .linksUpdated(_, let rewriteId)? = env.model.banner else {
            Issue.record("no banner")
            return
        }
        env.model.undoLinkRewrite(rewriteId)
        #expect(try env.text(mentioner.id) == "B\nabout Topic here")
    }

    @Test func testLinkGoesThroughTheMentioningNotesOpenSession() async throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        // The mentioning note is open elsewhere (another window) with typing not committed yet.
        let session = try env.environment.session(for: mentioner.id)
        var replaced: [String] = []
        let token = session.addTextListener { text, _ in replaced.append(text) }
        defer { session.removeListener(token) }
        env.environment.setOpenNoteIds([mentioner.id], for: ObjectIdentifier(session))
        env.show(target.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        let mention = try #require(env.info.backlinks.unlinked.first?.mentions.first)
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: ChangeSet(sections: [
            .retain("B\nabout Topic here".utf16.count), .replace(deleteLength: 0, insert: "!"),
        ]), origin: nil) == .acked(revision: 1))

        env.info.link(mention)
        #expect(session.text == "B\nabout [[Topic]] here!")
        #expect(try env.text(mentioner.id) == "B\nabout [[Topic]] here!")
        #expect(replaced.last == "B\nabout [[Topic]] here!")
        #expect(try env.store.allNotes().count == 2)  // no conflict copy
    }

    @Test func testAStaleMentionIsRefusedWithABanner() async throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        env.show(target.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        let mention = try #require(env.info.backlinks.unlinked.first?.mentions.first)
        let current = try #require(try env.store.note(id: mentioner.id))
        _ = try env.store.updateText(id: mentioner.id, text: "B\nall about Topic here", expectedRevision: current.revision)

        env.info.link(mention)
        #expect(try env.text(mentioner.id) == "B\nall about Topic here")
        #expect(env.model.banner == .mentionNotLinked(.stale))
    }

    @Test func testRefusalsSayWhy() async throws {
        let env = try Env()
        let older = try env.store.create(text: "Topic", now: Date(timeIntervalSince1970: 1_000))
        _ = try env.store.create(text: "Topic", now: Date(timeIntervalSince1970: 2_000))
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        // The older duplicate: [[Topic]] opens the newer note.
        let mention = Mention(noteId: mentioner.id, line: 1, range: 6..<11, snippet: "")
        #expect(!env.model.linkMention(mention, to: older.id))
        #expect(env.model.banner == .mentionNotLinked(.resolvesElsewhere))
        #expect(LibraryBanner.mentionNotLinked(.resolvesElsewhere).message.contains("another note"))
        let messages = [MentionLinkError.stale, .notEditable, .resolvesElsewhere, .titleNotLinkable, .sameNote]
            .map { LibraryBanner.mentionNotLinked($0).message }
        #expect(Set(messages).count == 5)
    }

    @Test func testBacklinksAreReadInTheBackgroundOncePerChange() async throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        _ = try env.store.create(text: "B\nabout Topic")
        env.show(target.id)
        env.info.writeDebounce = .milliseconds(300)
        // Opening the tab, presenting the popover and the view appearing read once.
        env.info.toggle(.backlinks)
        env.info.viewAppeared()
        defer { env.info.viewDisappeared() }
        await env.info.settle()
        #expect(env.info.backlinksComputations == 1)
        #expect(env.info.backlinks.unlinked.count == 1)

        // One write reaches the panel twice (GRDB observation and the change notifier's echo);
        // it reads once, after the debounce.
        _ = try env.store.create(text: "C\nmore Topic")
        let deadline = ContinuousClock.now + .seconds(3)
        while env.info.backlinks.unlinked.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(500))
        await env.info.settle()
        #expect(env.info.backlinks.unlinked.count == 2)
        #expect(env.info.backlinksComputations == 2)
    }

    @Test func testReopeningThePanelShowsMentionsWrittenWhileItWasHidden() async throws {
        // N1: no observation runs while hidden, so the cached list must not survive.
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        _ = try env.store.create(text: "B\nabout Topic")
        env.show(target.id)
        env.info.toggle(.backlinks)
        env.info.viewAppeared()
        await env.info.settle()
        #expect(env.info.backlinks.unlinked.count == 1)
        env.info.toggle(.backlinks)
        env.info.viewDisappeared()

        _ = try env.store.create(text: "C\nmore Topic")
        env.info.toggle(.backlinks)
        env.info.viewAppeared()
        defer { env.info.viewDisappeared() }
        await env.info.settle()
        #expect(env.info.backlinks.unlinked.count == 2)
    }

    @Test func testComingBackToANoteReloadsItsBacklinks() async throws {
        // N2: Backlinks on A → Statistics → note B → back to A → Backlinks shows A's list.
        let env = try Env()
        let a = try env.store.create(text: "Topic")
        let b = try env.store.create(text: "Other")
        _ = try env.store.create(text: "B\nabout Topic")
        env.show(a.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        #expect(env.info.backlinks.unlinked.count == 1)
        env.info.tab = .statistics
        env.show(b.id)
        env.info.refresh()
        env.show(a.id)
        env.info.refresh()
        env.info.tab = .backlinks
        await env.info.settle()
        #expect(env.info.backlinks.unlinked.count == 1)
    }

    @Test func testAReadInFlightDuringLinkIsDropped() async throws {
        // N6: a result read before the link must not bring the linked mention back.
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        _ = try env.store.create(text: "B\nabout Topic")
        env.show(target.id)
        env.info.toggle(.backlinks)
        await env.info.settle()
        let mention = try #require(env.info.backlinks.unlinked.first?.mentions.first)
        env.info.writeDebounce = .seconds(60)
        env.info.notesDidChange()
        env.info.refresh()  // a read (of the state before the link) is in flight
        let inFlight = env.info.backlinksTask
        env.info.link(mention)
        // Whether that read ran before or after the write is up to the reader queue, so the
        // check is that it was cancelled (and published nothing).
        #expect(inFlight?.isCancelled == true)
        await inFlight?.value
        #expect(env.info.backlinks.unlinked.isEmpty)
        env.info.viewDisappeared()  // drops the pending write refresh
    }

    @Test func testTruncationFooters() {
        var backlinks = Backlinks()
        #expect(InfoPanelModel.unlinkedFooter(backlinks) == nil)
        backlinks.unlinkedTruncated = true
        #expect(InfoPanelModel.unlinkedFooter(backlinks) == "No mentions in the first \(Backlinks.candidateScanLimit.formatted()) candidates")
        backlinks.unlinked = [MentioningNote(noteId: "n", title: "N", location: .notes, isLocked: false, isReadOnly: false, mentions: [
            Mention(noteId: "n", line: 1, range: 0..<1, snippet: ""), Mention(noteId: "n", line: 2, range: 0..<1, snippet: ""),
        ])]
        #expect(InfoPanelModel.unlinkedFooter(backlinks) == "Showing the first 2 mentions")
        backlinks.linkedTruncated = true
        backlinks.linked = backlinks.unlinked
        #expect(InfoPanelModel.linkedFooter(backlinks) == "Showing the first 1 note")
    }

    @Test func testSelectionStatisticsIncludeTypingNotYetCommitted() throws {
        let env = try Env()
        let note = try env.store.create(text: "one")
        env.show(note.id)
        env.info.toggle(.statistics)
        // The editor sends its edit before the selection that covers the new words.
        _ = env.editor.handle(.changes(
            noteId: note.id, txId: "t1", baseRevision: 0, revision: 1,
            changeSet: ChangeSet(sections: [.retain(3), .replace(deleteLength: 0, insert: " two three")])
        ))
        _ = env.editor.handle(.selectionChanged(noteId: note.id, anchor: 4, head: 13))
        env.info.refresh()
        #expect(env.info.isSelection)
        #expect(env.info.statistics.words == 2)
    }

    @Test func testOpeningAMentioningNoteShowsIt() throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic")
        let linker = try env.store.create(text: "A\n[[Topic]]")
        let archived = try env.store.create(text: "C\n[[Topic]]")
        try env.store.archive([archived.id])
        env.show(target.id)
        env.info.open(linker.id)
        #expect(env.model.focusedNoteID == linker.id)
        #expect(env.model.scope == .notes)
        env.info.open(archived.id)
        #expect(env.model.focusedNoteID == archived.id)
        #expect(env.model.scope == .archive)
    }

    @Test func testANoteWindowsPanelShowsItsNoteAndLinksWithUndo() async throws {
        let env = try Env()
        let target = try env.store.create(text: "Topic\n# Part")
        let mentioner = try env.store.create(text: "B\nabout Topic here")
        let page = FakeEditorPage()
        let editor = EditorBridgeController(environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        _ = editor.handle(.ready(version: EditorBridge.version))
        let window = NoteWindowState(environment: env.environment, noteId: target.id, editor: editor)
        defer { window.close() }
        let undoManager = makeUndoManager()
        window.undoManagerOverride = undoManager

        window.info.toggle(.contents)
        #expect(window.info.noteId == target.id)
        #expect(window.info.headings.map(\.text) == ["Part"])
        window.info.scrollToHeading(0)
        #expect(page.delivered.last == .scrollToHeading(noteId: target.id, index: 0))

        window.info.tab = .backlinks
        await window.info.settle()
        window.info.link(try #require(window.info.backlinks.unlinked.first?.mentions.first))
        #expect(try env.text(mentioner.id) == "B\nabout [[Topic]] here")
        #expect(undoManager.undoActionName == "Link Mention")
        undoManager.undo()
        #expect(try env.text(mentioner.id) == "B\nabout Topic here")
        undoManager.redo()
        #expect(try env.text(mentioner.id) == "B\nabout [[Topic]] here")

        // A mentioning note opens in the same window.
        window.info.open(mentioner.id)
        #expect(window.noteId == mentioner.id)
    }

    @Test func testNoNoteShowsNoContent() throws {
        let env = try Env()
        env.info.toggle(.statistics)
        #expect(env.info.noteId == nil)
        #expect(env.info.statistics == .zero)
    }
}
