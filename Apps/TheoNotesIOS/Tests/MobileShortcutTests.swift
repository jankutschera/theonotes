// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import BaerchenIOS

@Suite @MainActor
struct MobileShortcutTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-" + UUID().uuidString)))
    }

    @Test func createAppendAndColdReopenPreserveUnicodeWithoutImplicitTagsOrSeparators() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        library.workspace = Workspace(path: "work")
        library.scope = .tag("work")
        library.preferences.startContent = "heading"
        let service = MobileShortcutService(library: library)
        let source = "e\u{301} 👩‍💻\n  exact **Markdown**  "
        let plain = try service.create(text: source, title: nil)
        #expect(plain.text == source && plain.location == .notes)
        #expect(library.workspace == nil && library.scope == .notes && library.selectedID == plain.id)
        let titled = try service.create(text: "Body", title: "Title 🐻")
        #expect(titled.text == "# Title 🐻\nBody")
        let appended = try service.append(text: "suffix\n", to: plain.id)
        #expect(appended.text == source + "suffix\n")
        try library.close()
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try MobileShortcutService(library: reopened).note(id: plain.id).text == appended.text)
    }

    @Test func appendFlushesAcknowledgedTypingAndRefreshesTheExistingEditorSession() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Before")
        let session = try library.session(for: note.id)
        let change = try JSONDecoder().decode(ChangeSet.self, from: Data("[[6,\"Typed 🐻\"]]".utf8))
        let revision = session.revision
        #expect(session.apply(txId: "shortcut-pending", baseRevision: revision, changeSet: change, origin: nil) == .acked(revision: revision + 1))
        let appended = try MobileShortcutService(library: library).append(text: "+shortcut", to: note.id)
        #expect(appended.text == "Typed 🐻+shortcut")
        #expect(session.text == appended.text)
        #expect(try library.store.note(id: note.id)?.text == appended.text)
    }

    @Test func queriesUseSharedGrammarGlobalScopePrivacyFiltersAndBoundedResults() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let service = MobileShortcutService(library: library)
        let matching = try service.create(text: "# Café\nneedle\n#personal/ideas", title: nil)
        let archived = try service.create(text: "# Archive\nneedle\n#personal/ideas", title: nil)
        try library.store.archive([archived.id])
        let trashed = try service.create(text: "needle\n#personal/ideas", title: nil)
        try library.store.trash([trashed.id])
        let protected = try service.create(text: "# Locked needle\nprotected secret\n#personal/ideas", title: nil)
        try await library.unlockNotes(password: "shortcut-test-password", createPassword: true)
        try library.lockNote(protected.id)
        library.workspace = Workspace(path: "work")
        library.scope = .trash
        let results = try service.find(query: "#personal/ideas needle")
        #expect(Set(results.map(\.id)) == [matching.id, archived.id])
        #expect(try service.find(query: "protected secret").isEmpty)
        #expect(try service.find(query: "needle", limit: 1).count == 1)
        #expect(try service.find(query: "", limit: 0).isEmpty)
        for index in 0..<105 { _ = try library.store.create(text: "limit fixture \(index)") }
        #expect(try service.find(query: "limit fixture").count == 50)
        #expect(try service.find(query: "limit fixture", limit: 1000).count == 100)
        #expect(throws: MobileShortcutService.Failure.noteUnavailable) { try service.note(id: protected.id) }
        #expect(throws: MobileShortcutService.Failure.noteUnavailable) { try service.open(id: protected.id) }
        #expect(throws: MobileShortcutService.Failure.noteUnavailable) { try service.append(text: "leak", to: protected.id) }
        #expect(try library.privateAccess?.note(id: protected.id)?.text.contains("leak") == false)
        #expect(throws: MobileShortcutService.Failure.noteUnavailable) { try service.note(id: trashed.id) }
        #expect(throws: MobileShortcutService.Failure.readOnly) { try service.append(text: "no", to: archived.id) }
    }

    @Test func unavailableEntitiesReadOnlyClosedAndColdAppLockAreRejected() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let service = MobileShortcutService(library: library)
        let note = try service.create(text: "unchanged", title: nil)
        try library.database.pool.write { try $0.execute(sql: "UPDATE note SET isReadOnly = 1 WHERE id = ?", arguments: [note.id]) }
        #expect(throws: MobileShortcutService.Failure.readOnly) { try service.append(text: "no", to: note.id) }
        #expect(try service.note(id: note.id).text == "unchanged")
        try service.open(id: note.id)
        #expect(library.selectedID == note.id)
        #expect(throws: MobileShortcutService.Failure.noteUnavailable) { try service.note(id: "stale-entity") }
        try library.settings.set(.mobileAppLock, to: true)
        try library.close()
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try service.find(query: "") }
        let locked = try MobileLibrary(paths: library.paths)
        defer { try? locked.close() }
        let denied = MobileShortcutService(library: locked)
        #expect(locked.appLocked)
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try denied.create(text: "no", title: nil) }
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try denied.note(id: note.id) }
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try denied.append(text: "no", to: note.id) }
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try denied.open(id: note.id) }
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try denied.find(query: "") }
        #expect(try locked.store.allNotes().count == 1)
    }
}
