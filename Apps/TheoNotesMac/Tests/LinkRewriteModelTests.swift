// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// Runs scheduled actions only when a test advances its virtual time.
@MainActor
final class ManualScheduler: DebounceScheduler {
    private struct Item {
        var order: Int
        var due: Duration
        var action: @MainActor () -> Void
    }

    private(set) var now: Duration = .zero
    private var items: [Int: Item] = [:]
    private var nextOrder = 0

    var pendingCount: Int { items.count }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let order = nextOrder
        nextOrder += 1
        items[order] = Item(order: order, due: now + delay, action: action)
        return ScheduledAction { [weak self] in self?.items[order] = nil }
    }

    /// Moves time forward, running every action that falls due on the way (in due order).
    func advance(by duration: Duration) {
        let end = now + duration
        while let next = items.values.filter({ $0.due <= end }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            items[next.order] = nil
            now = next.due
            next.action()
        }
        now = end
    }
}

@MainActor
@Suite struct LinkRewriteModelTests {
    typealias Env = LibraryModelTests.Env

    private func text(_ env: Env, _ id: String) throws -> String {
        try #require(try env.store.note(id: id)).text
    }

    /// The note's session with an editor attached (so it is not evicted).
    private func session(_ env: Env, _ id: String) throws -> NoteSession {
        let session = try env.environment.session(for: id)
        if session.textListenerCount == 0 { _ = session.addTextListener { _, _ in } }
        return session
    }

    /// Types `newText` over the note's text in its editor; `commit` runs the debounced commit.
    private func type(_ env: Env, _ id: String, _ newText: String, commit: Bool = true) throws {
        let session = try session(env, id)
        let expected = session.revision + 1
        let change = ChangeSet(sections: [.replace(deleteLength: session.text.utf16.count, insert: newText)])
        #expect(session.apply(txId: UUID().uuidString, baseRevision: session.revision, changeSet: change, origin: nil)
            == .acked(revision: expected))
        if commit { try session.flush() }
    }

    /// Another process (CLI/MCP) writes the note; the app's change notification follows.
    private func writeElsewhere(_ env: Env, _ id: String, _ newText: String) throws {
        let external = try env.externalStore()
        let note = try #require(try external.note(id: id))
        _ = try external.updateText(id: id, text: newText, expectedRevision: note.revision)
        env.environment.databaseDidChange()
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    private func linksUpdated(_ banner: LibraryBanner?) -> (count: Int, id: UUID)? {
        if case .linksUpdated(let count, let id)? = banner { (count, id) } else { nil }
    }

    // MARK: - Debounce

    @Test func testRewriteWaitsUntilTheTitleIsStableFor1_5Seconds() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old\nbody")
        let linker = try env.store.create(text: "See [[Old/Part|alias]]")
        env.model.selectNotes([target.id])

        // Typing a title commits every few hundred ms; each new title restarts the wait.
        for (title, pause) in [("N", 1000), ("Ne", 1400), ("New", 1499)] {
            try type(env, target.id, title + "\nbody")
            scheduler.advance(by: .milliseconds(pause))
            #expect(try text(env, linker.id) == "See [[Old/Part|alias]]", "after \(title)")
            #expect(scheduler.pendingCount == 1)
        }
        #expect(env.model.banner == nil)
        scheduler.advance(by: .milliseconds(1))
        #expect(try text(env, linker.id) == "See [[New/Part|alias]]")
        #expect(linksUpdated(env.model.banner)?.count == 1)
        #expect(scheduler.pendingCount == 0)

        // Nothing more happens while the title stays.
        try type(env, target.id, "New\nbody edited")
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: .seconds(5))
        #expect(try text(env, linker.id) == "See [[New/Part|alias]]")
    }

    @Test func testBodyEditsDoNotRestartTheWait() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old\nbody")
        let linker = try env.store.create(text: "L [[Old]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "New\nbody")
        scheduler.advance(by: .milliseconds(1000))
        try type(env, target.id, "New\nbody typed on")
        scheduler.advance(by: .milliseconds(499))
        #expect(try text(env, linker.id) == "L [[Old]]")
        scheduler.advance(by: .milliseconds(1))  // 1.5 s after the title change, not after the body edit
        #expect(try text(env, linker.id) == "L [[New]]")
        #expect(scheduler.pendingCount == 0)
    }

    @Test func testAChainAcrossTwoWaitsAndRenamingBack() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "A")
        let linker = try env.store.create(text: "L [[A|x]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "B")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, linker.id) == "L [[B|x]]")
        let first = try #require(linksUpdated(env.model.banner))

        try type(env, target.id, "C")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, linker.id) == "L [[C|x]]")
        // The first banner could no longer undo the linker: only the newer one is offered.
        let second = try #require(linksUpdated(env.model.banner))
        #expect(second.id != first.id)
        env.model.dismissBanner()
        #expect(env.model.banner == nil)

        try type(env, target.id, "A")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, linker.id) == "L [[A|x]]")
    }

    // MARK: - Only the editor's own title edits (R15)

    @Test func testATitleWrittenElsewhereIsNotFollowed() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old\nbody")
        let linker = try env.store.create(text: "L [[Old]]")
        let laterLinker = try env.store.create(text: "M [[Cli]]")
        _ = try session(env, target.id)
        env.model.selectNotes([target.id])

        try writeElsewhere(env, target.id, "Cli\nbody")
        #expect(try env.environment.session(for: target.id).text == "Cli\nbody")
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, linker.id) == "L [[Old]]")
        #expect(env.model.banner == nil)

        // The baseline moved on: the editor's next rename starts from the CLI's title.
        try type(env, target.id, "User\nbody")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, linker.id) == "L [[Old]]")
        #expect(try text(env, laterLinker.id) == "M [[User]]")
    }

    @Test func testATagRenameThatChangesTheTitleIsNotFollowed() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Plan #work\nbody")
        let linker = try env.store.create(text: "L [[Plan #work]]")
        _ = try session(env, target.id)
        env.model.selectNotes([target.id])

        #expect(env.model.renameTag("work", to: "job", undoManager: nil))
        env.environment.databaseDidChange()
        #expect(try env.environment.session(for: target.id).text == "Plan #job\nbody")
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, linker.id) == "L [[Plan #work]]")
        #expect(scheduler.pendingCount == 0)
    }

    @Test func testAnExternalBodyChangeKeepsThePendingRename() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old\n\nbody")
        let linker = try env.store.create(text: "L [[Old]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "New\n\nbody")
        scheduler.advance(by: .milliseconds(700))
        try writeElsewhere(env, target.id, "New\n\nbody from the CLI")
        #expect(try env.environment.session(for: target.id).text == "New\n\nbody from the CLI")
        scheduler.advance(by: .milliseconds(800))
        #expect(try text(env, linker.id) == "L [[New]]")
    }

    @Test func testAnExternalRenameSupersedesAPendingOne() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old\n\nbody")
        let linker = try env.store.create(text: "L [[Old]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "Mine\n\nbody")
        scheduler.advance(by: .milliseconds(700))
        try writeElsewhere(env, target.id, "Theirs\n\nbody")
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, linker.id) == "L [[Old]]")
        #expect(scheduler.pendingCount == 0)
    }

    // MARK: - Undo

    @Test func testUndoFromTheBanner() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let undoManager = makeUndoManager()
        env.model.undoManager = undoManager
        let target = try env.store.create(text: "Old")
        let a = try env.store.create(text: "A [[Old]]")
        let b = try env.store.create(text: "B [[Old|x]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "New")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, a.id) == "A [[New]]")
        #expect(try text(env, b.id) == "B [[New|x]]")
        let banner = try #require(linksUpdated(env.model.banner))
        #expect(banner.count == 2)
        #expect(env.model.banner?.message == "Updated links in 2 notes")
        #expect(env.model.banner?.actionTitle == "Undo")
        #expect(undoManager.undoActionName == "Update Links")

        env.model.undoLinkRewrite(banner.id)
        #expect(try text(env, a.id) == "A [[Old]]")
        #expect(try text(env, b.id) == "B [[Old|x]]")
        #expect(try text(env, target.id) == "New")
        #expect(env.model.banner == nil)
        #expect(!undoManager.canUndo)  // the banner's undo took the undo manager's step with it
        scheduler.advance(by: .seconds(5))
        #expect(try text(env, a.id) == "A [[Old]]")  // undoing is not a new title change
    }

    @Test func testUndoAndRedoFromTheUndoManager() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let undoManager = makeUndoManager()
        env.model.undoManager = undoManager
        let target = try env.store.create(text: "Old")
        let a = try env.store.create(text: "A [[Old]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "New")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, a.id) == "A [[New]]")

        undoManager.undo()
        #expect(try text(env, a.id) == "A [[Old]]")
        #expect(env.model.banner == nil)  // its Undo would do nothing now
        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(try text(env, a.id) == "A [[New]]")
        #expect(undoManager.canUndo)
        #expect(LibraryBanner.linksUpdated(noteCount: 1, rewriteId: UUID()).message == "Updated links in 1 note")
    }

    // MARK: - The renamed note itself

    /// The renamed note is open and has unsaved typing when the rewrite runs: its own `[[/heading]]`
    /// link changes through its session (flushed first, then adopting the rewrite as an external
    /// change), so no local edit is lost and no conflict copy appears.
    @Test func testSameNoteHeadingLinksGoThroughTheOpenDirtySession() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let note = try env.store.create(text: "Note\n## Old heading\nsee [[/Old heading]]\n")
        let other = try env.store.create(text: "O [[Note/Old heading|x]] [[/Old heading]]")
        let session = try env.environment.session(for: note.id)
        var replaced: [String] = []
        _ = session.addTextListener { text, _ in replaced.append(text) }
        env.model.selectNotes([note.id])

        try type(env, note.id, "Note\n## New heading\nsee [[/Old heading]]\n")
        try type(env, note.id, "Note\n## New heading\nsee [[/Old heading]]\nmore", commit: false)

        scheduler.advance(by: .milliseconds(1500))
        let expected = "Note\n## New heading\nsee [[/New heading]]\nmore"
        #expect(session.text == expected)
        #expect(try text(env, note.id) == expected)
        #expect(replaced.last == expected)
        #expect(try text(env, other.id) == "O [[Note/New heading|x]] [[/Old heading]]")
        #expect(try env.store.allNotes().count == 2)  // no conflict copy
        #expect(linksUpdated(env.model.banner)?.count == 1)  // the renamed note itself is not counted

        // Undo restores the link line through the session too and keeps the typing.
        let banner = try #require(linksUpdated(env.model.banner))
        env.model.undoLinkRewrite(banner.id)
        #expect(session.text == "Note\n## New heading\nsee [[/Old heading]]\nmore")
        #expect(try text(env, other.id) == "O [[Note/Old heading|x]] [[/Old heading]]")
    }

    @Test func testWaitsWhileTheEditorIsTyping() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let note = try env.store.create(text: "Note\n## Old\nsee [[/Old]]\n")
        let other = try env.store.create(text: "O [[Note/Old]]")
        env.model.selectNotes([note.id])

        try type(env, note.id, "Note\n## New\nsee [[/Old]]\n")
        scheduler.advance(by: .milliseconds(1400))
        try type(env, note.id, "Note\n## New\nsee [[/Old]]\nx", commit: false)  // keystrokes may still be in flight
        scheduler.advance(by: .milliseconds(100))
        #expect(try text(env, other.id) == "O [[Note/Old]]")
        #expect(try env.environment.session(for: note.id).text == "Note\n## New\nsee [[/Old]]\nx")
        scheduler.advance(by: .milliseconds(499))
        #expect(try text(env, other.id) == "O [[Note/Old]]")
        scheduler.advance(by: .milliseconds(1))  // the retry, with the editor quiet for 500 ms
        #expect(try text(env, other.id) == "O [[Note/New]]")
        #expect(try env.environment.session(for: note.id).text == "Note\n## New\nsee [[/New]]\nx")
    }

    @Test func testAnEmptiedHeadingIsRenamedWhenRetyped() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let note = try env.store.create(text: "Note\n## Old\nx\n## Other")
        let other = try env.store.create(text: "O [[Note/Old]] [[Note/Other]]")
        env.model.selectNotes([note.id])

        try type(env, note.id, "Note\n## \nx\n## Other")
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, other.id) == "O [[Note/Old]] [[Note/Other]]")
        try type(env, note.id, "Note\n## New\nx\n## Other")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, other.id) == "O [[Note/New]] [[Note/Other]]")
    }

    @Test func testADeletedHeadingMovesTheBaselineOn() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let note = try env.store.create(text: "Note\n## A\nx\n## B")
        let other = try env.store.create(text: "O [[Note/A]] [[Note/B]]")
        env.model.selectNotes([note.id])

        try type(env, note.id, "Note\n## A\nx")  // B deleted, no empty heading line left
        scheduler.advance(by: .seconds(3))
        try type(env, note.id, "Note\n## A2\nx")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, other.id) == "O [[Note/A2]] [[Note/B]]")
    }

    @Test func aNewHeadingAfterADeletionIsNotARename() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let note = try env.store.create(text: "Note\n## A\nx\n## B")
        let other = try env.store.create(text: "O [[Note/A]] [[Note/B]]")
        env.model.selectNotes([note.id])

        try type(env, note.id, "Note\n## A\nx")
        scheduler.advance(by: .seconds(3))
        try type(env, note.id, "Note\n## A\nx\n## X")
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, other.id) == "O [[Note/A]] [[Note/B]]")
    }

    @Test func testAnEditorThatNeverPausesIsOverriddenAfter5Seconds() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let note = try env.store.create(text: "Note\n## Old\nsee [[/Old]]\n")
        let other = try env.store.create(text: "O [[Note/Old]]")
        env.model.selectNotes([note.id])

        try type(env, note.id, "Note\n## New\nsee [[/Old]]\n")
        var rewrittenAt: Duration?
        for _ in 0..<30 {  // a keystroke every 300 ms for 9 s
            scheduler.advance(by: .milliseconds(300))
            if rewrittenAt == nil, try text(env, other.id) == "O [[Note/New]]" { rewrittenAt = scheduler.now }
            let typed = try env.environment.session(for: note.id).text
            try type(env, note.id, typed + "x", commit: false)
        }
        // Deferred from 1.5 s (first try), forced on the first retry 5 s later.
        #expect(rewrittenAt == .milliseconds(6600))
        let session = try env.environment.session(for: note.id)
        #expect(session.text.hasPrefix("Note\n## New\nsee [[/New]]\n"))
        #expect(session.text.hasSuffix(String(repeating: "x", count: 30)))  // no keystroke lost here
        #expect(try env.store.allNotes().count == 2)
    }

    // MARK: - Note windows

    /// A title typed in a standalone note window (no `LibraryModel` of its own) is followed by the
    /// app's one updater; the main window presents the banner.
    @Test func testATitleTypedInANoteWindowRewritesLinks() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old")
        let linker = try env.store.create(text: "L [[Old]]")
        let page = FakeEditorPage()
        let editor = EditorBridgeController(
            environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil
        )
        _ = editor.handle(.ready(version: EditorBridge.version))
        let window = NoteWindowState(environment: env.environment, noteId: target.id, editor: editor)
        #expect(env.environment.openNoteIds == [target.id])

        let change = ChangeSet(sections: [.replace(deleteLength: 3, insert: "New")])
        #expect(editor.handle(.changes(noteId: target.id, txId: "t1", baseRevision: 0, revision: 1, changeSet: change))
            == .acked(revision: 1))
        try env.environment.session(for: target.id).flush()
        scheduler.advance(by: .milliseconds(1499))
        #expect(try text(env, linker.id) == "L [[Old]]")
        scheduler.advance(by: .milliseconds(1))
        #expect(try text(env, linker.id) == "L [[New]]")
        #expect(linksUpdated(env.model.banner)?.count == 1)

        // Closing the note window runs a pending update at once.
        #expect(editor.handle(.changes(noteId: target.id, txId: "t2", baseRevision: 1, revision: 2,
                                       changeSet: ChangeSet(sections: [.replace(deleteLength: 3, insert: "Newest")])))
            == .acked(revision: 2))
        window.close()
        #expect(try text(env, linker.id) == "L [[Newest]]")
    }

    // MARK: - Switching notes, quitting, emptied titles, banners

    @Test func testSwitchingNotesBeforeTheCommitStillRewrites() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old")
        let linker = try env.store.create(text: "L [[Old]]")
        env.model.selectNotes([target.id])

        // The new title is still only in the session when the user moves on.
        try type(env, target.id, "New", commit: false)
        env.model.selectNotes([linker.id])
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: .milliseconds(1500))  // flushes, sees the new title, waits again
        #expect(try text(env, target.id) == "New")
        #expect(try text(env, linker.id) == "L [[Old]]")
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, linker.id) == "L [[New]]")
        #expect(scheduler.pendingCount == 0)
    }

    @Test func testQuittingRunsPendingRewritesNow() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old")
        let other = try env.store.create(text: "Other")
        let linker = try env.store.create(text: "L [[Old]] [[Other]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "New")
        scheduler.advance(by: .milliseconds(100))
        env.model.runPendingLinkRewrites()
        #expect(try text(env, linker.id) == "L [[New]] [[Other]]")
        #expect(scheduler.pendingCount == 0)

        // Typing not committed yet is flushed first, also while the editor is busy.
        env.model.selectNotes([other.id])
        try type(env, other.id, "Renamed", commit: false)
        env.model.runPendingLinkRewrites()
        #expect(try text(env, linker.id) == "L [[New]] [[Renamed]]")
    }

    @Test func testClosingTheWindowRunsPendingRewritesNow() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old")
        let linker = try env.store.create(text: "L [[Old]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "New", commit: false)
        env.model.close()
        #expect(try text(env, linker.id) == "L [[New]]")
        #expect(linksUpdated(env.model.banner)?.count == 1)  // still presented by the closing window
        env.model.dismissBanner()

        // The closed window presents nothing more; with no main window left links still update.
        try type(env, target.id, "Newer")
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, linker.id) == "L [[Newer]]")
        #expect(env.model.banner == nil)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func testAnEmptiedTitleWaitsForTheNextOne() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old\nbody")
        let linker = try env.store.create(text: "L [[Old]]")
        env.model.selectNotes([target.id])

        try type(env, target.id, "\nbody")
        scheduler.advance(by: .seconds(3))
        #expect(try text(env, linker.id) == "L [[Old]]")
        try type(env, target.id, "New\nbody")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, linker.id) == "L [[New]]")
    }

    @Test func testLinksBannerComesBeforeTheSkippedOne() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let target = try env.store.create(text: "Old")
        let plain = try env.store.create(text: "P [[Old]]")
        let locked = try env.store.create(text: "L [[Old]]")
        try env.environment.database.pool.write {
            try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id])
        }
        env.model.selectNotes([target.id])

        try type(env, target.id, "New")
        scheduler.advance(by: .milliseconds(1500))
        #expect(try text(env, plain.id) == "P [[New]]")
        #expect(linksUpdated(env.model.banner)?.count == 1)
        env.model.dismissBanner()
        #expect(env.model.banner == .notesSkipped(locked: 1, readOnly: 0))
        env.model.dismissBanner()
        #expect(env.model.banner == nil)
        #expect(LibraryBanner.notesSkipped(locked: 0, readOnly: 0, unsaved: 1).message == "1 unsaved note was not changed")
        #expect(LibraryBanner.notesSkipped(locked: 1, readOnly: 1, unsaved: 1).message
            == "1 locked, 1 read-only, 1 unsaved notes were not changed")
    }

    @Test func testNothingLinkedMeansNoBanner() throws {
        let scheduler = ManualScheduler()
        let env = try Env(scheduler: scheduler)
        let lonely = try env.store.create(text: "Lonely")
        let unrelated = try env.store.create(text: "U [[Lonely2]]")
        env.model.selectNotes([lonely.id])

        try type(env, lonely.id, "Alone")
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: .milliseconds(1500))
        #expect(scheduler.pendingCount == 0)
        #expect(env.model.banner == nil)
        #expect(try text(env, unrelated.id) == "U [[Lonely2]]")
    }
}
