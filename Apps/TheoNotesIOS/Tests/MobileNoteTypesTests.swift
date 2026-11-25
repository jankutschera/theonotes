// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import UIKit
@testable import TheoNotesCore
@testable import BaerchenIOS

@MainActor @Suite(.serialized) struct MobileNoteTypesTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mobile-note-types-" + UUID().uuidString)))
    }

    @Test func sortingSkipsReadOnlyAndPreservesWorkspace() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "# First\n#work", now: Date(timeIntervalSince1970: 1))
        let readOnly = try library.store.create(text: "# Read only\n#work", now: Date(timeIntervalSince1970: 2))
        let outside = try library.store.create(text: "# Outside\n#home", now: Date(timeIntervalSince1970: 3))
        try library.store.setReadOnly(readOnly.id, readOnly: true)
        try library.enterWorkspace("work")
        let sort = try MobileSortInboxModel(library: library)
        #expect(sort.current?.id == first.id)
        #expect(sort.summary.skipped == 1)
        try await sort.apply(.type(.idea))
        #expect(try library.store.note(id: first.id)?.text.contains("#idea") == true)
        #expect(try library.store.note(id: outside.id)?.text == "# Outside\n#home")
        #expect(sort.summary.typed == 1 && sort.current == nil)
        try await sort.undo()
        #expect(try library.store.note(id: first.id)?.text == "# First\n#work")
        #expect(sort.current?.id == first.id)
    }

    @Test func sortingRechecksInboxBeforeActionAndArchivesOnlyRemaining() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let sort = try MobileSortInboxModel(library: library)
        _ = try library.store.setType(.log, noteIds: [first.id])
        try await sort.apply(.trash)
        #expect(try library.store.note(id: first.id)?.location == .notes)
        #expect(sort.current?.id == second.id)
        #expect(try await sort.archiveRest() == 1)
        #expect(try library.store.note(id: second.id)?.location == .archive)
        try await sort.undo()
        #expect(try library.store.note(id: second.id)?.location == .notes)
    }
    @Test func openEditorTypeChangeIsOneUndoableEdit() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let original = "# Idea\nA thought 👩‍💻"
        let note = try library.store.create(text: original)
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view = editor.webView
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(note.id)
        for _ in 0..<400 where !editor.ready || !editor.editable { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.ready && editor.editable)
        try await editor.setNoteType(.idea)
        for _ in 0..<200 where editor.session?.text != original + "\n\n#idea" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.session?.text == original + "\n\n#idea")
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',metaKey:true,bubbles:true,cancelable:true}))")
        for _ in 0..<200 where editor.session?.text != original { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.session?.text == original)
        try library.flush()
        #expect(try library.store.note(id: note.id)?.text == original)
    }

    @Test func undoNeverOverwritesAChangedNote() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Initial")
        let sort = try MobileSortInboxModel(library: library)
        try await sort.apply(.type(.log))
        let typed = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: "Edited after sorting\n#log", expectedRevision: typed.revision)
        try await sort.undo()
        #expect(try library.store.note(id: note.id)?.text == "Edited after sorting\n#log")
        #expect(sort.notice != nil)
    }

    @Test func sortRegistersAnAppUndoStep() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Undo me")
        let sort = try MobileSortInboxModel(library: library)
        let undo = UndoManager()
        try await sort.apply(.type(.reference))
        sort.registerUndo(undo)
        #expect(undo.canUndo)
        undo.undo()
        for _ in 0..<200 where (try library.store.note(id: note.id)?.text) != "Undo me" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try library.store.note(id: note.id)?.text == "Undo me")
        #expect(sort.current?.id == note.id)
    }

    @Test func sortingAndUndoDrainAnOpenEditorsQueuedEdit() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Initial")
        let sort = try MobileSortInboxModel(library: library)
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view = editor.webView
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(note.id)
        for _ in 0..<400 where !editor.ready || !editor.editable { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.ready && editor.editable)
        library.drainEditorForLibraryOperation = {
            let frozen = try await editor.prepareCaptureClose(note.id)
            return { editor.endCaptureClose(frozen) }
        }
        editor.command(.insertText, args: ["text": .string("queued edit ")])
        try await sort.apply(.type(.idea))
        let typed = try #require(try library.store.note(id: note.id))
        #expect(typed.text.contains("queued edit ") && typed.text.contains("#idea"))
        try await sort.undo()
        let restored = try #require(try library.store.note(id: note.id))
        #expect(restored.text.contains("queued edit ") && !restored.text.contains("#idea"))
    }

    @Test func invalidatingSortDropsPreviewsAndRejectsFurtherWrites() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "A private fixture")
        let sort = try MobileSortInboxModel(library: library)
        #expect(sort.current?.id == note.id)
        sort.invalidate()
        #expect(sort.current == nil && !sort.canUndo)
        await #expect(throws: CancellationError.self) { try await sort.apply(.trash) }
        #expect(try library.store.note(id: note.id)?.location == .notes)
    }

    @Test func systemUndoSkipsAnEditedNote() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Original")
        let sort = try MobileSortInboxModel(library: library)
        let manager = UndoManager()
        try await sort.apply(.type(.idea))
        sort.registerUndo(manager)
        let typed = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: "Changed\n#idea", expectedRevision: typed.revision)
        manager.undo()
        for _ in 0..<200 where sort.undoing { try await Task.sleep(for: .milliseconds(50)) }
        #expect(sort.notice != nil)
        #expect(try library.store.note(id: note.id)?.text == "Changed\n#idea")
        #expect(!manager.canUndo)
    }

    @Test func sortingDoesNotWriteDuringLibraryImport() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Keep during import")
        let sort = try MobileSortInboxModel(library: library)
        let input = library.paths.root.appendingPathComponent("fixture.md")
        try Data("# Imported".utf8).write(to: input)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let importing = Task { @MainActor in
            try await library.importNotes([input]) { done, _ in
                if done == 0 { continuation.yield(()); release.wait() }
            }
        }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        await #expect(throws: CancellationError.self) { try await sort.apply(.trash) }
        #expect(try library.store.note(id: note.id)?.location == .notes)
        release.signal()
        _ = try await importing.value
    }

    @Test func privacyInvalidationRemovesSortUndoActions() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        _ = try library.store.create(text: "Private sort fixture")
        let sort = try MobileSortInboxModel(library: library)
        let manager = UndoManager()
        manager.groupsByEvent = false
        try await sort.apply(.type(.idea))
        manager.beginUndoGrouping()
        sort.registerUndo(manager)
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        sort.invalidate()
        #expect(!manager.canUndo)
        #expect(!sort.canUndo)
        #expect(sort.current == nil)
    }

    @Test func unavailableEditorDrainNeverMutatesSortTarget() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Pending edit")
        let sort = try MobileSortInboxModel(library: library)
        library.drainEditorForLibraryOperation = { throw MobileEditorDrainError.unavailable }
        await #expect(throws: MobileEditorDrainError.self) { try await sort.apply(.trash) }
        #expect(try library.store.note(id: note.id)?.location == .notes)
        #expect(sort.current?.id == note.id)
    }

    @Test func sortInboxRecoversOrphanAndDoesNotFailAfterMutation() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let orphan = try library.store.create(text: "Original")
        let session = try library.session(for: orphan.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        let orphanID = orphan.id
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [orphanID]) }
        let target = try library.store.create(text: "Sort me")
        let sort = try MobileSortInboxModel(library: library)
        #expect(sort.current?.id == target.id)
        try await sort.apply(.archive)
        #expect(try library.store.note(id: target.id)?.location == .archive)
        #expect(try library.store.allNotes().contains { $0.text == "Unsaved" })
        #expect(library.hasCachedSession(for: orphanID))
    }

    @Test func archiveConfirmationRefusesAChangedCount() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First")
        let second = try library.store.create(text: "Second")
        let sort = try MobileSortInboxModel(library: library)
        #expect(try sort.eligibleRemaining() == 2)
        _ = try library.store.setType(.idea, noteIds: [first.id])
        await #expect(throws: MobileSortInboxModel.Failure.self) { _ = try await sort.archiveRest(expectedCount: 2) }
        #expect(try library.store.note(id: first.id)?.location == .notes)
        #expect(try library.store.note(id: second.id)?.location == .notes)
    }

    @Test func undoDoesNotReverseASeparateLaterArchive() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First")
        let second = try library.store.create(text: "Second")
        let sort = try MobileSortInboxModel(library: library)
        #expect(try await sort.archiveRest() == 2)
        try library.store.restore([first.id])
        try library.store.archive([first.id])
        try await sort.undo()
        #expect(try library.store.note(id: first.id)?.location == .archive)
        #expect(try library.store.note(id: second.id)?.location == .notes)
        #expect(sort.notice != nil)
    }

    @Test func privacyLockDuringDrainCancelsThePendingSort() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Pending sort")
        let sort = try MobileSortInboxModel(library: library)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        defer { release.finish(); signal.finish() }
        library.drainEditorForLibraryOperation = {
            signal.yield(())
            var iterator = released.makeAsyncIterator()
            await iterator.next()
            return nil
        }
        let action = Task { try await sort.apply(.trash) }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        sort.invalidate()
        release.yield(())
        await #expect(throws: CancellationError.self) { try await action.value }
        #expect(try library.store.note(id: note.id)?.location == .notes)
    }

    @Test func appUndoKeepsIndependentStepsAcrossSortingSessions() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let manager = UndoManager(); manager.groupsByEvent = false
        let firstSession = try MobileSortInboxModel(library: library)
        try await firstSession.apply(.type(.idea))
        manager.beginUndoGrouping(); firstSession.registerUndo(manager); manager.endUndoGrouping()
        firstSession.discardPendingQueue()
        #expect(firstSession.current == nil)
        let secondSession = try MobileSortInboxModel(library: library)
        try await secondSession.apply(.type(.log))
        manager.beginUndoGrouping(); secondSession.registerUndo(manager); manager.endUndoGrouping()
        manager.undo()
        for _ in 0..<200 where (try library.store.note(id: second.id)?.text) != "Second" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: second.id)?.text == "Second")
        #expect(try library.store.note(id: first.id)?.text.contains("#idea") == true)
        manager.undo()
        for _ in 0..<200 where (try library.store.note(id: first.id)?.text) != "First" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: first.id)?.text == "First")
    }

    @Test func unfinishedCodeBlockReportsWhyTypeWasSkipped() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Code\n```swift\nlet x = 1")
        let sort = try MobileSortInboxModel(library: library)
        try await sort.apply(.type(.idea))
        #expect(try library.store.note(id: note.id)?.text == "# Code\n```swift\nlet x = 1")
        #expect(sort.notice?.contains("unfinished code block") == true)
    }

    @Test func noteTypeScopesSurviveRestoration() throws {
        let scopes: [SidebarScope] = [.inbox, .type(.idea), .type(.log), .type(.reference)]
        for scope in scopes {
            let stored = try JSONEncoder().encode(MobileRestoration(scope: scope))
            #expect(try JSONDecoder().decode(MobileRestoration.self, from: stored).scopeValue == scope)
        }
    }

    @Test func movingSelectedNoteClearsEditorSelection() async throws {
        for action in [MobileSortInboxModel.Action.archive, .trash] {
            let library = try library()
            defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
            let note = try library.store.create(text: "Selected")
            library.selectedID = note.id
            let sort = try MobileSortInboxModel(library: library)
            try await sort.apply(action)
            #expect(library.selectedID == nil)
            library.selectedID = note.id
            try await sort.undo()
            #expect(library.selectedID == nil)
        }
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Selected for archive rest")
        library.selectedID = note.id
        let sort = try MobileSortInboxModel(library: library)
        _ = try await sort.archiveRest(expectedCount: 1)
        #expect(library.selectedID == nil)
    }

    @Test func rapidSystemUndoDoesNotLoseSortSteps() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let manager = UndoManager(); manager.groupsByEvent = false
        let sort = try MobileSortInboxModel(library: library)
        try await sort.apply(.type(.idea))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        try await sort.apply(.type(.log))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        manager.undo()
        manager.undo()
        for _ in 0..<200 where (try library.store.note(id: first.id)?.text) != "First" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: first.id)?.text == "First")
        #expect(try library.store.note(id: second.id)?.text == "Second")
    }

    @Test func rapidUndoAcrossSessionsKeepsTheOrder() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let manager = UndoManager(); manager.groupsByEvent = false
        let a = try MobileSortInboxModel(library: library)
        try await a.apply(.type(.idea))
        manager.beginUndoGrouping(); a.registerUndo(manager); manager.endUndoGrouping()
        let b = try MobileSortInboxModel(library: library)
        try await b.apply(.type(.log))
        manager.beginUndoGrouping(); b.registerUndo(manager); manager.endUndoGrouping()
        manager.undo(); manager.undo()
        for _ in 0..<200 where (try library.store.note(id: first.id)?.text) != "First" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: first.id)?.text == "First")
        #expect(try library.store.note(id: second.id)?.text == "Second")
    }

    @Test func staleUndoDoesNotBlockEarlierSteps() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let manager = UndoManager(); manager.groupsByEvent = false
        let sort = try MobileSortInboxModel(library: library)
        try await sort.apply(.type(.idea))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        try await sort.apply(.type(.log))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        let typed = try #require(try library.store.note(id: second.id))
        _ = try library.store.updateText(id: second.id, text: "Changed #log", expectedRevision: typed.revision)
        manager.undo(); manager.undo()
        for _ in 0..<200 where sort.undoing { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: first.id)?.text == "First")
        #expect(try library.store.note(id: second.id)?.text == "Changed #log")
        #expect(sort.notice != nil)
    }

    @Test func failedRapidUndoPreservesBothStepsInOrder() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let manager = UndoManager(); manager.groupsByEvent = false
        let sort = try MobileSortInboxModel(library: library)
        try await sort.apply(.type(.idea))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        try await sort.apply(.type(.log))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        library.drainEditorForLibraryOperation = { throw MobileEditorDrainError.unavailable }
        manager.undo(); manager.undo()
        for _ in 0..<200 where sort.undoing { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.errorMessage != nil)
        library.drainEditorForLibraryOperation = nil
        manager.undo(); manager.undo()
        for _ in 0..<200 where (try library.store.note(id: first.id)?.text) != "First" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: first.id)?.text == "First")
        #expect(try library.store.note(id: second.id)?.text == "Second")
    }

    @Test func failedRapidUndoRestoresSeparateSystemGroups() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = try library.store.create(text: "First", now: Date(timeIntervalSince1970: 1))
        let second = try library.store.create(text: "Second", now: Date(timeIntervalSince1970: 2))
        let manager = UndoManager(); manager.groupsByEvent = false
        let sort = try MobileSortInboxModel(library: library)
        try await sort.apply(.type(.idea))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        try await sort.apply(.type(.log))
        manager.beginUndoGrouping(); sort.registerUndo(manager); manager.endUndoGrouping()
        manager.groupsByEvent = true
        library.drainEditorForLibraryOperation = { throw MobileEditorDrainError.unavailable }
        manager.undo(); manager.undo()
        for _ in 0..<200 where sort.undoing { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.errorMessage != nil)
        #expect(manager.groupsByEvent)
        library.drainEditorForLibraryOperation = nil
        manager.undo()
        for _ in 0..<200 where sort.undoing { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: second.id)?.text == "Second")
        #expect(try library.store.note(id: first.id)?.text.contains("#idea") == true)
        #expect(manager.canUndo)
        manager.undo()
        for _ in 0..<200 where sort.undoing { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.store.note(id: first.id)?.text == "First")
    }

    @Test func lockedNoteCannotBeRetypedEvenWhileItsVaultIsOpen() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Protected\nKeep this")
        try await library.unlockNotes(password: "synthetic test password", createPassword: true)
        try library.lockNote(note.id)
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view = editor.webView
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(note.id)
        for _ in 0..<400 where !editor.ready { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.ready)
        await #expect(throws: MobileEditor.NoteTypeChangeError.self) { try await editor.setNoteType(.idea) }
        #expect(try library.privateAccess?.note(id: note.id)?.text == "# Protected\nKeep this")
    }

}
