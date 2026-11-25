// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import Synchronization
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A library in a short folder under /tmp, so `<root>/app.sock` fits a socket path (a `TestLibrary`
/// folder lives under TMPDIR and is too long: its socket would go to the real Caches folder).
final class ShortLibrary: @unchecked Sendable {
    let library: AutomationLibrary
    let root: URL

    init(_ notes: [(text: String, locked: Bool)] = []) throws {
        let name = UUID().uuidString.prefix(8).lowercased()
        root = URL(fileURLWithPath: "/tmp/bc-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root)
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: ChangeNotifier(), paths: paths)
        for spec in notes {
            let note = try store.create(text: spec.text, now: TestLibrary.epoch)
            if spec.locked {
                try db.pool.write { db in
                    try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [note.id])
                }
            }
        }
        library = try AutomationLibrary.open(dataDir: root.path, environment: [:])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var paths: AppPaths { library.paths }

    func lockedId() throws -> String {
        let found = try library.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM note WHERE isLocked = 1 LIMIT 1")
        }
        return try #require(found)
    }

    func id(titled title: String) throws -> String {
        let found = try library.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM note WHERE title = ? ORDER BY rowid LIMIT 1", arguments: [title])
        }
        return try #require(found)
    }
}

/// The app's side of the socket, for tests: answers every request with `handler` (nil: stays silent).
final class FakeApp: @unchecked Sendable {
    typealias Handler = @Sendable (AppSocketRequest) -> AppSocketResponse?
    private let lock = NSLock()
    private var seen: [AppSocketRequest] = []
    private var stopped = false
    private var listener: Int32 = -1
    let path: String

    init(paths: AppPaths, handler: @escaping Handler) throws {
        path = AppSocket.path(for: paths)
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AppSocket.address(for: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0 && listen(listener, 8) == 0)
        chmod(path, 0o600)
        let fd = listener
        Thread.detachNewThread { [self] in
            while !isStopped {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 50) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                if case .line(let data) = AppSocket.readLine(from: client, maxBytes: AppSocket.maxRequestBytes),
                   let request = try? JSONDecoder().decode(AppSocketRequest.self, from: data) {
                    lock.withLock { seen.append(request) }
                    if let response = handler(request), var out = try? JSONEncoder().encode(response) {
                        out.append(0x0A)
                        _ = AppSocket.writeAll(out, to: client)
                    } else {
                        // Silent: hold the connection until the client gives up.
                        var gone = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                        while !isStopped, poll(&gone, 1, 50) == 0 {}
                    }
                }
                close(client)
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }
    var requests: [AppSocketRequest] { lock.withLock { seen } }

    func stop() {
        lock.withLock { stopped = true }
        close(listener)
        unlink(path)
    }

    deinit { if !isStopped { stop() } }
}

private func run(
    _ argv: [String], context: AutomationContext = .fixed(TestLibrary.epoch)
) -> CLIResult {
    let capture = OutputCapture()
    let io = CLIIO(
        readStdin: { Data() }, stdinIsTTY: false, write: { capture.write($0) },
        writeError: { capture.writeError($0) }, stdoutIsTTY: false)
    let exit = TheoNotesCLI.run(argv, context: context, io: io)
    return CLIResult(exit: exit, out: String(decoding: capture.data, as: UTF8.self), outData: capture.data, err: capture.errorText)
}

private func appCLI(_ lib: ShortLibrary, _ args: String..., context: AutomationContext = .fixed(TestLibrary.epoch)) -> CLIResult {
    run(["baerchen", "--data-dir", lib.root.path] + args, context: context)
}

private func ok(_ result: SelectionResult = SelectionResult()) -> FakeApp.Handler {
    { AppSocketResponse(id: $0.id, result: result) }
}

private func json(_ text: String) throws -> JSONValue { try JSONValue(parsing: Data(text.utf8)) }

private func paramsOf(_ app: FakeApp, method: String) -> OpenParams? {
    app.requests.last { $0.method == method }?.params
}

@Suite struct AppSocketPathTests {
    @Test func socketPathFallsBackForLongDataDirs() {
        let long = AppPaths(root: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120)))
        let p = AppSocket.path(for: long, home: URL(fileURLWithPath: "/Users/me"))
        #expect(p.utf8.count <= 103 && p.hasPrefix("/Users/me/Library/Caches/com.truebrewbirdie.baerchen/sockets/"))
        #expect(p.hasSuffix(".sock"))
        // First 16 hex digits of SHA-256 of the data dir path.
        let name = p.split(separator: "/").last.map(String.init) ?? ""
        #expect(name.count == 16 + ".sock".count)
        #expect(AppSocket.path(for: long, home: URL(fileURLWithPath: "/Users/me")) == p)
        let other = AppPaths(root: URL(fileURLWithPath: "/tmp/" + String(repeating: "y", count: 120)))
        #expect(AppSocket.path(for: other, home: URL(fileURLWithPath: "/Users/me")) != p)
    }

    @Test func socketPathIsInTheDataDirWhenItFits() {
        #expect(AppSocket.path(for: AppPaths(root: URL(fileURLWithPath: "/tmp/lib"))) == "/tmp/lib/app.sock")
        // 103 bytes fit, 104 do not.
        let fits = "/tmp/" + String(repeating: "a", count: 103 - "/tmp/".count - "/app.sock".count)
        let tooLong = fits + "a"
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(AppSocket.path(for: AppPaths(root: URL(fileURLWithPath: fits)), home: home) == fits + "/app.sock")
        #expect(AppSocket.path(for: AppPaths(root: URL(fileURLWithPath: tooLong)), home: home).hasPrefix("/Users/me/Library/Caches/"))
    }

    @Test func onlyTheSameUserIsAllowed() {
        #expect(AppSocket.allows(peer: 501, own: 501))
        #expect(!AppSocket.allows(peer: 502, own: 501))
        #expect(!AppSocket.allows(peer: nil, own: 501))
        #expect(!AppSocket.allows(peer: 0, own: 501))
    }

    @Test func requestsAndResponsesRoundTripThroughJSON() throws {
        let request = AppSocketRequest(
            id: 7, method: "open",
            params: OpenParams(noteId: "N1", header: "H", edit: true, newWindow: false, float: true, selectionText: "x"))
        let again = try JSONDecoder().decode(AppSocketRequest.self, from: JSONEncoder().encode(request))
        #expect(again == request)
        let response = AppSocketResponse(id: 7, error: AppSocketError(code: .ambiguous, message: "Selection text matches 2 times"))
        let back = try JSONDecoder().decode(AppSocketResponse.self, from: JSONEncoder().encode(response))
        #expect(back == response && back.result == nil)
    }

    @Test func readLineStopsAtTheLimitAndHandlesPartialInput() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        _ = AppSocket.writeAll(Data("hello\nrest".utf8), to: pair[0])
        guard case .line(let first) = AppSocket.readLine(from: pair[1], maxBytes: 100) else { throw TestFailure() }
        #expect(String(decoding: first, as: UTF8.self) == "hello")

        var big: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &big) == 0)
        defer { close(big[0]); close(big[1]) }
        let chunk = Data(repeating: 0x61, count: 600) + Data([0x0A])
        let sender = big[0]
        let writer = Thread { _ = AppSocket.writeAll(chunk, to: sender) }
        writer.start()
        guard case .tooLong = AppSocket.readLine(from: big[1], maxBytes: 512) else { throw TestFailure() }
    }

    struct TestFailure: Error {}
}

@Suite struct AppCLITests {
    // MARK: no app

    @Test func getSelectionWithoutAppIsEmptySuccess() throws {
        let lib = try TestLibrary.make()
        let json = cli(lib, "app", "get-selection", "--format", "json")
        #expect(json.out == "{}\n" && json.exit == 0)
        let tsv = cli(lib, "app", "get-selection")
        #expect(tsv.out == "" && tsv.exit == 0 && tsv.err == "")
        let csv = cli(lib, "app", "get-selection", "--format", "csv")
        #expect(csv.out == "" && csv.exit == 0)
    }

    @Test func getSelectionChecksFieldsBeforeLookingForTheApp() throws {
        let lib = try TestLibrary.make()
        let bad = cli(lib, "app", "get-selection", "--fields", "nope")
        #expect(bad.exit == 64 && bad.err.contains("Unknown field: nope"))
    }

    @Test func appOpenWithDataDirAndNoAppFails() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Mars")])
        let result = cli(lib, "app", "open", "--title", "Mars")
        #expect(result.exit == 1)
        #expect(result.err == "Error: Theo Notes is not running with this library\n")
    }

    @Test func appOpenUsageErrorsComeBeforeTheAppLookup() throws {
        let lib = try TestLibrary.make()
        #expect(cli(lib, "app", "open").exit == 64)
        #expect(cli(lib, "app", "open").err == "Error: Note ID or title is required\n")
        let both = cli(lib, "app", "open", "ID", "--selection-text", "a", "--selection-offset", "1")
        #expect(both.exit == 64 && both.err.contains("selection text or selection offset, not both"))
        let negative = cli(lib, "app", "open", "ID", "--selection-offset=-1")
        #expect(negative.exit == 64 && negative.err.contains("Selection offset must be non-negative"))
    }

    // MARK: launching (M5-R17)

    @Test func theDefaultLibraryLaunchesTheAppWithTheResolvedNoteId() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let id = try lib.id(titled: "Mars")
        let launched = Mutex<[URL]>([])
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.production = lib.paths
        context.launcher = { url in launched.withLock { $0.append(url) } }
        // By title: the URL carries the id the library resolved, never the title (M5-R190).
        let result = run(
            ["baerchen", "app", "open", "--title", "mars", "--header", "Phobos+Deimos&x", "--edit", "--new-window", "--float"],
            context: context)
        #expect(result.exit == 0 && result.out == "")
        #expect(launched.withLock { $0 }.map(\.absoluteString) == [
            "theonotes://x-callback-url/open-note?id=\(id)&header=Phobos%2BDeimos%26x&edit=yes&new_window=yes&float=yes"
        ])

        let bad = run(
            ["baerchen", "app", "open", id, "--selection-text", "é", "--selection-offset", "x"], context: context)
        #expect(bad.exit == 64)

        launched.withLock { $0 = [] }
        let selecting = run(["baerchen", "app", "open", id, "--selection-offset", "5", "--selection-length", "2"], context: context)
        #expect(selecting.exit == 0)
        #expect(launched.withLock { $0 }.map(\.absoluteString) == [
            "theonotes://x-callback-url/open-note?id=\(id)&selection_offset=5&selection_length=2"
        ])
    }

    @Test func aNoteTheLibraryDoesNotResolveIsNeverLaunched() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let launched = Mutex(0)
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.production = lib.paths
        context.launcher = { _ in launched.withLock { $0 += 1 } }
        let byTitle = run(["baerchen", "app", "open", "--title", "Nope"], context: context)
        #expect(byTitle.exit == 1 && byTitle.err.contains("No active note has the title Nope."))
        let byId = run(["baerchen", "app", "open", "NOPE-1"], context: context)
        #expect(byId.exit == 1 && byId.err.contains("Note not found: NOPE-1"))
        #expect(launched.withLock { $0 } == 0)
    }

    @Test func aFailedLaunchIsAppUnavailable() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.production = lib.paths
        context.launcher = { _ in throw AutomationError(code: .appUnavailable, message: "Theo Notes could not be launched") }
        let result = run(["baerchen", "app", "open", "--title", "Mars"], context: context)
        #expect(result.exit == 1 && result.err == "Error: Theo Notes could not be launched\n")
    }

    @Test func aCustomLibraryNeverLaunchesTheApp() throws {
        let lib = try ShortLibrary()
        let launched = Mutex(0)
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.launcher = { _ in launched.withLock { $0 += 1 } }
        let result = appCLI(lib, "app", "open", "ABC-1", context: context)
        #expect(result.exit == 1 && launched.withLock { $0 } == 0)
    }

    // MARK: with an app

    @Test func appOpenSendsTheResolvedNoteOverTheSocket() throws {
        let lib = try ShortLibrary([("# Mars\nPhobos", false)])
        let app = try FakeApp(paths: lib.paths, handler: ok())
        let id = try lib.id(titled: "Mars")
        let result = appCLI(
            lib, "app", "open", "--title", "mars", "--header", "Moons", "--edit", "--float", "--new-window",
            "--selection-text", "Phobos")
        #expect(result.exit == 0 && result.out == "" && result.err == "")
        let params = try #require(paramsOf(app, method: "open"))
        #expect(params == OpenParams(
            noteId: id, header: "Moons", edit: true, newWindow: true, float: true, selectionText: "Phobos"))
        // `ping` came first, then `open`.
        #expect(app.requests.map(\.method) == ["ping", "open"])
        app.stop()
    }

    @Test func appOpenByIdWithAnOffsetSendsTheOffsetAndLength() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let app = try FakeApp(paths: lib.paths, handler: ok())
        let id = try lib.id(titled: "Mars")
        #expect(appCLI(lib, "app", "open", id, "--selection-offset", "3", "--selection-length", "2").exit == 0)
        let params = try #require(paramsOf(app, method: "open"))
        #expect(params.noteId == id && params.selectionOffset == 3 && params.selectionLength == 2 && params.selectionText == nil)
        #expect(!params.edit && !params.newWindow && !params.float && params.header == nil)
        app.stop()
    }

    @Test func appOpenOfAnUnknownNoteFailsBeforeTheOpenRequest() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths, handler: ok())
        let result = appCLI(lib, "app", "open", "--title", "Nope")
        #expect(result.exit == 1 && result.err.contains("No active note has the title Nope."))
        #expect(app.requests.map(\.method) == ["ping"])
        app.stop()
    }

    @Test func anErrorFromTheAppIsReported() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let app = try FakeApp(paths: lib.paths) { request in
            request.method == "ping"
                ? AppSocketResponse(id: request.id, result: SelectionResult())
                : AppSocketResponse(id: request.id, error: AppSocketError(code: .ambiguous, message: "Selection text matches 2 times"))
        }
        let result = appCLI(lib, "app", "open", "--title", "Mars", "--selection-text", "a")
        #expect(result.exit == 1 && result.err == "Error: Selection text matches 2 times\n")
        app.stop()
    }

    @Test func anErrorFromTheAppIsAJSONEnvelopeForGetSelection() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths) { request in
            AppSocketResponse(id: request.id, error: AppSocketError(code: .busy, message: "The library is busy"))
        }
        let result = appCLI(lib, "app", "get-selection", "--format", "json")
        #expect(result.exit == 1)
        #expect(try result.json()["error"]?["code"]?.string == "busy")
        app.stop()
    }

    /// M9M-R62: a locked app answers `app_locked`; the CLI reports that code, not `internal`.
    @Test func aLockedAppIsReportedAsAppLockedForOpenAndGetSelection() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let app = try FakeApp(paths: lib.paths) { request in
            request.method == "ping"
                ? AppSocketResponse(id: request.id, result: SelectionResult())
                : AppSocketResponse(id: request.id, error: AppSocketError(code: .appLocked, message: "Theo Notes is locked"))
        }
        let open = appCLI(lib, "app", "open", "--title", "Mars")
        #expect(open.exit == 1 && open.err == "Error: Theo Notes is locked\n" && open.out.isEmpty)
        let selection = appCLI(lib, "app", "get-selection", "--format", "json")
        #expect(selection.exit == 1)
        #expect(try selection.json()["error"]?["code"]?.string == "app_locked")
        #expect(!selection.out.contains("Mars"))
        app.stop()
    }

    @Test func getSelectionPrintsTheNoteAndTheSelection() throws {
        let lib = try ShortLibrary([("# Mars\nPhobos", false)])
        let id = try lib.id(titled: "Mars")
        let app = try FakeApp(
            paths: lib.paths,
            handler: ok(SelectionResult(noteId: id, selectionOffset: 7, selectionLength: 6, selectionText: "Phobos")))
        let tsv = appCLI(lib, "app", "get-selection")
        #expect(tsv.exit == 0)
        #expect(tsv.out == "\(id)\tMars\t7\t6\tPhobos\n")
        let object = try appCLI(lib, "app", "get-selection", "--format", "json", "--fields", "all,content").json()
        #expect(object["id"]?.string == id)
        #expect(object["selectionOffset"]?.intValue == 7 && object["selectionLength"]?.intValue == 6)
        #expect(object["selectionText"]?.string == "Phobos" && object["content"]?.string == "# Mars\nPhobos")
        #expect(object["locked"]?.string == "no")
        app.stop()
    }

    @Test func aCaretHasLengthZeroAndEmptyText() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let id = try lib.id(titled: "Mars")
        let app = try FakeApp(
            paths: lib.paths, handler: ok(SelectionResult(noteId: id, selectionOffset: 2, selectionLength: 0, selectionText: "")))
        let tsv = appCLI(lib, "app", "get-selection", "--fields", "selectionOffset,selectionLength,selectionText")
        #expect(tsv.out == "2\t0\t\n")
        app.stop()
    }

    @Test func aLockedNoteHasNoSelectionAndNoContent() throws {
        let lib = try ShortLibrary([("# Secret", false), ("", true)])
        let id = try lib.lockedId()
        let app = try FakeApp(paths: lib.paths, handler: ok(SelectionResult(noteId: id)))
        let tsv = appCLI(lib, "app", "get-selection", "--fields", "id,locked,selectionOffset,selectionText,content")
        #expect(tsv.out == "\(id)\tyes\t\t\t\n")
        app.stop()
    }

    @Test func noOpenNoteIsEmptyOutput() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths, handler: ok())
        let json = appCLI(lib, "app", "get-selection", "--format", "json")
        #expect(json.out == "{}\n" && json.exit == 0)
        #expect(appCLI(lib, "app", "get-selection").out == "")
        app.stop()
    }

    @Test func aNoteTheAppNamesButTheLibraryLacksIsNoteNotFound() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths, handler: ok(SelectionResult(noteId: "GONE")))
        let result = appCLI(lib, "app", "get-selection")
        #expect(result.exit == 1 && result.err.contains("Note not found: GONE"))
        app.stop()
    }

    // MARK: client

    @Test func aMissingOrStaleSocketIsNotRunning() throws {
        let lib = try ShortLibrary()
        let request = AppSocketRequest(id: 1, method: "ping")
        var failure: AutomationError?
        do { _ = try AppSocketClient.send(request, paths: lib.paths) } catch { failure = error }
        #expect(failure == AutomationError(code: .appUnavailable, message: "Theo Notes is not running with this library"))
        // A socket file nobody listens on (a crashed app) is the same.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AppSocket.address(for: AppSocket.path(for: lib.paths)))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        failure = nil
        do { _ = try AppSocketClient.send(request, paths: lib.paths) } catch { failure = error }
        let stale = try #require(failure)
        #expect(AppSocketClient.isNotRunning(stale))
    }

    @Test func clientAndServerRoundTrip() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths, handler: ok(SelectionResult(noteId: "N", selectionOffset: 1)))
        let response = try AppSocketClient.send(AppSocketRequest(id: 42, method: "getSelection"), paths: lib.paths)
        #expect(response.id == 42 && response.result == SelectionResult(noteId: "N", selectionOffset: 1) && response.error == nil)
        app.stop()
    }

    @Test func aSilentAppTimesOutAsUnavailableButNotAsNotRunning() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths) { _ in nil }
        var failure: AutomationError?
        do {
            _ = try AppSocketClient.send(
                AppSocketRequest(id: 1, method: "ping"), paths: lib.paths, replyTimeout: .milliseconds(200))
        } catch { failure = error }
        let error = try #require(failure)
        #expect(error.code == .appUnavailable && !AppSocketClient.isNotRunning(error))
        #expect(error.message == "Theo Notes did not answer in time")
        app.stop()
    }

    @Test func getSelectionWithASilentAppIsAnError() throws {
        let lib = try ShortLibrary()
        let app = try FakeApp(paths: lib.paths) { _ in nil }
        // The CLI's own reply timeout is 5 s; the point here is only that it is not "empty success".
        let started = Date()
        let result = appCLI(lib, "app", "get-selection")
        #expect(result.exit == 1 && result.err.contains("did not answer"))
        #expect(Date().timeIntervalSince(started) < 8)
        app.stop()
    }
}

@Suite struct AppMCPToolsTests {
    private func tools(
        _ lib: ShortLibrary, context: AutomationContext = .fixed(TestLibrary.epoch), scope: NoteScope = .unrestricted
    ) -> MCPTools {
        let library = lib.library
        return MCPTools(
            libraryProvider: LibraryProvider { () throws(AutomationError) -> AutomationLibrary in library },
            context: context, scope: scope)
    }

    private func call(_ tools: MCPTools, _ name: String, _ arguments: String = "{}") async throws -> Result<JSONValue, AutomationError> {
        await tools.call(name, arguments: try json(arguments))
    }

    @Test func appOpenNoteSendsTheRequestAndReturnsAnEmptyObject() async throws {
        let lib = try ShortLibrary([("# Mars\nPhobos", false)])
        let app = try FakeApp(paths: lib.paths, handler: ok())
        let id = try lib.id(titled: "Mars")
        let result = try await call(
            tools(lib), "app_open_note",
            #"{"title":"Mars","header":"Moons","edit":true,"newWindow":true,"float":true,"selectionText":"Phobos"}"#)
        #expect(try result.get() == .object([]))
        #expect(paramsOf(app, method: "open") == OpenParams(
            noteId: id, header: "Moons", edit: true, newWindow: true, float: true, selectionText: "Phobos"))
        app.stop()
    }

    @Test func appOpenNoteChecksArgumentsFirst() async throws {
        let lib = try ShortLibrary()
        let t = tools(lib)
        var failure = try await call(t, "app_open_note", "{}")
        #expect(failure.error?.code == .usage && failure.error?.message == "Note ID or title is required")
        failure = try await call(t, "app_open_note", #"{"id":"x","selectionText":"a","selectionOffset":1}"#)
        #expect(failure.error?.code == .usage)
        failure = try await call(t, "app_open_note", #"{"id":"x","selectionOffset":-1}"#)
        #expect(failure.error?.message == "Selection offset must be non-negative")
        failure = try await call(t, "app_open_note", #"{"id":"x","edit":"yes"}"#)
        #expect(failure.error?.message == "Invalid value for edit")
    }

    @Test func appOpenNoteLaunchesTheAppWithTheResolvedIdOnlyForANoteItResolves() async throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let id = try lib.id(titled: "Mars")
        let launched = Mutex<[URL]>([])
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.production = lib.paths
        context.launcher = { url in launched.withLock { $0.append(url) } }
        let t = tools(lib, context: context)
        let missing = try await call(t, "app_open_note", #"{"title":"Nope"}"#)
        #expect(missing.error?.code == .noteNotFound)
        #expect(launched.withLock { $0 }.isEmpty)
        #expect(try await call(t, "app_open_note", #"{"title":"mars","edit":true}"#).get() == .object([]))
        #expect(launched.withLock { $0 }.map(\.absoluteString) == ["theonotes://x-callback-url/open-note?id=\(id)&edit=yes"])
    }

    /// M5-R190 with a real scope (Task 11 merged after Task 12 was written): a scoped server never
    /// cold-launches a note outside its scope, by id or by title.
    @Test func aScopedServerNeverColdLaunchesAnOutOfScopeNote() async throws {
        let lib = try ShortLibrary([("# Work\n#work", false), ("# Home\n#home", false)])
        let work = try lib.id(titled: "Work")
        let home = try lib.id(titled: "Home")
        let launched = Mutex<[URL]>([])
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.production = lib.paths
        context.launcher = { url in launched.withLock { $0.append(url) } }
        let t = tools(lib, context: context, scope: NoteScope(onlyTags: ["work"], excludeTags: []))
        let byId = try await call(t, "app_open_note", #"{"id":"\#(home)"}"#)
        #expect(byId.error?.code == .outOfScope)
        let byTitle = try await call(t, "app_open_note", #"{"title":"Home"}"#)
        #expect(byTitle.error?.code == .noteNotFound)
        #expect(launched.withLock { $0 }.isEmpty)
        #expect(try await call(t, "app_open_note", #"{"title":"Work"}"#).get() == .object([]))
        #expect(launched.withLock { $0 }.map(\.absoluteString) == ["theonotes://x-callback-url/open-note?id=\(work)"])
    }

    @Test func appOpenNoteWithoutAppForACustomLibraryIsAppUnavailable() async throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let failure = try await call(tools(lib), "app_open_note", #"{"title":"Mars"}"#)
        #expect(failure.error == AutomationError(code: .appUnavailable, message: "Theo Notes is not running with this library"))
    }

    @Test func appGetSelectionReturnsMetadataAndSelection() async throws {
        let lib = try ShortLibrary([("# Mars\nPhobos", false)])
        let id = try lib.id(titled: "Mars")
        let app = try FakeApp(
            paths: lib.paths,
            handler: ok(SelectionResult(noteId: id, selectionOffset: 7, selectionLength: 6, selectionText: "Phobos")))
        let value = try await call(tools(lib), "app_get_selection").get()
        #expect(value["metadata"]?["id"]?.string == id && value["metadata"]?["title"]?.string == "Mars")
        #expect(value["selection"]?["offset"]?.intValue == 7 && value["selection"]?["length"]?.intValue == 6)
        #expect(value["selection"]?["text"]?.string == "Phobos")
        #expect(value["content"] == nil)
        let withContent = try await call(tools(lib), "app_get_selection", #"{"includeContent":true}"#).get()
        #expect(withContent["content"]?.string == "# Mars\nPhobos")
        app.stop()
    }

    @Test func aCaretOmitsTheSelection() async throws {
        let lib = try ShortLibrary([("# Mars", false)])
        let id = try lib.id(titled: "Mars")
        let app = try FakeApp(
            paths: lib.paths, handler: ok(SelectionResult(noteId: id, selectionOffset: 2, selectionLength: 0, selectionText: "")))
        let value = try await call(tools(lib), "app_get_selection").get()
        #expect(value["metadata"]?["id"]?.string == id && value["selection"] == nil)
        app.stop()
    }

    @Test func aLockedNoteHasMetadataOnly() async throws {
        let lib = try ShortLibrary([("", true)])
        let id = try lib.lockedId()
        let app = try FakeApp(paths: lib.paths, handler: ok(SelectionResult(noteId: id, selectionOffset: 1, selectionLength: 1, selectionText: "x")))
        let value = try await call(tools(lib), "app_get_selection", #"{"includeContent":true}"#).get()
        #expect(value["metadata"]?["locked"] == .bool(true) && value["selection"] == nil && value["content"] == nil)
        app.stop()
    }

    @Test func nothingOpenOrNoAppIsAnEmptyObject() async throws {
        let lib = try ShortLibrary()
        let t = tools(lib)
        #expect(try await call(t, "app_get_selection").get() == .object([]))
        let app = try FakeApp(paths: lib.paths, handler: ok())
        #expect(try await call(t, "app_get_selection").get() == .object([]))
        app.stop()
    }

    @Test func appGetSelectionChecksArgumentTypes() async throws {
        let lib = try ShortLibrary()
        let failure = try await call(tools(lib), "app_get_selection", #"{"includeContent":"yes"}"#)
        #expect(failure.error?.message == "Invalid value for includeContent")
    }
}

extension Result where Failure == AutomationError {
    var error: AutomationError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}


/// A server that accepts and then sends one byte every 50 ms, never a newline.
final class TricklingServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false

    init(path: String) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AppSocket.address(for: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0 && listen(listener, 4) == 0)
        let fd = listener
        Thread.detachNewThread { [self] in
            while !isStopped {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 50) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                while !isStopped, AppSocket.writeAll(Data([0x41]), to: client) { usleep(50_000) }
                close(client)
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        lock.withLock { stopped = true }
        close(listener)
        unlink(path)
    }
}

@Suite struct AppSocketHardeningTests {
    @Test func aPendingOrBackloggedConnectIsNeverNotRunning() throws {
        let lib = try ShortLibrary()
        let path = AppSocket.path(for: lib.paths)
        // A full backlog (EAGAIN) that does not clear: busy, which callers treat as live.
        let backlogged = AppSocket.connect(path: path, timeout: .milliseconds(100)) { _, _ in
            errno = EAGAIN
            return -1
        }
        #expect(backlogged == .failure(.busy))
        // Any other failure says nothing about the instance.
        let denied = AppSocket.connect(path: path, timeout: .milliseconds(100)) { _, _ in
            errno = EACCES
            return -1
        }
        #expect(denied == .failure(.failed(EACCES)))
        // A connect that is already in progress is waited for, not retried and not "not running".
        let pending = AppSocket.connect(path: path, timeout: .milliseconds(100)) { _, _ in
            errno = EALREADY
            return -1
        }
        if case .success(let fd) = pending { close(fd) }
        #expect(pending != .failure(.notRunning))
        // Only a refusal or a missing file is "not running".
        let refused = AppSocket.connect(path: path, timeout: .milliseconds(100)) { _, _ in
            errno = ECONNREFUSED
            return -1
        }
        #expect(refused == .failure(.refused))
        let missing = AppSocket.connect(path: path, timeout: .milliseconds(100)) { _, _ in
            errno = ENOENT
            return -1
        }
        #expect(missing == .failure(.notRunning))
    }

    @Test func aMissingOrRefusedSocketIsNotRunning() throws {
        let lib = try ShortLibrary()
        let path = AppSocket.path(for: lib.paths)
        #expect(AppSocket.connect(path: path, timeout: .milliseconds(100)) == .failure(.notRunning))
    }

    @Test func aTricklingReplyIsCutOffAtTheDeadline() throws {
        let lib = try ShortLibrary()
        let server = try TricklingServer(path: AppSocket.path(for: lib.paths))
        defer { server.stop() }
        let started = ContinuousClock.now
        var failure: AutomationError?
        do { _ = try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: lib.paths, replyTimeout: .milliseconds(400)) }
        catch { failure = error }
        let elapsed = ContinuousClock.now - started
        #expect(failure?.message == AppSocketClient.timeoutMessage)
        // Each byte arrives inside any per-read timeout; only the whole-reply deadline stops it.
        #expect(elapsed < .seconds(2))
    }

    @Test func readLineHonoursAnAbsoluteDeadline() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let sender = pair[0]
        let writer = Thread {
            for _ in 0..<40 {
                _ = AppSocket.writeAll(Data([0x41]), to: sender)
                usleep(30_000)
            }
        }
        writer.start()
        let started = ContinuousClock.now
        guard case .timeout = AppSocket.readLine(from: pair[1], maxBytes: 1000, deadline: started + .milliseconds(300)) else {
            Issue.record("expected a timeout")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}


/// Failures that say nothing about whether an app runs are never "not running" (ruling M5-R204).
@Suite struct AppSocketIndeterminateTests {
    /// A socket file nobody listens on, with the given mode.
    private func leaveSocket(_ lib: ShortLibrary, mode: mode_t = 0o600) throws -> String {
        let path = AppSocket.path(for: lib.paths)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AppSocket.address(for: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(bound == 0)
        chmod(path, mode)
        return path
    }

    @Test func permissionDeniedIsCouldNotReachNotNotRunning() throws {
        let lib = try ShortLibrary()
        _ = try leaveSocket(lib, mode: 0o000)
        var failure: AutomationError?
        do { _ = try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: lib.paths) } catch { failure = error }
        let error = try #require(failure)
        #expect(error.code == .appUnavailable && error.message == "Could not reach Theo Notes: Permission denied")
        #expect(!AppSocketClient.isNotRunning(error))
    }

    @Test func anImpossibleSocketPathIsCouldNotReach() throws {
        let long = AppPaths(root: URL(fileURLWithPath: "/tmp/" + String(repeating: "r", count: 120)))
        var failure: AutomationError?
        do {
            _ = try AppSocketClient.send(
                AppSocketRequest(id: 1, method: "ping"), paths: long,
                home: URL(fileURLWithPath: "/tmp/" + String(repeating: "h", count: 120)))
        } catch { failure = error }
        #expect(failure == AutomationError(code: .appUnavailable, message: "Could not reach Theo Notes: the socket path is too long"))
    }

    @Test func aRefusalWhileTheLockIsHeldIsALiveAppNotAbsence() throws {
        let lib = try ShortLibrary()
        let path = try leaveSocket(lib)
        // Refused (nobody accepts), but a live app holds the lock: a busy app, not a missing one.
        let lockFD = open(path + ".lock", O_RDWR | O_CREAT, 0o600)
        defer { close(lockFD) }
        #expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        #expect(AppSocket.lockIsHeld(socketPath: path))
        var failure: AutomationError?
        do { _ = try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: lib.paths) } catch { failure = error }
        let error = try #require(failure)
        #expect(error.message == AppSocketClient.timeoutMessage && !AppSocketClient.isNotRunning(error))
        // Without the lock the same refusal is a crashed app.
        flock(lockFD, LOCK_UN)
        #expect(!AppSocket.lockIsHeld(socketPath: path))
        failure = nil
        do { _ = try AppSocketClient.send(AppSocketRequest(id: 1, method: "ping"), paths: lib.paths) } catch { failure = error }
        #expect(failure.map(AppSocketClient.isNotRunning) == true)
    }

    @Test func getSelectionReportsAnIndeterminateFailureInsteadOfEmptyOutput() throws {
        let lib = try ShortLibrary()
        _ = try leaveSocket(lib, mode: 0o000)
        let result = run(["baerchen", "--data-dir", lib.root.path, "app", "get-selection"])
        #expect(result.exit == 1 && result.out == "")
        #expect(result.err == "Error: Could not reach Theo Notes: Permission denied\n")
        let json = run(["baerchen", "--data-dir", lib.root.path, "app", "get-selection", "--format", "json"])
        #expect(json.exit == 1 && json.out.contains("app_unavailable"))
    }

    @Test func anIndeterminateFailureNeverColdLaunchesTheApp() throws {
        let lib = try ShortLibrary([("# Mars", false)])
        _ = try leaveSocket(lib, mode: 0o000)
        let launched = Mutex(0)
        var context = AutomationContext.fixed(TestLibrary.epoch)
        context.production = lib.paths
        context.launcher = { _ in launched.withLock { $0 += 1 } }
        let result = run(["baerchen", "app", "open", "--title", "Mars"], context: context)
        #expect(result.exit == 1 && result.err == "Error: Could not reach Theo Notes: Permission denied\n")
        #expect(launched.withLock { $0 } == 0)
    }

    @Test func aHugeDeadlineDoesNotOverflow() {
        let far = ContinuousClock.now + .seconds(Int64.max / 4)
        #expect(AppSocket.remainingMilliseconds(until: far) == Int32.max)
        #expect(AppSocket.remainingMilliseconds(until: ContinuousClock.now - .seconds(1)) == 0)
        let soon = AppSocket.remainingMilliseconds(until: ContinuousClock.now + .milliseconds(500))
        #expect(soon > 0 && soon <= 500)
    }
}
