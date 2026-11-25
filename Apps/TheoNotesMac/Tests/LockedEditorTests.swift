// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// A temporary library with one locked note (body, one attachment), a vault with an in-memory key
/// cache and a manual lifecycle source. The vault starts unlocked; tests call `relock()`.
@MainActor
struct LockedFixture {
    static let password = "correct horse"
    static let title = "Visible title"
    static let secret = "zqxsecretbody"
    static let attachmentMarker = "zqxattachmentbytes"

    let root: URL
    let environment: AppEnvironment
    let cache: FakeVaultKeyCache
    let lifecycle: ManualLifecycleSource
    let noteId: String
    let attachment: Data

    var text: String { "# \(Self.title)\n\n\(Self.secret)\n![](photo.png)" }

    /// `root` is reused to start a second environment on the same library (a relaunch).
    init(root: URL? = nil, cache: FakeVaultKeyCache = FakeVaultKeyCache(), relaunchingNote: String? = nil) async throws {
        let root = root ?? URL(fileURLWithPath: "/tmp/theo-locked-\(UUID().uuidString.prefix(8))", isDirectory: true)
        self.root = root
        self.cache = cache
        lifecycle = ManualLifecycleSource()
        environment = try AppEnvironment(paths: AppPaths(root: root), vaultCache: cache, vaultLifecycle: lifecycle)
        attachment = Data((Self.attachmentMarker + String(repeating: "x", count: 5000)).utf8)
        if let relaunchingNote {
            noteId = relaunchingNote
            return
        }
        let note = try environment.store.create(text: "# \(Self.title)\n\n\(Self.secret)\n![](photo.png)")
        noteId = note.id
        _ = try AttachmentStore(paths: environment.paths, database: environment.database)
            .add(data: attachment, filename: "photo.png", to: note.id)
        try await environment.vault.createPassword(Self.password)
        try environment.vault.requireAccess().lock(noteId: note.id)
    }

    var vault: NoteVault { environment.vault }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    func makeController(page: FakeEditorPage = FakeEditorPage()) -> (EditorBridgeController, FakeEditorPage) {
        let controller = EditorBridgeController(
            environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        _ = controller.handle(.ready(version: EditorBridge.version))
        return (controller, page)
    }

    /// An editor transaction appending `text` to the document as the editor last saw it.
    func append(_ text: String, to controller: EditorBridgeController, from document: String, txId: String, base: Int) -> ChangesReply? {
        controller.handle(.changes(
            noteId: noteId, txId: txId, baseRevision: base, revision: base + 1,
            changeSet: ChangeSet(sections: [.retain(document.utf16.count), .replace(deleteLength: 0, insert: text)])))
    }

    /// What the library holds on disk right now, decrypted with the password (a fresh unlock).
    func storedText() async throws -> String? {
        let access = try NotePrivacy(store: environment.store).unlock(password: Self.password)
        defer { access.revoke() }
        return try access.note(id: noteId)?.text
    }

    func allFiles(under folder: URL) -> [URL] {
        var found: [URL] = []
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { found.append(url) }
        }
        return found
    }

    var journalFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: environment.paths.journal, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(noteId) }
    }
}

@MainActor
@Suite struct LockedEditorTests {
    // MARK: Placeholder

    @Test func theContentFollowsTheNoteAndTheVault() throws {
        var note = Note(id: "n", text: "", title: "T", titleKey: "t", createdAt: .now, modifiedAt: .now, location: .notes)
        #expect(EditorPaneContent.for(note: nil, vaultUnlocked: true) == .empty)
        #expect(EditorPaneContent.for(note: note, vaultUnlocked: false) == .editor(noteId: "n"))
        note.isLocked = true
        #expect(EditorPaneContent.for(note: note, vaultUnlocked: false) == .locked(noteId: "n"))
        #expect(EditorPaneContent.for(note: note, vaultUnlocked: true) == .editor(noteId: "n"))
    }

    @Test func aLockedNoteShowsThePlaceholderAndNoPlaintextReachesTheEditor() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        fixture.vault.relock()
        let (controller, page) = fixture.makeController()

        try controller.open(noteId: fixture.noteId)

        #expect(controller.paneContent == .locked(noteId: fixture.noteId))
        #expect(controller.session == nil)
        #expect(controller.status.showsNote == false)
        #expect(page.loadNotes.isEmpty)
        #expect(!"\(page.delivered)".contains(LockedFixture.secret))
        #expect(fixture.environment.existingSession(for: fixture.noteId) == nil)
    }

    @Test func theLockViewModelHoldsNoPlaintext() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        try fixture.vault.setUsesBiometricUnlock(false)
        fixture.vault.relock()
        let model = LockedNoteModel(vault: fixture.vault, noteId: fixture.noteId, title: LockedFixture.title)

        let strings = model.visibleStrings.joined(separator: "\n")
        #expect(strings.contains(LockedNoteModel.message))
        #expect(strings.contains(LockedFixture.title))
        #expect(!strings.contains(LockedFixture.secret))
        #expect(!strings.contains("photo.png"))
        #expect(!model.canUseTouchID)
        #expect(!model.visibleStrings.contains(LockedNoteModel.touchIDTitle))
    }

    @Test func touchIDIsOfferedOnlyWhenTheVaultCanUseIt() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        try fixture.vault.setUsesBiometricUnlock(true)
        try await fixture.vault.unlock(password: LockedFixture.password)
        fixture.vault.relock()
        let model = LockedNoteModel(vault: fixture.vault, noteId: fixture.noteId, title: LockedFixture.title)
        #expect(fixture.vault.canUnlockWithBiometrics)
        #expect(model.canUseTouchID)
        #expect(model.visibleStrings.contains(LockedNoteModel.touchIDTitle))
    }

    @Test func theViewShowsNoPlaintextInItsAccessibilityTree() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        fixture.vault.relock()
        let model = LockedNoteModel(vault: fixture.vault, noteId: fixture.noteId, title: LockedFixture.title)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LockedNoteView(model: model))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        // An offscreen hosted window may expose no SwiftUI elements (see AccessibilityAuditTests);
        // what it does expose must hold no body text or attachment name.
        var seen: [String] = []
        for element in AccessibilityAudit.elements(in: window) {
            guard let node = element as? NSObject else { continue }
            // SwiftUI nodes do not answer every accessibility key; reading one they lack throws.
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp", "accessibilityPlaceholderValue"]
            where node.responds(to: NSSelectorFromString(key)) {
                if let value = node.value(forKey: key) { seen.append("\(value)") }
            }
        }
        let tree = seen.joined(separator: "\n")
        #expect(!tree.contains(LockedFixture.secret))
        #expect(!tree.contains("photo.png"))
    }

    @Test func theAuthenticationScopeIsHeldWhileTheLockViewIsUp() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        fixture.vault.relock()
        let model = LockedNoteModel(vault: fixture.vault, noteId: fixture.noteId, title: LockedFixture.title)
        #expect(!fixture.vault.isAuthenticating)
        model.beginAuthenticationScope()
        model.beginAuthenticationScope()
        #expect(fixture.vault.isAuthenticating)
        model.endAuthenticationScope()
        #expect(!fixture.vault.isAuthenticating)
        model.endAuthenticationScope()
        #expect(!fixture.vault.isAuthenticating)
    }

    @Test func aWrongPasswordKeepsTheNoteLockedAndSaysSo() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        fixture.vault.relock()
        let model = LockedNoteModel(vault: fixture.vault, noteId: fixture.noteId, title: LockedFixture.title)
        model.password = "wrong"
        await model.unlock()
        #expect(!fixture.vault.isUnlocked)
        #expect(model.errorMessage == LockedNoteModel.wrongPasswordMessage)
        #expect(model.password.isEmpty)
        #expect(model.visibleStrings.contains(LockedNoteModel.wrongPasswordMessage))
    }

    // MARK: Unlock and edit

    @Test func passwordUnlockOpensTheEditorWithThePlaintext() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        fixture.vault.relock()
        let (controller, page) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        #expect(controller.paneContent == .locked(noteId: fixture.noteId))

        let model = LockedNoteModel(vault: fixture.vault, noteId: fixture.noteId, title: LockedFixture.title)
        model.password = LockedFixture.password
        await model.unlock()

        #expect(fixture.vault.isUnlocked)
        #expect(model.password.isEmpty)
        #expect(controller.paneContent == .editor(noteId: fixture.noteId))
        #expect(page.loadNotes.last == .loadNote(
            noteId: fixture.noteId, text: fixture.text, revision: 0, readOnly: false))
    }

    @Test func editsAreSealedInTheJournalAndCommittedEncrypted() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, _) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)

        let reply = fixture.append(" zqxedit", to: controller, from: fixture.text, txId: "t1", base: 0)
        #expect(reply == .acked(revision: 1))
        for file in fixture.journalFiles where file.pathExtension == "jsonl" || file.pathExtension == "base" {
            #expect(try Data(contentsOf: file).range(of: Data("zqxedit".utf8)) == nil)
        }
        controller.flush()

        let stored = try #require(try fixture.environment.store.note(id: fixture.noteId))
        #expect(stored.isLocked && stored.text.isEmpty)
        #expect(try await fixture.storedText() == fixture.text + " zqxedit")
    }

    @Test func editRelockReopenShowsTheEdit() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        _ = fixture.append(" zqxedit", to: controller, from: fixture.text, txId: "t1", base: 0)

        fixture.vault.relock()
        #expect(controller.paneContent == .locked(noteId: fixture.noteId))
        #expect(page.delivered.last == EditorBridgeController.placeholderLoad)

        try await fixture.vault.unlock(password: LockedFixture.password)
        #expect(controller.paneContent == .editor(noteId: fixture.noteId))
        #expect(page.loadNotes.last == .loadNote(
            noteId: fixture.noteId, text: fixture.text + " zqxedit", revision: 0, readOnly: false))
    }

    @Test func relockFlushesAckedEditsBeforeDroppingTheKey() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, _) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        var document = fixture.text
        for (index, word) in [" one", " two"].enumerated() {
            #expect(fixture.append(word, to: controller, from: document, txId: "t\(index)", base: index) == .acked(revision: index + 1))
            document += word
        }
        let key = try fixture.vault.requireAccess()

        fixture.vault.relock()

        #expect(fixture.environment.existingSession(for: fixture.noteId) == nil)
        #expect(throws: NotePrivacyError.accessRevoked) { try key.note(id: fixture.noteId) }
        #expect(try await fixture.storedText() == document)
        for file in fixture.journalFiles where file.pathExtension == "jsonl" {
            #expect(try Data(contentsOf: file).isEmpty)
        }
    }

    @Test func everyWindowShowsThePlaceholderAfterARelock() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (first, firstPage) = fixture.makeController()
        let (second, secondPage) = fixture.makeController()
        try first.open(noteId: fixture.noteId)
        try second.open(noteId: fixture.noteId)
        #expect(first.session === second.session)

        fixture.vault.relock()

        for (controller, page) in [(first, firstPage), (second, secondPage)] {
            #expect(controller.paneContent == .locked(noteId: fixture.noteId))
            #expect(controller.session == nil)
            #expect(page.delivered.last == EditorBridgeController.placeholderLoad)
        }
        try await fixture.vault.unlock(password: LockedFixture.password)
        #expect(first.paneContent == .editor(noteId: fixture.noteId))
        #expect(second.paneContent == .editor(noteId: fixture.noteId))
        #expect(first.session === second.session)
    }

    @Test func aDeviceLockClosesTheSessionsToo() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, _) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        fixture.lifecycle.send(.deviceLocked)
        #expect(controller.paneContent == .locked(noteId: fixture.noteId))
        #expect(fixture.environment.existingSession(for: fixture.noteId) == nil)
    }

    // MARK: Recovery

    @Test func launchRecoveryKeepsTheSealedJournalAndTheReplayFollowsTheUnlock() async throws {
        let cache = FakeVaultKeyCache()
        let first = try await LockedFixture(cache: cache)
        defer { first.destroy() }
        let noteId = first.noteId
        let session = try first.environment.session(for: noteId)
        let applied = session.apply(
            txId: "t1", baseRevision: 0,
            changeSet: ChangeSet(sections: [.retain(first.text.utf16.count), .replace(deleteLength: 0, insert: " zqxkilled")]),
            origin: nil)
        #expect(applied == .acked(revision: 1))
        // The process dies here: nothing was flushed, and its commit must not run.
        try first.environment.vault.requireAccess().revoke()
        let journal = first.journalFiles.filter { $0.pathExtension == "jsonl" }
        #expect(journal.count == 1)
        #expect(try Data(contentsOf: journal[0]).count > 0)

        let second = try await LockedFixture(root: first.root, cache: cache, relaunchingNote: noteId)

        // Still sealed and untouched: the launch pass did not replay (no key) and did not move it aside.
        #expect(!second.vault.isUnlocked)
        let sealed = try Data(contentsOf: journal[0])
        #expect(!sealed.isEmpty)
        #expect(sealed.range(of: Data("zqxkilled".utf8)) == nil)
        #expect(second.journalFiles.allSatisfy { !$0.lastPathComponent.contains("unreplayed") })
        #expect(try second.environment.store.note(id: noteId)?.text == "")

        try await second.vault.unlock(password: LockedFixture.password)

        #expect(try await second.storedText() == first.text + " zqxkilled")
        #expect(try Data(contentsOf: journal[0]).isEmpty)
    }

    // MARK: Attachments

    @Test func aLockedAttachmentIsServedFromMemoryAndNeverCached() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let temp = FileManager.default.temporaryDirectory
        let tempBefore = Set(fixture.allFiles(under: temp).map(\.path))
        let libraryBefore = Set(fixture.allFiles(under: fixture.root).map(\.path))
        let handler = AssetSchemeHandler(
            attachments: AttachmentStore(paths: fixture.environment.paths, database: fixture.environment.database),
            thumbnails: Thumbnails(paths: fixture.environment.paths),
            lockedAttachments: fixture.environment.lockedAttachments)
        let url = URL(string: "baerchen-asset://attachment/\(fixture.noteId)/photo.png")!

        let served = await handler.fullResponse(for: url)
        #expect(served.statusCode == 200)
        #expect(served.body == fixture.attachment)
        #expect(served.headers["Cache-Control"] == "no-store")
        #expect(served.headers["Content-Type"] == "image/png")
        #expect(await handler.fullResponse(for: url, method: "HEAD").headers["Content-Length"] == String(fixture.attachment.count))
        let thumbnail = await handler.thumbnailResponse(
            for: URL(string: "baerchen-asset://thumbnail/\(fixture.noteId)/photo.png")!)
        #expect(thumbnail.statusCode == 200)
        #expect(thumbnail.headers["Cache-Control"] == "no-store")

        #expect(!FileManager.default.fileExists(atPath: fixture.environment.paths.thumbnails.appendingPathComponent(fixture.noteId).path))
        #expect(Set(fixture.allFiles(under: fixture.root).map(\.path)).subtracting(libraryBefore).isEmpty)
        for file in fixture.allFiles(under: temp) where !tempBefore.contains(file.path) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size < 50_000_000, let data = try? Data(contentsOf: file) else { continue }
            #expect(data.range(of: Data(LockedFixture.attachmentMarker.utf8)) == nil, "plaintext attachment written to \(file.lastPathComponent)")
        }

        fixture.vault.relock()
        #expect(await handler.fullResponse(for: url).statusCode == 404)
        #expect(await handler.fullResponse(for: url, method: "HEAD").statusCode == 404)
        let after = await handler.thumbnailResponse(
            for: URL(string: "baerchen-asset://thumbnail/\(fixture.noteId)/photo.png")!)
        #expect(after.statusCode == 404)
        #expect(fixture.environment.lockedAttachments.cachedByteCount == 0)
    }

    @Test func aLockedPDFGetsAnInMemoryPreview() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let access = try fixture.vault.requireAccess()
        let pdf = EditorAttachmentIntegrationTestsSupport.onePagePDF()
        let name = try access.addAttachment(data: pdf, filename: "r.pdf", to: fixture.noteId)
        let handler = AssetSchemeHandler(
            attachments: AttachmentStore(paths: fixture.environment.paths, database: fixture.environment.database),
            thumbnails: Thumbnails(paths: fixture.environment.paths),
            lockedAttachments: fixture.environment.lockedAttachments)
        let preview = await handler.thumbnailResponse(for: URL(string: "baerchen-asset://thumbnail/\(fixture.noteId)/\(name)")!)
        #expect(preview.statusCode == 200)
        #expect(NSImage(data: preview.body) != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.environment.paths.thumbnails.appendingPathComponent(fixture.noteId).path))
    }

    @Test func anOrdinaryNoteStillServesItsFileFromDisk() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let plain = try fixture.environment.store.create(text: "plain")
        let bytes = Data("plain-bytes".utf8)
        _ = try AttachmentStore(paths: fixture.environment.paths, database: fixture.environment.database)
            .add(data: bytes, filename: "a.txt", to: plain.id)
        let handler = AssetSchemeHandler(
            attachments: AttachmentStore(paths: fixture.environment.paths, database: fixture.environment.database),
            thumbnails: Thumbnails(paths: fixture.environment.paths),
            lockedAttachments: fixture.environment.lockedAttachments)
        let served = handler.response(for: URL(string: "baerchen-asset://attachment/\(plain.id)/a.txt")!)
        #expect(served.statusCode == 200 && served.body == bytes)
        #expect(served.headers["Cache-Control"] == "no-cache")
    }

    @Test func quickLookOpenWithAndShowInFinderAreDisabledForLockedNotes() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, _) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        let attachments = controller.attachments
        var previews = 0, opens = 0, reveals = 0
        attachments.preview = { _ in previews += 1 }
        attachments.open = { _ in opens += 1 }
        attachments.reveal = { _ in reveals += 1 }
        attachments.openWith = { _, _ in opens += 1 }
        let target = AttachmentController.Target(
            noteId: fixture.noteId, filename: "photo.png", from: 0, to: 0, source: "![](photo.png)")

        attachments.showQuickLook(noteId: fixture.noteId, filename: "photo.png")
        attachments.perform(.open, on: target)
        attachments.perform(.openWith(URL(fileURLWithPath: "/System/Applications/Preview.app")), on: target)
        attachments.perform(.reveal, on: target)
        attachments.openLinked("photo.png", noteId: fixture.noteId)

        #expect(previews == 0 && opens == 0 && reveals == 0)
        let titles = attachments.menuItems(for: target).map(\.title)
        #expect(!titles.contains("Open") && !titles.contains("Open With") && !titles.contains("Show in Finder"))
        #expect(titles.contains("Save As…"))
    }

    @Test func insertingAnImageIntoAnUnlockedLockedNoteEncryptsIt() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let (controller, page) = fixture.makeController()
        try controller.open(noteId: fixture.noteId)
        let bytes = Data((LockedFixture.attachmentMarker + "-inserted").utf8)

        controller.attachments.insert(
            [AttachmentUpload(filename: "new.png", dataBase64: bytes.base64EncodedString())],
            insertId: "i1", noteId: fixture.noteId)
        await controller.attachments.pendingWork?.value

        let directory = fixture.environment.paths.attachments.appendingPathComponent(fixture.noteId)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        #expect(!names.isEmpty && names.allSatisfy { $0.hasSuffix(".bch") })
        #expect(try fixture.vault.requireAccess().attachmentData("new.png", noteId: fixture.noteId, maximumBytes: 1 << 20) == bytes)
        #expect("\(page.delivered)".contains("new.png"))
        for file in fixture.allFiles(under: fixture.root) {
            #expect(try Data(contentsOf: file).range(of: bytes) == nil, "plaintext in \(file.lastPathComponent)")
        }
    }

    @Test func relockDropsTheDecryptedAttachmentData() async throws {
        let fixture = try await LockedFixture()
        defer { fixture.destroy() }
        let memory = fixture.environment.lockedAttachments
        #expect(await memory.data(noteId: fixture.noteId, filename: "photo.png") == fixture.attachment)
        #expect(memory.cachedByteCount > 0)
        fixture.vault.relock()
        #expect(memory.cachedByteCount == 0)
        #expect(await memory.data(noteId: fixture.noteId, filename: "photo.png") == nil)
    }
}

enum EditorAttachmentIntegrationTestsSupport {
    static func onePagePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
