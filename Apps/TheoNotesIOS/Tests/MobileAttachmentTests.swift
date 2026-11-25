// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import PDFKit
import Testing
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor
struct MobileAttachmentTests {
    @MainActor private final class HeldEditReply: NSObject, WKScriptMessageHandlerWithReply {
        let editor: MobileEditor
        var release: (() -> Void)?
        init(_ editor: MobileEditor) { self.editor = editor }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            editor.userContentController(controller, didReceive: message) { value, error in
                if (message.body as? [String: Any])?["type"] as? String == "changes", self.release == nil {
                    self.release = { replyHandler(value, error) }
                } else { replyHandler(value, error) }
            }
        }
        func deliver() { let pending = release; release = nil; pending?() }
    }

    @Test(arguments: ["Sketch.png", "photo.png"])
    func attachmentInsertionWaitsForWebAcknowledgementBeforeReopen(filename: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "")
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({changes:{from:0,insert:'QA-Sketch\\n'}})")
        let origin = try await editor.captureAttachmentInsertionOrigin()
        let held = HeldEditReply(editor), controller = editor.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        var finished = false
        let insertion = Task { try await editor.insertAttachments([ImportedAttachment(filename: filename, data: bytes)], origin: origin); finished = true }
        try await wait { held.release != nil }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!finished)
        held.deliver()
        try await insertion.value
        try editor.open(note.id)
        let reopened = try await editor.prepareCaptureClose(note.id)
        editor.endCaptureClose(reopened)
        try library.flush()
        #expect(try library.store.note(id: note.id)?.text.contains("QA-Sketch") == true)
        #expect(try library.store.note(id: note.id)?.text.contains("![](\(filename))") == true)
        #expect(try Data(contentsOf: #require(try library.attachmentURL(filename, noteID: note.id))) == bytes)
        #expect(try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 1)
    }
    @Test func missingCaretInsertsAtTheEndInUTF16Units() {
        let text = "# Title\nA 🐻"
        let expected = (text as NSString).length
        #expect(MobileEditor.attachmentSelection(nil, text: text) == SelectionRange(anchor: expected, head: expected))
        let selection = SelectionRange(anchor: 2, head: 4)
        #expect(MobileEditor.attachmentSelection(selection, text: text) == selection)
    }
    private let source = #"![alt](photo.png)<!-- {"width":"320","custom":"keep"} -->"#
    private var bytes: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }


    @Test func boundedFileCollectionRejectsOversizeAndChangedProviders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("provider.bin")
        try Data([1, 2]).write(to: url)
        #expect(throws: CocoaError.self) { _ = try MobileAttachmentFileReader.read([url], maximumBytes: 1) }
        #expect(throws: CocoaError.self) {
            _ = try MobileAttachmentFileReader.read([url], maximumBytes: 4, afterOpen: { source in
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data([3, 4, 5]))
            })
        }
        try Data([1, 2]).write(to: url)
        #expect(throws: CocoaError.self) {
            _ = try MobileAttachmentFileReader.read([url], afterOpen: { source in
                try Data([8, 9]).write(to: source, options: .atomic)
            })
        }
        #expect(throws: CocoaError.self) {
            _ = try MobileAttachmentFileReader.read([url], afterOpen: { source in
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data([6, 7]))
            })
        }
        try Data([8, 9]).write(to: url)
        #expect(throws: CocoaError.self) { _ = try MobileAttachmentFileReader.read([url, url], maximumBytes: 3) }
        #expect(throws: CocoaError.self) { _ = try MobileAttachmentFileReader.read([directory]) }
        let oversized = directory.appendingPathComponent("oversized.bin")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(250 * 1024 * 1024 + 1)); try handle.close()
        #expect(throws: CocoaError.self) { _ = try MobileAttachmentFileReader.read([oversized]) }
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { _ = try MobileAttachmentFileReader.read([link]) }
        #expect(try MobileAttachmentFileReader.read([url]).first?.data == Data([8, 9]))
    }

    private func mounted(_ library: MobileLibrary, noteID: String) async throws -> (MobileEditor, UIWindow) {
        _ = try #require(UIImage(data: bytes))
        library.selectedID = noteID
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        let container = MobileWebViewContainer(); container.attach(editor)
        host.view = container; window.rootViewController = host; window.makeKeyAndVisible()
        try editor.open(noteID)
        try await wait(stage: "WebKit startup/readiness for note \(noteID)", attempts: 600) {
            guard editor.ready && editor.canShare else { return false }
            return (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.textContent")) as? String != nil
        }
        return (editor, window)
    }

    private func target(_ id: String, text: String) -> MobileAttachmentTarget {
        let range = (text as NSString).range(of: source)
        return MobileAttachmentTarget(noteID: id, filename: "photo.png", from: range.location,
                                      to: range.location + range.length, source: source)
    }

    @Test func renameCollisionResizeRemoveAndUndoKeepBytesAndExactSource() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = "👩‍💻 heading\n" + source + "\nend"
        let note = try library.store.create(text: original)
        _ = try library.addAttachment(data: bytes, filename: "photo.png", noteID: note.id)
        _ = try library.addAttachment(data: Data("collision".utf8), filename: "renamed.png", noteID: note.id)
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true }
        let request = target(note.id, text: original)
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-bc-attachment').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}))")
        try await wait { editor.attachmentTarget != nil }
        #expect(editor.attachmentTarget?.source == source)
        #expect(editor.attachmentTarget?.from == request.from)
        #expect(editor.attachmentTarget?.filename == "photo.png")
        editor.attachmentTarget = nil
        try editor.resizeAttachment(request, width: 640)
        try await wait { editor.session?.text.contains(#""width":"640""#) == true }
        #expect(editor.session?.text.contains(#""custom":"keep""#) == true)
        try await history(editor)
        try await wait { editor.session?.text == original }
        try editor.renameAttachment(request, to: "renamed.png")
        let renamed = original.replacingOccurrences(of: source, with: AttachmentMarkdown.renaming(source, to: "renamed 2.png")!)
        try await wait { editor.session?.text == renamed }
        try library.flush()
        #expect(try Data(contentsOf: #require(try library.attachmentURL("renamed 2.png", noteID: note.id))) == bytes)
        #expect(try Data(contentsOf: #require(try library.attachmentURL("photo.png", noteID: note.id))) == bytes)
        try await history(editor); try await wait { editor.session?.text == original }
        try await history(editor, redo: true); try await wait { editor.session?.text == renamed }
        try await history(editor); try await wait { editor.session?.text == original }
        try editor.removeAttachment(request)
        try await wait { editor.session?.text == original.replacingOccurrences(of: source, with: "") }
        try await history(editor); try await wait { editor.session?.text == original }
        // The file menu rechecks stale ranges, current note, and read-only state before every edit.
        let stale = MobileAttachmentTarget(noteID: note.id, filename: "photo.png", from: 0, to: 1, source: source)
        #expect(throws: MobileAttachmentError.self) { try editor.removeAttachment(stale) }
        #expect(throws: MobileAttachmentError.self) { try editor.renameAttachment(request, to: "../escape.png") }
        try library.store.setReadOnly(note.id, readOnly: true); editor.loadNote()
        try await wait { !editor.editable }
        #expect(!editor.canEditAttachment(request))
        #expect(try Data(contentsOf: editor.attachmentFile(request)) == bytes)
        #expect(throws: MobileAttachmentError.self) { try editor.resizeAttachment(request, width: 200) }
    }

    @Test func encryptedRenameRetainsUndoAliasesAndPrivacyRevokesMenuAccess() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: source)
        _ = try library.addAttachment(data: bytes, filename: "photo.png", noteID: note.id)
        try await library.unlockNotes(password: "attachment-test-password", createPassword: true)
        try library.lockNote(note.id)
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true }
        let request = target(note.id, text: source)
        try editor.renameAttachment(request, to: "private.png")
        let renamed = AttachmentMarkdown.renaming(source, to: "private.png")!
        try await wait { editor.session?.text == renamed }
        try library.flush()
        let first = try #require(try library.attachmentURL("photo.png", noteID: note.id))
        let second = try #require(try library.attachmentURL("private.png", noteID: note.id))
        #expect(try Data(contentsOf: first) == bytes)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(try library.store.note(id: note.id)?.text == "")
        try await history(editor); try await wait { editor.session?.text == source }
        try library.flush()
        editor.attachmentTarget = request
        try editor.closeForPrivacy(); try library.lockVault()
        #expect(editor.attachmentTarget == nil)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(throws: MobileAttachmentError.self) { try editor.attachmentFile(request) }
    }

    @Test func pdfPreviewStateAndFormattingPasteReachTheProductionEditor() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let pdf = #"[doc.pdf](doc.pdf)<!-- {"preview":"true","custom":"keep"} -->"#
        let note = try library.store.create(text: "**bold**\n" + pdf)
        _ = try library.addAttachment(data: Data("pdf fixture".utf8), filename: "doc.pdf", noteID: note.id)
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true }
        try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({selection:{anchor:3}})")
        try await wait { editor.formatState?.active.contains(.bold) == true }
        let range = (editor.session!.text as NSString).range(of: pdf)
        let request = MobileAttachmentTarget(noteID: note.id, filename: "doc.pdf", from: range.location, to: range.location + range.length, source: pdf)
        try editor.setAttachmentPreview(request, shown: false)
        try await wait { editor.session?.text.contains(#""preview":"false""#) == true }
        #expect(editor.session?.text.contains(#""custom":"keep""#) == true)
        try await history(editor)
        try await wait { editor.session?.text == "**bold**\n" + pdf }
        editor.command(.selectAll)
        editor.pasteAsCode("let x = 1\nlet y = 2")
        try await wait { editor.session?.text.contains("```\nlet x = 1\nlet y = 2\n```") == true }
        try editor.closeForPrivacy()
        #expect(editor.formatState == nil)
        #expect(editor.attachmentTarget == nil)
    }

    @Test func scannedPagesInsertOnePDFAndBecomeOCRBacklogEligible() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Scan: ")
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({selection:{anchor:6,head:6}})")
        let origin = try await editor.captureAttachmentInsertionOrigin()
        let first = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
            ("Page One" as NSString).draw(at: CGPoint(x: 8, y: 20), withAttributes: [.foregroundColor: UIColor.black])
        }
        let second = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            ("Page Two" as NSString).draw(at: CGPoint(x: 8, y: 20), withAttributes: [.foregroundColor: UIColor.black])
        }
        let batch = try await MobileMediaCapture.scanPDFOffMain(images: [first, second])
        defer { batch.remove() }
        #expect(batch.files.count == 1)
        let source = try #require(batch.files.first)
        let sourceBytes = try Data(contentsOf: source)
        #expect(PDFDocument(data: sourceBytes)?.pageCount == 2)
        try await editor.insertFiles(batch.files, origin: origin)
        let expected = #"Scan: [Scan.pdf](Scan.pdf)<!-- {"preview":"true","embed":"true"} -->"#
        #expect(editor.session?.text == expected)
        try library.flush()
        #expect(try library.store.note(id: note.id)?.text == expected)
        let stored = try #require(try library.attachmentURL("Scan.pdf", noteID: note.id))
        #expect(try Data(contentsOf: stored) == sourceBytes)
        #expect(PDFDocument(url: stored)?.pageCount == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.attachments.appendingPathComponent(note.id).path) == ["Scan.pdf"])
        let filenames = try await library.database.pool.read {
            try String.fetchAll($0, sql: "SELECT filename FROM attachment WHERE noteId=? AND deletedAt IS NULL", arguments: [note.id])
        }
        #expect(filenames == ["Scan.pdf"])
        #expect(try await library.database.pool.read {
            try String.fetchOne($0, sql: "SELECT ocrState FROM attachment WHERE noteId=? AND filename=?", arguments: [note.id, "Scan.pdf"])
        } == "pending")
        let textStore = AttachmentTextStore(database: library.database)
        let job = OCRJob(noteId: note.id, filename: "Scan.pdf")
        #expect(try textStore.pendingJobs(limit: 10) == [job])
        #expect(try textStore.runnableToken(job) != nil)
    }

    @Test func asynchronousBatchUsesCapturedSelectionOrderAndSupportsUndo() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = "before selected after"
        let note = try library.store.create(text: original)
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({selection:{anchor:7,head:15}})")
        try await wait { editor.hasSelection }
        let origin = try await editor.captureAttachmentInsertionOrigin()
        let items = [ImportedAttachment(filename: "one.png", data: bytes), ImportedAttachment(filename: "two.png", data: bytes)]
        try await editor.insertAttachments(items, origin: origin)
        let expected = "before ![](one.png)\n![](two.png) after"
        #expect(editor.session?.text == expected)
        try library.flush()
        for name in ["one.png", "two.png"] {
            #expect(try Data(contentsOf: #require(try library.attachmentURL(name, noteID: note.id))) == bytes)
        }
        await #expect(throws: MobileAttachmentError.stale) { try await editor.insertAttachments(items, origin: origin) }
        try await history(editor)
        try await wait { editor.session?.text == original }
    }

    @Test(arguments: ["selection", "note", "navigation", "reload", "readOnly", "relock", "revision", "close", "library"])
    func asynchronousInsertionRejectsStaleOriginBeforeWriting(reason: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        if reason == "relock" {
            try await library.unlockNotes(password: "fixture-password", createPassword: true)
            try library.lockNote(note.id)
        }
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        let origin = try await editor.captureAttachmentInsertionOrigin()
        switch reason {
        case "selection":
            _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({selection:{anchor:3}})")
            try await wait { try library.store.editorState(noteID: note.id).selection?.anchor == 3 }
        case "note":
            // Switch the way the app does: a ready page is replaced only after a verified close, so
            // unacked browser text is never dropped with it (P1 round 1, e3268f62).
            let frozen = try await editor.prepareCaptureClose(note.id)
            defer { editor.endCaptureClose(frozen) }
            try editor.open(library.store.create(text: "Other").id)
        case "navigation": library.selectedID = try library.store.create(text: "Other selected before editor switches").id
        case "reload": try editor.open(note.id)
        case "readOnly": try library.store.setReadOnly(note.id, readOnly: true)
        case "relock": try library.lockVault()
        case "revision":
            editor.command(.insertText, args: ["text": .string("changed")])
            try await wait { editor.session?.text.contains("changed") == true }
        case "close": try editor.closeForPrivacy()
        default: _ = try await library.importNotes([])
        }
        await #expect(throws: MobileAttachmentError.stale) {
            try await editor.insertAttachments([ImportedAttachment(filename: "late.png", data: bytes)], origin: origin)
        }
        #expect(try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment") } == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.attachments.appendingPathComponent(note.id + "/late.png").path))
    }

    @Test func openedProtectedNoteKeepsCapturedMediaEncrypted() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Private")
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        try library.lockNote(note.id)
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        let origin = try await editor.captureAttachmentInsertionOrigin()
        try await editor.insertAttachments([ImportedAttachment(filename: "private.png", data: bytes)], origin: origin)
        try library.flush()
        #expect(try library.store.note(id: note.id)?.text == "")
        #expect(editor.session?.text.contains("![](private.png)") == true)
        #expect(try Data(contentsOf: #require(try library.attachmentURL("private.png", noteID: note.id))) == bytes)
        let stored = try FileManager.default.contentsOfDirectory(at: paths.attachments.appendingPathComponent(note.id), includingPropertiesForKeys: nil)
        #expect(stored.count == 1 && stored[0].pathExtension == "bch")
        #expect(try Data(contentsOf: stored[0]) != bytes)
    }

    @Test func failedFileCollectionAndCancellationWriteNoAttachments() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        let origin = try await editor.captureAttachmentInsertionOrigin()
        let file = paths.root.appendingPathComponent("one.png")
        try bytes.write(to: file)
        await #expect(throws: (any Error).self) {
            try await editor.insertFiles([file, paths.root.appendingPathComponent("missing.png")], origin: origin)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await editor.insertAttachments([ImportedAttachment(filename: "cancelled.png", data: bytes)], origin: origin)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment") } == 0)
        #expect(editor.session?.text == "Original")
    }

    @Test(arguments: [false, true])
    func batchFailureDoesNotLeaveUnreferencedAttachments(locked: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        if locked {
            try await library.unlockNotes(password: "fixture-password", createPassword: true)
            try library.lockNote(note.id)
        }
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        let origin = try await editor.captureAttachmentInsertionOrigin()
        if locked {
            try await library.database.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER fail_second_media BEFORE UPDATE OF encryptedPayload ON note
                    WHEN (SELECT COUNT(*) FROM attachment WHERE noteId=NEW.id)>1
                    BEGIN SELECT RAISE(ABORT, 'second media write failed'); END
                    """)
            }
        }
        let second = locked ? "two.png" : String(repeating: "%", count: 200) + ".png"
        await #expect(throws: (any Error).self) {
            try await editor.insertAttachments([ImportedAttachment(filename: "one.png", data: bytes),
                ImportedAttachment(filename: second, data: bytes)], origin: origin)
        }
        #expect(editor.session?.text == "Original")
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: paths.attachments.appendingPathComponent(note.id).path)) ?? []
        #expect(stored.isEmpty)
        #expect(try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment") } == 0)
    }

    @Test func timedOutInsertionDoesNotDeleteBytesBeforeLateAcknowledgement() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        let (editor, window) = try await mounted(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy() }
        let origin = try await editor.captureAttachmentInsertionOrigin()
        _ = try await editor.webView.evaluateJavaScript("window.__mediaReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='applyCommand'&&m.name==='replaceRange'){window.__heldMedia=m;return;}return window.__mediaReceive(m)};true")
        await #expect(throws: MobileAttachmentError.notApplied) {
            try await editor.insertAttachments([ImportedAttachment(filename: "late.png", data: bytes)], origin: origin)
        }
        #expect(try Data(contentsOf: #require(try library.attachmentURL("late.png", noteID: note.id))) == bytes)
        _ = try await editor.webView.evaluateJavaScript("window.__baerchen.receive=window.__mediaReceive;window.__mediaReceive(window.__heldMedia);true")
        try await wait { editor.session?.text.contains("![](late.png)") == true }
        try library.flush()
        #expect(try Data(contentsOf: #require(try library.attachmentURL("late.png", noteID: note.id))) == bytes)
    }

    private func history(_ editor: MobileEditor, redo: Bool = false) async throws {
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',metaKey:true,shiftKey:\(redo),bubbles:true,cancelable:true}))")
    }

    private func wait(stage: String = "editor behavioral state", attempts: Int = 200,
                      _ condition: () async throws -> Bool) async throws {
        for _ in 0..<attempts { if try await condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        Issue.record("Timed out waiting for \(stage)")
        throw CocoaError(.coderReadCorrupt)
    }
}
