// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor
struct MobileShareInboxMultiEditorTests {
    /// Holds a real WebKit edit before NoteSession can acknowledge it; other bridge traffic continues.
    @MainActor private final class HeldChanges: NSObject, WKScriptMessageHandlerWithReply {
        let editor: MobileEditor
        var release: (() -> Void)?
        var holding = true
        init(_ editor: MobileEditor) { self.editor = editor }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            if holding, (message.body as? [String: Any])?["type"] as? String == "changes" {
                release = { self.editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
            } else {
                editor.userContentController(controller, didReceive: message, replyHandler: replyHandler)
            }
        }
        func deliver() {
            holding = false
            let pending = release
            release = nil
            pending?()
        }
    }

    @MainActor private final class FrozenReplies {
        var first: MobileEditor?
        var releaseSecond: (() -> Void)?
        func receive(_ editor: MobileEditor, controller: WKUserContentController, message: WKScriptMessage,
                     reply: @escaping @MainActor (Any?, String?) -> Void) {
            let body = message.body as? [String: Any]
            if body?["type"] as? String == "frozenForClose", body?["ok"] as? Bool == true {
                if first == nil { first = editor }
                else {
                    releaseSecond = { editor.userContentController(controller, didReceive: message, replyHandler: reply) }
                    return
                }
            }
            editor.userContentController(controller, didReceive: message, replyHandler: reply)
        }
        func deliver() {
            let pending = releaseSecond
            releaseSecond = nil
            pending?()
        }
    }

    @MainActor private final class FrozenHandler: NSObject, WKScriptMessageHandlerWithReply {
        let editor: MobileEditor
        let replies: FrozenReplies
        init(_ editor: MobileEditor, replies: FrozenReplies) { self.editor = editor; self.replies = replies }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            replies.receive(editor, controller: controller, message: message, reply: replyHandler)
        }
    }

    private func waitFor(_ stage: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for multi-editor stage: \(stage)")
        throw CocoaError(.coderReadCorrupt)
    }

    @Test func appendDoesNotDiscardAnUnacknowledgedEditInAnotherRegisteredEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Original")
        let first = MobileEditor(library: library), last = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let windows = [first, last].map { editor in
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            host.view = editor.webView
            window.rootViewController = host
            window.makeKeyAndVisible()
            return window
        }
        defer {
            windows.forEach { $0.isHidden = true }
            try? first.closeForPrivacy(); try? last.closeForPrivacy()
        }
        try first.open(note.id); try last.open(note.id)
        try await waitFor("both editors ready and editable") { first.ready && first.editable && last.ready && last.editable }
        let held = HeldChanges(first)
        let controller = first.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        // Exactly the singleton callback installed when the second MobileLibraryView appears last.
        library.drainEditorForLibraryOperation = {
            let frozen = try await last.prepareCaptureClose(note.id)
            return { last.endCaptureClose(frozen) }
        }
        first.command(.insertText, args: ["text": .string("UNACKNOWLEDGED")])
        try await waitFor("first editor change held before acknowledgement") { held.release != nil }
        #expect(try library.session(for: note.id).text == "Original")
        let request = CaptureRequest(itemId: UUID().uuidString.lowercased(), mode: .append,
            targetNoteId: note.id, text: "Shared append")
        try CaptureInbox(directory: container.appendingPathComponent("CaptureInbox")).enqueue(request, files: [])
        _ = try await first.webView.evaluateJavaScript("window.__shareFreezeSeen=false;window.__shareReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')window.__shareFreezeSeen=true;return window.__shareReceive(m)};true")
        var completed = false
        let drain = Task {
            defer { completed = true }
            do { return try await library.drainShareInbox() }
            catch is MobileEditorDrainError { return [] }
        }
        // The baseline finishes without freezing A. A safe drain freezes A or defers the append.
        var firstFrozen = false
        for _ in 0..<600 where !completed && !firstFrozen {
            firstFrozen = (try await first.webView.evaluateJavaScript("window.__shareFreezeSeen") as? Bool) == true
            if !firstFrozen { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(completed || firstFrozen)
        #expect(try library.store.note(id: note.id)?.text == "Original")
        held.deliver()
        _ = try await drain.value
        try await waitFor("first editor marker acknowledged after release") { first.session?.text.contains("UNACKNOWLEDGED") == true }
        _ = try await library.drainShareInbox()
        let saved = try #require(try library.store.note(id: note.id))
        #expect(saved.text.contains("UNACKNOWLEDGED"))
        #expect(saved.text.contains("Shared append"))
    }
    @Test(arguments: [false, true])
    func reloadOrCancellationInvalidatesFreezeWhileAnotherEditorDrains(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Original")
        let editors = [MobileEditor(library: library), MobileEditor(library: library)]
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let windows = editors.map { editor in
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            host.view = editor.webView
            window.rootViewController = host
            window.makeKeyAndVisible()
            return window
        }
        defer {
            windows.forEach { $0.isHidden = true }
            editors.forEach { try? $0.closeForPrivacy() }
        }
        for editor in editors { try editor.open(note.id) }
        try await waitFor("both reload fixture editors ready") { editors.allSatisfy { $0.ready && $0.editable } }
        let replies = FrozenReplies()
        defer { replies.deliver() }
        for editor in editors {
            let controller = editor.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
            controller.addScriptMessageHandler(FrozenHandler(editor, replies: replies), contentWorld: .page, name: "bridge")
            _ = try await editor.webView.evaluateJavaScript("window.__shareLoads=0;window.__shareReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='loadNote')window.__shareLoads++;return window.__shareReceive(m)};true")
        }
        let inbox = CaptureInbox(directory: container.appendingPathComponent("CaptureInbox"))
        let request = CaptureRequest(itemId: UUID().uuidString.lowercased(), mode: .append,
            targetNoteId: note.id, text: "Shared append")
        try inbox.enqueue(request, files: [])
        let drain = Task { try await library.drainShareInbox() }
        try await waitFor("second freeze reply held") { replies.releaseSecond != nil }
        let reloaded = try #require(replies.first)
        let page = reloaded.webView
        if cancel { drain.cancel() }
        else {
            try reloaded.open(note.id)
            var loaded = false
            for _ in 0..<60 where !loaded {
                loaded = (try await page.evaluateJavaScript("window.__shareLoads") as? Int ?? 0) > 0
                if !loaded { try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(loaded)
        }
        #expect(reloaded.webView === page && reloaded.session?.noteId == note.id)
        replies.deliver()
        if cancel {
            await #expect(throws: CancellationError.self) { try await drain.value }
        } else {
            await #expect(throws: MobileEditorDrainError.busy) { try await drain.value }
        }
        #expect(try library.store.note(id: note.id)?.text == "Original")
        let queued = inbox.directory.appendingPathComponent(request.itemId + ".capture")
        #expect(FileManager.default.fileExists(atPath: queued.path))
        for editor in editors {
            let controller = editor.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
            let forwarding = HeldChanges(editor)
            forwarding.holding = false
            controller.addScriptMessageHandler(forwarding, contentWorld: .page, name: "bridge")
            _ = try await editor.webView.evaluateJavaScript("window.__baerchen.receive=window.__shareReceive;true")
        }
        #expect(try await library.drainShareInbox() == [note.id])
        #expect(try library.store.note(id: note.id)?.text == "Original\n\nShared append")
        #expect(!FileManager.default.fileExists(atPath: queued.path))
        #expect(try await library.drainShareInbox() == [])
    }

}
