// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesAutomation
import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// M9M-R63: while App Lock is engaged the x-callback handler and the app socket refuse, with a clear
/// "locked" answer and nothing from the library. Libraries are throw-away folders under /tmp, callbacks
/// go to a spy and the identity check is a fake.
@MainActor
@Suite struct AppLockAutomationTests {
    typealias Env = AppSocketServerTests.Env

    private func xcallback(_ action: String, _ items: [(String, String)] = []) -> URL {
        var components = URLComponents()
        components.scheme = "theonotes"
        components.host = "x-callback-url"
        components.path = "/" + action
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    private func parameters(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private func handler(_ env: Env, _ urls: XCallbackURLs) -> XCallbackHandler {
        XCallbackHandler(
            app: env.app, openURL: { urls.list.append($0) },
            context: .fixed(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func noteCount(_ env: Env) throws -> Int {
        try env.environment.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") ?? 0 }
    }

    final class XCallbackURLs {
        var list: [URL] = []
    }

    // MARK: x-callback

    @Test func aLockedAppAnswersXCallbackWithCode6AndNothingElse() async throws {
        let env = try Env()
        let urls = XCallbackURLs()
        let token = try AutomationToken.ensure(TheoNotesCore.Settings(db: env.environment.database))
        let before = try noteCount(env)
        await env.engageAppLock()

        handler(env, urls).handle(xcallback("create", [
            ("title", "Sneaky"), ("text", "zqx body"), ("token", token),
            ("x-success", "shortcuts://ok"), ("x-error", "shortcuts://fail"),
        ]))

        #expect(urls.list.count == 1)
        let callback = try #require(urls.list.first)
        #expect(callback.scheme == "shortcuts" && callback.host == "fail", "only x-error is called, never x-success")
        let items = parameters(callback)
        #expect(items["errorCode"] == "6")
        #expect(items["errorMessage"] == AppLockedRefusal.message)
        #expect(items["identifier"] == nil && items["title"] == nil)
        #expect(try noteCount(env) == before, "nothing was created")
    }

    @Test func everyXCallbackActionIsRefusedWhileLockedAndShowsNothing() async throws {
        let env = try Env()
        let urls = XCallbackURLs()
        let note = try env.store.create(text: "# Visible title zqx")
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        let token = try AutomationToken.ensure(TheoNotesCore.Settings(db: env.environment.database))
        await env.engageAppLock()
        let focusedBefore = main.model.focusedNoteID

        for action in XCallbackAction.allCases {
            handler(env, urls).handle(xcallback(action.rawValue, [
                ("id", note.id), ("title", "Visible title zqx"), ("search", "zqx"), ("token", token),
                ("x-error", "shortcuts://fail"), ("x-success", "shortcuts://ok"),
            ]))
        }

        #expect(urls.list.count == XCallbackAction.allCases.count)
        for callback in urls.list {
            let items = parameters(callback)
            #expect(callback.host == "fail" && items["errorCode"] == "6")
            #expect(!callback.absoluteString.contains("zqx") && !callback.absoluteString.contains(note.id))
        }
        #expect(main.model.focusedNoteID == focusedBefore, "no note was opened")
        #expect(editor.session == nil)
    }

    @Test func aRefusedXCallbackWithoutAnErrorTargetCallsNothingBack() async throws {
        let env = try Env()
        let urls = XCallbackURLs()
        await env.engageAppLock()
        handler(env, urls).handle(xcallback("today"))
        #expect(urls.list.isEmpty)
    }

    @Test func xCallbackWorksAgainAfterTheAppIsUnlocked() async throws {
        let env = try Env()
        let urls = XCallbackURLs()
        let token = try AutomationToken.ensure(TheoNotesCore.Settings(db: env.environment.database))
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        await env.engageAppLock()
        await env.unlockApp()

        handler(env, urls).handle(xcallback("create", [("title", "Back"), ("token", token), ("x-success", "shortcuts://ok")]))
        #expect(parameters(try #require(urls.list.first))["identifier"] != nil)
    }

    // MARK: socket

    @Test func aLockedAppRefusesOpenAndGetSelectionOnTheSocketHandler() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        try editor.open(noteId: note.id)
        let handler = AppAutomationHandler(app: env.app)
        // Unlocked, the same requests answer (the control).
        #expect(handler.handle(AppSocketRequest(id: 1, method: "getSelection")).result?.noteId == note.id)
        await env.engageAppLock()

        for (id, method) in [(2, "getSelection"), (3, "open"), (4, "no-such-method")] {
            let params: OpenParams? = method == "open" ? OpenParams(noteId: note.id) : nil
            let response = handler.handle(AppSocketRequest(id: id, method: method, params: params))
            #expect(response.id == id)
            #expect(response.result == nil, "\(method) returns no content while locked")
            #expect(response.error?.code == "app_locked")
            #expect(response.error?.message == AppLockedRefusal.message)
            #expect(response.error?.message.contains(note.id) == false)
        }
        #expect(handler.handle(AppSocketRequest(id: 5, method: "ping")).error == nil, "ping only says the app runs")

        await env.unlockApp()
        #expect(handler.handle(AppSocketRequest(id: 6, method: "getSelection")).result?.noteId == note.id)
    }

    @Test func theRealSocketCarriesTheLockedRefusalToTheClient() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        let handler = AppAutomationHandler(app: env.app)
        let server = AppSocketServer(paths: env.paths) { request in await handler.handle(request) }
        try server.start()
        defer { server.stop() }
        await env.engageAppLock()
        let paths = env.paths
        let id = note.id

        let reply = try await Task.detached {
            try AppSocketClient.send(AppSocketRequest(id: 7, method: "open", params: OpenParams(noteId: id)), paths: paths)
        }.value
        #expect(reply.result == nil)
        #expect(reply.error?.automationError.code == .appLocked)
        let selection = try await Task.detached {
            try AppSocketClient.send(AppSocketRequest(id: 8, method: "getSelection"), paths: paths)
        }.value
        #expect(selection.result == nil && selection.error?.automationError.code == .appLocked)
        #expect(try await Task.detached { try AppSocketClient.send(AppSocketRequest(id: 9, method: "ping"), paths: paths) }.value.error == nil)
    }

    // MARK: app model

    @Test func whileLockedTheAppOpensNoNoteAndNoQuickOpen() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        await env.engageAppLock()

        #expect(env.app.isLocked)
        #expect(env.app.openNote(OpenNoteRequest(noteId: note.id)) == false)
        #expect(env.app.openNoteInNewWindow(id: note.id) == false)
        env.app.showQuickOpen(main: main, noteWindow: nil)
        #expect(!env.app.quickOpen.isShown)
        env.app.showTemplatePicker(main: main, noteWindow: nil)
        #expect(!env.app.templatePicker.isShown)
        let before = try noteCount(env)
        env.app.newNoteInMainWindow()
        env.app.newNoteInNewWindow(from: main)
        #expect(try noteCount(env) == before, "no note is made behind the lock screen")
    }

    @Test func engagingTheLockClosesTheQuickOpenPanel() async throws {
        let env = try Env()
        _ = try env.store.create(text: "# Visible title zqx")
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        env.app.showQuickOpen(main: main, noteWindow: nil)
        #expect(env.app.quickOpen.panel?.isVisible == true || env.app.quickOpen.model != nil)
        await env.engageAppLock()
        #expect(!env.app.quickOpen.isShown)
        #expect(env.app.quickOpen.model == nil)
    }

    @Test func theSweepHidesPanelsAndEndsSheets() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Quick Open"
        panel.orderFront(nil)
        let touched = AppLockWindowSweep.run(windows: [panel], abortModal: false)
        #expect(!panel.isVisible)
        #expect(touched.contains { $0 === panel } || !panel.isVisible)
    }
}
