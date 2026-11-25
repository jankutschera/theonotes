// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import OSLog
import Testing
@testable import TheoNotes

/// A temporary library, an environment with an in-memory key cache and a hand-fed lifecycle, one
/// main window's list model and its privacy controller.
@MainActor
final class PrivacyFixture {
    static let password = "correct horse"
    static let secret = "zqxsecretbody"

    let root: URL
    let environment: AppEnvironment
    let lifecycle: ManualLifecycleSource
    let model: LibraryModel
    let controller: NotePrivacyController

    init() throws {
        let root = URL(fileURLWithPath: "/tmp/theo-privacy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let lifecycle = ManualLifecycleSource()
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: lifecycle)
        let model = LibraryModel(environment: environment)
        self.root = root
        self.lifecycle = lifecycle
        self.environment = environment
        self.model = model
        controller = NotePrivacyController(library: model)
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    var vault: NoteVault { environment.vault }
    var store: NoteStore { environment.store }

    @discardableResult
    func addNote(_ text: String = "# Plan\n\n\(secret)") throws -> String {
        let id = try store.create(text: text).id
        model.refresh()
        return id
    }

    func addAttachment(_ data: Data, named name: String, to id: String) throws {
        _ = try AttachmentStore(paths: environment.paths, database: environment.database).add(data: data, filename: name, to: id)
    }

    func select(_ ids: [String]) {
        model.refresh()
        model.selectNotes(Set(ids))
    }

    func makePassword() async throws {
        try await vault.createPassword(Self.password)
    }

    func note(_ id: String) throws -> Note { try #require(try store.note(id: id)) }

    func attachmentFiles(_ id: String) -> [String] {
        let dir = environment.paths.attachments.appendingPathComponent(id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func makeEditor(page: FakeEditorPage = FakeEditorPage()) -> (EditorBridgeController, FakeEditorPage) {
        let editor = EditorBridgeController(
            environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        _ = editor.handle(.ready(version: EditorBridge.version))
        return (editor, page)
    }
}

@MainActor
@Suite struct NotePrivacyControllerTests {
    // MARK: Create the Note Password

    @Test func lockingWithoutAPasswordAsksForOneWithAConfirmation() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        let id = try fx.addNote()
        let titleBefore = try fx.note(id).title
        fx.select([id])

        await fx.controller.lockSelectedNotes()

        let sheet = try #require(fx.controller.sheet)
        #expect(sheet.kind == .create)
        #expect(sheet.warning?.contains("cannot be recovered") == true)
        #expect(fx.vault.isAuthenticating)
        #expect(!sheet.canSubmit)
        sheet.password = "one"
        sheet.confirmation = "two"
        #expect(!sheet.canSubmit)
        #expect(sheet.mismatchMessage != nil)
        sheet.confirmation = "one"
        #expect(sheet.canSubmit)
        #expect(sheet.mismatchMessage == nil)

        await sheet.submit()

        #expect(fx.controller.sheet == nil)
        #expect(!fx.vault.isAuthenticating)
        #expect(fx.vault.hasPassword && fx.vault.isUnlocked)
        let stored = try fx.note(id)
        #expect(stored.isLocked)
        #expect(stored.title == titleBefore)
        #expect(stored.text.isEmpty)
        fx.model.refresh()
        let row = try #require(fx.model.items.first { $0.id == id })
        #expect(row.isLocked && row.subtitle.isEmpty)
    }

    @Test func theCreateSheetWarnsAndNamesItsFields() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        let id = try fx.addNote()
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        let sheet = try #require(fx.controller.sheet)
        let strings = sheet.visibleStrings.joined(separator: "\n")
        #expect(strings.contains("cannot be recovered"))
        #expect(strings.contains("Confirm Password"))
        #expect(!strings.contains(PrivacyFixture.secret))
    }

    @Test func cancellingTheCreateSheetChangesNothing() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        let id = try fx.addNote()
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        let sheet = try #require(fx.controller.sheet)
        sheet.password = "typed"
        sheet.confirmation = "typed"

        fx.controller.dismissSheet()

        #expect(fx.controller.sheet == nil)
        #expect(sheet.password.isEmpty && sheet.confirmation.isEmpty)
        #expect(!fx.vault.isAuthenticating)
        #expect(!fx.vault.hasPassword)
        #expect(try !fx.note(id).isLocked)
    }

    // MARK: Unlock to lock

    @Test func lockingWithALockedVaultAsksForThePasswordAndKeepsTheSheetOnAWrongOne() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        fx.vault.relock()
        let id = try fx.addNote()
        fx.select([id])

        await fx.controller.lockSelectedNotes()

        let sheet = try #require(fx.controller.sheet)
        #expect(sheet.kind == .unlock(.lockNotes))
        sheet.password = "wrong"
        await sheet.submit()
        #expect(fx.controller.sheet === sheet)
        #expect(sheet.errorMessage == LockedNoteModel.wrongPasswordMessage)
        #expect(sheet.password.isEmpty)
        #expect(!fx.vault.isUnlocked)
        #expect(try !fx.note(id).isLocked)

        sheet.password = PrivacyFixture.password
        await sheet.submit()
        #expect(fx.controller.sheet == nil)
        #expect(try fx.note(id).isLocked)
        #expect(fx.vault.isUnlocked)
    }

    @Test func anUnlockedVaultLocksWithoutAnySheet() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let a = try fx.addNote("# A\n\none")
        let b = try fx.addNote("# B\n\ntwo")
        fx.select([a, b])

        await fx.controller.lockSelectedNotes()

        #expect(fx.controller.sheet == nil)
        #expect(try fx.note(a).isLocked && fx.note(b).isLocked)
        #expect(fx.model.banner == nil)
    }

    // MARK: Lock and remove the lock

    @Test func lockAndRemoveLockRoundTripRestoresTextAndAttachments() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let text = "# Trip\n\n\(PrivacyFixture.secret)\n![](photo.png)"
        let id = try fx.addNote(text)
        let photo = Data("zqxattachmentbytes".utf8) + Data(repeating: 7, count: 4000)
        try fx.addAttachment(photo, named: "photo.png", to: id)
        fx.select([id])

        await fx.controller.lockSelectedNotes()

        #expect(try fx.note(id).isLocked)
        #expect(try fx.note(id).text.isEmpty)
        #expect(!fx.attachmentFiles(id).contains("photo.png"))
        #expect(fx.attachmentFiles(id).allSatisfy { $0.hasSuffix(".bch") })

        await fx.controller.removeLockFromSelectedNote()

        #expect(fx.controller.sheet == nil)
        let restored = try fx.note(id)
        #expect(!restored.isLocked)
        #expect(restored.text == text)
        #expect(fx.attachmentFiles(id) == ["photo.png"])
        let file = fx.environment.paths.attachments.appendingPathComponent(id).appendingPathComponent("photo.png")
        #expect(try Data(contentsOf: file) == photo)
    }

    @Test func removingTheLockWithALockedVaultAsksForThePasswordFirst() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        fx.vault.relock()

        await fx.controller.removeLockFromSelectedNote()

        let sheet = try #require(fx.controller.sheet)
        #expect(sheet.kind == .unlock(.removeLock))
        #expect(try fx.note(id).isLocked)
        sheet.password = "nope"
        await sheet.submit()
        #expect(try fx.note(id).isLocked)
        #expect(sheet.errorMessage == LockedNoteModel.wrongPasswordMessage)
        sheet.password = PrivacyFixture.password
        await sheet.submit()
        #expect(fx.controller.sheet == nil)
        #expect(try !fx.note(id).isLocked)
        #expect(try fx.note(id).text.contains(PrivacyFixture.secret))
    }

    @Test func removeLockActsOnOneNoteOnly() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let a = try fx.addNote("# A\n\none")
        let b = try fx.addNote("# B\n\ntwo")
        fx.select([a, b])
        await fx.controller.lockSelectedNotes()
        fx.select([a, b])

        await fx.controller.removeLockFromSelectedNote()

        #expect(try fx.note(a).isLocked && fx.note(b).isLocked)
    }

    // MARK: The list

    @Test func aLockedNoteReachesTheListWithoutItsContent() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote("# Quarterly plan\n\n\(PrivacyFixture.secret)\n![](photo.png)")
        try fx.addAttachment(Data("zqxattachmentbytes".utf8), named: "photo.png", to: id)
        fx.select([id])

        await fx.controller.lockSelectedNotes()

        fx.model.refresh()
        let row = try #require(fx.model.items.first { $0.id == id })
        #expect(row.isLocked)
        #expect(row.title == "Quarterly plan")
        #expect(row.subtitle.isEmpty)
        #expect(NoteRow.previewText(for: row) == nil)
        #expect(NoteRow.thumbnailFilename(for: row) == nil)
        let label = NoteListAccessibility.label(for: row, date: row.modifiedAt, now: .now)
        #expect(label.hasPrefix("Quarterly plan, locked, modified "))
        #expect(NoteListAccessibility.value(for: row).isEmpty)
        let everything = "\(row)\n\(label)"
        #expect(!everything.contains(PrivacyFixture.secret))
        #expect(!everything.contains("photo.png"))
    }

    // MARK: Open notes

    @Test func lockingTheOpenNoteKeepsItsEditsAndReopensTheEditorKeyed() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let text = "# Open\n\n\(PrivacyFixture.secret)"
        let id = try fx.addNote(text)
        let (editor, page) = fx.makeEditor()
        try editor.open(noteId: id)
        let reply = editor.handle(.changes(
            noteId: id, txId: "t1", baseRevision: 0, revision: 1,
            changeSet: ChangeSet(sections: [.retain(text.utf16.count), .replace(deleteLength: 0, insert: " zqxtyped")])))
        #expect(reply == .acked(revision: 1))
        fx.select([id])

        await fx.controller.lockSelectedNotes()

        #expect(try fx.note(id).isLocked)
        let access = try fx.vault.requireAccess()
        #expect(try access.note(id: id)?.text == text + " zqxtyped")
        let session = try #require(editor.session)
        #expect(fx.environment.isKeyedSession(session))
        #expect(editor.paneContent == .editor(noteId: id))
        guard case .loadNote(_, let shown, _, let readOnly, _, _, _)? = page.loadNotes.last else {
            Issue.record("no loadNote after the lock")
            return
        }
        #expect(shown == text + " zqxtyped")
        #expect(!readOnly)

        await fx.controller.removeLockFromSelectedNote()

        #expect(try !fx.note(id).isLocked)
        #expect(try fx.note(id).text == text + " zqxtyped")
        let plain = try #require(editor.session)
        #expect(!fx.environment.isKeyedSession(plain))
        #expect(fx.environment.keyedSessionCount == 0)
        #expect(editor.paneContent == .editor(noteId: id))
    }

    // MARK: Trash and archive

    @Test func lockSkipsNotesInTheTrashAndReportsThem() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let a = try fx.addNote("# A\n\none")
        let b = try fx.addNote("# B\n\ntwo")
        try fx.store.trash([b])

        await fx.controller.lock(ids: [a, b])

        #expect(try fx.note(a).isLocked)
        #expect(try !fx.note(b).isLocked)
        #expect(fx.model.banner == .notesNotLocked(inTrash: 1, other: 0))
        #expect(fx.model.banner?.message == "1 note in the Trash was not locked")
    }

    @Test func removeLockRefusesANoteInTheTrash() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        try fx.store.trash([id])

        await #expect(throws: (any Error).self) { try await fx.environment.removeLock(noteId: id) }
        #expect(try fx.note(id).isLocked)
    }

    @Test func aNoteInTheArchiveCanBeLockedAndUnlocked() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        try fx.store.archive([id])

        let outcome = try await fx.environment.lockNotes(ids: [id])
        #expect(outcome.locked == [id])
        #expect(try fx.note(id).isLocked && fx.note(id).location == .archive)
        try await fx.environment.removeLock(noteId: id)
        #expect(try !fx.note(id).isLocked)
    }

    @Test func aLockedNoteCanBeTrashedRestoredArchivedAndDeleted() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        try fx.addAttachment(Data("zqxbytes".utf8), named: "a.png", to: id)
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        fx.select([id])

        fx.model.trashSelected()
        #expect(try fx.note(id).location == .trash && fx.note(id).isLocked)
        fx.model.selectScope(.trash)
        fx.model.selectNotes([id])
        fx.model.restoreSelected()
        #expect(try fx.note(id).location == .notes && fx.note(id).isLocked)
        fx.model.selectScope(.notes)
        fx.model.selectNotes([id])
        fx.model.archiveSelected()
        #expect(try fx.note(id).location == .archive && fx.note(id).isLocked)
        fx.model.selectScope(.archive)
        fx.model.selectNotes([id])
        fx.model.restoreSelected()
        fx.model.selectScope(.notes)
        fx.model.selectNotes([id])
        fx.model.trashSelected()
        fx.model.selectScope(.trash)
        fx.model.selectNotes([id])

        fx.model.deleteSelectedPermanently()

        #expect(try fx.store.note(id: id) == nil)
        #expect(fx.attachmentFiles(id).isEmpty)
    }

    // MARK: Change the password

    @Test func changePasswordNeedsTheCurrentOneAndKeepsLockedNotesReadable() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        fx.select([id])
        await fx.controller.lockSelectedNotes()

        fx.controller.changePassword()

        let sheet = try #require(fx.controller.sheet)
        #expect(sheet.kind == .change)
        #expect(sheet.warning?.contains("cannot be recovered") == true)
        #expect(!sheet.canSubmit)
        sheet.password = "wrong"
        sheet.newPassword = "fresh start"
        sheet.confirmation = "different"
        #expect(!sheet.canSubmit)
        sheet.confirmation = "fresh start"
        #expect(sheet.canSubmit)
        await sheet.submit()
        #expect(fx.controller.sheet === sheet)
        #expect(sheet.errorMessage == LockedNoteModel.wrongPasswordMessage)
        #expect(sheet.password.isEmpty && sheet.newPassword.isEmpty && sheet.confirmation.isEmpty)

        sheet.password = PrivacyFixture.password
        sheet.newPassword = "fresh start"
        sheet.confirmation = "fresh start"
        await sheet.submit()

        #expect(fx.controller.sheet == nil)
        #expect(!fx.vault.isAuthenticating)
        let privacy = NotePrivacy(store: fx.store)
        #expect(throws: CryptoError.self) { _ = try privacy.unlock(password: PrivacyFixture.password) }
        let access = try privacy.unlock(password: "fresh start")
        defer { access.revoke() }
        #expect(try access.note(id: id)?.text.contains(PrivacyFixture.secret) == true)
    }

    @Test func changePasswordIsNotOfferedWithoutAPassword() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        fx.controller.changePassword()
        #expect(fx.controller.sheet == nil)
    }

    // MARK: Lock now

    @Test func lockNowRelocksTheVaultAndTheOpenLockedNote() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        let id = try fx.addNote()
        let (editor, _) = fx.makeEditor()
        try editor.open(noteId: id)
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        #expect(editor.paneContent == .editor(noteId: id))

        await fx.controller.lockNow()

        #expect(!fx.vault.isUnlocked)
        #expect(editor.paneContent == .locked(noteId: id))
        #expect(fx.environment.keyedSessionCount == 0)
    }

    // MARK: Authentication scope

    @Test func sheetsHoldTheAuthenticationScopeSoALeavingAppDoesNotRelock() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        fx.controller.changePassword()
        #expect(fx.vault.isAuthenticating)

        fx.lifecycle.send(.appResigned)
        #expect(fx.vault.isUnlocked)

        fx.controller.dismissSheet()
        #expect(!fx.vault.isAuthenticating)
        fx.lifecycle.send(.appResigned)
        #expect(!fx.vault.isUnlocked)
    }

    @Test func aNewSheetReplacesTheOldOneWithoutLeakingTheScope() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        try await fx.makePassword()
        fx.controller.changePassword()
        fx.controller.changePassword()
        fx.controller.dismissSheet()
        #expect(!fx.vault.isAuthenticating)
    }

    // MARK: No password in a log

    @Test func passwordsNeverReachTheLog() async throws {
        let fx = try PrivacyFixture()
        defer { fx.destroy() }
        let started = Date()
        let id = try fx.addNote()
        fx.select([id])
        await fx.controller.lockSelectedNotes()
        let create = try #require(fx.controller.sheet)
        create.password = "zqxpasswordone"
        create.confirmation = "zqxpasswordone"
        await create.submit()
        fx.vault.relock()
        await fx.controller.removeLockFromSelectedNote()
        let unlock = try #require(fx.controller.sheet)
        unlock.password = "zqxwrongguess"
        await unlock.submit()
        fx.controller.dismissSheet()
        fx.controller.changePassword()
        let change = try #require(fx.controller.sheet)
        change.password = "zqxwrongcurrent"
        change.newPassword = "zqxpasswordtwo"
        change.confirmation = "zqxpasswordtwo"
        await change.submit()

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.truebrewbirdie.baerchen" }
        for entry in entries {
            #expect(!entry.composedMessage.contains("zqxpassword"), "password in a log line")
            #expect(!entry.composedMessage.contains("zqxwrong"), "password in a log line")
            #expect(!entry.composedMessage.contains(PrivacyFixture.secret))
        }
    }
}
