// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileExportPrivacyTests {
    @Test func protectedExportsAreRejectedBeforeAndAfterAuthentication() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Private fixture\nsecret")
        try await library.unlockNotes(password: "disposable-test-password", createPassword: true)
        try library.lockNote(note.id)
        for authenticated in [true, false, true] {
            if !authenticated { try library.lockVault() }
            else if library.privateAccess == nil { try await library.unlockNotes(password: "disposable-test-password") }
            for format in MobileExportFormat.allCases {
                let access = try MobileExportAccess(library: library, ids: [note.id])
                #expect(access.notes.isEmpty)
                await #expect(throws: Error.self) {
                    _ = try await access.document(format: format, preferences: library.preferences, dark: false)
                }
            }
        }
        try library.removeNoteLock(note.id)
        let access = try MobileExportAccess(library: library, ids: [note.id])
        for format in MobileExportFormat.allCases {
            let wrapper = try await access.document(format: format, preferences: library.preferences, dark: false)
            #expect(wrapper.isRegularFile || wrapper.isDirectory)
        }
    }

    @Test func mixedBatchOmitsProtectedAndPublicationRechecksPersistedProtection() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let plain = try library.store.create(text: "# Public fixture")
        let secret = try library.store.create(text: "# Private fixture")
        try await library.unlockNotes(password: "disposable-test-password", createPassword: true)
        try library.lockNote(secret.id)
        let access = try MobileExportAccess(library: library, ids: [plain.id, secret.id])
        #expect(access.notes.map(\.id) == [plain.id])
        let document = try await access.document(format: .markdown, preferences: library.preferences, dark: false)
        #expect(String(decoding: try #require(document.regularFileContents), as: UTF8.self) == plain.text)
        try library.lockNote(plain.id)
        var publications = 0
        #expect(throws: Error.self) { try access.publish { publications += 1 } }
        #expect(publications == 0)
    }

    @Test func bridgeCopyAndQuickLookRejectProtectedOriginAndStalePages() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Protected\n```\nprivate fixture\n```")
        let normal = try library.store.create(text: "# Normal fixture")
        let filename = try library.addAttachment(data: Data("attachment fixture".utf8), filename: "fixture.txt", noteID: note.id)
        try await library.unlockNotes(password: "disposable-test-password", createPassword: true)
        try library.lockNote(note.id)
        var editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let container = MobileWebViewContainer(); container.attach(editor)
        controller.view = container; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        try editor.open(note.id)
        try await wait { editor.ready && editor.editable }
        #expect(editor.canShare && !editor.canExport) // Reading/editing remain available during authentication.
        try await wait {
            ((try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.textContent")) as? String)?.contains("private fixture") == true
        }
        #expect(try await editor.webView.evaluateJavaScript("document.querySelector('.cm-bc-copy') && getComputedStyle(document.querySelector('.cm-bc-copy')).display === 'none'") as? Bool == true)
        #expect(try library.attachmentURL(filename, noteID: note.id) != nil) // Inline assets still resolve.
        UIPasteboard.general.string = "disposable clipboard sentinel"
        _ = try await editor.webView.callAsyncJavaScript("return await window.webkit.messageHandlers.bridge.postMessage({type:'copyText',text:'private fixture',html:'<b>private fixture</b>'})", arguments: [:], in: nil, contentWorld: .page)
        #expect(UIPasteboard.general.string == "disposable clipboard sentinel")
        try editor.receive(.quickLook(noteId: note.id, filename: filename), from: editor.webView)
        #expect(editor.previewURL == nil)
        await #expect(throws: Error.self) {
            _ = try await editor.renderExport(source: "private fixture", attachments: [:], keepTags: true)
        }
        let retired = editor.webView
        do {  // Switch like the app: a ready page is replaced only inside a verified close (P1, e3268f62).
            let frozen = try await editor.prepareCaptureClose(note.id)
            defer { editor.endCaptureClose(frozen) }
            try editor.open(normal.id)
        }
        try await wait { editor.ready && editor.session?.noteId == normal.id }
        try editor.receive(.copyText(text: "late private fixture", html: nil), from: retired)
        #expect(UIPasteboard.general.string == "disposable clipboard sentinel")
        #expect(editor.webView.superview === container)
        editor.command(.insertText, args: ["text": .string("Typed after switch")])
        try await wait { editor.session?.text.contains("Typed after switch") == true }
        try library.flush()
        #expect(try library.store.note(id: normal.id)?.text.contains("Typed after switch") == true)
        try editor.receive(.copyText(text: "normal fixture", html: nil), from: editor.webView)
        #expect(UIPasteboard.general.string == "normal fixture")
        let beforeLock = editor.webView
        let beforeLockText = try #require(try library.store.note(id: normal.id)).text
        #expect(throws: NotePrivacyError.pendingEdits) { try library.lockNote(normal.id) }
        let unchanged = try #require(try library.store.note(id: normal.id))
        #expect(!unchanged.isLocked && unchanged.text == beforeLockText)
        #expect(editor.session?.text == beforeLockText)
        let closedEditor = editor
        try await library.withDrainedShareEditors {
            try closedEditor.closeForPrivacy()
            try library.lockNote(normal.id)
        }
        #expect(try library.store.note(id: normal.id)?.isLocked == true)
        #expect(try library.privateAccess?.note(id: normal.id)?.text == beforeLockText)
        try closedEditor.receive(.copyText(text: "locked fixture", html: nil), from: beforeLock)
        #expect(UIPasteboard.general.string == "normal fixture")
        editor = MobileEditor(library: library)
        container.attach(editor)
        try editor.receive(.copyText(text: "late locked fixture", html: nil), from: beforeLock)
        #expect(UIPasteboard.general.string == "normal fixture")
        try library.removeNoteLock(note.id)
        try editor.open(note.id)
        try await wait { editor.ready && editor.editable }
        try editor.receive(.copyText(text: "permanently unprotected fixture", html: nil), from: retired)
        #expect(UIPasteboard.general.string == "normal fixture")
        try editor.receive(.copyText(text: "permanently unprotected fixture", html: nil), from: editor.webView)
        #expect(UIPasteboard.general.string == "permanently unprotected fixture")
        let closed = editor.webView
        try editor.closeForPrivacy()
        try editor.receive(.copyText(text: "closed fixture", html: nil), from: closed)
        #expect(UIPasteboard.general.string == "permanently unprotected fixture")
        UIPasteboard.general.items = []
    }

    @Test func lockingRequiresEveryEditorToDetachEvenAfterCacheEviction() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Two editor fixture")
        try await library.unlockNotes(password: "disposable-test-password", createPassword: true)
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        defer { try? first.closeForPrivacy(); try? second.closeForPrivacy() }
        // No JS commands or user edits are issued: this isolates the native ownership gate.
        try first.open(note.id)
        try second.open(note.id)
        try library.discardSession(note.id)
        #expect(throws: NotePrivacyError.pendingEdits) { try library.lockNote(note.id) }
        try first.closeForPrivacy()
        #expect(second.session?.noteId == note.id)
        #expect(throws: NotePrivacyError.pendingEdits) { try library.lockNote(note.id) }
        let unchanged = try #require(try library.store.note(id: note.id))
        #expect(!unchanged.isLocked && unchanged.text == note.text)
        try second.closeForPrivacy()
        try library.lockNote(note.id)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(try library.privateAccess?.note(id: note.id)?.text == note.text)
    }

    @Test func suspendedExportCannotPublishAfterRelock() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Suspended fixture")
        try await library.unlockNotes(password: "disposable-test-password", createPassword: true)
        let access = try MobileExportAccess(library: library, ids: [note.id])
        // document() must suspend in the actual WebKit renderer before returning an artifact.
        let task = Task { _ = try await access.document(format: .html, preferences: library.preferences, dark: false) }
        // Both run on MainActor. Observing true means document passed initial validation
        // and yielded from the actual renderer; a completed/never-started render cannot pass.
        try await wait { access.isRendering }
        try #require(access.isRendering)
        try library.lockNote(note.id)
        await #expect(throws: CocoaError(.fileReadNoPermission)) { _ = try await task.value }
        #expect(!access.isRendering)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("export-privacy-" + UUID().uuidString)))
    }
}
