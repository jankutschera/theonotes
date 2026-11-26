// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import TheoNotesAutomation
import Foundation
import Testing
import UIKit
@testable import BaerchenIOS

@Suite @MainActor struct MobileXCallbackTests {
    @Test(.serialized, arguments: ["create", "open-note", "pin"])
    func closedWindowDrainKeepsWriteSuccessButRejectsFailedNavigation(action: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let original = try library.store.create(text: "# Closing window")
        let navigation = MobileSceneNavigation(), editor = MobileEditor(library: library)
        navigation.selectedID = original.id
        editor.sceneNavigation = navigation
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
        var detaching: Task<Void, any Error>?
        defer {
            detaching?.cancel(); window.isHidden = true; try? editor.closeForPrivacy()
            try? library.close(); MobileAutomationToken.revoke(paths)
            try? FileManager.default.removeItem(at: paths.root); previous?.makeKey()
        }
        try editor.open(original.id)
        for _ in 0..<600 where !editor.ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(editor.ready)
        _ = try await editor.webView.evaluateJavaScript("window.__f1Receive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose'){window.__f1Held=m;return;}return window.__f1Receive(m)};true")
        var callbacks: [URL] = []
        let controller = MobileXCallbackController(library: library, openURL: { callbacks.append($0) })
        controller.beforeResultDeliveryForTesting = {
            detaching = Task { try await library.detachScene(id: navigation.id) }
            for _ in 0..<300 {
                if (try await editor.webView.evaluateJavaScript("!!window.__f1Held") as? Bool) == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require((try await editor.webView.evaluateJavaScript("!!window.__f1Held") as? Bool) == true)
            try #require(library.sceneEditorAdmissionBlocked)
        }
        let parameters = action == "create" ? "title=Accepted&text=Exact" : "id=" + original.id + (action == "pin" ? "&pin=yes" : "")
        let route = action == "pin" ? "open-note" : action
        await controller.handle(URL(string: "baerchen://x-callback-url/" + route + "?" + parameters + "&x-success=shortcuts://success&x-error=shortcuts://error")!)
        // Release the real detach before assertions/cleanup, including on an old implementation failure.
        _ = try await editor.webView.evaluateJavaScript("window.__baerchen.receive=window.__f1Receive;window.__f1Receive(window.__f1Held);true")
        try await detaching?.value
        let notes = try library.store.allNotes()
        #expect(notes.count == (action == "create" ? 2 : 1))
        #expect(callbacks.count == 1 && callbacks.first?.host == (action == "open-note" ? "error" : "success"))
        if action == "create" {
            let callback = try #require(callbacks.first)
            let id = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "identifier" })?.value)
            #expect(try library.store.note(id: id)?.text == "# Accepted\nExact")
            #expect(library.errorMessage?.contains("saved") == true)
        }
        if action == "pin" {
            #expect(try library.store.note(id: original.id)?.isPinnedGlobal == true)
            #expect(library.errorMessage?.contains("saved") == true)
        }
        #expect(navigation.selectedID == original.id && navigation.pendingCallbackNavigation == nil)
        try await library.closeAfterStopping()
    }

    private struct RestoreDuringFetch: URLFetcher {
        let restore: @MainActor @Sendable () async throws -> Void
        func fetch(_ url: URL) async throws -> (data: Data, suggestedName: String?) {
            try await restore()
            return (Data("<h1>Stale fetched page</h1>".utf8), "page.html")
        }
    }

    @Test(arguments: ["yes", "no"])
    func fetchCrossingRestoreCannotCreateInRestoredLibrary(wait: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        var failure: (any Error)?
        do {
            let keep = try library.store.create(text: "# Keep")
            let backup = try await library.makeBackup()
            var callbacks: [URL] = []
            let fetcher = RestoreDuringFetch {
                _ = try await library.restoreBackup(backup, mode: .replaceAll, backupPassword: nil, currentPassword: nil)
            }
            let controller = MobileXCallbackController(library: library, openURL: { callbacks.append($0) }, fetcher: fetcher)
            await controller.handle(URL(string: "baerchen://x-callback-url/grab-url?url=https://example.com/page&wait=" + wait + "&x-success=shortcuts://success&x-error=shortcuts://error")!)
            #expect(try library.store.allNotes().map(\.id) == [keep.id])
            #expect(callbacks.count == 1)
            #expect(callbacks.first?.host == (wait == "yes" ? "error" : "success"))
            #expect(library.selectedID == nil && library.pendingCallbackNavigation == nil)
        } catch { failure = error }
        do { try await library.closeAfterStopping() } catch { if failure == nil { failure = error } }
        MobileAutomationToken.revoke(paths)
        try? FileManager.default.removeItem(at: paths.root)
        if let failure { throw failure }
    }

    @Test(arguments: ["create?title=Accepted&text=Preserved", "search?search=stale-query"])
    func acceptedExecutionCrossingRestoreKeepsSuccessWithoutReplayingNavigation(action: String) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        var failure: (any Error)?
        do {
            let keep = try library.store.create(text: "# Keep")
            let backup = try await library.makeBackup()
            let left = MobileSceneNavigation(), right = MobileSceneNavigation()
            let editors = [MobileEditor(library: library), MobileEditor(library: library)]
            for (nav, editor) in zip([left, right], editors) {
                try library.registerScene(id: nav.id, editor: editor, navigation: nav, observation: nil, activity: .active)
                nav.selectedID = keep.id
            }
            left.scope = .pinned; left.query = "left query"
            right.scope = .archive; right.query = "right query"
            library.markSceneFrontmost(id: right.id)
            var callbacks: [URL] = []
            let controller = MobileXCallbackController(library: library, openURL: { callbacks.append($0) })
            controller.beforeResultDeliveryForTesting = {
                _ = try await library.restoreBackup(backup, mode: .merge, backupPassword: nil, currentPassword: nil)
            }
            await controller.handle(URL(string: "baerchen://x-callback-url/" + action + "&x-success=shortcuts://success&x-error=shortcuts://error")!)
            #expect(callbacks.count == 1 && callbacks.first?.host == "success")
            #expect(left.selectedID == keep.id && left.scope == .pinned && left.query == "left query")
            #expect(right.selectedID == keep.id && right.scope == .archive && right.query == "right query")
            #expect(left.pendingCallbackNavigation == nil && right.pendingCallbackNavigation == nil)
            if action.hasPrefix("create") {
                let callback = try #require(callbacks.first)
                let id = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "identifier" })?.value)
                #expect(try library.store.note(id: id)?.text == "# Accepted\nPreserved")
            }
            for nav in [left, right] { try await library.detachScene(id: nav.id) }
        } catch { failure = error }
        do { try await library.closeAfterStopping() } catch { if failure == nil { failure = error } }
        MobileAutomationToken.revoke(paths)
        try? FileManager.default.removeItem(at: paths.root)
        if let failure { throw failure }
    }

    @Test func creationCallbackAndOpenNavigationUseOnlyTemporaryLibrary() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); MobileAutomationToken.revoke(paths); try? FileManager.default.removeItem(at: paths.root) }
        var opened: [URL] = []
        let controller = MobileXCallbackController(library: library, openURL: { opened.append($0) })
        var url = URLComponents(string: "baerchen://x-callback-url/create")!
        url.queryItems = [URLQueryItem(name: "title", value: "Caller 🐻"), URLQueryItem(name: "text", value: "Exact **text**"), URLQueryItem(name: "x-success", value: "shortcuts://done")]
        await controller.handle(url.url!)
        let callback = try #require(opened.first)
        let id = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "identifier" })?.value)
        #expect(library.selectedID == id)
        #expect(try library.store.note(id: id)?.text == "# Caller 🐻\nExact **text**")
        #expect(library.pendingCallbackNavigation?.noteID == id)
    }
    /// The app locks after the note was saved, the caller gets `x-error` and runs the
    /// same request again; it gets the first note back, and only an answered request repeats.
    @Test func retryAfterLockingReturnsTheFirstNoteInsteadOfASecond() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); MobileAutomationToken.revoke(paths); try? FileManager.default.removeItem(at: paths.root) }
        library.enableAppLockForTesting()
        var opened: [URL] = []
        let controller = MobileXCallbackController(library: library, openURL: { opened.append($0) })
        let url = URL(string: "theonotes://x-callback-url/create?title=Once&text=Body&x-success=shortcuts://success&x-error=shortcuts://error")!
        func identifier(_ callback: URL?) -> String? {
            callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "identifier" })?.value }
        }
        controller.beforeResultDeliveryForTesting = { library.lockApplication() }
        await controller.handle(url)
        #expect(opened.last?.host == "error")
        #expect(try library.store.allNotes().count == 1)
        controller.beforeResultDeliveryForTesting = nil
        library.unlockAppForTesting()
        await controller.handle(url)
        #expect(opened.last?.host == "success")
        let first = try #require(identifier(opened.last))
        #expect(try library.store.allNotes().map(\.id) == [first])
        await controller.handle(url)
        #expect(opened.last?.host == "success" && identifier(opened.last) != first)
        #expect(try library.store.allNotes().count == 2)
    }

    @Test func copiedNoteLinksAndLegacyLinksOpenTheSameNote() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let capture = try MobileShortcutCapture(library: library).capture(inputs: [.text("Link destination")])
        #expect(capture.link.scheme == AppIdentity.current.urlSchemes[0])
        let controller = MobileXCallbackController(library: library, openURL: { _ in })
        for scheme in AppIdentity.production.urlSchemes + AppIdentity.dev.urlSchemes {
            var components = URLComponents(url: capture.link, resolvingAgainstBaseURL: false)!
            components.scheme = scheme
            library.selectedID = nil
            library.pendingCallbackNavigation = nil
            await controller.handle(components.url!)
            #expect(library.selectedID == capture.note.id)
            #expect(library.pendingCallbackNavigation?.noteID == capture.note.id)
            #expect(library.errorMessage == nil)
        }
    }

    @Test func invalidTokenFailsBeforeWritesAndRotationInvalidatesOldTokens() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); MobileAutomationToken.revoke(paths); try? FileManager.default.removeItem(at: paths.root) }
        let old = try MobileAutomationToken.generate(paths), current = try MobileAutomationToken.generate(paths)
        #expect(old != current)
        #expect(try MobileAutomationToken.load(paths) == current)
        var opened: [URL] = []
        let controller = MobileXCallbackController(library: library, openURL: { opened.append($0) })
        var url = URLComponents(string: "baerchen://x-callback-url/create")!
        url.queryItems = [URLQueryItem(name: "text", value: "Must not be created"), URLQueryItem(name: "token", value: old), URLQueryItem(name: "x-error", value: "shortcuts://error")]
        await controller.handle(url.url!)
        #expect(try library.store.allNotes().isEmpty)
        #expect(opened.first?.host == "error")
    }
    @Test func waitNoRejectsMissingOrUnsafeCaptureURLBeforeSuccess() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        var opened: [URL] = []
        let controller = MobileXCallbackController(library: library, openURL: { opened.append($0) })
        for source in [nil, "file:///private/input"] as [String?] {
            var url = URLComponents(string: "baerchen://x-callback-url/grab-url")!
            url.queryItems = [URLQueryItem(name: "wait", value: "no"), URLQueryItem(name: "x-success", value: "shortcuts://success"), URLQueryItem(name: "x-error", value: "shortcuts://error")]
            if let source { url.queryItems?.append(URLQueryItem(name: "url", value: source)) }
            await controller.handle(url.url!)
        }
        #expect(opened.count == 2)
        #expect(opened.allSatisfy { $0.host == "error" })
        #expect(try library.store.allNotes().isEmpty)
    }
    @Test func globalTagNavigationClearsWorkspaceAndTagRewritesFollowIt() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        _ = try library.store.create(text: "# Work\n#work/team")
        _ = try library.store.create(text: "# Home\n#home")
        try library.enterWorkspace("work")
        let controller = MobileXCallbackController(library: library, openURL: { _ in })
        await controller.handle(URL(string: "baerchen://x-callback-url/open-tag?name=home")!)
        #expect(library.workspace == nil)
        #expect(library.scope == .tag("home"))
        try library.enterWorkspace("work/team")
        await controller.handle(URL(string: "baerchen://x-callback-url/rename-tag?name=work&new_name=projects")!)
        #expect(library.workspace?.path == "projects/team")
        #expect(library.scope == .tag("projects"))
        #expect(library.tagUndo != nil)
        await controller.handle(URL(string: "baerchen://x-callback-url/delete-tag?name=projects")!)
        #expect(library.workspace == nil)
        #expect(library.scope == .notes)
    }
    @Test func recoveryTokenSurvivesContainerRelocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("Original"), moved = root.appendingPathComponent("Moved")
        let id = UUID().uuidString.lowercased(), name = "Library-Recovery-" + id
        let base = AppPaths(root: original.appendingPathComponent("Library"))
        let paths = AppPaths(root: original.appendingPathComponent(name))
        try base.createDirectories(); try paths.createDirectories()
        try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "origin": "Library"]).write(to: paths.root.appendingPathComponent(".sync-recovery-library.json"))
        let token = try MobileAutomationToken.generate(paths)
        try FileManager.default.moveItem(at: original, to: moved)
        let relocated = AppPaths(root: moved.appendingPathComponent(name))
        defer { MobileAutomationToken.revoke(relocated); try? FileManager.default.removeItem(at: root) }
        #expect(try MobileAutomationToken.load(relocated) == token)
    }

}
