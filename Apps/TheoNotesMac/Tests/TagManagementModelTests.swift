// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct TagManagementModelTests {
    typealias Env = LibraryModelTests.Env

    private func insert(_ s: String, at offset: Int, in text: String) -> ChangeSet {
        ChangeSet(sections: [.retain(offset), .replace(deleteLength: 0, insert: s), .retain(text.utf16.count - offset)])
    }

    /// One undo group per user action, as AppKit opens per event.
    private func undoable(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    @Test func testRenameFlushesOpenSessionsAndTheyAdoptTheRewrite() throws {
        let env = try Env()
        let note = try env.store.create(text: "A #work")
        let session = try env.environment.session(for: note.id)
        _ = session.addTextListener { _, _ in }
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: insert("!", at: 1, in: "A #work"), origin: nil) == .acked(revision: 1))

        #expect(env.model.renameTag("work", to: "job", undoManager: nil))
        #expect(try env.store.note(id: note.id)?.text == "A! #job")
        env.environment.databaseDidChange()
        #expect(session.text == "A! #job")
        #expect(env.model.tagTree.map(\.path) == ["job"])
    }

    /// Final review M1: open sessions adopt a rename, a delete and their undo right away (before
    /// an editor could send an edit on the old revision), as for link rewrites.
    @Test func testOpenSessionsAdoptTagRewritesAndUndoAtOnce() throws {
        let env = try Env()
        let note = try env.store.create(text: "A #work")
        let session = try env.environment.session(for: note.id)
        _ = session.addTextListener { _, _ in }
        let undoManager = makeUndoManager()

        undoable(undoManager) { #expect(env.model.renameTag("work", to: "job", undoManager: undoManager)) }
        #expect(session.text == "A #job")
        undoManager.undo()
        #expect(session.text == "A #work")
        undoable(undoManager) { env.model.deleteTag("work", undoManager: undoManager) }
        #expect(session.text == "A")
        undoManager.undo()
        #expect(session.text == "A #work")
        #expect(session.committedStoreRevision == (try env.store.revision(id: note.id)))
    }

    @Test func testRenameUndoAndRedo() throws {
        let env = try Env()
        let note = try env.store.create(text: "A #work #work/sub")
        let undoManager = makeUndoManager()
        env.model.selectScope(.tag("work/sub"))

        undoable(undoManager) { #expect(env.model.renameTag("work", to: "job", undoManager: undoManager)) }
        #expect(try env.store.note(id: note.id)?.text == "A #job #job/sub")
        #expect(env.model.scope == .tag("job/sub"))
        #expect(undoManager.undoActionName == "Rename Tag")

        undoManager.undo()
        #expect(try env.store.note(id: note.id)?.text == "A #work #work/sub")
        #expect(env.model.scope == .tag("work/sub"))
        #expect(undoManager.canRedo)

        undoManager.redo()
        #expect(try env.store.note(id: note.id)?.text == "A #job #job/sub")
        #expect(env.model.scope == .tag("job/sub"))
        #expect(undoManager.canUndo)
    }

    @Test func testDeleteTagUndo() throws {
        let env = try Env()
        let note = try env.store.create(text: "Title\n#work\nbody")
        let undoManager = makeUndoManager()
        env.model.selectScope(.tag("work"))
        #expect(env.model.noteCount(forTag: "work") == 1)

        undoable(undoManager) { env.model.deleteTag("work", undoManager: undoManager) }
        #expect(try env.store.note(id: note.id)?.text == "Title\nbody")
        #expect(env.model.scope == .notes)
        #expect(env.model.tagTree.isEmpty)
        #expect(undoManager.undoActionName == "Delete Tag")

        undoManager.undo()
        #expect(try env.store.note(id: note.id)?.text == "Title\n#work\nbody")
        #expect(env.model.tagTree.map(\.path) == ["work"])
    }

    @Test func testSkippedNotesAreReported() throws {
        let env = try Env()
        _ = try env.store.create(text: "A #work")
        let locked = try env.store.create(text: "L #work")
        let readOnly = try env.store.create(text: "R #work")
        try env.environment.database.pool.write {
            try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id])
            try $0.execute(sql: "UPDATE note SET isReadOnly = 1 WHERE id = ?", arguments: [readOnly.id])
        }
        #expect(env.model.renameTag("work", to: "job", undoManager: nil))
        #expect(env.model.banner == .notesSkipped(locked: 1, readOnly: 1))
        #expect(LibraryBanner.notesSkipped(locked: 1, readOnly: 0).message == "1 locked note was not changed")
        #expect(LibraryBanner.notesSkipped(locked: 2, readOnly: 0).message == "2 locked notes were not changed")
        #expect(LibraryBanner.notesSkipped(locked: 0, readOnly: 1).message == "1 read-only note was not changed")
        #expect(LibraryBanner.notesSkipped(locked: 1, readOnly: 2).message == "1 locked and 2 read-only notes were not changed")
        #expect(LibraryBanner.notesSkipped(locked: 1, readOnly: 0).actionTitle == "Show Locked")
        #expect(LibraryBanner.notesSkipped(locked: 0, readOnly: 1).actionTitle == "OK")
    }

    @Test func testRefusedRenameShowsABanner() throws {
        let env = try Env()
        let note = try env.store.create(text: "A #work")
        let undoManager = makeUndoManager()
        undoable(undoManager) { #expect(!env.model.renameTag("work", to: "work/sub", undoManager: undoManager)) }
        #expect(try env.store.note(id: note.id)?.text == "A #work")
        #expect(env.model.banner == .tagOperationFailed(message: "“work” can’t be moved into its own subtag"))
        #expect(undoManager.undoActionName.isEmpty)  // the empty group stays, but holds no action

        env.model.dismissBanner()
        env.model.deleteTag("absent", undoManager: nil)
        #expect(env.model.banner == .tagOperationFailed(message: "Could not delete the tag “absent”"))
    }

    @Test func testNoUndoStepWhenNothingChanged() throws {
        let env = try Env()
        _ = try env.store.create(text: "A #work")
        let locked = try env.store.create(text: "L #secret")
        try env.environment.database.pool.write {
            try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id])
        }
        let undoManager = makeUndoManager()
        undoable(undoManager) { #expect(env.model.renameTag("work", to: "work", undoManager: undoManager)) }
        undoable(undoManager) { env.model.deleteTag("secret", undoManager: undoManager) }
        #expect(undoManager.undoActionName.isEmpty)  // empty groups stay, but hold no action
        undoable(undoManager) { #expect(env.model.renameTag("work", to: "job", undoManager: undoManager)) }
        #expect(undoManager.undoActionName == "Rename Tag")
    }

    @Test func testABannerDoesNotReplaceAPendingOne() throws {
        let env = try Env()
        _ = try env.store.create(text: "A #work")
        let locked = try env.store.create(text: "L #work")
        try env.environment.database.pool.write {
            try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id])
        }
        env.model.banner = .conflictCopiesCreated(noteIds: ["c"])
        #expect(env.model.renameTag("work", to: "job", undoManager: nil))
        #expect(env.model.banner == .conflictCopiesCreated(noteIds: ["c"]))
        env.model.dismissBanner()
        #expect(env.model.banner == .notesSkipped(locked: 1, readOnly: 0))
        env.model.dismissBanner()
        #expect(env.model.banner == nil)
    }

    @Test func testUndoRecordDoesNotRetainTheUndoManager() throws {
        let env = try Env()
        _ = try env.store.create(text: "A #work")
        weak var weakUndoManager: UndoManager?
        autoreleasepool {
            let undoManager = makeUndoManager()
            weakUndoManager = undoManager
            undoable(undoManager) { #expect(env.model.renameTag("work", to: "job", undoManager: undoManager)) }
            #expect(undoManager.canUndo)
        }
        #expect(weakUndoManager == nil)
    }

    @Test func testConfirmationTextsAndSaveRules() {
        #expect(TagConfirmation.nest(child: "my tag", newPath: "a/my tag", noteCount: 1).message
            == "#my tag# becomes #a/my tag# in 1 note.")
        #expect(TagConfirmation.nest(child: "b", newPath: "a/b", noteCount: 2).message == "#b becomes #a/b in 2 notes.")
        #expect(TagEditSheet.canSave(name: "job", originalPath: "work"))
        #expect(TagEditSheet.canSave(name: "tag1/work", originalPath: "work"))
        #expect(!TagEditSheet.canSave(name: "work/sub", originalPath: "work"))
        #expect(!TagEditSheet.canSave(name: " / ", originalPath: "work"))
    }

    @Test func testNestTagOntoTag() throws {
        let env = try Env()
        let note = try env.store.create(text: "A #b/c #a")
        #expect(LibraryModel.nestedPath("b/c", into: "a") == "a/c")
        #expect(LibraryModel.nestedPath("a", into: "a") == nil)
        #expect(LibraryModel.nestedPath("a", into: "a/x") == nil)
        #expect(LibraryModel.nestedPath("a/x", into: "a") == nil)  // already there

        #expect(env.model.nestTag("b/c", into: "a", undoManager: nil))
        #expect(try env.store.note(id: note.id)?.text == "A #a/c #a")
        #expect(!env.model.nestTag("a", into: "a/c", undoManager: nil))
    }

    @Test func testPinAndIcon() throws {
        let env = try Env()
        _ = try env.store.create(text: "A #zeta #alpha/sub")
        env.model.setTagPinned("zeta", pinned: true)
        #expect(env.model.tagTree.first { $0.path == "zeta" }?.isPinned == true)
        env.model.setTagIcon("alpha/sub", symbol: "leaf")
        let alpha = try #require(env.model.tagTree.first { $0.path == "alpha" })
        #expect(alpha.children.first?.iconName == "leaf")
        #expect(alpha.children.first?.symbolName == "leaf")
        #expect(LibraryModel.canPin(alpha) && !LibraryModel.canPin(alpha.children[0]))
    }

    @Test func testSymbolNameFallsBackToTagCon() throws {
        let env = try Env()
        _ = try env.store.create(text: "A #Arbeit #work #misc #tools")
        try env.store.setTagIcon("work", symbol: "no.such.symbol.xyz")
        try env.store.setTagIcon("tools", symbol: "hammer")
        env.model.refresh()
        let symbols = Dictionary(uniqueKeysWithValues: env.model.tagTree.map { ($0.path, $0.symbolName) })
        #expect(symbols == ["Arbeit": "briefcase", "work": "briefcase", "misc": "number", "tools": "hammer"])
    }
}
