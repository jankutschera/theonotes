// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import PencilKit
import Testing
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileAttachmentEditBackendTests {
    private final class ReopenBeforeEdit: NSObject, WKScriptMessageHandlerWithReply {
        let editor: MobileEditor
        let noteID: String
        var didReopen = false
        init(_ editor: MobileEditor, noteID: String) { self.editor = editor; self.noteID = noteID }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            if !didReopen, (message.body as? [String: Any])?["type"] as? String == "changes" {
                didReopen = true
                try? editor.open(noteID)
            }
            editor.userContentController(controller, didReceive: message, replyHandler: replyHandler)
        }
    }

    @Test func reopeningDuringSketchSaveKeepsEditInOriginalWithoutRecoveryCopy() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths), note = try library.store.create(text: source)
        let red = try #require(UIImage(data: image(.red))?.cgImage), green = try #require(UIImage(data: image(.green))?.cgImage)
        let original = try MobileSketchPNG.embed(drawing: PKDrawing(), in: MobileSketchPNG.pngForNewSketch(from: red))
        let edited = try MobileSketchPNG.embed(drawing: PKDrawing(), in: MobileSketchPNG.pngForNewSketch(from: green))
        _ = try library.addAttachment(data: original, filename: "photo.png", noteID: note.id)
        let (editor, window) = try await mount(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let inspected = try await editor.inspectAttachmentForEditing(target(note.id, text: source))
        let proxy = ReopenBeforeEdit(editor, noteID: note.id), controller = editor.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(proxy, contentWorld: .page, name: "bridge")
        try await editor.saveEditedAttachment(png: edited, origin: inspected.origin, mode: .sketch)
        #expect(proxy.didReopen)
        try library.flush()
        let links = NoteParser.attachmentLinks(in: try #require(library.store.note(id: note.id)?.text))
        #expect(links.map(\.filename) == ["photo edited.png"])
        #expect(try Data(contentsOf: #require(try library.attachmentURL("photo edited.png", noteID: note.id))) == edited)
        #expect(try await library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 1)
    }
    private let source = #"![photo.png](photo.png)<!-- {"width":"320","custom":"photo.png"} -->"#
    private func image(_ color: UIColor, scale: CGFloat = 1) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).pngData {
            color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<600 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw MobileEditorDrainError.timeout
    }
    private func mount(_ library: MobileLibrary, noteID: String) async throws -> (MobileEditor, UIWindow) {
        library.selectedID = noteID
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController(), container = MobileWebViewContainer()
        container.attach(editor); host.view = container; window.rootViewController = host; window.makeKeyAndVisible()
        try editor.open(noteID)
        try await wait {
            guard editor.ready && editor.editable else { return false }
            return (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.getAttribute('contenteditable')")) as? String == "true"
        }
        return (editor, window)
    }
    private func target(_ noteID: String, text: String) -> MobileAttachmentTarget {
        let range = (text as NSString).range(of: source, options: .backwards)
        return MobileAttachmentTarget(noteID: noteID, filename: "photo.png", from: range.location, to: range.location + range.length, source: source)
    }
    @Test(arguments: [false, true])
    func copyOnWriteChangesOnlyChosenDestinationAndUndoRetainsBothFiles(locked: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let original = "# 🐻\n" + source + "\n" + source + "\n"
        let note = try library.store.create(text: original), oldBytes = image(.red), edited = image(.green)
        _ = try library.addAttachment(data: oldBytes, filename: "photo.png", noteID: note.id)
        if locked { try await library.unlockNotes(password: "fixture-password", createPassword: true); try library.lockNote(note.id) }
        let (editor, window) = try await mount(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let inspected = try await editor.inspectAttachmentForEditing(target(note.id, text: original))
        #expect(inspected.bytes == oldBytes && !inspected.isEditableSketch)
        try await editor.saveEditedAttachment(png: edited, origin: inspected.origin, mode: .crop)
        let changed = try #require(editor.session?.text), links = NoteParser.attachmentLinks(in: changed)
        try #require(links.count == 2)
        #expect(links[0].filename == "photo.png" && links[1].filename != "photo.png")
        #expect(links[1].filename == "photo edited.png")
        let expectedSource = source.replacingOccurrences(of: "(photo.png)", with: "(photo%20edited.png)")
        #expect(changed == "# 🐻\n" + source + "\n" + expectedSource + "\n")
        try library.flush()
        if locked {
            let access = try #require(library.privateAccess)
            #expect(try access.attachmentData("photo.png", noteId: note.id, maximumBytes: 1_048_576) == oldBytes)
            #expect(try access.attachmentData(links[1].filename, noteId: note.id, maximumBytes: 1_048_576) == edited)
            #expect(try library.store.note(id: note.id)?.text == "")
        } else {
            #expect(try Data(contentsOf: #require(try library.attachmentURL("photo.png", noteID: note.id))) == oldBytes)
            #expect(try Data(contentsOf: #require(try library.attachmentURL(links[1].filename, noteID: note.id))) == edited)
        }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',metaKey:true,bubbles:true,cancelable:true}))")
        try await wait { editor.session?.text == original }
        await #expect(throws: (any Error).self) { try await editor.saveEditedAttachment(png: edited, origin: inspected.origin, mode: .crop) }
    }
    @Test func jpegCropUsesReadableCollisionSafeNameAndPreservesOriginalAndUndo() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths), note = try library.store.create(text: source)
        let original = image(.red), occupied = image(.blue)
        _ = try library.addAttachment(data: original, filename: "photo.png", noteID: note.id)
        _ = try library.addAttachment(data: occupied, filename: "photo edited.jpg", noteID: note.id)
        let (editor, window) = try await mount(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let inspection = try await editor.inspectAttachmentForEditing(target(note.id, text: source))
        let jpeg = try #require(UIImage(data: image(.green))?.jpegData(compressionQuality: 0.95))
        await #expect(throws: MobileAttachmentError.self) { try await editor.saveEditedAttachment(png: jpeg, origin: inspection.origin, mode: .sketch) }
        try await editor.saveEditedAttachment(png: jpeg, origin: inspection.origin, mode: .crop)
        let updated = try #require(editor.session?.text)
        #expect(NoteParser.attachmentLinks(in: updated).map(\.filename) == ["photo edited 2.jpg"])
        try library.flush()
        let written = try Data(contentsOf: #require(try library.attachmentURL("photo edited 2.jpg", noteID: note.id)))
        #expect(written == jpeg && written.starts(with: [255, 216, 255]))
        #expect(try Data(contentsOf: #require(try library.attachmentURL("photo.png", noteID: note.id))) == original)
        #expect(try Data(contentsOf: #require(try library.attachmentURL("photo edited.jpg", noteID: note.id))) == occupied)
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',metaKey:true,bubbles:true,cancelable:true}))")
        try await wait { editor.session?.text == source }
        #expect(try Data(contentsOf: #require(try library.attachmentURL("photo edited 2.jpg", noteID: note.id))) == jpeg)
    }

    @Test func readableEditNameIsBoundedAndSketchKeepsPNGExtension() {
        #expect(MobileEditor.editedAttachmentFilename(original: "Holiday.jpeg", jpeg: true) == "Holiday edited.jpg")
        #expect(MobileEditor.editedAttachmentFilename(original: "Sketch.png", jpeg: false) == "Sketch edited.png")
        let long = MobileEditor.editedAttachmentFilename(original: String(repeating: "🐻", count: 100) + ".png", jpeg: false)
        #expect(long.utf8.count <= 240 && long.hasSuffix(" edited.png"))
    }

    @Test(arguments: [false, true])
    func sameRevisionSourceByteChangeIsRejectedWithoutNewFile(locked: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), library = try MobileLibrary(paths: paths)
        let note = try library.store.create(text: source)
        let original = image(.red), changed = image(.blue)
        _ = try library.addAttachment(data: original, filename: "photo.png", noteID: note.id)
        if locked { try await library.unlockNotes(password: "fixture-password", createPassword: true); try library.lockNote(note.id) }
        let (editor, window) = try await mount(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let inspection = try await editor.inspectAttachmentForEditing(target(note.id, text: source))
        let revision = try #require(try library.store.note(id: note.id)).revision
        let diskName: String, bytes: Data
        if locked {
            diskName = try #require(try await library.database.pool.read {
                try String.fetchOne($0, sql: "SELECT filename FROM attachment WHERE noteId=?", arguments: [note.id])
            })
            let encrypted = paths.root.appendingPathComponent("fixture-inner.bch")
            defer { try? FileManager.default.removeItem(at: encrypted) }
            try ChunkedCipher.encrypt(data: changed, output: encrypted,
                keyEncryptionKey: #require(library.privateAccess).journalKey(), context: diskName)
            bytes = try Data(contentsOf: encrypted)
        } else { diskName = "photo.png"; bytes = changed }
        try AttachmentFiles(paths: paths, database: library.database).write(
            [ImportedAttachment(filename: diskName, data: bytes)], noteId: note.id, replacing: true) { _ in }
        #expect(try library.store.note(id: note.id)?.revision == revision)
        let before = try FileManager.default.contentsOfDirectory(atPath: paths.attachments.appendingPathComponent(note.id).path).sorted()
        await #expect(throws: MobileAttachmentError.stale) { try await editor.saveEditedAttachment(png: image(.green), origin: inspection.origin, mode: .crop) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.attachments.appendingPathComponent(note.id).path).sorted() == before)
        #expect(editor.session?.text == source)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2), CGFloat(3)])
    func cropKeepsRasterPixelsIndependentOfRendererPointScale(scale: CGFloat) async throws {
        let bytes = image(.red, scale: scale)
        let raster = try #require(UIImage(data: bytes)?.cgImage)
        #expect(raster.width == Int(32 * scale) && raster.height == Int(24 * scale))
        let crop = try await MobileImageCrop.prepare(data: bytes)
        #expect(crop.width == raster.width && crop.height == raster.height)
    }

    @Test func invalidPencilKitArchiveRemainsOrdinaryAndDoesNotBlockCrop() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), ordinary = image(.red)
        let library = try MobileLibrary(paths: paths), note = try library.store.create(text: source)
        let malformed = try addingInvalidDrawing(to: ordinary)
        _ = try library.addAttachment(data: malformed, filename: "photo.png", noteID: note.id)
        let (editor, window) = try await mount(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let inspected = try await editor.inspectAttachmentForEditing(target(note.id, text: source))
        #expect(!inspected.isEditableSketch && inspected.drawingData == nil && inspected.bytes == malformed)
        let crop = try await MobileImageCrop.prepare(data: inspected.bytes)
        #expect(crop.width == 32 && crop.height == 24)
    }
    @Test func recognizedSketchRefusesDestructiveCropBeforeWriting() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), library = try MobileLibrary(paths: paths)
        let note = try library.store.create(text: source)
        let pixels = try #require(UIImage(data: image(.red))?.cgImage)
        let encoded = try MobileSketchPNG.embed(drawing: PKDrawing(), in: MobileSketchPNG.pngForNewSketch(from: pixels))
        _ = try library.addAttachment(data: encoded, filename: "photo.png", noteID: note.id)
        let (editor, window) = try await mount(library, noteID: note.id)
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let inspected = try await editor.inspectAttachmentForEditing(target(note.id, text: source))
        #expect(inspected.isEditableSketch)
        await #expect(throws: MobileAttachmentEditFailure.self) { try await editor.saveEditedAttachment(png: image(.green), origin: inspected.origin, mode: .crop) }
        #expect(editor.session?.text == source)
        #expect(try Data(contentsOf: #require(try library.attachmentURL("photo.png", noteID: note.id))) == encoded)
        try await editor.saveEditedAttachment(png: encoded, origin: inspected.origin, mode: .sketch)
        try library.flush()
        #expect(NoteParser.attachmentLinks(in: try #require(editor.session?.text)).map(\.filename) == ["photo edited.png"])
        let saved = try Data(contentsOf: #require(try library.attachmentURL("photo edited.png", noteID: note.id)))
        #expect(saved == encoded && saved.starts(with: [137,80,78,71,13,10,26,10]))
        #expect(try MobileSketchPNG.drawing(in: saved) != nil)
    }
    @Test func cancellationBarrierWaitsForNoncooperativeReadAndRejectsLateBytes() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), library = try MobileLibrary(paths: paths)
        let note = try library.store.create(text: source)
        _ = try library.addAttachment(data: image(.red), filename: "photo.png", noteID: note.id)
        let (editor, window) = try await mount(library, noteID: note.id), held = HeldAttachmentRead()
        defer { window.isHidden = true; try? editor.closeForPrivacy(); try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        editor.beforeAttachmentRead = { await held.run(offMain: !attachmentReadIsOnMainThread()) }
        let target = target(note.id, text: source)
        let inspection = Task { try await editor.inspectAttachmentForEditing(target) }
        try await wait { await held.started }
        try #require(await held.started)
        #expect(await held.offMain)
        editor.cancelAttachmentReads()
        var finished = false
        let waiter = Task { await editor.waitForAttachmentReads(); finished = true }
        await Task.yield()
        #expect(editor.hasAttachmentReads && !finished)
        await held.release()
        await #expect(throws: CancellationError.self) { _ = try await inspection.value }
        await waiter.value
        #expect(!editor.hasAttachmentReads && finished)
    }
    private func addingInvalidDrawing(to png: Data) throws -> Data {
        try #require(png.suffix(8).prefix(4) == Data("IEND".utf8))
        let payload = Data([84,78,80,75,1,0,1,2]), body = Data("thND".utf8) + payload
        var crc = UInt32.max
        for byte in body { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        func word(_ value: UInt32) -> Data { Data([24,16,8,0].map { UInt8(truncatingIfNeeded: value >> $0) }) }
        return Data(png.dropLast(12)) + word(UInt32(payload.count)) + body + word(~crc) + png.suffix(12)
    }
}

private func attachmentReadIsOnMainThread() -> Bool { Thread.isMainThread }
private actor HeldAttachmentRead {
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }
    private(set) var offMain = false
    func run(offMain: Bool) async { self.offMain = offMain; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
