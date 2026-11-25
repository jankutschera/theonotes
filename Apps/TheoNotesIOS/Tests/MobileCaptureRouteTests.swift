// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Testing
import UIKit
import SwiftUI
import WebKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor
struct MobileCaptureRouteTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<600 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for the editor to load")
        throw CocoaError(.coderReadCorrupt)
    }

    private func mount(_ editor: MobileEditor) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view = editor.webView
        window.rootViewController = host
        window.makeKeyAndVisible()
        return window
    }

    /// Switch the way the app does: a ready page is replaced only after a verified close (P1, e3268f62).
    private func switchNote(_ editor: MobileEditor, to id: String) async throws {
        guard let current = editor.session?.noteId, editor.ready else { return try editor.open(id) }
        let frozen = try await editor.prepareCaptureClose(current)
        defer { editor.endCaptureClose(frozen) }
        try editor.open(id)
    }

    @Test func thoughtRouteCreatesAnEmptyLockscreenCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await MobileShortcutRouter.newCapture(source: .lockscreen, library: library)
        let note = try #require(try library.store.note(id: id))
        #expect(note.text == "")
        #expect(note.location == .notes)
        #expect(try library.store.captureSource(noteId: id) == .lockscreen)
        #expect(library.selectedID == id)
        #expect(try library.store.lastOpenedAt(noteId: id) == nil)
    }

    @Test func directCancellationWithoutAnEditorKeepsTheCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        try library.cancelCapture(noteId: id)
        #expect(try library.store.note(id: id)?.location == .notes)
        let edited = try await library.captureThought(source: .shortcut)
        let note = try #require(try library.store.note(id: edited))
        _ = try library.store.updateText(id: edited, text: "Kept thought", expectedRevision: note.revision)
        try library.cancelCapture(noteId: edited)
        #expect(try library.store.note(id: edited)?.location == .notes)
        #expect(try library.store.note(id: edited)?.text == "Kept thought")
    }

    @Test func loadingANoteRecordsLastOpened() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "An ordinary note")
        let before = try #require(try library.store.note(id: note.id))
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(note.id)
        try await waitFor { editor.ready && editor.editable }
        let opened = try #require(try library.store.lastOpenedAt(noteId: note.id))
        editor.loadNote()
        #expect(try library.store.lastOpenedAt(noteId: note.id) == opened)
        let after = try #require(try library.store.note(id: note.id))
        #expect(after.revision == before.revision)
        #expect(after.modifiedAt == before.modifiedAt)
    }

    @Test func captureLoadIsNotAnOpen() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(id)
        try await waitFor { editor.ready && editor.session?.noteId == id && editor.editable }
        #expect(try library.store.lastOpenedAt(noteId: id) == nil)
        let another = try library.store.create(text: "Another note")
        try await switchNote(editor, to: another.id)
        try await waitFor { (try library.store.lastOpenedAt(noteId: another.id)) != nil }
        try await waitFor { editor.ready && editor.session?.noteId == another.id }
        try await switchNote(editor, to: id)
        try await waitFor { (try library.store.lastOpenedAt(noteId: id)) != nil }
    }

    @Test func leavingTheActualEditorCancelsOnlyAnUntouchedCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        library.selectedID = nil
        try await waitFor { try library.store.note(id: id)?.location == .trash }
        let edited = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == edited }
        editor.command(.insertText, args: ["text": .string("Saved thought")])
        try await waitFor { editor.session?.text == "Saved thought" }
        library.selectedID = nil
        try await waitFor { try library.store.note(id: edited)?.text == "Saved thought" }
        #expect(try library.store.note(id: edited)?.location == .notes)
    }

    @Test func immediateCloseAfterTypingDoesNotTrashTheCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        editor.command(.insertText, args: ["text": .string("Immediate thought")])
        library.selectedID = nil
        try await Task.sleep(for: .seconds(1))
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "Immediate thought")
    }

    @Test func switchingNotesWaitsForAnUnacknowledgedCaptureEdit() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        let other = try library.store.create(text: "Other note")
        editor.command(.insertText, args: ["text": .string("Keep on switch")])
        library.selectedID = other.id
        try await waitFor { editor.session?.noteId == other.id && editor.ready }
        let captured = try #require(try library.store.note(id: id))
        #expect(captured.location == .notes)
        #expect(captured.text == "Keep on switch")
    }

    /// N15: when the destination fails to open inside the capture close, the switch is not done:
    /// the ordinary switch path runs (a second freeze) instead of leaving the capture page shown.
    @Test func failedOpenInsideCaptureCloseFallsBackToOrdinarySwitch() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        let other = try library.store.create(text: "Other note")
        editor.command(.insertText, args: ["text": .string("Keep on switch")])
        // A directory where the destination's journal belongs makes opening it fail.
        let blocker = library.paths.journal.appendingPathComponent(other.id + ".jsonl")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        _ = try await editor.webView.evaluateJavaScript("window.__n15Freezes=0;window.__n15Receive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')window.__n15Freezes++;return window.__n15Receive(m)};true")
        library.selectedID = other.id
        var freezes = 0
        for _ in 0..<200 where freezes < 2 {
            freezes = try await editor.webView.evaluateJavaScript("window.__n15Freezes") as? Int ?? 0
            if freezes < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(freezes == 2, "the capture close and then the ordinary switch")
        try await waitFor { library.errorMessage != nil }
        try FileManager.default.removeItem(at: blocker)
        #expect(editor.session?.noteId == id)
        #expect(try library.store.note(id: id)?.text == "Keep on switch")
    }

    @Test func unavailableEditorBarrierNeverTrashesCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        try editor.closeForPrivacy()
        library.selectedID = nil
        try await Task.sleep(for: .milliseconds(500))
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func directCancellationCannotDiscardAnUnacknowledgedEdit() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(id)
        try await waitFor { editor.ready && editor.editable }
        editor.command(.insertText, args: ["text": .string("Unacknowledged thought")])
        try? library.cancelCapture(noteId: id)
        try await Task.sleep(for: .seconds(1))
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "Unacknowledged thought")
    }

    @Test func abandoningCaptureBeforeInitialLoadDoesNotSuppressLaterOpen() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        library.selectedID = nil
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(id)
        try await waitFor { editor.ready && editor.editable }
        #expect(try library.store.lastOpenedAt(noteId: id) != nil)
    }

    @Test func rapidSwitchKeepsCaptureEditsAndOpensFinalDestination() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let capture = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == capture }
        let middle = try library.store.create(text: "Middle")
        let target = try library.store.create(text: "Final")
        _ = try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen=false; window.__i1Receive=window.__baerchen.receive; window.__baerchen.receive=async function(m){ if(m.type==='freezeForClose'){window.__i1FreezeSeen=true; await new Promise(r=>setTimeout(r,500));} return window.__i1Receive(m); }; true")
        editor.command(.insertText, args: ["text": .string("Rapidly written")])
        library.selectedID = middle.id
        for _ in 0..<100 {
            if (try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true)
        library.selectedID = target.id
        try await waitFor { editor.ready && editor.session?.noteId == target.id }
        let note = try #require(try library.store.note(id: capture))
        #expect(note.location == .notes)
        #expect(note.text == "Rapidly written")
    }

    @Test func inactiveSceneNeverDiscardsCaptureOnSwitch() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let lifecycle = CaptureTestLifecycle()
        window.rootViewController = UIHostingController(rootView: CaptureTestLifecycleView(library: library, editor: editor, lifecycle: lifecycle))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        editor.command(.insertText, args: ["text": .string("Safe while inactive")])
        try await waitFor { editor.session?.text == "Safe while inactive" }
        // Start with an acknowledged foreground page, then make THIS scene inactive
        // before delivering a queued selection-away intent. Cold inactive pages must not load.
        lifecycle.phase = .inactive
        try await waitFor { !library.hasActiveSceneWindows }
        let navigation = try #require(editor.sceneNavigation)
        navigation.selectedID = nil
        try await Task.sleep(for: .seconds(4))
        #expect(try library.store.note(id: id)?.location == .notes)
        #expect(editor.sceneNavigation?.selectedID == id)
        #expect(editor.session?.noteId == id)
        #expect(editor.session?.text == "Safe while inactive")
        try library.flush()
        #expect(try library.store.note(id: id)?.text == "Safe while inactive")
    }

    @Test func anotherEditorPreventsDiscardingCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        let otherEditor = MobileEditor(library: library)
        try otherEditor.open(id)
        library.selectedID = nil
        try await Task.sleep(for: .seconds(4))
        #expect(try library.store.note(id: id)?.location == .notes)
        #expect(otherEditor.session?.noteId == id)
    }

    @Test func inactiveSceneKeepsUntouchedCaptureAndRestoresSelection() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let lifecycle = CaptureTestLifecycle()
        window.rootViewController = UIHostingController(rootView: CaptureTestLifecycleView(library: library, editor: editor, lifecycle: lifecycle))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        // Start with an acknowledged foreground page, then make THIS scene inactive
        // before delivering a queued selection-away intent. Cold inactive pages must not load.
        lifecycle.phase = .inactive
        try await waitFor { !library.hasActiveSceneWindows }
        let navigation = try #require(editor.sceneNavigation)
        navigation.selectedID = nil
        try await Task.sleep(for: .seconds(4))
        #expect(editor.sceneNavigation?.selectedID == id)
        #expect(try library.store.note(id: id)?.location == .notes)
        #expect(editor.session?.noteId == id)
    }

    @Test func backgroundDuringSwitchRestoresDisplayedCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer {
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            window.isHidden = true
        }
        try await Task.sleep(for: .milliseconds(250))
        let id = try await library.captureThought(source: .lockscreen)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == id }
        let target = try library.store.create(text: "Other note")
        _ = try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen=false; window.__i1Receive=window.__baerchen.receive; window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__i1FreezeSeen=true; await new Promise(r=>setTimeout(r,500));}return window.__i1Receive(m)}; true")
        library.selectedID = target.id
        for _ in 0..<100 {
            if (try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .seconds(2))
        #expect(editor.sceneNavigation?.selectedID == id)
        #expect(editor.session?.noteId == id)
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func terminatedWebContentReloadsTheAcknowledgedNote() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "Recover this note")
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(note.id)
        try await waitFor { editor.ready && editor.editable }
        editor.webViewWebContentProcessDidTerminate(editor.webView)
        #expect(!editor.ready)
        try await waitFor { editor.ready && editor.editable }
        #expect(editor.session?.noteId == note.id)
        #expect(editor.session?.text == "Recover this note")
    }

    @Test func unresponsiveEditorKeepsUntouchedCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(id)
        try await waitFor { editor.ready && editor.editable }
        _ = try await editor.webView.evaluateJavaScript("window.__i1Receive=window.__baerchen.receive; window.__baerchen.receive=function(m){if(m.type==='freezeForClose')return; return window.__i1Receive(m)}; true")
        let started = Date()
        var rejected = false
        do { try await library.finishCapture(noteId: id, editor: editor, mayFinish: { true }) }
        catch { rejected = true }
        #expect(rejected)
        #expect(Date().timeIntervalSince(started) >= 2.5)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func badFreezeRepliesKeepUntouchedCapture() async throws {
        for wrongNote in [false, true] {
            let library = try library()
            defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
            let id = try await library.captureThought(source: .lockscreen)
            let editor = MobileEditor(library: library)
            let window = try mount(editor)
            defer { window.isHidden = true }
            try editor.open(id)
            try await waitFor { editor.ready && editor.editable }
            let badNote = wrongNote ? "'wrong-note'" : "m.noteId"
            let hash = wrongNote ? "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" : String(repeating: "0", count: 64)
            let script = "window.__i1Receive=window.__baerchen.receive; window.__baerchen.receive=function(m){if(m.type==='freezeForClose'){window.webkit.messageHandlers.bridge.postMessage({type:'frozenForClose',requestId:m.requestId,noteId:\(badNote),ok:true,editedSinceLoad:false,sha256:'\(hash)'});return;}return window.__i1Receive(m)}; true"
            _ = try await editor.webView.evaluateJavaScript(script)
            var rejected = false
            do { try await library.finishCapture(noteId: id, editor: editor, mayFinish: { true }) }
            catch { rejected = true }
            #expect(rejected)
            #expect(try library.store.note(id: id)?.location == .notes)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test func appLockDuringFreezeKeepsUntouchedCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(id)
        try await waitFor { editor.ready && editor.editable }
        library.enableAppLockForTesting()
        _ = try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen=false; window.__i1Receive=window.__baerchen.receive; window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__i1FreezeSeen=true; await new Promise(r=>setTimeout(r,500));}return window.__i1Receive(m)}; true")
        let closing = Task { try await library.finishCapture(noteId: id, editor: editor, mayFinish: { true }) }
        for _ in 0..<100 {
            if (try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true)
        library.lockApplication()
        var rejected = false
        do { try await closing.value } catch { rejected = true }
        #expect(rejected)
        #expect(library.appLocked)
        #expect(try library.store.note(id: id)?.location == .notes)
    }
    #endif

    @Test func terminatedWebContentDuringFreezeKeepsUntouchedCapture() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let id = try await library.captureThought(source: .lockscreen)
        let editor = MobileEditor(library: library)
        let window = try mount(editor)
        defer { window.isHidden = true }
        try editor.open(id)
        try await waitFor { editor.ready && editor.editable }
        _ = try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen=false; window.__i1Receive=window.__baerchen.receive; window.__baerchen.receive=function(m){if(m.type==='freezeForClose'){window.__i1FreezeSeen=true;return;}return window.__i1Receive(m)}; true")
        let closing = Task { try await library.finishCapture(noteId: id, editor: editor, mayFinish: { true }) }
        for _ in 0..<100 {
            if (try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try await editor.webView.evaluateJavaScript("window.__i1FreezeSeen") as? Bool) == true)
        let started = Date()
        editor.webViewWebContentProcessDidTerminate(editor.webView)
        editor.webView.stopLoading()
        var rejected = false
        do { try await closing.value } catch { rejected = true }
        #expect(rejected)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func ordinarySwitchWaitsForQueuedEditorCommand() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Original")
        let target = try library.store.create(text: "Destination")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1bReceive=window.__baerchen.receive; window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));return window.__i1bReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Queued edit")])
        library.selectedID = target.id
        try await waitFor { editor.ready && editor.session?.noteId == target.id }
        #expect((try library.store.note(id: source.id)?.text ?? "").contains("Queued edit"))
    }

    @Test func backupDrainsQueuedEditorCommandBeforeClosingPage() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Original")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));return window.__i1cReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Backup edit")])
        _ = try await library.makeBackup()
        #expect((try library.store.note(id: source.id)?.text ?? "").contains("Backup edit"))
    }

    @Test func syncCommitDrainsQueuedEditorCommandBeforeMutation() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Original")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));return window.__i1cReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Sync edit")])
        _ = try await MobileSyncCommitCoordinator(library: library).commit { .unchanged }
        #expect((try library.store.note(id: source.id)?.text ?? "").contains("Sync edit"))
    }

    @Test func deletingPreviouslyOpenedNoteDrainsCurrentEditorFirst() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let previous = try library.store.create(text: "Previously opened")
        let current = try library.store.create(text: "Currently typing")
        library.selectedID = previous.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == previous.id }
        library.selectedID = current.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == current.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));return window.__i1cReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Must survive")])
        let database = library.database
        _ = try await MobileSyncCommitCoordinator(library: library).commit(scope: .note(previous.id)) {
            try database.pool.write { db in
                try db.execute(sql: "UPDATE note SET deletedAt = 1 WHERE id = ?", arguments: [previous.id])
            }
            return .applied
        }
        #expect(try library.store.note(id: previous.id)?.deletedAt != nil)
        #expect((try library.store.note(id: current.id)?.text ?? "").contains("Must survive"))
    }

    @Test func unrelatedSyncCommitsDoNotFreezeOrInterruptTyping() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Original")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        editor.webView.becomeFirstResponder()
        _ = try await editor.webView.evaluateJavaScript("window.__i1cFreezeCount=0;window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')window.__i1cFreezeCount++;return window.__i1cReceive(m)};document.querySelector('.cm-content').focus();true")
        let focusedBefore = try await editor.webView.evaluateJavaScript("document.activeElement === document.querySelector('.cm-content')") as? Bool
        #expect(focusedBefore == true)
        let coordinator = MobileSyncCommitCoordinator(library: library)
        for index in 0..<8 {
            editor.command(.insertText, args: ["text": .string("x")])
            _ = try await coordinator.commit(scope: index.isMultiple(of: 2) ? .note("another-note-\(index)") : .unrelated) { .unchanged }
        }
        try await waitFor { editor.session?.text.filter { $0 == "x" }.count == 8 }
        #expect((try await editor.webView.evaluateJavaScript("window.__i1cFreezeCount") as? Int) == 0)
        #expect((try await editor.webView.evaluateJavaScript("document.activeElement === document.querySelector('.cm-content')") as? Bool) == true)
    }

    @Test func noteSwitchWaitsForBusySyncDrain() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Source")
        let target = try library.store.create(text: "Target")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen=false;window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__i1cFreezeSeen=true;await new Promise(r=>setTimeout(r,700))}return window.__i1cReceive(m)};true")
        let sync = Task { try await MobileSyncCommitCoordinator(library: library).commit(scope: .note(source.id)) { .unchanged } }
        for _ in 0..<100 {
            if (try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true)
        library.selectedID = target.id
        _ = try await sync.value
        try await waitFor { editor.session?.noteId == target.id }
        #expect(editor.sceneNavigation?.selectedID == target.id)
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test func lockingNoteDrainsQueuedEditorCommandBeforeEncrypting() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        try await library.unlockNotes(password: "simulated-test-password", createPassword: true)
        let source = try library.store.create(text: "Original")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));return window.__i1cReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Locked edit")])
        let lock = try #require(library.lockSelectedNoteForTesting)
        lock()
        try await waitFor { try library.store.note(id: source.id)?.isLocked == true }
        try await library.unlockNotes(password: "simulated-test-password")
        #expect((try library.privateAccess?.note(id: source.id)?.text ?? "").contains("Locked edit"))
    }

    @Test func unavailableEditorDoesNotBlockLockingNote() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        try await library.unlockNotes(password: "simulated-test-password", createPassword: true)
        let note = try library.store.create(text: "Protect this note")
        library.selectedID = note.id
        try await waitFor { editor.ready && editor.session?.noteId == note.id }
        library.drainEditorForLibraryOperation = { throw MobileEditorDrainError.unavailable }
        let lock = try #require(library.lockSelectedNoteForTesting)
        lock()
        try await waitFor { try library.store.note(id: note.id)?.isLocked == true }
        try await library.unlockNotes(password: "simulated-test-password")
        #expect(try library.privateAccess?.note(id: note.id)?.text == "Protect this note")
    }
    #endif

    /// Holds every `changes` message without a reply, so typed text stays unacknowledged in the page.
    private final class UnackedChanges: NSObject, WKScriptMessageHandlerWithReply {
        let editor: MobileEditor
        var held: [(Any?, String?) -> Void] = []
        /// With `holdsRecoveryText`, the page's full-text copy also waits until `releaseRecovery()`.
        var holdsRecoveryText = false
        var heldRecovery: [() -> Void] = []
        init(_ editor: MobileEditor) { self.editor = editor }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            let type = (message.body as? [String: Any])?["type"] as? String
            if type == "changes" { held.append(replyHandler); return }
            if holdsRecoveryText, type == "recoveryText" {
                heldRecovery.append { self.editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
                return
            }
            editor.userContentController(controller, didReceive: message, replyHandler: replyHandler)
        }
        func releaseRecovery() { let replies = heldRecovery; heldRecovery = []; replies.forEach { $0() } }
    }

    /// N16: the page ignores the freeze and holds typed text the host never acknowledged. The switch
    /// still goes through the full-text fallback: exactly one recovery copy with the page's text.
    @Test func unresponsiveSwitchSavesDifferingBrowserTextAsOneCopy() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Keep original")
        let target = try library.store.create(text: "Destination")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        let page = editor.webView, unacked = UnackedChanges(editor), controller = page.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(unacked, contentWorld: .page, name: "bridge")
        defer {
            // Leave nothing pending for the next test: answer the held replies, restore the handler.
            for reply in unacked.held { reply(nil, "test ended") }
            controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
            controller.addScriptMessageHandler(editor, contentWorld: .page, name: "bridge")
        }
        _ = try await page.evaluateJavaScript("window.__i1bReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')return;return window.__i1bReceive(m)}; true")
        // Typed in the page itself (no host command in flight), so only the edit's ack is missing.
        _ = try await page.evaluateJavaScript("(()=>{const v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({changes:{from:0,insert:'typed '}});return true})()")
        try await waitFor { !unacked.held.isEmpty }
        let browserText = try #require(try await page.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.state.doc.toString()") as? String)
        #expect(browserText != "Keep original")
        let before = try library.store.allNotes().count
        library.selectedID = target.id
        // The freeze wait (3 s) and the full-text fallback run first; allow up to 60 s under load.
        for _ in 0..<1200 where !(editor.ready && editor.session?.noteId == target.id) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.ready && editor.session?.noteId == target.id,
                "error \(library.errorMessage ?? "-"), selected target \(editor.sceneNavigation?.selectedID == target.id)")
        #expect(try library.store.note(id: source.id)?.text == "Keep original")
        #expect(try library.store.allNotes().filter { $0.text == browserText }.count == 1)
        #expect(try library.store.allNotes().count == before + 1)
    }

    /// F1: the app locks while the switch's full-text fallback is under way. The fallback keeps its
    /// permit, so the page's unacknowledged text still ends up as exactly one recovery copy.
    @Test func appLockDuringSwitchFallbackStillSavesTheBrowserText() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        library.enableAppLockForTesting()
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Keep original")
        let target = try library.store.create(text: "Destination")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        let page = editor.webView, unacked = UnackedChanges(editor), controller = page.configuration.userContentController
        unacked.holdsRecoveryText = true
        controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        controller.addScriptMessageHandler(unacked, contentWorld: .page, name: "bridge")
        defer {
            unacked.releaseRecovery()
            for reply in unacked.held { reply(nil, "test ended") }
            controller.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
            controller.addScriptMessageHandler(editor, contentWorld: .page, name: "bridge")
        }
        _ = try await page.evaluateJavaScript("window.__f1Receive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')return;return window.__f1Receive(m)}; true")
        _ = try await page.evaluateJavaScript("(()=>{const v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({changes:{from:0,insert:'typed '}});return true})()")
        try await waitFor { !unacked.held.isEmpty }
        let browserText = try #require(try await page.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.state.doc.toString()") as? String)
        let before = try library.store.allNotes().count
        library.selectedID = target.id
        // After the freeze wait (3 s) the fallback sends the page text; lock before the host sees it.
        try await waitFor { !unacked.heldRecovery.isEmpty }
        library.lockApplication()
        #expect(library.appLocked)
        unacked.releaseRecovery()
        for _ in 0..<200 {
            if try library.store.allNotes().contains(where: { $0.text == browserText }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try library.store.allNotes().filter { $0.text == browserText }.count == 1)
        #expect(try library.store.allNotes().count == before + 1)
        #expect(try library.store.note(id: source.id)?.text == "Keep original")
    }

    /// F2 + F4: a page that never answers the full-text fallback cannot hold the switch past its
    /// deadline, and a note tapped meanwhile is opened afterwards.
    @Test func hungFallbackEndsAtItsDeadlineAndOpensTheNoteTappedMeanwhile() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Keep original")
        let target = try library.store.create(text: "Destination")
        let later = try library.store.create(text: "Tapped meanwhile")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        let page = editor.webView
        _ = try await page.evaluateJavaScript("window.__f2={receive:window.__baerchen.receive,preserve:window.__baerchen.preserveForPrivacy,called:false};window.__baerchen.receive=function(m){if(m.type==='freezeForClose')return;return window.__f2.receive(m)};window.__baerchen.preserveForPrivacy=function(){window.__f2.called=true;return new Promise(()=>{})};true")
        library.selectedID = target.id
        var called = false
        for _ in 0..<400 where !called {
            called = (try await page.evaluateJavaScript("window.__f2.called") as? Bool) == true
            if !called { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(called, "the switch reached the full-text fallback")
        // The page works again, but the hung call never answers; the user taps another note.
        _ = try await page.evaluateJavaScript("window.__baerchen.receive=window.__f2.receive;window.__baerchen.preserveForPrivacy=window.__f2.preserve;true")
        library.selectedID = later.id
        for _ in 0..<800 where !(editor.ready && editor.session?.noteId == later.id) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.ready && editor.session?.noteId == later.id, "error \(library.errorMessage ?? "-")")
        #expect(try library.store.note(id: source.id)?.text == "Keep original")
    }

    @Test func ordinarySwitchWithUnresponsiveEditorKeepsOriginalNote() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Keep original")
        let target = try library.store.create(text: "Destination")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1bReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')return;return window.__i1bReceive(m)}; true")
        let before = try library.store.allNotes().count
        library.selectedID = target.id
        // Since P1 (e3268f62) a page that does not answer the freeze still switches once the host has
        // confirmed the page's full text (identical here, so no copy). The original note is kept as is.
        try await waitFor { editor.ready && editor.session?.noteId == target.id }
        #expect(editor.sceneNavigation?.selectedID == target.id)
        #expect(try library.store.note(id: source.id)?.text == "Keep original")
        #expect(try library.store.allNotes().count == before)
    }

    @Test func switchingWhileEditorIsBootingDoesNotTrapSelection() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "First")
        let target = try library.store.create(text: "Second")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.session?.noteId == source.id }
        editor.webViewWebContentProcessDidTerminate(editor.webView)
        library.selectedID = target.id
        try await waitFor { editor.session?.noteId == target.id }
        #expect(editor.sceneNavigation?.selectedID == target.id)
    }

    @Test func unavailableFreezeReplyDoesNotTrapSelection() async throws {
        for reason in ["halted", "notShown"] {
            let library = try library()
            defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
            let editor = MobileEditor(library: library)
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(250))
            let source = try library.store.create(text: "First")
            let target = try library.store.create(text: "Second")
            library.selectedID = source.id
            try await waitFor { editor.ready && editor.session?.noteId == source.id }
            let script = "window.__i1bReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose'){window.webkit.messageHandlers.bridge.postMessage({type:'frozenForClose',requestId:m.requestId,noteId:m.noteId,ok:false,editedSinceLoad:false,reason:'\(reason)'});return;}return window.__i1bReceive(m)}; true"
            _ = try await editor.webView.evaluateJavaScript(script)
            library.selectedID = target.id
            try await waitFor { editor.session?.noteId == target.id }
            #expect(editor.sceneNavigation?.selectedID == target.id)
        }
    }

    @Test func transientResignOnlyShieldsWithoutLockingOrClosingEditor() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        let note = try library.store.create(text: "Transient interruption")
        library.selectedID = note.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == note.id }
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        let access = try #require(library.privateAccess)
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == note.id }
        #if DEBUG && targetEnvironment(simulator)
        library.enableAppLockForTesting()
        #endif
        _ = try await editor.webView.evaluateJavaScript("window.__transientFreezeCount=0;window.__transientReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')window.__transientFreezeCount++;return window.__transientReceive(m)};true")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.viewWithTag(0xBAE2026) != nil)
        #expect(!library.appLocked)
        #expect(library.privateAccess === access)
        #expect(editor.session?.noteId == note.id)
        #expect((try await editor.webView.evaluateJavaScript("window.__transientFreezeCount") as? Int) == 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @Test func sceneAndNotificationBackgroundSignalsDrainOnlyOnce() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let lifecycle = CaptureTestLifecycle()
        window.rootViewController = UIHostingController(rootView: CaptureTestLifecycleView(library: library, editor: editor, lifecycle: lifecycle))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        let note = try library.store.create(text: "One background drain")
        library.selectedID = note.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == note.id }
        _ = try await editor.webView.evaluateJavaScript("window.__backgroundFreezeCount=0;window.__backgroundReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__backgroundFreezeCount++;await new Promise(r=>setTimeout(r,300))}return window.__backgroundReceive(m)};true")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        lifecycle.phase = .background
        try await Task.sleep(for: .seconds(2))
        // A second notification after the first drain finished must also be deduplicated.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect((try await editor.webView.evaluateJavaScript("window.__backgroundFreezeCount") as? Int) == 1)
        #expect(editor.session?.noteId == note.id)
        #expect(try library.store.note(id: note.id)?.text == "One background drain")
    }

    @Test func backgroundWithoutAppLockDrainsQueuedEditorCommand() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Original")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1bFreezeSeen=false;window.__i1bReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));if(m.type==='freezeForClose')window.__i1bFreezeSeen=true;return window.__i1bReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Background edit")])
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .seconds(2))
        #expect((try await editor.webView.evaluateJavaScript("window.__i1bFreezeSeen") as? Bool) == true)
        #expect((try library.store.note(id: source.id)?.text ?? "").contains("Background edit"))
    }

    @Test func backgroundDrainDoesNotResumeSelectionWhileApplicationIsBackgrounded() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        var applicationState = UIApplication.State.active
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor, applicationState: { applicationState }).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Source")
        let target = try library.store.create(text: "Target")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen=false;window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__i1cFreezeSeen=true;await new Promise(r=>setTimeout(r,1000))}return window.__i1cReceive(m)}; true")
        applicationState = .background
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        for _ in 0..<100 {
            if (try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true)
        try library.reveal(target.id)
        try await Task.sleep(for: .milliseconds(200))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .seconds(2))
        #expect(editor.sceneNavigation?.selectedID == source.id)
        #expect(editor.session?.noteId == source.id)
        applicationState = .active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitFor { editor.session?.noteId == target.id }
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test func appLockDrainsQueuedEditorCommand() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer {
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            window.isHidden = true
        }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Original")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        library.enableAppLockForTesting()
        _ = try await editor.webView.evaluateJavaScript("window.__i1bReceive=window.__baerchen.receive; window.__baerchen.receive=async function(m){if(m.type==='applyCommand')await new Promise(r=>setTimeout(r,500));return window.__i1bReceive(m)}; true")
        editor.command(.insertText, args: ["text": .string("Locked edit")])
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .seconds(2))
        #expect(library.appLocked)
        #expect((try library.store.note(id: source.id)?.text ?? "").contains("Locked edit"))
    }

    @Test func appLockClosesVaultWhenDrainTimesOut() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Keep on timeout")
        try await library.unlockNotes(password: "simulated-test-password", createPassword: true)
        #expect(library.privateAccess != nil)
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        library.enableAppLockForTesting()
        _ = try await editor.webView.evaluateJavaScript("window.__i1bReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')return;return window.__i1bReceive(m)}; true")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .seconds(4))
        #expect(library.appLocked)
        #expect(editor.session == nil)
        #expect(library.privateAccess == nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.viewWithTag(0xBAE2026) == nil)
        #expect(try library.store.note(id: source.id)?.text == "Keep on timeout")
    }

    @Test func appLockWaitsForAlreadyRunningEditorDrain() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Keep during lock")
        let target = try library.store.create(text: "Destination")
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        library.enableAppLockForTesting()
        _ = try await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen=false;window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__i1cFreezeSeen=true;await new Promise(r=>setTimeout(r,1000))}return window.__i1cReceive(m)}; true")
        library.selectedID = target.id
        for _ in 0..<100 {
            if (try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(library.appLocked)
        #expect(editor.session?.noteId == source.id)
        try await waitFor { editor.session == nil }
        #expect(try library.store.note(id: source.id)?.text == "Keep during lock")
    }

    @Test func privacyCloseDoesNotResumeSelectionWhileApplicationIsBackgrounded() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        var applicationState = UIApplication.State.active
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor, applicationState: { applicationState }).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Source")
        let target = try library.store.create(text: "Target")
        try await library.unlockNotes(password: "simulated-test-password", createPassword: true)
        library.selectedID = source.id
        try await waitFor { editor.ready && editor.editable && editor.session?.noteId == source.id }
        _ = try await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen=false;window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=async function(m){if(m.type==='freezeForClose'){window.__i1cFreezeSeen=true;await new Promise(r=>setTimeout(r,1000))}return window.__i1cReceive(m)}; true")
        applicationState = .background
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        for _ in 0..<100 {
            if (try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try? await editor.webView.evaluateJavaScript("window.__i1cFreezeSeen")) as? Bool == true)
        // Deliver a queued scene-local selection intent, as NavigationLink does.
        // Shared library mutations are correctly forbidden by the active privacy fence.
        let navigation = try #require(editor.sceneNavigation)
        navigation.selectedID = target.id
        try await Task.sleep(for: .milliseconds(200))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitFor { editor.session == nil }
        #expect(editor.sceneNavigation?.selectedID == source.id)
        applicationState = .active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitFor { editor.sceneNavigation?.selectedID == target.id }
    }

    @Test func unlockingReopensSelectedNoteAfterPrivacyClose() async throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { MobilePrivacyShield.uncover(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let note = try library.store.create(text: "Reopen after unlock")
        library.selectedID = note.id
        try await waitFor { editor.ready && editor.session?.noteId == note.id }
        library.enableAppLockForTesting()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitFor { library.appLocked && editor.session == nil }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        library.unlockAppForTesting()
        func webViews(_ view: UIView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        var found = false
        for _ in 0..<600 {
            if let page = webViews(window).first,
               let text = try? await page.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()") as? String,
               text == "Reopen after unlock" { found = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(found)
        #expect(editor.sceneNavigation?.selectedID == note.id)
    }
    #endif

    @Test func rowShowsCapturedMark() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var item = NoteListItem(id: "fixture", title: "Same title", subtitle: "Same body", modifiedAt: .distantPast,
                                createdAt: .distantPast, isPinned: false, isLocked: false, isReadOnly: false,
                                hasAttachments: false, firstImageFilename: nil)
        func render(_ note: NoteListItem) throws -> Data {
            let renderer = ImageRenderer(content: MobileNoteRow(note: note, preferences: MobilePreferences(), paths: paths).frame(width: 320))
            return try #require(renderer.uiImage?.pngData())
        }
        let ordinary = try render(item)
        item.captureSource = .lockscreen
        let captured = try render(item)
        #expect(captured != ordinary, "A captured note must have a visible mark absent from an otherwise identical ordinary row.")
    }
}

@MainActor private final class CaptureTestLifecycle: ObservableObject {
    @Published var phase: ScenePhase = .active
}
@MainActor private struct CaptureTestLifecycleView: View {
    let library: MobileLibrary
    let editor: MobileEditor
    @ObservedObject var lifecycle: CaptureTestLifecycle
    var body: some View {
        MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, lifecycle.phase)
    }
}
