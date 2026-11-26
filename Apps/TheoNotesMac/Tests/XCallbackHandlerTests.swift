// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesAutomation
import TheoNotesCore
import Foundation
import GRDB
import OSLog
import Testing
@testable import TheoNotes

/// M5 Task 14: `theonotes://x-callback-url/…` (and the older `baerchen://`) in the app. Libraries are throw-away folders under /tmp
/// and callbacks go to a spy: nothing here opens a real URL, touches the real library or reaches a
/// running Theo Notes.
@MainActor
@Suite struct XCallbackHandlerTests {
    typealias Env = AppSocketServerTests.Env

    final class Spy {
        var urls: [URL] = []
    }

    private func handler(_ env: Env, _ spy: Spy) -> XCallbackHandler {
        XCallbackHandler(
            app: env.app, openURL: { spy.urls.append($0) },
            context: .fixed(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func url(_ action: String, _ items: [(String, String)] = [], scheme: String = "theonotes") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "x-callback-url"
        components.path = "/" + action
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    private func token(_ env: Env) throws -> String {
        try AutomationToken.ensure(TheoNotesCore.Settings(db: env.environment.database))
    }

    private func parameters(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private func selectRanges(_ page: FakeEditorPage) -> [HostToEditorMessage] {
        page.delivered.filter { if case .selectRange = $0 { true } else { false } }
    }

    // MARK: - Opening notes

    @Test func createThenOpenNoteSelectsItInTheFrontmostMainWindow() async throws {
        let env = try Env()
        let spy = Spy()
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        let token = try token(env)
        handler(env, spy).handle(
            url("create", [("title", "XC Test"), ("text", "hello"), ("token", token), ("x-success", "shortcuts://done")]))

        let callback = try #require(spy.urls.first)
        let id = try #require(parameters(callback)["identifier"])
        #expect(parameters(callback)["title"]?.contains("XC Test") == true)
        let note = try #require(try env.store.note(id: id))
        #expect(note.text.contains("hello"))
        #expect(main.model.focusedNoteID == id)
        #expect(editor.session?.noteId == id)
        #expect(spy.urls.count == 1)
    }

    /// An answered create repeats; one whose answer never went out gets its first note.
    @Test func sameCreateTwiceMakesTwoNotesOnlyWhenTheFirstWasAnswered() async throws {
        let env = try Env()
        let spy = Spy()
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        let create = url("create", [("text", "Retry me"), ("x-success", "shortcuts://done")])
        func ids() throws -> [String] { try env.store.allNotes().filter { $0.text == "Retry me" }.map(\.id) }

        let answered = handler(env, spy)
        answered.handle(create)
        answered.handle(create)
        #expect(spy.urls.count == 2)
        #expect(try ids().count == 2)

        let withheld = handler(env, spy)
        let before = Set(try ids())
        withheld.stopsBeforeAnswerForTesting = true
        withheld.handle(create)
        #expect(spy.urls.count == 2)
        let first = try #require(Set(try ids()).subtracting(before).first)
        withheld.stopsBeforeAnswerForTesting = false
        withheld.handle(create)
        #expect(try ids().count == 3)
        #expect(parameters(try #require(spy.urls.last))["identifier"] == first)
    }

    @Test func openNoteResolvesTheColdLaunchSelectionAndOpensTheNote() async throws {
        let env = try Env()
        let spy = Spy()
        let id = try env.store.create(text: "😀 abc").id
        let (main, _, page) = try env.mainWindow()
        defer { main.close() }
        handler(env, spy).handle(url("open-note", [("id", id), ("selection_text", "abc")]))
        #expect(main.model.focusedNoteID == id)
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 3, head: 6)])

        // By UTF-8 byte range.
        page.delivered = []
        handler(env, spy).handle(url("open-note", [("id", id), ("selection_offset", "5"), ("selection_length", "2")]))
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 3, head: 5)])

        // A selection that no longer fits still opens the note, without a selection.
        page.delivered = []
        handler(env, spy).handle(url("open-note", [("id", id), ("selection_text", "zzz")]))
        #expect(main.model.focusedNoteID == id)
        #expect(selectRanges(page).isEmpty)
        #expect(spy.urls.isEmpty)
    }

    @Test func showWindowNoDoesNotActivate() async throws {
        let env = try Env()
        let spy = Spy()
        let id = try env.store.create(text: "hello").id
        let (main, _, _) = try env.mainWindow()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        main.attach(window: window)
        defer {
            main.close()
            window.close()
        }
        var activations = 0
        env.app.activate = { activations += 1 }

        handler(env, spy).handle(url("open-note", [("id", id), ("show_window", "no")]))
        #expect(main.model.focusedNoteID == id)
        #expect(activations == 0)
        #expect(!window.isVisible)

        handler(env, spy).handle(url("open-note", [("id", id)]))
        #expect(activations == 1)
        #expect(window.isVisible)
    }

    @Test func openNoteWithoutAnyWindowWaitsForTheFirstMainWindow() async throws {
        let env = try Env()
        let spy = Spy()
        let id = try env.store.create(text: "hello").id
        var requests: [WindowRequest] = []
        env.app.openWindowRequest = { requests.append($0) }
        handler(env, spy).handle(url("open-note", [("id", id)]))
        #expect(requests == [.main])
        let (editor, _) = try env.editor()
        let main = env.app.makeMainWindow(editor: editor)
        defer { main.close() }
        #expect(main.model.focusedNoteID == id)
    }

    // MARK: - Callbacks

    /// The app registers both schemes of its identity (the dev build its own pair),
    /// and a link copied under the old one still runs.
    @Test func linksCopiedBeforeTheRenameStillWork() async throws {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        #expect(schemes == Set(AppIdentity.current.urlSchemes))

        let env = try Env()
        let spy = Spy()
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        let token = try token(env)
        handler(env, spy).handle(url(
            "create", [("text", "old link"), ("token", token), ("x-success", "shortcuts://done")], scheme: "baerchen"))
        #expect(spy.urls.count == 1)
        #expect(parameters(spy.urls[0])["identifier"] != nil)
    }

    @Test func successCallbackOpenedOnlyForAllowedSchemes() async throws {
        let env = try Env()
        let spy = Spy()
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        let token = try token(env)

        handler(env, spy).handle(
            url("create", [("text", "one"), ("token", token), ("x-success", "shortcuts://run-shortcut?name=Done")]))
        #expect(spy.urls.count == 1)
        #expect(spy.urls[0].scheme == "shortcuts")
        #expect(parameters(spy.urls[0])["name"] == "Done")
        #expect(parameters(spy.urls[0])["identifier"] != nil)

        spy.urls = []
        for blocked in ["https://evil.example/hook", "http://evil.example", "file:///etc/hosts", "javascript:alert(1)"] {
            handler(env, spy).handle(url("create", [("text", "two"), ("token", token), ("x-success", blocked)]))
        }
        #expect(spy.urls.isEmpty)
        // The notes were still made: only the callback is dropped.
        let made = try await env.environment.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note WHERE text = 'two'")
        }
        #expect(made == 4)
    }

    @Test func unknownActionsGetAGenericErrorCallbackThroughTheSameSchemeRule() async throws {
        let env = try Env()
        let spy = Spy()
        handler(env, spy).handle(url("bogus", [("x-error", "shortcuts://failed")]))
        let callback = try #require(spy.urls.first)
        #expect(callback.scheme == "shortcuts")
        #expect(parameters(callback)["errorCode"] == "5")
        #expect(parameters(callback)["errorMessage"] == "Action not supported")

        spy.urls = []
        handler(env, spy).handle(url("bogus", [("x-error", "https://evil.example/")]))
        #expect(spy.urls.isEmpty)
        // No callback given, none made.
        handler(env, spy).handle(url("bogus"))
        #expect(spy.urls.isEmpty)
    }

    @Test func errorsWithoutATokenSayNothingAboutTheLibrary() async throws {
        let env = try Env()
        let spy = Spy()
        handler(env, spy).handle(url("open-note", [("id", "secret-id"), ("x-error", "shortcuts://failed")]))
        let callback = try #require(spy.urls.first)
        #expect(parameters(callback)["errorCode"] == "2")
        #expect(parameters(callback)["errorMessage"] == "Note not found")
        #expect(!callback.absoluteString.contains("secret-id"))

        // With the token the executor's detailed message goes through unchanged.
        spy.urls = []
        let token = try token(env)
        handler(env, spy).handle(
            url("open-note", [("id", "secret-id"), ("token", token), ("x-error", "shortcuts://failed")]))
        #expect(parameters(try #require(spy.urls.first))["errorMessage"] == "Note not found: secret-id")

        // A wrong token is code 4 and does nothing.
        spy.urls = []
        handler(env, spy).handle(url("create", [("text", "x"), ("token", "nope"), ("x-error", "shortcuts://failed")]))
        #expect(parameters(try #require(spy.urls.first))["errorCode"] == "4")
    }

    @Test func dataActionsReadTheClipboardAndTheKeyEditorsNote() async throws {
        let env = try Env()
        let spy = Spy()
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        let token = try token(env)
        env.app.clipboardText = { "from the clipboard" }
        let id = try env.store.create(text: "# Title\nbody").id
        try editor.open(noteId: id)

        handler(env, spy).handle(url("add-text", [("selected", "yes"), ("clipboard", "yes"), ("token", token)]))
        #expect(try env.store.note(id: id)?.text.contains("from the clipboard") == true)

        // `selected=yes` without a token is refused.
        handler(env, spy).handle(url("add-text", [("selected", "yes"), ("text", "no"), ("x-error", "shortcuts://e")]))
        #expect(parameters(try #require(spy.urls.last))["errorCode"] == "4")
        #expect(try env.store.note(id: id)?.text.contains("no") == false)
    }

    // MARK: - Queue

    @Test func urlsBeforeLaunchAreQueued() async throws {
        let env = try Env()
        let spy = Spy()
        let inbox = XCallbackInbox()
        inbox.receive(url("bogus", [("x-error", "shortcuts://first")]))
        inbox.receive(url("bogus", [("x-error", "shortcuts://second")]))
        inbox.receive(URL(string: "baerchen://elsewhere/")!)
        #expect(spy.urls.isEmpty)

        inbox.handler = handler(env, spy)
        #expect(spy.urls.map(\.host) == ["first", "second"])

        // Later URLs go straight through.
        inbox.receive(url("bogus", [("x-error", "shortcuts://third")]))
        #expect(spy.urls.map(\.host) == ["first", "second", "third"])
    }

    @Test func theQueueIsBounded() async throws {
        let env = try Env()
        let spy = Spy()
        let inbox = XCallbackInbox()
        for index in 0..<(XCallbackInbox.maxPending + 5) {
            inbox.receive(url("bogus", [("x-error", "shortcuts://n\(index)")]))
        }
        inbox.handler = handler(env, spy)
        #expect(spy.urls.count == XCallbackInbox.maxPending)
    }

    // MARK: - Sidebar and workspaces

    @Test func searchAndWorkspaceIntents() async throws {
        let env = try Env()
        let spy = Spy()
        _ = try env.store.create(text: "#t some x here")
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        let token = try token(env)

        handler(env, spy).handle(url("search", [("term", "x"), ("tag", "t"), ("token", token)]))
        #expect(main.model.scope == .tag("t"))
        #expect(main.model.search.query == "x")

        // Another sidebar action clears the search it does not carry.
        handler(env, spy).handle(url("today"))
        #expect(main.model.scope == .today)

        // Spelling does not matter; an unknown tag changes nothing.
        handler(env, spy).handle(url("open-workspace", [("name", "T")]))
        #expect(main.model.workspace?.path == "t")
        handler(env, spy).handle(url("open-workspace", [("name", "nope")]))
        #expect(main.model.workspace?.path == "t")
        handler(env, spy).handle(url("close-workspace"))
        #expect(main.model.workspace == nil)
    }

    @Test func sidebarIntentsWaitForTheFirstMainWindow() async throws {
        let env = try Env()
        let spy = Spy()
        _ = try env.store.create(text: "#t body")
        var requests: [WindowRequest] = []
        env.app.openWindowRequest = { requests.append($0) }
        handler(env, spy).handle(url("open-workspace", [("name", "t")]))
        handler(env, spy).handle(url("trash", [("search", "body")]))
        // One window is asked for, however many actions wait for it.
        #expect(requests == [.main])
        let (editor, _) = try env.editor()
        let main = env.app.makeMainWindow(editor: editor)
        defer { main.close() }
        #expect(main.model.workspace?.path == "t")
        #expect(main.model.scope == .trash)
        #expect(main.model.search.query == "body")
    }

    @Test func actionsWaitingForTheFirstWindowRunInArrivalOrder() async throws {
        let env = try Env()
        let spy = Spy()
        let id = try env.store.create(text: "a note").id
        var requests: [WindowRequest] = []
        env.app.openWindowRequest = { requests.append($0) }
        // A sidebar change first, then the note: the note's section wins. Reversed, the sidebar would.
        handler(env, spy).handle(url("trash", [("search", "zzz")]))
        handler(env, spy).handle(url("open-note", [("id", id)]))
        #expect(requests == [.main])
        let (editor, _) = try env.editor()
        let main = env.app.makeMainWindow(editor: editor)
        defer { main.close() }
        #expect(main.model.focusedNoteID == id)
        #expect(main.model.scope == .notes)

        // The other way round: the note first, the sidebar change last.
        let second = try Env()
        var secondRequests: [WindowRequest] = []
        second.app.openWindowRequest = { secondRequests.append($0) }
        let other = try second.store.create(text: "a note").id
        handler(second, spy).handle(url("open-note", [("id", other)]))
        handler(second, spy).handle(url("trash", [("search", "zzz")]))
        #expect(secondRequests == [.main])
        let (secondEditor, _) = try second.editor()
        let secondMain = second.app.makeMainWindow(editor: secondEditor)
        defer { secondMain.close() }
        #expect(secondMain.model.scope == .trash)
    }

    @Test func theQueueForAWindowIsBounded() async throws {
        let env = try Env()
        let spy = Spy()
        env.app.openWindowRequest = { _ in }
        for _ in 0..<AppModel.maxPendingMainActions {
            handler(env, spy).handle(url("close-workspace"))
        }
        // A note open that does not fit is told so, not silently lost.
        let id = try env.store.create(text: "x").id
        #expect(env.app.openNote(OpenNoteRequest(noteId: id)) == false)
    }

    @Test func anEmptyErrorCallbackInFrontDoesNotHideARealOne() async throws {
        let env = try Env()
        let spy = Spy()
        handler(env, spy).handle(url("bogus", [("x-error", ""), ("x-error", "shortcuts://failed")]))
        let callback = try #require(spy.urls.first)
        #expect(callback.scheme == "shortcuts")
        #expect(parameters(callback)["errorCode"] == "5")
        // Only empty ones: nothing to call.
        spy.urls = []
        handler(env, spy).handle(url("bogus", [("x-error", ""), ("x-error", "")]))
        #expect(spy.urls.isEmpty)
    }

    @Test func aNoteThatVanishedIsNotNamedInTheLog() async throws {
        let env = try Env()
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        let started = Date()
        let gone = "vanished-note-\(UUID().uuidString)"
        #expect(env.app.show(OpenNoteRequest(noteId: gone), in: main) == false)

        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try log.getEntries(at: log.position(date: started.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.truebrewbirdie.baerchen" }
            .map(\.composedMessage)
        #expect(messages.contains { $0.contains("could not be shown") })
        #expect(!messages.contains { $0.contains(gone) })
    }

    @Test func locationIntentsRespectShowWindowNo() async throws {
        let env = try Env()
        let spy = Spy()
        let (main, _, _) = try env.mainWindow()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        main.attach(window: window)
        defer {
            main.close()
            window.close()
        }
        var activations = 0
        env.app.activate = { activations += 1 }
        handler(env, spy).handle(url("archive", [("search", "q"), ("show_window", "no")]))
        #expect(main.model.scope == .archive)
        #expect(activations == 0)
        #expect(!window.isVisible)
    }
}
