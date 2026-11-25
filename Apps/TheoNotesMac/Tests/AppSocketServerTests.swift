// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesAutomation
import TheoNotesCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TheoNotes

/// M5 Task 12: the app's automation socket and the handler behind it. Libraries live in short
/// folders under /tmp so `<library>/app.sock` fits a socket path; nothing here touches the real
/// library or a running Theo Notes.
@MainActor
@Suite struct AppSocketServerTests {
    @MainActor
    final class Env {
        let root: URL
        let paths: AppPaths
        let suiteName = "TheoNotesSocket-\(UUID().uuidString)"
        let defaults: UserDefaults
        let environment: AppEnvironment
        let app: AppModel
        /// What App Lock asks to confirm the owner (a fake: never a real prompt).
        let authenticator = FakeAppAuthenticator()
        var requests: [WindowRequest] = []

        init() throws {
            root = URL(fileURLWithPath: "/tmp/bc-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            paths = try AppPaths.resolve(arguments: ["baerchen", "--data-dir", root.path], environment: [:])
            defaults = UserDefaults(suiteName: suiteName)!
            environment = try AppEnvironment(paths: paths, appAuthenticator: authenticator, appLockLifecycle: nil, appIdleSeconds: { 0 })
            app = AppModel(environment: environment, defaults: defaults)
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        func editor(showing noteId: String? = nil) throws -> (EditorBridgeController, FakeEditorPage) {
            let page = FakeEditorPage()
            let controller = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            _ = controller.handle(.ready(version: EditorBridge.version))
            if let noteId { try controller.open(noteId: noteId) }
            return (controller, page)
        }

        /// A main window with a ready fake editor, as `MainWindowHost` would make one.
        func mainWindow() throws -> (MainWindowState, EditorBridgeController, FakeEditorPage) {
            let (editor, page) = try self.editor()
            app.openWindowRequest = { [unowned self] in requests.append($0) }
            let state = app.makeMainWindow(editor: editor)
            return (state, editor, page)
        }

        /// Turns App Lock on and engages it, as the user would; `unlockApp()` opens it again.
        func engageAppLock() async {
            authenticator.script(.success)
            _ = await environment.appLock.setEnabled(true)
            environment.appLock.lock()
        }

        func unlockApp() async {
            authenticator.script(.success)
            _ = await environment.appLock.unlock()
        }

        func lock(_ noteId: String) throws {
            try environment.database.pool.write {
                try $0.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [noteId])
            }
        }
    }

    private func selectionChanged(_ editor: EditorBridgeController, _ id: String, _ anchor: Int, _ head: Int) {
        _ = editor.handle(.selectionChanged(noteId: id, anchor: anchor, head: head))
    }

    private func selectRanges(_ page: FakeEditorPage) -> [HostToEditorMessage] {
        page.delivered.filter { if case .selectRange = $0 { true } else { false } }
    }

    // MARK: - getSelection

    @Test func getSelectionReportsUTF8OffsetsOfKeyEditor() async throws {
        let env = try Env()
        let id = try env.store.create(text: "😀 abc").id
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        try editor.open(noteId: id)
        selectionChanged(editor, id, 3, 5)
        let handler = AppAutomationHandler(app: env.app)

        // 😀 is four UTF-8 bytes (two UTF-16 units) and the space one: "ab" starts at byte 5.
        #expect(handler.getSelection() == SelectionResult(noteId: id, selectionOffset: 5, selectionLength: 2, selectionText: "ab"))
        // A backwards selection reads the same.
        selectionChanged(editor, id, 5, 3)
        #expect(handler.getSelection() == SelectionResult(noteId: id, selectionOffset: 5, selectionLength: 2, selectionText: "ab"))
        // A caret has length 0 and empty text.
        selectionChanged(editor, id, 3, 3)
        #expect(handler.getSelection() == SelectionResult(noteId: id, selectionOffset: 5, selectionLength: 0, selectionText: ""))
        // Half an emoji is no selection: the note is still named.
        selectionChanged(editor, id, 1, 3)
        #expect(handler.getSelection() == SelectionResult(noteId: id))
    }

    /// Typing the commit debounce has not stored yet is flushed first, so the offsets and selected
    /// text come from the same text the CLI and MCP then read from the store (final review M2).
    @Test func getSelectionFlushesTypingSoOffsetsMatchTheStoredText() async throws {
        let env = try Env()
        let id = try env.store.create(text: "abc").id
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        try editor.open(noteId: id)
        let session = try env.environment.session(for: id)
        _ = editor.handle(.changes(
            noteId: id, txId: "t1", baseRevision: session.revision, revision: session.revision + 1,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "XY "), .retain(3)])))
        #expect(session.text == "XY abc")
        #expect(try #require(try env.store.note(id: id)).text == "abc")
        selectionChanged(editor, id, 3, 6)
        let result = AppAutomationHandler(app: env.app).getSelection()
        #expect(result == SelectionResult(noteId: id, selectionOffset: 3, selectionLength: 3, selectionText: "abc"))
        #expect(try #require(try env.store.note(id: id)).text == "XY abc")
    }

    /// FOC-R401: while a voice capture holds unfinished words out of the store, the live text and
    /// the stored one differ; offsets from the live text would not fit what the caller reads, so
    /// only the note is named.
    @Test func getSelectionNamesOnlyTheNoteWhileWordsAreHeldOutOfTheStore() async throws {
        let env = try Env()
        let id = try env.store.create(text: "abc").id
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        try editor.open(noteId: id)
        let session = try env.environment.session(for: id)
        _ = editor.handle(.changes(
            noteId: id, txId: "t1", baseRevision: session.revision, revision: session.revision + 1,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "XY "), .retain(3)])))
        session.heldRange = 0..<3
        defer { session.heldRange = nil }
        selectionChanged(editor, id, 3, 6)
        #expect(AppAutomationHandler(app: env.app).getSelection() == SelectionResult(noteId: id))
        #expect(try #require(try env.store.note(id: id)).text == "abc")
    }

    @Test func getSelectionWithNoNoteOpenIsEmpty() throws {
        let env = try Env()
        let handler = AppAutomationHandler(app: env.app)
        #expect(handler.getSelection() == SelectionResult())
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        #expect(handler.getSelection() == SelectionResult())
    }

    @Test func aLockedNoteReportsItsIdOnly() throws {
        let env = try Env()
        let id = try env.store.create(text: "secret").id
        let (main, editor, _) = try env.mainWindow()
        defer { main.close() }
        try editor.open(noteId: id)
        selectionChanged(editor, id, 0, 3)
        try env.lock(id)
        #expect(AppAutomationHandler(app: env.app).getSelection() == SelectionResult(noteId: id))
    }

    @Test func aNoteWindowIsTheKeyEditorWhenNoMainWindowIsOpen() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello world").id
        let (editor, _) = try env.editor()
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)
        defer { window.close() }
        selectionChanged(editor, id, 6, 11)
        #expect(AppAutomationHandler(app: env.app).getSelection()
            == SelectionResult(noteId: id, selectionOffset: 6, selectionLength: 5, selectionText: "world"))
    }

    // MARK: - open

    @Test func openSelectsTextAndRejectsAmbiguousOrSplitScalarSelections() async throws {
        let env = try Env()
        let id = try env.store.create(text: "😀 abc").id
        let twice = try env.store.create(text: "abc abc").id
        let (main, _, page) = try env.mainWindow()
        defer { main.close() }
        let handler = AppAutomationHandler(app: env.app)

        let opened = try handler.open(OpenParams(noteId: id, selectionText: "abc"))
        #expect(opened == SelectionResult(noteId: id))
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 3, head: 6)])
        #expect(main.model.focusedNoteID == id)
        #expect(page.delivered.contains(.focus))

        // By UTF-8 byte range: bytes 5..<7 are "ab".
        page.delivered = []
        try handler.open(OpenParams(noteId: id, selectionOffset: 5, selectionLength: 2))
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 3, head: 5)])
        // Without a length: a caret.
        page.delivered = []
        try handler.open(OpenParams(noteId: id, selectionOffset: 5))
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 3, head: 3)])

        func failure(_ params: OpenParams) -> AutomationError? {
            do { try handler.open(params) } catch { return error }
            return nil
        }
        page.delivered = []
        #expect(failure(OpenParams(noteId: twice, selectionText: "abc"))
            == AutomationError(code: .ambiguous, message: "Selection text matches 2 times"))
        #expect(failure(OpenParams(noteId: id, selectionText: "ABC"))
            == AutomationError(code: .notFound, message: "Selection text not found"))
        let outside = AutomationError(code: .usage, message: "Selection is outside the note")
        // Byte 1 is inside the emoji; the note has 8 bytes.
        #expect(failure(OpenParams(noteId: id, selectionOffset: 1)) == outside)
        #expect(failure(OpenParams(noteId: id, selectionOffset: 6, selectionLength: 3)) == outside)
        #expect(failure(OpenParams(noteId: id, selectionOffset: 9)) == outside)
        #expect(failure(OpenParams(noteId: id, selectionOffset: 4, selectionLength: 1)) == nil)
        #expect(failure(OpenParams(noteId: "nope"))?.code == .noteNotFound)
        // A refused open shows nothing: only the one valid selection above was delivered.
        #expect(selectRanges(page).count == 1)
    }

    @Test func overlappingOccurrencesCountAsAmbiguous() throws {
        do {
            _ = try AppAutomationHandler.selection(in: "aaa", matching: "aa", offset: nil, length: nil)
            Issue.record("expected ambiguous")
        } catch {
            #expect(error == AutomationError(code: .ambiguous, message: "Selection text matches 2 times"))
        }
        // Case-sensitive and byte for byte: a decomposed é is not a precomposed one.
        do {
            _ = try AppAutomationHandler.selection(in: "cafe\u{301}", matching: "caf\u{e9}", offset: nil, length: nil)
            Issue.record("expected not_found")
        } catch {
            #expect(error.code == .notFound)
        }
    }

    @Test func aLockedNoteTakesNoSelection() throws {
        let env = try Env()
        let id = try env.store.create(text: "secret").id
        try env.lock(id)
        let handler = AppAutomationHandler(app: env.app)
        do {
            try handler.open(OpenParams(noteId: id, selectionText: "s"))
            Issue.record("expected note_locked")
        } catch {
            #expect(error.code == .noteLocked)
        }
    }

    @Test func openScrollsToTheHeadingAndFocusesOnEdit() throws {
        let env = try Env()
        let id = try env.store.create(text: "# A\n## B\n## C").id
        let (main, _, page) = try env.mainWindow()
        defer { main.close() }
        let handler = AppAutomationHandler(app: env.app)
        try handler.open(OpenParams(noteId: id, header: "C", edit: true))
        let index = try #require(try env.store.headingIndex(noteId: id, heading: "C"))
        #expect(page.delivered.contains(.scrollToHeading(noteId: id, index: index)))
        #expect(page.delivered.contains(.focus))

        // A heading the note lacks: the note opens at the top and the call succeeds.
        page.delivered = []
        try handler.open(OpenParams(noteId: id, header: "Nope"))
        #expect(!page.delivered.contains { if case .scrollToHeading = $0 { true } else { false } })
        #expect(!page.delivered.contains(.focus))
    }

    @Test func openWithoutAMainWindowOpensOneAndShowsTheNoteThere() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello").id
        env.app.openWindowRequest = { env.requests.append($0) }
        try AppAutomationHandler(app: env.app).open(OpenParams(noteId: id))
        #expect(env.requests == [.main])
        // The window SwiftUI makes for it shows the note.
        let (editor, _) = try env.editor()
        let main = env.app.makeMainWindow(editor: editor)
        defer { main.close() }
        #expect(main.model.focusedNoteID == id)
        #expect(editor.session?.noteId == id)
    }

    @Test func newWindowAndFloatOpenAFloatingNoteWindow() throws {
        let env = try Env()
        let id = try env.store.create(text: "😀 abc").id
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        env.requests = []
        try AppAutomationHandler(app: env.app).open(OpenParams(noteId: id, float: true, selectionText: "abc"))
        #expect(env.requests == [.note(id: id)])
        // The note window SwiftUI opens takes the request: floating, with the selection.
        let (editor, page) = try env.editor()
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)
        defer { window.close() }
        #expect(window.isFloating)
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 3, head: 6)])
        // The request is used once.
        let (otherEditor, _) = try env.editor()
        let again = env.app.makeNoteWindow(noteId: id, editor: otherEditor)
        defer { again.close() }
        #expect(!again.isFloating)
    }

    @Test func aPlainNewWindowIsNotFloating() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello").id
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        env.requests = []
        try AppAutomationHandler(app: env.app).open(OpenParams(noteId: id, newWindow: true))
        #expect(env.requests == [.note(id: id)])
        let (editor, _) = try env.editor()
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)
        defer { window.close() }
        #expect(!window.isFloating)
    }

    @Test func aNoteWindowAlreadyShowingTheNoteIsReused() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello world").id
        let (editor, page) = try env.editor()
        env.app.openWindowRequest = { env.requests.append($0) }
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)
        defer { window.close() }
        try AppAutomationHandler(app: env.app).open(OpenParams(noteId: id, float: true, selectionText: "world"))
        #expect(env.requests.isEmpty)
        #expect(window.isFloating)
        #expect(selectRanges(page) == [.selectRange(noteId: id, anchor: 6, head: 11)])
    }

    @Test func handleAnswersEachMethod() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello").id
        let (main, _, _) = try env.mainWindow()
        defer { main.close() }
        let handler = AppAutomationHandler(app: env.app)
        #expect(handler.handle(AppSocketRequest(id: 1, method: "ping")) == AppSocketResponse(id: 1, result: SelectionResult()))
        #expect(handler.handle(AppSocketRequest(id: 2, method: "open", params: OpenParams(noteId: id)))
            == AppSocketResponse(id: 2, result: SelectionResult(noteId: id)))
        #expect(handler.handle(AppSocketRequest(id: 3, method: "open")).error?.code == "usage")
        #expect(handler.handle(AppSocketRequest(id: 4, method: "open", params: OpenParams(noteId: "x"))).error?.code == "note_not_found")
        #expect(handler.handle(AppSocketRequest(id: 5, method: "getSelection")).result?.noteId == id)
        #expect(handler.handle(AppSocketRequest(id: 6, method: "shutdown")).error?.code == "usage")
    }

    // MARK: - The server

    private func ping(_ paths: AppPaths) throws -> AppSocketResponse {
        try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: paths)
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode : nil
    }

    /// A gate handlers wait at (a continuation, so a cancelled task does not spin).
    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            all.forEach { $0.resume() }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// Binds a socket file and leaves it behind without a listener, like a crashed app.
    private func leaveStaleSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AppSocket.address(for: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(bound == 0)
    }

    @Test func theSocketIsPrivateAndGoneAfterStop() throws {
        let env = try Env()
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        try server.start()
        defer { server.stop() }
        #expect(server.path == env.root.appendingPathComponent("app.sock").path)
        let bits = try #require(mode(server.path))
        #expect((bits & S_IFMT) == S_IFSOCK && (bits & 0o777) == 0o600)
        #expect(try ping(env.paths) == AppSocketResponse(id: 1, result: SelectionResult()))
        server.stop()
        #expect(mode(server.path) == nil)
        #expect(!server.isStarted)
        var failure: AutomationError?
        do { _ = try ping(env.paths) } catch { failure = error as? AutomationError }
        #expect(failure.map(AppSocketClient.isNotRunning) == true)
    }

    @Test func staleSocketIsReplacedAndLiveInstanceIsNot() throws {
        let env = try Env()
        let path = AppSocket.path(for: env.paths)
        try leaveStaleSocket(at: path)
        #expect(mode(path) != nil)

        let first = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id, result: SelectionResult(noteId: "first")) }
        try first.start()
        defer { first.stop() }
        #expect(try ping(env.paths).error == nil)

        // A second instance on the same library does not take the socket over.
        let second = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id, result: SelectionResult(noteId: "second")) }
        do {
            try second.start()
            Issue.record("expected alreadyRunning")
        } catch let error as AppSocketServer.StartError {
            #expect(error == .alreadyRunning(path))
        }
        #expect(!second.isStarted)
        second.stop()
        // Stopping the instance that never started leaves the live socket alone.
        let reply = try AppSocketClient.send(AppSocketRequest(id: 2, method: "getSelection"), paths: env.paths)
        #expect(reply.result?.noteId == "first")
    }

    @Test func aFileThatIsNotASocketIsLeftAlone() throws {
        let env = try Env()
        let path = AppSocket.path(for: env.paths)
        try Data("precious".utf8).write(to: URL(fileURLWithPath: path))
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        do {
            try server.start()
            Issue.record("expected occupied")
        } catch let error as AppSocketServer.StartError {
            #expect(error == .occupied(path))
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "precious")
    }

    @Test func foreignUidIsRejected() throws {
        // The decision itself.
        #expect(AppSocket.allows(peer: geteuid(), own: geteuid()))
        #expect(!AppSocket.allows(peer: geteuid() &+ 1, own: geteuid()))
        // A server that believes another user owns it closes every connection unanswered.
        let env = try Env()
        let handled = Counter()
        let server = AppSocketServer(paths: env.paths, peerUID: geteuid() &+ 1) {
            handled.bump()
            return AppSocketResponse(id: $0.id)
        }
        try server.start()
        defer { server.stop() }
        var failure: AutomationError?
        do { _ = try AppSocketClient.send(AppSocketRequest(id: 1, method: "getSelection"), paths: env.paths) } catch { failure = error }
        #expect(failure?.code == .appUnavailable)
        #expect(handled.count == 0)
    }

    @Test func anOversizedRequestLineClosesTheConnection() throws {
        let env = try Env()
        let handled = Counter()
        let server = AppSocketServer(paths: env.paths) {
            handled.bump()
            return AppSocketResponse(id: $0.id)
        }
        try server.start()
        defer { server.stop() }
        guard case .success(let fd) = AppSocket.connect(path: server.path, timeout: .seconds(1)) else {
            Issue.record("could not connect")
            return
        }
        defer { close(fd) }
        AppSocket.setTimeouts(fd, receive: .seconds(3), send: .seconds(3))
        // More than 1 MiB and no newline: the server gives up before it ever decodes anything.
        _ = AppSocket.writeAll(Data(repeating: 0x41, count: AppSocket.maxRequestBytes + 4096), to: fd)
        guard case .closed = AppSocket.readLine(from: fd, maxBytes: 1024) else {
            Issue.record("expected the server to close the connection")
            return
        }
        #expect(handled.count == 0)
    }

    @Test func garbageGetsAUsageErrorAndAFullLineGoesToTheHandler() throws {
        let env = try Env()
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id, result: SelectionResult(noteId: $0.method)) }
        try server.start()
        defer { server.stop() }
        guard case .success(let fd) = AppSocket.connect(path: server.path, timeout: .seconds(1)) else { return }
        defer { close(fd) }
        AppSocket.setTimeouts(fd, receive: .seconds(3), send: .seconds(3))
        _ = AppSocket.writeAll(Data("not json\n".utf8), to: fd)
        guard case .line(let data) = AppSocket.readLine(from: fd, maxBytes: 4096) else {
            Issue.record("expected an error reply")
            return
        }
        let reply = try JSONDecoder().decode(AppSocketResponse.self, from: data)
        #expect(reply.error?.code == "usage")
        // A request of nearly the limit still goes through.
        let big = String(repeating: "x", count: 900_000)
        let response = try AppSocketClient.send(
            AppSocketRequest(id: 9, method: "open", params: OpenParams(noteId: "n", selectionText: big)), paths: env.paths)
        #expect(response.result?.noteId == "open")
    }

    // MARK: - Fix round 1: where and how the socket is published

    private func listeningRaw(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AppSocket.address(for: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0 && listen(fd, 4) == 0)
        return fd
    }

    private func startError(_ server: AppSocketServer) -> AppSocketServer.StartError? {
        do { try server.start() } catch { return error as? AppSocketServer.StartError }
        return nil
    }

    @Test func aFolderOthersCanWriteToIsRefused() throws {
        let env = try Env()
        chmod(env.root.path, 0o775)
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        #expect(startError(server) == .unsafeDirectory(env.root.path))
        #expect(!server.isStarted)
        chmod(env.root.path, 0o757)
        #expect(startError(server) == .unsafeDirectory(env.root.path))
        chmod(env.root.path, 0o755)
        #expect(startError(server) == nil)
        server.stop()
    }

    @Test func aSymlinkedFolderIsRefused() throws {
        let env = try Env()
        let link = URL(fileURLWithPath: "/tmp/bc-link-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.root)
        defer { try? FileManager.default.removeItem(at: link) }
        let server = AppSocketServer(paths: AppPaths(root: link)) { AppSocketResponse(id: $0.id) }
        #expect(startError(server) == .unsafeDirectory(link.path))
        #expect(!FileManager.default.fileExists(atPath: env.root.appendingPathComponent("app.sock").path))
    }

    @Test func theFallbackFolderIsMadePrivateAndRepaired() throws {
        let home = URL(fileURLWithPath: "/tmp/bc-home-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = AppSocket.fallbackDirectory(home: home)
        // A folder somebody made wide open is tightened, not trusted.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o777)
        let long = AppPaths(root: URL(fileURLWithPath: "/tmp/" + String(repeating: "q", count: 120)))
        let server = AppSocketServer(paths: long, home: home) { AppSocketResponse(id: $0.id) }
        try server.start()
        defer { server.stop() }
        #expect(server.path.hasPrefix(folder.path + "/"))
        var info = stat()
        #expect(lstat(folder.path, &info) == 0 && (info.st_mode & 0o777) == 0o700)
        #expect(try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: long, home: home).error == nil)
    }

    @Test func theSocketIsPublishedPrivateWithNoStagingLeftBehind() throws {
        let env = try Env()
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        try server.start()
        defer { server.stop() }
        #expect((try #require(mode(server.path)) & 0o777) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: env.root.path)
        #expect(!names.contains { $0.hasPrefix(".sock-") })
        #expect(names.contains("app.sock.lock"))
    }

    @Test func aLiveListenerWithoutOurLockIsNotReplaced() throws {
        let env = try Env()
        let path = AppSocket.path(for: env.paths)
        let live = try listeningRaw(at: path)
        defer { close(live); unlink(path) }
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        #expect(startError(server) == .alreadyRunning(path))
        #expect(mode(path) != nil)
    }

    @Test func concurrentStartsLeaveExactlyOneServer() throws {
        let env = try Env()
        let path = AppSocket.path(for: env.paths)
        try leaveStaleSocket(at: path)
        let servers = (0..<8).map { _ in AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) } }
        let results = Counter()
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: servers.count) { index in
            do {
                try servers[index].start()
                results.bump()
            } catch is AppSocketServer.StartError {
                failures.bump()
            } catch {}
        }
        defer { servers.forEach { $0.stop() } }
        #expect(results.count == 1 && failures.count == 7)
        #expect(try ping(env.paths).error == nil)
    }

    @Test func stoppingReleasesTheLockForTheNextInstance() throws {
        let env = try Env()
        let first = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        try first.start()
        first.stop()
        let second = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        try second.start()
        defer { second.stop() }
        #expect(try ping(env.paths).error == nil)
    }

    @Test func aPeerThatTricklesBytesIsCutOffAtTheRequestDeadline() throws {
        let env = try Env()
        let handled = Counter()
        let server = AppSocketServer(paths: env.paths, requestTimeout: .milliseconds(400)) {
            handled.bump()
            return AppSocketResponse(id: $0.id)
        }
        try server.start()
        defer { server.stop() }
        guard case .success(let fd) = AppSocket.connect(path: server.path, timeout: .seconds(1)) else {
            Issue.record("could not connect")
            return
        }
        defer { close(fd) }
        let started = ContinuousClock.now
        // One byte every 50 ms never trips a per-read timeout; the whole-request deadline must.
        var open = true
        while open, ContinuousClock.now - started < .seconds(3) {
            open = AppSocket.writeAll(Data([0x41]), to: fd)
            usleep(50_000)
        }
        #expect(!open)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(handled.count == 0)
    }

    // MARK: - Fix round 2

    private func makeFolder(_ path: String, mode: mode_t) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        chmod(path, mode)
    }

    @Test func theParentOfTheSocketFolderMustNotBeWritableByOthers() throws {
        let outer = "/tmp/bc-p-\(UUID().uuidString.prefix(8).lowercased())"
        defer { chmod(outer, 0o755); try? FileManager.default.removeItem(atPath: outer) }
        let inner = outer + "/lib"
        try makeFolder(outer, mode: 0o775)
        try makeFolder(inner, mode: 0o755)
        let server = AppSocketServer(paths: AppPaths(root: URL(fileURLWithPath: inner, isDirectory: true))) { AppSocketResponse(id: $0.id) }
        #expect(startError(server) == .unsafeDirectory(outer))
        chmod(outer, 0o757)
        #expect(startError(server) == .unsafeDirectory(outer))
        // Sticky (like /tmp itself): others cannot move our folder away.
        chmod(outer, 0o1777)
        #expect(startError(server) == nil)
        server.stop()
        chmod(outer, 0o755)
        #expect(startError(server) == nil)
        server.stop()
    }

    @Test func aStuckHandlerKeepsItsSlotAndIsCancelledAfterTheTimeoutReply() async throws {
        let env = try Env()
        let gate = AsyncGate()
        let cancelled = Flag()
        let server = AppSocketServer(paths: env.paths, handlerTimeout: .milliseconds(300)) { request in
            await gate.wait()
            if Task.isCancelled { cancelled.set() }
            return AppSocketResponse(id: request.id)
        }
        try server.start()
        defer { server.stop() }
        let paths = env.paths
        let reply = try await Task.detached {
            try AppSocketClient.send(AppSocketRequest(id: 5, method: "getSelection"), paths: paths)
        }.value
        #expect(reply.error?.message == AppSocketClient.timeoutMessage)
        // The caller has its answer, but the handler is still running and still holds its slot.
        #expect(server.runningCount == 1)
        gate.open()
        for _ in 0..<100 where server.runningCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.runningCount == 0)
        #expect(cancelled.isSet)
    }

    @Test func atMostSixteenHandlersRunAtOnce() async throws {
        let env = try Env()
        let gate = AsyncGate()
        let started = Counter()
        let server = AppSocketServer(paths: env.paths, handlerTimeout: .milliseconds(200)) { request in
            started.bump()
            await gate.wait()
            return AppSocketResponse(id: request.id)
        }
        try server.start()
        defer { server.stop(); gate.open() }
        let paths = env.paths
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<AppSocketServer.maxConnections {
                group.addTask { _ = try? AppSocketClient.send(AppSocketRequest(id: index, method: "getSelection"), paths: paths) }
            }
        }
        #expect(server.runningCount == AppSocketServer.maxConnections)
        // The 17th is turned away at the door: no handler starts for it.
        var failure: AutomationError?
        do { _ = try AppSocketClient.send(AppSocketRequest(id: 99, method: "getSelection"), paths: paths) } catch { failure = error as? AutomationError }
        #expect(failure?.code == .appUnavailable)
        #expect(started.count == AppSocketServer.maxConnections)
        gate.open()
        for _ in 0..<100 where server.runningCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.runningCount == 0)
    }

    @Test func aCancelledRequestDoesNotActWhenTheMainActorGetsToIt() async throws {
        let env = try Env()
        let id = try env.store.create(text: "hello").id
        var requests: [WindowRequest] = []
        env.app.openWindowRequest = { requests.append($0) }
        let handler = AppAutomationHandler(app: env.app)
        let request = AppSocketRequest(id: 1, method: "open", params: OpenParams(noteId: id, newWindow: true))
        let task = Task { @MainActor in
            await Task.yield()
            return handler.handle(request)
        }
        task.cancel()
        let response = await task.value
        #expect(response.error?.message == AppSocketClient.timeoutMessage)
        #expect(requests.isEmpty && env.app.pendingNoteOpens.isEmpty)
        // The same request, not cancelled, does act.
        #expect(handler.handle(request).error == nil)
        #expect(requests == [.note(id: id)])
    }

    @Test func requestsBeyondTheEarlyQueueGetAnErrorNotSuccess() throws {
        let env = try Env()
        let ids = try (0...AppModel.maxQueuedWindowRequests).map { try env.store.create(text: "note \($0)").id }
        let handler = AppAutomationHandler(app: env.app)
        for id in ids.dropLast() { try handler.open(OpenParams(noteId: id, newWindow: true)) }
        do {
            try handler.open(OpenParams(noteId: ids.last!, newWindow: true))
            Issue.record("expected an error for request 17")
        } catch {
            #expect(error == AutomationError(code: .busy, message: "Theo Notes is still starting; try again"))
        }
        #expect(env.app.pendingNoteOpens[ids.last!] == nil)
        // The 16 that were kept run once routing exists.
        var seen: [WindowRequest] = []
        env.app.openWindowRequest = { seen.append($0) }
        #expect(seen == ids.dropLast().map { WindowRequest.note(id: $0) })
    }

    @Test func aLockFileThatIsNotPrivateRefusesTheStart() throws {
        let env = try Env()
        let lockPath = AppSocket.path(for: env.paths) + ".lock"
        try Data().write(to: URL(fileURLWithPath: lockPath))
        chmod(lockPath, 0o644)
        let server = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        #expect(startError(server) == .unsafeLockFile(lockPath))
        #expect(!server.isStarted)
        // The same file with mode 0600 is accepted and reused.
        chmod(lockPath, 0o600)
        #expect(startError(server) == nil)
        server.stop()
    }

    @Test func stagingDebrisIsSweptAndANameCollisionIsRedrawn() throws {
        let env = try Env()
        let root = env.root.path
        // Debris of a crashed start: a staging folder with a socket-ish file, and an empty one.
        try makeFolder(root + "/.sock-deadbeef", mode: 0o700)
        try Data().write(to: URL(fileURLWithPath: root + "/.sock-deadbeef/s"))
        try makeFolder(root + "/.sock-cafe", mode: 0o700)
        try makeFolder(root + "/keep", mode: 0o755)
        // A file (not a folder) in the way of the first staging name.
        try Data().write(to: URL(fileURLWithPath: root + "/.sock-1"))
        let names = Mutex([UInt32(1), 1, 2])
        let server = AppSocketServer(
            paths: env.paths,
            stagingSuffix: { names.withLock { $0.isEmpty ? 3 : $0.removeFirst() } }
        ) { AppSocketResponse(id: $0.id) }
        try server.start()
        defer { server.stop() }
        let left = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
        #expect(!left.contains(".sock-deadbeef") && !left.contains(".sock-cafe") && !left.contains(".sock-2"))
        #expect(left.contains("keep") && left.contains(".sock-1"))
        #expect(try ping(env.paths).error == nil)
    }

    @Test func aVolumeWithoutExclusiveRenameRunsWithoutTheSocket() throws {
        let env = try Env()
        let server = AppSocketServer(paths: env.paths, renameExclusive: { _, _ in
            errno = ENOTSUP
            return -1
        }) { AppSocketResponse(id: $0.id) }
        #expect(startError(server) == .unsupportedVolume(server.path))
        #expect(!server.isStarted)
        let left = try FileManager.default.contentsOfDirectory(atPath: env.root.path)
        #expect(!left.contains { $0.hasPrefix(".sock-") } && !left.contains("app.sock"))
        // The CLI side then simply finds no app.
        var failure: AutomationError?
        do { _ = try ping(env.paths) } catch { failure = error as? AutomationError }
        #expect(failure.map(AppSocketClient.isNotRunning) == true)
        // The lock was given back: a normal instance can start.
        let normal = AppSocketServer(paths: env.paths) { AppSocketResponse(id: $0.id) }
        try normal.start()
        normal.stop()
    }

    // MARK: - Fix round 1: window requests and the selection fallback

    @Test func windowRequestsMadeBeforeRoutingIsInstalledRunWhenItIs() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello").id
        // The socket answers before the first window has installed `openWindow`.
        try AppAutomationHandler(app: env.app).open(OpenParams(noteId: id, float: true))
        var seen: [WindowRequest] = []
        env.app.openWindowRequest = { seen.append($0) }
        #expect(seen == [.note(id: id)])
        // Drained once.
        env.app.openWindowRequest = { seen.append($0) }
        #expect(seen == [.note(id: id)])
    }

    @Test func aDefaultOpenBeforeAnyWindowWaitsForTheLaunchWindowWithoutAskingForAnother() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello").id
        try AppAutomationHandler(app: env.app).open(OpenParams(noteId: id))
        var seen: [WindowRequest] = []
        env.app.openWindowRequest = { seen.append($0) }
        #expect(seen.isEmpty)
        let (editor, _) = try env.editor()
        let main = env.app.makeMainWindow(editor: editor)
        defer { main.close() }
        #expect(editor.session?.noteId == id)
    }

    @Test func theSelectionFallbackIsTheMostRecentlyActiveWindowOfEitherKind() throws {
        let env = try Env()
        let id = try env.store.create(text: "hello world").id
        let (mainEditor, _) = try env.editor(showing: id)
        let main = env.app.makeMainWindow(editor: mainEditor)
        let (noteEditor, _) = try env.editor()
        let note = env.app.makeNoteWindow(noteId: id, editor: noteEditor)
        defer { main.close(); note.close() }
        func window() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        }
        let (mainWindow, noteWindow) = (window(), window())
        mainWindow.isReleasedWhenClosed = false
        noteWindow.isReleasedWhenClosed = false
        main.attach(window: mainWindow)
        note.attach(window: noteWindow)

        // Never key: the newest window.
        #expect(env.app.keyEditor() === noteEditor)
        env.app.windowBecameKey(mainWindow)
        #expect(env.app.keyEditor() === mainEditor)
        env.app.windowBecameKey(noteWindow)
        #expect(env.app.keyEditor() === noteEditor)
        env.app.windowBecameKey(mainWindow)
        #expect(env.app.keyEditor() === mainEditor)
    }

    // MARK: - CLI against the real server and handler

    /// Runs `baerchen --data-dir <library> <args>` off the main actor (the handler needs it).
    private func runCLI(_ env: Env, _ args: [String]) async -> (exit: Int32, out: String, err: String) {
        let root = env.root.path
        return await Task.detached {
            final class Capture: @unchecked Sendable {
                let lock = NSLock()
                var out = Data()
                var err = ""
            }
            let capture = Capture()
            let io = CLIIO(
                readStdin: { Data() }, stdinIsTTY: false, write: { data in capture.lock.withLock { capture.out.append(data) } },
                writeError: { text in capture.lock.withLock { capture.err += text } }, stdoutIsTTY: false)
            let exit = TheoNotesCLI.run(
                ["baerchen", "--data-dir", root] + args, context: .fixed(Date(timeIntervalSince1970: 1_767_323_045)), io: io)
            return (exit, String(decoding: capture.out, as: UTF8.self), capture.err)
        }.value
    }

    @Test func cliGetSelectionAndOpenThroughTheRealSocket() async throws {
        let env = try Env()
        let id = try env.store.create(text: "# Mars\n😀 abc").id
        let (main, editor, page) = try env.mainWindow()
        defer { main.close() }
        try editor.open(noteId: id)
        selectionChanged(editor, id, 10, 12)
        let handler = AppAutomationHandler(app: env.app)
        let server = AppSocketServer(paths: env.paths) { request in await handler.handle(request) }
        try server.start()
        defer { server.stop() }

        let selection = await runCLI(env, ["app", "get-selection", "--fields", "id,title,selectionOffset,selectionLength,selectionText"])
        #expect(selection.exit == 0)
        // "# Mars\n" is 7 bytes, 😀 four, the space one: "ab" starts at byte 12.
        #expect(selection.out == "\(id)\tMars\t12\t2\tab\n")

        let opened = await runCLI(env, ["app", "open", id, "--selection-text", "abc"])
        #expect(opened.exit == 0 && opened.out == "" && opened.err == "")
        #expect(selectRanges(page).last == .selectRange(noteId: id, anchor: 10, head: 13))

        let refused = await runCLI(env, ["app", "open", id, "--selection-text", "zzz"])
        #expect(refused.exit == 1 && refused.err == "Error: Selection text not found\n")
    }
}
