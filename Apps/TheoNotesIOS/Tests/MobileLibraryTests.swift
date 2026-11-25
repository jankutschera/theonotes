// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Testing
import Foundation
@testable import BaerchenIOS

@Suite @MainActor
struct MobileLibraryTests {
    func temporaryLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    @Test func selectionCopyRevealsFreshNoteOutsideTheSourcesWorkspace() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let selected = "# Selected e\u{301} 🐻\n![](one.bin)\n#personal"
        let source = try library.store.create(text: "# Original\n#work\n" + selected + "\nafter")
        _ = try library.addAttachment(data: Data([1, 2]), filename: "one.bin", noteID: source.id)
        try library.store.archive([source.id])
        let before = try #require(try library.store.note(id: source.id))
        library.workspace = Workspace(path: "work")
        library.scope = .archive
        let id = try library.copySelectionToNewNote(selected, sourceID: source.id)
        #expect(library.selectedID == id && library.workspace == nil && library.scope == .notes)
        #expect(try library.store.note(id: id)?.text == selected)
        #expect(try library.store.note(id: source.id) == before)
        #expect(try Data(contentsOf: #require(try library.attachmentURL("one.bin", noteID: id))) == Data([1, 2]))
    }

    @Test func privateSelectionCopyStaysEncryptedAcrossRevocationAndReopen() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let selected = "# Selected\nprivate-selection-e\u{301}-🐻\n![](one.bin)"
        let source = try library.store.create(text: "# Original\nbefore\n" + selected + "\nafter")
        let bytes = Data("protected selection attachment".utf8)
        _ = try library.addAttachment(data: bytes, filename: "one.bin", noteID: source.id)
        try await library.unlockNotes(password: "selection-password", createPassword: true)
        try library.lockNote(source.id)
        let before = try #require(try library.store.note(id: source.id))
        let id = try library.copySelectionToNewNote(selected, sourceID: source.id)
        #expect(library.selectedID == id)
        #expect(try library.session(for: id).text == selected)
        #expect(try library.store.note(id: id)?.isLocked == true)
        #expect(try library.store.note(id: id)?.text.isEmpty == true)
        #expect(try library.store.note(id: source.id) == before)
        let preview = try #require(try library.attachmentURL("one.bin", noteID: id))
        #expect(try Data(contentsOf: preview) == bytes)
        try library.lockVault()
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(throws: NotePrivacyError.accessRevoked) { try library.copySelectionToNewNote(selected, sourceID: source.id) }
        try library.close()
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try reopened.readableNote(id) == nil)
        try await reopened.unlockNotes(password: "selection-password")
        #expect(try reopened.session(for: id).text == selected)
        #expect(try reopened.store.note(id: source.id) == before)
    }

    @Test func trashConfirmationKeepsWorkspaceSnapshotAndRechecksRestoredNotes() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let remove = try library.store.create(text: "# Remove\n#work/child")
        let restored = try library.store.create(text: "# Restored\n#work")
        let outside = try library.store.create(text: "# Personal\n#personal")
        let later = try library.store.create(text: "# Later\n#work")
        try library.store.trash([remove.id, restored.id, outside.id])
        library.workspace = Workspace(path: "work")
        library.query = "no visible results"
        let confirmed = try library.trashDeletionCandidates()
        #expect(Set(confirmed) == [remove.id, restored.id])
        // Changes while confirmation is open must not expand the destructive action.
        try library.store.restore([restored.id])
        try library.store.trash([later.id])
        library.selectedID = remove.id
        _ = try library.session(for: remove.id)
        let filename = try library.addAttachment(data: Data("fixture".utf8), filename: "attachment.txt", noteID: remove.id)
        let attachment = try #require(try library.attachmentURL(filename, noteID: remove.id))
        let preview = library.paths.root.appendingPathComponent("UnlockedPreviews/\(remove.id)")
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try Data("private fixture".utf8).write(to: preview.appendingPathComponent("preview.txt"))
        #expect(try library.deleteTrashedNotes(confirmed) == [remove.id])
        #expect(try library.store.note(id: remove.id) == nil)
        #expect(try library.store.note(id: restored.id)?.location == .notes)
        #expect(try library.store.note(id: outside.id)?.location == .trash)
        #expect(try library.store.note(id: later.id)?.location == .trash)
        #expect(library.selectedID == nil)
        #expect(!FileManager.default.fileExists(atPath: attachment.path))
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        try library.flush()
        #expect(try library.store.note(id: remove.id) == nil)
    }

    @Test func headingLinksUseCurrentUnicodeTitleAndRejectAmbiguousOrStaleTargets() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Reise/Plan 🐻\n## Café\nText\n## Café")
        library.selectedID = note.id
        let first = HeadingMenuRequest(noteId: note.id, menuId: "heading", line: 2, level: 2, folded: false,
                                       rect: CaretRect(x: 0, y: 0, width: 10, height: 10))
        #expect(try library.headingLink(for: first) == "[[Reise\\/Plan 🐻/Café]]")
        var duplicate = first; duplicate.line = 4
        #expect(try library.headingLink(for: duplicate) == nil)
        var stale = first; stale.line = 3
        #expect(try library.headingLink(for: stale) == nil)
        _ = try library.store.updateText(id: note.id, text: "# Renamed\n## Café", expectedRevision: note.revision)
        try library.refreshSessions()
        #expect(try library.headingLink(for: first) == "[[Renamed/Café]]")
        try library.store.trash([note.id])
        #expect(try library.headingLink(for: first) == nil)
        try library.store.restore([note.id]); library.selectedID = nil
        #expect(try library.headingLink(for: first) == nil)
    }

    @Test func defaultTemplateEligibilityMatchesPickerAndStaleChoicesUseOrdinaryCapture() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let source = "# Meeting {{title}}\n{{cursor}}Agenda\n#template/meeting"
        let valid = try library.store.create(text: source)
        let archived = try library.store.create(text: "# Archived\n#template")
        try library.store.archive([archived.id])
        let locked = try library.store.create(text: "# Protected\n#template")
        try await library.unlockNotes(password: "default-template-password", createPassword: true)
        try library.lockNote(locked.id)
        let untagged = try library.store.create(text: "# Former template\n#template")
        try library.store.removeTag("template", from: [untagged.id])
        let deleted = try library.store.create(text: "# Gone\n#template")
        try library.store.trash([deleted.id])
        _ = try library.store.emptyTrash(ids: [deleted.id])
        try library.settings.set(.startNoteTemplate, to: valid.id)
        #expect(try library.eligibleStartTemplateID() == valid.id)
        #expect(try library.store.note(id: valid.id)?.text == source)
        library.preferences.startContent = "heading"
        for id in [untagged.id, archived.id, locked.id, deleted.id, "missing-template"] {
            try library.settings.set(.startNoteTemplate, to: id)
            #expect(try library.eligibleStartTemplateID() == nil)
            #expect(try library.settings.value(.startNoteTemplate).isEmpty)
            let created = try library.createNote()
            #expect(try library.store.note(id: created)?.text == "# ")
            #expect(library.pendingCaret[created] == 2)
        }
        #expect(try library.store.note(id: valid.id)?.text == source)
    }

    @Test func templateRecentsStayUniqueBoundedAndSurviveReopening() throws {
        let library = try temporaryLibrary(), paths = library.paths
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var ids: [String] = []
        for index in 0..<7 {
            let template = try library.store.create(text: "# Template \(index)\n#template")
            ids.append(template.id)
            _ = try library.createFromTemplate(template.id, title: "", clipboard: nil)
        }
        _ = try library.createFromTemplate(ids[3], title: "", clipboard: nil)
        #expect(library.preferences.recentTemplateIDs.count == 5)
        #expect(library.preferences.recentTemplateIDs.first == ids[3])
        #expect(Set(library.preferences.recentTemplateIDs).count == 5)
        let expected = library.preferences.recentTemplateIDs
        try library.close()
        let reopened = try MobileLibrary(paths: paths)
        defer { try? reopened.close() }
        #expect(reopened.preferences.recentTemplateIDs == expected)
    }

    @Test func templatePickerUsesFuzzyUnicodeTitlesWithoutQuickOpenFallbackOrResultTruncation() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let unicode = try library.store.create(text: "# Straße Café Standup\n#template/meeting")
        let literal = try library.store.create(text: "# @Daily Checklist\n#template")
        for number in 0..<65 { _ = try library.store.create(text: "# Project \(number) retrospective\n#template") }
        let ordinary = try library.store.create(text: "# + unreachable ordinary note")
        let (choices, fallback) = try library.database.pool.read { db in
            let index = try QuickOpen.load(db: db, now: .now)
            return (MobileTemplateChoices(templates: try Templates.list(db: db), index: index),
                    index.results(query: "+ unreachable", limit: 67))
        }
        #expect(fallback.contains { $0.target == .note(id: ordinary.id) })
        #expect(choices.matching("STRASSE cfe").map(\.id) == [unicode.id])
        #expect(choices.matching("@dly").map(\.id) == [literal.id])
        #expect(choices.matching("prj rtr").count == 65)
        #expect(choices.matching("unreachable").isEmpty)
        #expect(choices.matching("   ").count == 67)
    }

    @Test func filteredTemplateSelectionKeepsRecentsDefaultsAndPlaceholderCreation() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let source = "# Straße Café {{title}}\n{{date}}\n{{clipboard}}\n{{cursor}}Agenda\n#template/meeting"
        let template = try library.store.create(text: source)
        let other = try library.store.create(text: "# Weekly retrospective\n#template")
        try library.settings.set(.startNoteTemplate, to: template.id)
        let choices = try library.database.pool.read { db in
            MobileTemplateChoices(templates: try Templates.list(db: db), index: try QuickOpen.load(db: db, now: .now))
        }
        let recents = ["missing", other.id, template.id, other.id]
        #expect(choices.recent(recents, query: "").map(\.id) == [other.id, template.id])
        #expect(choices.recent(recents, query: "strasse").map(\.id) == [template.id])
        #expect(choices.selection(current: nil, recentIDs: [], defaultID: template.id, query: "") == template.id)
        #expect(choices.selection(current: template.id, recentIDs: recents, defaultID: other.id, query: "") == template.id)
        #expect(choices.selection(current: "missing", recentIDs: recents, defaultID: template.id, query: "") == other.id)
        #expect(choices.selection(current: other.id, recentIDs: recents, defaultID: other.id, query: "strasse") == template.id)
        #expect(choices.selection(current: template.id, recentIDs: recents, defaultID: template.id, query: "no match anywhere") == nil)
        let selected = try #require(choices.selection(current: other.id, recentIDs: recents,
            defaultID: other.id, query: "strasse"))
        let createdID = try library.createFromTemplate(selected, title: "Wochenplan", clipboard: "Pasted 👩‍💻")
        let note = try #require(try library.store.note(id: createdID))
        #expect(note.text.contains("Straße Café Wochenplan"))
        #expect(note.text.contains("Pasted 👩‍💻"))
        #expect(!note.text.contains("{{date}}") && !note.text.contains("{{cursor}}"))
        #expect(!note.text.contains("#template"))
        #expect(library.pendingCaret[createdID] != nil)
        #expect(library.preferences.recentTemplateIDs.first == selected)
        #expect(try library.settings.value(.startNoteTemplate) == template.id)
        #expect(try library.store.note(id: selected)?.text == source)
    }

    @Test func syncCommitFlushesAcknowledgedEditsAndRefreshesTheOpenSession() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Original")
        let session = try library.session(for: note.id)
        let change = try JSONDecoder().decode(ChangeSet.self, from: Data("[[8,\"Local edit\"]]".utf8))
        _ = session.apply(txId: "sync-edit", baseRevision: session.revision, changeSet: change, origin: nil)
        let store = library.store
        let result = try library.commitSyncedChange {
            let committed = try #require(try store.note(id: note.id))
            #expect(committed.text == "Local edit")
            _ = try store.updateText(id: note.id, text: committed.text + " and remote change", expectedRevision: committed.revision)
            return .applied
        }
        #expect(result == .applied)
        #expect(session.text == "Local edit and remote change")
        #expect(!library.libraryOperationBusy)
    }

    @Test func taggedCaptureAndRestorePreserveExactMarkdown() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        library.scope = .tag("work/mobile")
        let id = try library.createNote()
        let original = try #require(try library.store.note(id: id))
        #expect(original.text == "\n\n#work/mobile")
        let session = try library.session(for: id)
        let text = "# iPhone 👩‍💻\nExact **Markdown**\n\n#work/mobile"
        let change = try JSONDecoder().decode(ChangeSet.self, from: JSONSerialization.data(withJSONObject: [[original.text.utf16.count] + text.components(separatedBy: "\n")]))
        #expect(session.apply(txId: "capture", baseRevision: session.revision, changeSet: change, origin: nil) == .acked(revision: session.revision))
        try library.move(id, to: .trash)
        #expect(try library.store.note(id: id)?.location == .trash)
        try library.move(id, to: .notes)
        #expect(try library.store.note(id: id)?.text == text)
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try reopened.store.note(id: id)?.text == text)
    }

    @Test func uncommittedAcknowledgedEditRecoversOnLaunch() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try library.createNote()
        let session = try library.session(for: id)
        let change = try JSONDecoder().decode(ChangeSet.self, from: Data("[[0,\"Recovered 🐻\"]]".utf8))
        _ = session.apply(txId: "unflushed", baseRevision: session.revision, changeSet: change, origin: nil)
        // No run-loop turn: the debounced SQLite commit has not run yet.
        #expect(try library.store.note(id: id)?.text == "")
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try reopened.store.note(id: id)?.text == "Recovered 🐻")
    }

    @Test func searchUsesSharedOperators() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        _ = try library.store.create(text: "# Travel\nPack camera #trip")
        _ = try library.store.create(text: "# Work\nShip iOS #work")
        library.query = "#trip camera"
        for _ in 0..<100 {
            if library.items.count == 1 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(library.items.map(\.title) == ["Travel"])
    }
    @Test func workspaceTemplatesAndHistoryKeepNavigationConsistent() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let template = try library.store.create(text: "# {{title}}\n{{cursor}}Agenda {{clipboard}}\n#template/meeting")
        let outside = try library.store.create(text: "# Outside")
        _ = try library.store.create(text: "# Work\n#work")
        try library.enterWorkspace("work")
        library.scope = .tag("work/team")
        let id = try library.createFromTemplate(template.id, title: "Planning", clipboard: "next week")
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("# Planning\nAgenda next week"))
        #expect(note.text.contains("#work/team"))
        #expect(!note.text.contains("#template"))
        #expect(library.pendingCaret[id] == 11)
        try library.reveal(outside.id)
        #expect(library.workspace == nil)
        try library.navigate(back: true)
        #expect(library.selectedID == id)
        try library.navigate(back: false)
        #expect(library.selectedID == outside.id)
    }

    @Test func tagRewriteUpdatesOpenSessionAndCanBeUndone() throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Idea\n#old/child")
        let session = try library.session(for: note.id)
        try library.renameTag("old", to: "new")
        #expect(session.text.contains("#new/child"))
        try library.undoTagEdit()
        #expect(session.text == note.text)
    }

    @Test func restorationAndEditorPositionDoNotModifyNote() throws {
        let library = try temporaryLibrary()
        let paths = library.paths
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# Position\ntext #work")
        try library.enterWorkspace("work")
        library.selectedID = note.id
        library.preferences.fontSize = 22
        try library.savePreferences()
        try library.store.saveEditorState(noteID: note.id, selection: SelectionRange(anchor: 4, head: 8), scrollTop: 120)
        #expect(try library.store.note(id: note.id) == note)
        try library.close()
        let reopened = try MobileLibrary(paths: paths)
        defer { try? reopened.close() }
        #expect(reopened.selectedID == note.id)
        #expect(reopened.workspace?.path == "work")
        #expect(reopened.preferences.fontSize == 22)
        let state = try reopened.store.editorState(noteID: note.id)
        #expect(state.selection == SelectionRange(anchor: 4, head: 8))
        #expect(state.scrollTop == 120)
    }

    @Test func privateNotesRequireAuthenticationAndClearPreviewFilesOnLock() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Visible title\nPrivate body")
        _ = try library.addAttachment(data: Data("private bytes".utf8), filename: "test.txt", noteID: note.id)
        try await library.unlockNotes(password: "mobile-password", createPassword: true)
        try library.lockNote(note.id)
        let session = try library.session(for: note.id)
        #expect(session.text == note.text)
        let preview = try #require(try library.attachmentURL("test.txt", noteID: note.id))
        #expect(try Data(contentsOf: preview) == Data("private bytes".utf8))
        try library.lockVault()
        #expect(library.privateAccess == nil)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(try library.readableNote(note.id) == nil)
        #expect(throws: StoreError.noteLocked(id: note.id)) { try library.session(for: note.id) }
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(reopened.hasNotePassword)
        #expect(try reopened.readableNote(note.id) == nil)
        try await reopened.unlockNotes(password: "mobile-password")
        #expect(try reopened.session(for: note.id).text == note.text)
        try reopened.removeNoteLock(note.id)
        #expect(try reopened.store.note(id: note.id)?.text == note.text)
    }

}
