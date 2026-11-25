// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Testing
import UIKit
import WebKit
import SwiftUI
@testable import BaerchenIOS

@Suite(.serialized) @MainActor
struct MobileEditorTests {
    @Test func realWebKitEditsPersistAndRecoverAfterPageTermination() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let id = try library.createNote()
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view = editor.webView
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(id)
        try await wait { editor.ready && editor.editable }
        // Wait for the actual page document, not just the native ready flag.
        try await wait {
            (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.getAttribute('contenteditable')")) as? String == "true"
        }
        let expected = "# Mobile test\nExact **source** 👩‍💻\n#ios"
        editor.command(.insertText, args: ["text": .string(expected)])
        try await wait { editor.session?.text == expected }
        try library.flush()
        #expect(try library.store.note(id: id)?.text == expected)
        editor.webViewWebContentProcessDidTerminate(editor.webView)
        try await wait {
            guard editor.ready else { return false }
            return (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == expected
        }
        #expect(editor.session?.text == expected)
        // A live editor must use the production asynchronous drain before location changes.
        #expect(throws: MobileEditorDrainError.busy) { try library.move(id, to: .archive) }
        let navigation = MobileSceneNavigation(); navigation.selectedID = id
        try await library.moveNotesAfterDraining([id], to: .archive, in: navigation)
        #expect(try library.store.note(id: id)?.location == .archive)
        // Archived notes cannot be mutated by the editor or its formatting toolbar.
        editor.loadNote()
        try await wait { !editor.editable }
        editor.command(.insertText, args: ["text": .string("must not save")])
        try await Task.sleep(for: .milliseconds(200))
        #expect(try library.store.note(id: id)?.text == expected)
    }

    @Test(arguments: [SelectionRange(anchor: 18, head: 18), SelectionRange(anchor: 25, head: 18)])
    func settingTypePreservesMidNoteSelection(selected: SelectionRange) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = "# Selection 😀\nKeep typing here\nAnother paragraph"
        let note = try library.store.create(text: original)
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view = editor.webView
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(note.id)
        try await wait {
            guard editor.ready && editor.editable else { return false }
            return (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == original
        }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({selection:{anchor:\(selected.anchor),head:\(selected.head)}})")
        try await editor.setNoteType(.idea)
        #expect(editor.session?.text == original + "\n\n#idea")
        let selection = try await editor.webView.evaluateJavaScript("(()=>{const s=document.querySelector('.cm-content').cmTile.root.view.state.selection.main;return [s.anchor,s.head]})()")
        #expect(selection as? [Int] == [selected.anchor, selected.head])
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'z',code:'KeyZ',metaKey:true,bubbles:true,cancelable:true}))")
        try await wait { editor.session?.text == original }
        let restored = try await editor.webView.evaluateJavaScript("(()=>{const s=document.querySelector('.cm-content').cmTile.root.view.state.selection.main;return [s.anchor,s.head]})()")
        #expect(restored as? [Int] == [selected.anchor, selected.head])
    }

    @Test func fullShellOpensNewNoteInWebKit() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let id = try library.createNote()
        try await wait { editor.ready && editor.editable && editor.session?.noteId == id }
        #expect(library.errorMessage == nil)
        let value = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.getAttribute('contenteditable')")
        #expect(value as? String == "true")
    }

    @Test func coldShellRestoresSavedSelectionIntoVisibleWebKit() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let expected = "Mobile capture\nA typed note restored after launch."
        let first = try MobileLibrary(paths: paths)
        let id = try first.store.create(text: expected).id
        try first.reveal(id)
        try first.flush()
        try first.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        #expect(library.selectedID == id)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        // This test drives visible foreground navigation; the test host's scene can
        // otherwise report .background even while its test window is mounted.
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await wait {
            guard let webView = mountedWebView(in: window) else { return false }
            return (try? await webView.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == expected
        }
        let webView = try #require(mountedWebView(in: window))
        #expect(webView.bounds.width > 0 && webView.bounds.height > 0)
        #expect(try await webView.evaluateJavaScript("document.querySelector('.cm-content')?.contentEditable") as? String == "true")
        #expect(library.errorMessage == nil)
        let next = try library.store.create(text: "A different selected note")
        try library.reveal(next.id)
        try await wait {
            (try? await mountedWebView(in: window)?.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == next.text
        }
        // A library operation closes the old editor for privacy and replaces it before reopening.
        _ = try await library.makeBackup()
        try await wait {
            guard let replacement = mountedWebView(in: window), replacement !== webView else { return false }
            return (try? await replacement.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == next.text
        }
    }

    private func mountedWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { mountedWebView(in: $0) }.first
    }

    @Test func offscreenDetailCannotStealMountedEditor() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let visible = MobileWebViewContainer()
        let controller = UIViewController()
        controller.view = visible
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        visible.attach(editor)
        #expect(editor.webView.superview === visible)
        let speculative = MobileWebViewContainer()
        speculative.attach(editor)
        #expect(editor.webView.superview === visible)
        #expect(speculative.subviews.isEmpty)
    }

    @Test func inactiveSelectionOpensWhenSceneBecomesActive() async throws {
        try await deferredSelectionOpens(initialPhase: .inactive)
    }

    @Test func backgroundSelectionOpensWhenSceneBecomesActive() async throws {
        try await deferredSelectionOpens(initialPhase: .background)
    }

    @Test func latestSelectionCancelsDeferredBackgroundSelection() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let first = try library.store.create(text: "Keep this note")
        let other = try library.store.create(text: "Do not open this note")
        try library.reveal(first.id)
        let editor = MobileEditor(library: library)
        let navigation = MobileSceneNavigation(restoration: MobileRestoration(noteID: first.id))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation).environment(\.scenePhase, .background))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await wait { editor.sceneNavigation === navigation && library.hasRegisteredSceneWindows }
        #expect(editor.session == nil && !editor.ready, "Cold background scenes must not decrypt/load a page")
        navigation.selectedID = other.id
        try await Task.sleep(for: .milliseconds(500))
        navigation.selectedID = first.id
        try await Task.sleep(for: .milliseconds(500))
        #expect(editor.session == nil, "Changing a pending background target must not open WebKit")
        host.rootView = MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation).environment(\.scenePhase, .active)
        try await Task.sleep(for: .seconds(3))
        #expect(navigation.selectedID == first.id)
        #expect(editor.session?.noteId == first.id)
    }

    private func deferredSelectionOpens(initialPhase: ScenePhase) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let first = try library.store.create(text: "Initially displayed")
        let target = try library.store.create(text: "Open after foreground")
        try library.reveal(first.id)
        let editor = MobileEditor(library: library)
        let navigation = MobileSceneNavigation(restoration: MobileRestoration(noteID: first.id))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation).environment(\.scenePhase, initialPhase))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await wait { editor.sceneNavigation === navigation && library.hasRegisteredSceneWindows }
        #expect(editor.session == nil && !editor.ready, "Cold nonactive scenes must not decrypt/load a page")
        navigation.selectedID = target.id
        try await Task.sleep(for: .milliseconds(500))
        #expect(editor.session == nil, "Deferred intent must remain unopened until this scene activates")
        host.rootView = MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation).environment(\.scenePhase, .active)
        try await wait {
            guard navigation.selectedID == target.id, editor.session?.noteId == target.id,
                  let page = mountedWebView(in: window) else { return false }
            return (try? await page.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == target.text
        }
    }

    @Test func departingDetailHandsPageBackToRemainingMountedHost() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let remaining = MobileWebViewContainer(frame: controller.view.bounds)
        controller.view.addSubview(remaining)
        remaining.attach(editor)
        let departing = MobileWebViewContainer(frame: controller.view.bounds)
        controller.view.addSubview(departing)
        departing.attach(editor)
        remaining.layoutIfNeeded()
        #expect(editor.webView.superview === departing)
        // This must invalidate the remaining host's layout; no timer or unrelated UI update.
        departing.removeFromSuperview()
        remaining.layoutIfNeeded()
        #expect(editor.webView.superview === remaining)
        #expect(editor.webView.window === window)
        #expect(departing.subviews.isEmpty)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for the real iOS editor")
        throw CocoaError(.coderReadCorrupt)
    }
}
