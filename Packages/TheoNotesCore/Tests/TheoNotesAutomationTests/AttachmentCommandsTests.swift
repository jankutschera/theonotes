// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A fetcher that returns canned bytes and remembers what it was asked for.
final class StubFetcher: URLFetcher {
    private let outcome: Result<(data: Data, suggestedName: String?), any Error>
    private let asked = Mutex<[URL]>([])
    private let offPool = Mutex<[Bool]>([])

    init(_ data: Data, name: String? = nil) { outcome = .success((data, name)) }
    init(failing error: any Error) { outcome = .failure(error) }

    var urls: [URL] { asked.withLock { $0 } }
    /// Per call: whether it ran on `OffPoolExecutor` rather than the shared cooperative pool.
    var callsOffThePool: [Bool] { offPool.withLock { $0 } }

    func fetch(_ url: URL) async throws -> (data: Data, suggestedName: String?) {
        asked.withLock { $0.append(url) }
        offPool.withLock { $0.append(OffPoolExecutor.isCurrent) }
        return try outcome.get()
    }
}

/// `attachments list|add|add-url|delete|save` end to end, against temporary libraries.
@Suite struct AttachmentCommandsTests {
    private func store(_ lib: TestLibrary) -> AttachmentStore {
        AttachmentStore(paths: lib.paths, database: lib.library.database)
    }

    @discardableResult
    private func place(_ lib: TestLibrary, _ id: String, _ name: String, _ data: Data = Data("x".utf8)) throws -> String {
        try store(lib).add(data: data, filename: name, to: id)
    }

    private func exists(_ lib: TestLibrary, _ id: String, _ name: String) -> Bool {
        store(lib).url(for: name, noteId: id) != nil
    }

    private func filesOnDisk(_ lib: TestLibrary, _ id: String) -> [String] {
        let dir = lib.paths.root.appendingPathComponent("Attachments").appendingPathComponent(id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: add

    @Test func addFromStdinAppendsLinkAndRenamesOnCollision() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](photo.jpg)")])
        let id = try lib.firstId()
        try place(lib, id, "photo.jpg", Data([9]))
        let run = cli(lib, "attachments", "add", id, "--filename", "photo.jpg", stdin: Data([1, 2, 3]))
        #expect(run.exit == 0 && run.out == "" && run.err == "")
        #expect(try lib.text(id).hasSuffix("\n" + AttachmentMarkdown.link(for: "photo 2.jpg") + "\n"))
        #expect(cli(lib, "attachments", "list", id).out == "photo.jpg\t1\nphoto 2.jpg\t3\n")
        #expect(try Data(contentsOf: #require(store(lib).url(for: "photo 2.jpg", noteId: id))) == Data([1, 2, 3]))
    }

    @Test func addedFilesCarryAQuarantineRecordAndTheIndexerSeesThem() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "add", id, "--filename", "tool.sh", stdin: Data("echo".utf8)).exit == 0)
        let url = try #require(store(lib).url(for: "tool.sh", noteId: id))
        #expect(AttachmentQuarantine.properties(of: url.path) != nil)
        let rows = try lib.library.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId = ? AND filenameKey = 'tool.sh'", arguments: [id])
        }
        #expect(rows == 1)
        #expect(try lib.text(id) == "# T\n" + AttachmentMarkdown.link(for: "tool.sh") + "\n")
    }

    @Test func addPutsTheLinkBeforeBottomTags() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\nbody\n#tag")])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "add", id, "--title", "T", "--filename", "p.png", stdin: Data([1])).exit == 64)
        #expect(cli(lib, "attachments", "add", "--title", "T", "--filename", "p.png", stdin: Data([1])).exit == 0)
        #expect(try lib.text(id) == "# T\nbody\n![](p.png)\n#tag")
    }

    @Test func addUsesOnlyTheLastPathComponentOfTheFilename() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "add", id, "--filename", "../../etc/evil.png", stdin: Data([1])).exit == 0)
        #expect(filesOnDisk(lib, id) == ["evil.png"])
        let bad = cli(lib, "attachments", "add", id, "--filename", "..", stdin: Data([1]))
        #expect(bad.exit == 64 && bad.err == "Error: Invalid filename: ..\n")
        #expect(filesOnDisk(lib, id) == ["evil.png"])
    }

    @Test func addStopsReadingStdinOnceItIsOverTheLimit() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let served = Mutex(0)
        let asked = Mutex<[Int]>([])
        let errors = OutputCapture()
        // An unbounded stdin, served in 100-byte pieces: a reader that did not stop would never return.
        let bounded: @Sendable (Int) -> Data = { limit in
            asked.withLock { $0.append(limit) }
            var data = Data()
            while data.count < limit {
                let piece = Data(repeating: 1, count: min(100, limit - data.count))
                data.append(piece)
                served.withLock { $0 += piece.count }
            }
            return data
        }
        let io = CLIIO(
            readStdin: { Issue.record("stdin was read to the end"); return Data() }, stdinIsTTY: false,
            write: { _ in }, writeError: { errors.writeError($0) }, stdoutIsTTY: false, readStdinBounded: bounded)
        let context = AutomationContext(
            now: { TestLibrary.epoch }, calendar: .current, locale: .current, environment: [:],
            maxAttachmentBytes: 1_000)
        let exit = TheoNotesCLI.run(
            ["baerchen", "--data-dir", lib.paths.root.path, "attachments", "add", id, "--filename", "big.bin"],
            context: context, io: io)
        #expect(exit == 64 && errors.errorText == "Error: Attachment is larger than 1000 bytes\n")
        #expect(asked.withLock { $0 } == [1_001] && served.withLock { $0 } == 1_001)
        #expect(filesOnDisk(lib, id).isEmpty)
        #expect(try lib.text(id) == "# T")
        // Exactly at the limit passes; stdin without a bounded reader is cut the same way.
        func plain(_ count: Int) -> CLIIO {
            CLIIO(
                readStdin: { Data(repeating: 2, count: count) }, stdinIsTTY: false, write: { _ in },
                writeError: { _ in }, stdoutIsTTY: false)
        }
        let ok = TheoNotesCLI.run(
            ["baerchen", "--data-dir", lib.paths.root.path, "attachments", "add", id, "--filename", "ok.bin"],
            context: context, io: plain(1_000))
        #expect(ok == 0 && filesOnDisk(lib, id) == ["ok.bin"])
        let tooBig = TheoNotesCLI.run(
            ["baerchen", "--data-dir", lib.paths.root.path, "attachments", "add", id, "--filename", "no.bin"],
            context: context, io: plain(5_000))
        #expect(tooBig == 64)
    }

    @Test func aStdinReadErrorIsAnInternalErrorNotTheEndOfTheInput() throws {
        struct Broken: Error, LocalizedError { var errorDescription: String? { "device not configured" } }
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let errors = OutputCapture()
        let io = CLIIO(
            readStdin: { Data() }, stdinIsTTY: false, write: { _ in }, writeError: { errors.writeError($0) },
            stdoutIsTTY: false, readStdinBounded: { _ in throw Broken() })
        let exit = TheoNotesCLI.run(
            ["baerchen", "--data-dir", lib.paths.root.path, "attachments", "add", id, "--filename", "a.bin"],
            context: .fixed(TestLibrary.epoch), io: io)
        #expect(exit == 1 && errors.errorText == "Error: Standard input could not be read: device not configured\n")
        #expect(filesOnDisk(lib, id).isEmpty)
        #expect(try lib.text(id) == "# T")
    }

    @Test func aFailingWriteToStdoutIsAnInternalErrorNotACrash() throws {
        struct Full: Error, LocalizedError { var errorDescription: String? { "No space left on device" } }
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](a.bin)")])
        let id = try lib.firstId()
        try place(lib, id, "a.bin", Data(repeating: 1, count: 10))
        let errors = OutputCapture()
        let io = CLIIO(
            readStdin: { Data() }, stdinIsTTY: false, write: { _ in }, writeError: { errors.writeError($0) },
            stdoutIsTTY: false, writeChecked: { _ in throw Full() })
        let exit = TheoNotesCLI.run(
            ["baerchen", "--data-dir", lib.paths.root.path, "attachments", "save", id, "--filename", "a.bin"],
            context: .fixed(TestLibrary.epoch), io: io)
        #expect(exit == 1 && errors.errorText == "Error: The attachment could not be written: No space left on device\n")
    }

    @Test func saveOpensOnlyRegularFilesWithoutFollowingSymlinks() throws {
        let dir = try TestLibrary.emptyFolder()
        let regular = dir.appendingPathComponent("regular.bin")
        try Data([1, 2, 3]).write(to: regular)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let fifo = dir.appendingPathComponent("pipe.bin")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let handle = try AttachmentCommands.openRegularFile(regular, named: "regular.bin")
        #expect(try handle.readToEnd() == Data([1, 2, 3]))
        try handle.close()
        for (url, name) in [(link, "link.bin"), (fifo, "pipe.bin"), (dir.appendingPathComponent("gone.bin"), "gone.bin"), (dir, "dir")] {
            do {
                _ = try AttachmentCommands.openRegularFile(url, named: name)
                Issue.record("\(name) was opened")
            } catch {
                #expect(error.code == .attachmentNotFound && error.message == "Attachment not found: \(name)", "\(name)")
            }
        }
    }

    @Test func addChecksArgumentsBeforeTheLibrary() {
        let nowhere = ["baerchen", "--data-dir", "/nonexistent-theonotes-dir"]
        let noFilename = runCLI(nowhere + ["attachments", "add", "X"], stdin: Data([1]))
        #expect(noFilename.exit == 64 && noFilename.err == "Error: --filename is required\n")
        let tty = runCLI(nowhere + ["attachments", "add", "X", "--filename", "a.png"], stdinIsTTY: true)
        #expect(tty.exit == 64 && tty.err == "Error: Attachment data is read from stdin; pipe a file in\n")
        let empty = runCLI(nowhere + ["attachments", "add", "X", "--filename", "a.png"])
        #expect(empty.exit == 64 && empty.err == "Error: Attachment data is empty\n")
        let noNote = runCLI(nowhere + ["attachments", "add", "--filename", "a.png"], stdin: Data([1]))
        #expect(noNote.exit == 64 && noNote.err == "Error: Note ID or title is required\n")
        let blank = runCLI(nowhere + ["attachments", "add", "X", "--filename", "  "], stdin: Data([1]))
        #expect(blank.exit == 64 && blank.err == "Error: --filename is required\n")
        let library = runCLI(nowhere + ["attachments", "add", "X", "--filename", "a.png"], stdin: Data([1]))
        #expect(library.exit == 1 && library.err.hasPrefix("Error: "))
    }

    @Test func addRefusesLockedAndReadOnlyNotesBeforeStoringAnything() throws {
        let lib = try TestLibrary.make([TestNote(text: "# L", locked: true), TestNote(text: "# R", readOnly: true)])
        let locked = try lib.firstId()
        let readOnly = try lib.id(titled: "R")
        let a = cli(lib, "attachments", "add", locked, "--filename", "a.png", stdin: Data([1]))
        #expect(a.exit == 1 && a.err == "Error: Note is locked: \(locked)\n")
        let b = cli(lib, "attachments", "add", readOnly, "--filename", "a.png", stdin: Data([1]))
        #expect(b.exit == 1 && b.err == "Error: Note is read-only: \(readOnly)\n")
        #expect(filesOnDisk(lib, locked).isEmpty && filesOnDisk(lib, readOnly).isEmpty)
        let missing = cli(lib, "attachments", "add", "ZZZ", "--filename", "a.png", stdin: Data([1]))
        #expect(missing.exit == 1 && missing.err == "Error: Note not found: ZZZ\n")
    }

    @Test func addKeepsOrUpdatesTheModifiedDate() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let lib = try TestLibrary.make([TestNote(text: "# T", modified: old)])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "add", id, "--filename", "a.png", "--no-update-modified", stdin: Data([1])).exit == 0)
        #expect(try lib.note(id).modifiedAt == old)
        #expect(cli(lib, "attachments", "add", id, "--filename", "b.png", stdin: Data([1])).exit == 0)
        #expect(try lib.note(id).modifiedAt == TestLibrary.epoch)
    }

    @Test func aRetriedWriteStoresTheFileOnceAndLinksItOnce() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let raced = Mutex(false)
        let service = AutomationService(
            library: lib.library, context: .fixed(TestLibrary.epoch),
            beforeCommit: { _ in
                guard raced.withLock({ let was = $0; $0 = true; return !was }) else { return }
                let current = try? lib.library.store.note(id: id)
                if let current {
                    _ = try? lib.library.store.updateText(
                        id: id, text: current.text + "\nother", expectedRevision: current.revision)
                }
            })
        let (_, stored) = try service.addAttachment(.id(id), data: Data([1, 2]), filename: "a.png", preservingModifiedDate: false)
        #expect(stored == "a.png" && filesOnDisk(lib, id) == ["a.png"])
        #expect(try lib.text(id) == "# T\nother\n![](a.png)\n")
    }

    // MARK: add-url

    /// The CLI's blocking bridges wait on the calling thread for async work. That work must not
    /// need a cooperative-pool thread: called from the pool (every synchronous test is), ten such
    /// waits at once used to deadlock the whole test process.
    @Test func blockingBridgesRunTheirWorkOffTheCooperativePool() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let cliFetcher = StubFetcher(Data([1]), name: "a.png")
        #expect(cli(lib, "attachments", "add-url", id, "--url", "https://example.com/a", fetcher: cliFetcher).exit == 0)
        #expect(cliFetcher.callsOffThePool == [true])
        let mcpFetcher = StubFetcher(Data([2]), name: "b.png")
        let initialize = MCPProtocolTests.initialize
        let call = ###"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_attachment_from_url","arguments":{"id":"\###(id)","url":"https://example.com/b"}}}"###
        let server = runCLI(
            ["baerchen", "mcp-server", "--data-dir", lib.paths.root.path], stdin: Data((initialize + "\n" + call + "\n").utf8),
            fetcher: mcpFetcher)
        #expect(server.exit == 0 && server.out.contains("b.png"), "\(server.out) \(server.err)")
        #expect(mcpFetcher.callsOffThePool == [true])
    }

    @Test func addURLUsesTheStubFetcherAndTheSuggestedName() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let fetcher = StubFetcher(Data([5, 6, 7]), name: "from-server.png")
        let run = cli(lib, "attachments", "add-url", id, "--url", "https://example.com/raw", fetcher: fetcher)
        #expect(run.exit == 0 && run.out == "" && run.err == "")
        #expect(fetcher.urls == [URL(string: "https://example.com/raw")!])
        #expect(try lib.text(id) == "# T\n![](from-server.png)\n")
        #expect(try Data(contentsOf: #require(store(lib).url(for: "from-server.png", noteId: id))) == Data([5, 6, 7]))
        let url = try #require(store(lib).url(for: "from-server.png", noteId: id))
        #expect(AttachmentQuarantine.properties(of: url.path) != nil)
        // --filename wins, and a collision renames.
        let named = cli(lib, "attachments", "add-url", id, "-u", "https://example.com/x", "-f", "from-server.png", fetcher: fetcher)
        #expect(named.exit == 0)
        #expect(filesOnDisk(lib, id) == ["from-server 2.png", "from-server.png"])
    }

    @Test func addURLRefusesEverySchemeButHTTPAndHTTPSWithoutFetching() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let fetcher = StubFetcher(Data([1]), name: "a.png")
        for raw in [
            "http://example.com/a.png", "file:///etc/passwd", "data:text/plain;base64,aGk=", "ftp://example.com/a.png",
            "javascript:alert(1)",
        ] {
            let run = cli(lib, "attachments", "add-url", id, "--url", raw, fetcher: fetcher)
            #expect(run.exit == 64 && run.err == "Error: Only https:// URLs are supported\n", "\(raw)")
        }
        let local = [
            "https://localhost/a.png", "https://127.0.0.1/a.png", "https://192.168.0.2/a.png", "https://[::1]/a.png",
            "https://x.local/a.png",
        ]
        for raw in local {
            let run = cli(lib, "attachments", "add-url", id, "--url", raw, fetcher: fetcher)
            #expect(run.exit == 1 && run.err == "Error: Refusing to fetch a local or private network address\n", "\(raw)")
        }
        let bad = cli(lib, "attachments", "add-url", id, "--url", "not a url", fetcher: fetcher)
        #expect(bad.exit == 1 && bad.err == "Error: Invalid URL: not a url\n")
        let missing = cli(lib, "attachments", "add-url", id, fetcher: fetcher)
        #expect(missing.exit == 64 && missing.err == "Error: --url is required\n")
        #expect(fetcher.urls.isEmpty && filesOnDisk(lib, id).isEmpty)
        #expect(try lib.text(id) == "# T")
    }

    @Test func addURLWithoutAnyNameIsInvalidURL() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let run = cli(lib, "attachments", "add-url", id, "--url", "https://example.com/", fetcher: StubFetcher(Data([1])))
        #expect(run.exit == 1 && run.err == "Error: Could not tell a filename from the URL; use --filename\n")
        let json = cli(lib, "attachments", "add-url", id, "--url", "https://example.com/", "--format", "json", fetcher: StubFetcher(Data([1])))
        _ = json
        #expect(filesOnDisk(lib, id).isEmpty)
        #expect(try lib.text(id) == "# T")
    }

    @Test func addURLReportsFetchFailuresAndBadBodies() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        func run(_ fetcher: StubFetcher) -> CLIResult {
            cli(lib, "attachments", "add-url", id, "--url", "https://example.com/a.png", fetcher: fetcher)
        }
        let http = run(StubFetcher(failing: AutomationError(code: .fetchFailed, message: "Could not fetch the URL (HTTP 500)")))
        #expect(http.exit == 1 && http.err == "Error: Could not fetch the URL (HTTP 500)\n")
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let other = run(StubFetcher(failing: Boom()))
        #expect(other.exit == 1 && other.err == "Error: Could not fetch the URL (boom)\n")
        let empty = run(StubFetcher(Data()))
        #expect(empty.exit == 1 && empty.err == "Error: Could not fetch the URL (empty response)\n")
        let huge = run(StubFetcher(Data(count: HTTPSFetcher.maxBytes + 1)))
        #expect(huge.exit == 1 && huge.err == "Error: Could not fetch the URL (larger than 100 MB)\n")
        #expect(filesOnDisk(lib, id).isEmpty)
        #expect(try lib.text(id) == "# T")
    }

    @Test func addURLRefusesLockedAndReadOnlyNotesBeforeFetching() throws {
        let lib = try TestLibrary.make([TestNote(text: "# L", locked: true), TestNote(text: "# R", readOnly: true)])
        let fetcher = StubFetcher(Data([1]), name: "a.png")
        let locked = cli(lib, "attachments", "add-url", try lib.firstId(), "--url", "https://example.com/a.png", fetcher: fetcher)
        #expect(locked.exit == 1 && locked.err.hasPrefix("Error: Note is locked: "))
        let readOnly = cli(lib, "attachments", "add-url", try lib.id(titled: "R"), "--url", "https://example.com/a.png", fetcher: fetcher)
        #expect(readOnly.exit == 1 && readOnly.err.hasPrefix("Error: Note is read-only: "))
        #expect(fetcher.urls.isEmpty)
    }

    @Test func addURLThroughTheRealFetcherAndAStubbedProtocol() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        StubURLProtocol.respond(
            "https://cmd-real.example/dl", body: Data([4, 2]),
            headers: ["Content-Disposition": #"attachment; filename="answer.bin""#])
        let real = HTTPSFetcher(
            maxBytes: 1_000, requestTimeout: 5, totalTimeout: 5, maxRedirects: 5, protocolClasses: [StubURLProtocol.self],
            resolver: StubResolver(), gate: LookupGate(limit: 4), peerAddresses: publicPeer)
        let run = cli(lib, "attachments", "add-url", id, "--url", "https://cmd-real.example/dl", fetcher: real)
        #expect(run.exit == 0 && run.err == "")
        #expect(try Data(contentsOf: #require(store(lib).url(for: "answer.bin", noteId: id))) == Data([4, 2]))
        StubURLProtocol.register("https://cmd-real.example/missing", .respond(status: 404, headers: [:], chunks: []))
        let gone = cli(lib, "attachments", "add-url", id, "--url", "https://cmd-real.example/missing", fetcher: real)
        #expect(gone.exit == 1 && gone.err == "Error: Could not fetch the URL (HTTP 404)\n")
    }

    // MARK: delete

    @Test func deleteRemovesLinkButNotBytes() throws {
        let doc = #"[doc.pdf](doc.pdf)<!-- {"embed":"true"} -->"#
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](a.jpg)\n\(doc)\ntext")])
        let id = try lib.firstId()
        try place(lib, id, "a.jpg")
        try place(lib, id, "doc.pdf")
        let run = cli(lib, "attachments", "delete", id, "--filename", "a.jpg")
        #expect(run.exit == 0 && run.out == "" && run.err == "")
        #expect(try lib.text(id) == "# T\n\(doc)\ntext")
        // R23: the bytes stay for the app's cleanup; the list and save no longer know the file.
        #expect(exists(lib, id, "a.jpg"))
        #expect(cli(lib, "attachments", "list", id).out == "doc.pdf\t1\n")
        let save = cli(lib, "attachments", "save", id, "--filename", "a.jpg")
        #expect(save.exit == 1 && save.err == "Error: Attachment not found: a.jpg\n" && save.outData.isEmpty)
        // The link's metadata comment goes with it.
        #expect(cli(lib, "attachments", "delete", id, "--filename", "doc.pdf").exit == 0)
        #expect(try lib.text(id) == "# T\ntext")
        let again = cli(lib, "attachments", "delete", id, "--filename", "doc.pdf")
        #expect(again.exit == 1 && again.err == "Error: Attachment not found: doc.pdf\n")
    }

    @Test func deleteRemovesEveryLinkAndCutsOnlyWhatItMust() throws {
        let text = """
            # T
            see ![](a.jpg) here
            ![](A.JPG)<!-- {"width":"200"} -->
            ![](b.jpg)
            [a](a.jpg)<!-- {"embed":"true"} --> and [b](b.jpg)<!-- {"embed":"true"} -->
            ![](a.jpg)
            """
        let lib = try TestLibrary.make([TestNote(text: text)])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "delete", id, "-f", "a.jpg").exit == 0)
        #expect(try lib.text(id) == #"""
            # T
            see  here
            ![](b.jpg)
             and [b](b.jpg)<!-- {"embed":"true"} -->
            """#)
    }

    @Test func deleteHandlesEncodedNamesTitlesAndCRLF() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\r\n![](my%20pic.jpg \"cap\")\r\ntail\r\n![alt](<my pic.jpg>)")])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "delete", id, "--filename", "my pic.jpg").exit == 0)
        #expect(try lib.text(id) == "# T\ntail")
    }

    @Test func deleteRefusesLockedAndReadOnlyNotesAndUnknownNotes() throws {
        let lib = try TestLibrary.make([TestNote(text: "# L", locked: true), TestNote(text: "# R\n![](a.png)", readOnly: true)])
        let locked = cli(lib, "attachments", "delete", try lib.firstId(), "--filename", "a.png")
        #expect(locked.exit == 1 && locked.err.hasPrefix("Error: Note is locked: "))
        let readOnly = cli(lib, "attachments", "delete", try lib.id(titled: "R"), "--filename", "a.png")
        #expect(readOnly.exit == 1 && readOnly.err.hasPrefix("Error: Note is read-only: "))
        #expect(cli(lib, "attachments", "delete", "ZZZ", "--filename", "a.png").err == "Error: Note not found: ZZZ\n")
        #expect(cli(lib, "attachments", "delete", try lib.firstId()).err == "Error: --filename is required\n")
    }

    @Test func deleteKeepsTheModifiedDateOnRequest() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](a.png)\n![](b.png)", modified: old)])
        let id = try lib.firstId()
        #expect(cli(lib, "attachments", "delete", id, "-f", "a.png", "--no-update-modified").exit == 0)
        #expect(try lib.note(id).modifiedAt == old)
        #expect(cli(lib, "attachments", "delete", id, "-f", "b.png").exit == 0)
        #expect(try lib.note(id).modifiedAt == TestLibrary.epoch)
    }

    // MARK: save

    @Test func saveWritesRawBytesAndRefusesTTY() throws {
        let bytes = Data([0x00, 0xFF, 0x0A, 0x80, 0x1B])
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](pic.png)")])
        let id = try lib.firstId()
        try place(lib, id, "pic.png", bytes)
        let run = cli(lib, "attachments", "save", id, "--filename", "pic.png")
        #expect(run.exit == 0 && run.outData == bytes && run.err == "")
        #expect(cli(lib, "attachments", "save", id, "-f", "PIC.PNG").outData == bytes)
        let tty = cli(lib, "attachments", "save", id, "--filename", "pic.png", stdoutIsTTY: true)
        #expect(tty.exit == 64 && tty.outData.isEmpty)
        #expect(tty.err == "Error: Refusing to write binary data to a terminal; redirect stdout to a file\n")
        #expect(cli(lib, "attachments", "save", id).err == "Error: --filename is required\n")
    }

    @Test func saveStreamsALargeFileInChunks() throws {
        let size = 3 * 1024 * 1024 + 5
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](big.bin)")])
        let id = try lib.firstId()
        try place(lib, id, "big.bin", bytes)
        let writes = Mutex<[Int]>([])
        let received = Mutex(Data())
        let io = CLIIO(
            readStdin: { Data() }, stdinIsTTY: false,
            write: { chunk in
                writes.withLock { $0.append(chunk.count) }
                received.withLock { $0.append(chunk) }
            },
            writeError: { _ in }, stdoutIsTTY: false)
        let exit = TheoNotesCLI.run(
            ["baerchen", "--data-dir", lib.paths.root.path, "attachments", "save", id, "--filename", "big.bin"],
            context: .fixed(TestLibrary.epoch), io: io)
        #expect(exit == 0)
        #expect(received.withLock { $0 } == bytes)
        let sizes = writes.withLock { $0 }
        #expect(sizes.count >= 4 && sizes.allSatisfy { $0 <= 1 << 20 })
    }

    @Test func saveOnlyServesLinkedRegularFilesOfTheNote() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](linked.png)\n![](gone.png)\n![](sneaky.png)"), TestNote(text: "# Other")])
        let id = try lib.firstId()
        let other = try lib.id(titled: "Other")
        try place(lib, id, "linked.png", Data([1]))
        try place(lib, id, "unlinked.png", Data([2]))
        try place(lib, other, "secret.png", Data([3]))
        // A link whose file is a symlink to a file outside the note's folder.
        let dir = lib.paths.root.appendingPathComponent("Attachments").appendingPathComponent(id)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("sneaky.png"),
            withDestinationURL: lib.paths.root.appendingPathComponent("Attachments").appendingPathComponent(other).appendingPathComponent("secret.png"))
        #expect(cli(lib, "attachments", "save", id, "-f", "linked.png").outData == Data([1]))
        for name in ["unlinked.png", "gone.png", "sneaky.png", "secret.png", "../\(other)/secret.png"] {
            let run = cli(lib, "attachments", "save", id, "-f", name)
            #expect(run.exit == 1 && run.outData.isEmpty && run.err == "Error: Attachment not found: \(name)\n", "\(name)")
        }
        #expect(cli(lib, "attachments", "list", id).out == "linked.png\t1\n")
    }

    @Test func saveRefusesLockedNotes() throws {
        let lib = try TestLibrary.make([TestNote(text: "# L", locked: true)])
        let run = cli(lib, "attachments", "save", try lib.firstId(), "-f", "a.png")
        #expect(run.exit == 1 && run.outData.isEmpty && run.err.hasPrefix("Error: Note is locked: "))
    }

    // MARK: list

    @Test func listOmitsMissingFilesAndKeepsTextOrder() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](b.jpg)\n![](missing.jpg)\n![](a.jpg)\n![](B.JPG)")])
        let id = try lib.firstId()
        try place(lib, id, "a.jpg", Data([1]))
        try place(lib, id, "b.jpg", Data([1, 2]))
        try place(lib, id, "unlinked.jpg", Data([1, 2, 3]))
        #expect(cli(lib, "attachments", "list", id).out == "b.jpg\t2\na.jpg\t1\n")
        #expect(cli(lib, "attachments", id).out == "b.jpg\t2\na.jpg\t1\n")  // list is the group's default
        #expect(cli(lib, "attachments", "list", "--title", "T", "--format", "csv").out == "filename,size\nb.jpg,2\na.jpg,1\n")
        #expect(cli(lib, "attachments", "list", id, "--fields", "size").out == "2\n1\n")
        let json = try cli(lib, "attachments", "list", id, "--format", "json").json()
        #expect(json.array?.count == 2 && json.array?[0].keys == ["filename", "size"])
        #expect(json.array?[0]["filename"] == .string("b.jpg") && json.array?[0]["size"] == .int(2))
    }

    @Test func listOfNothingIsEmpty() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let tsv = cli(lib, "attachments", "list", id)
        #expect(tsv.exit == 0 && tsv.out == "" && tsv.err == "")
        #expect(cli(lib, "attachments", "list", id, "--format", "json").out == "[]\n")
    }

    @Test func listChecksTheNoteBeforeTheFieldsAndTheFieldsBeforeTheLock() throws {
        let lib = try TestLibrary.make([TestNote(text: "# L", locked: true)])
        let locked = try lib.firstId()
        let missing = cli(lib, "attachments", "list", "ZZZ", "--fields", "bogus")
        #expect(missing.exit == 1 && missing.err == "Error: Note not found: ZZZ\n")
        let bogus = cli(lib, "attachments", "list", locked, "--fields", "bogus")
        #expect(bogus.exit == 64 && bogus.err == "Error: Unknown field: bogus (valid: filename, size)\n")
        let refused = cli(lib, "attachments", "list", locked)
        #expect(refused.exit == 1 && refused.err == "Error: Note is locked: \(locked)\n")
        let json = cli(lib, "attachments", "list", locked, "--format", "json")
        #expect(json.exit == 1)
        #expect(try json.json()["error"]?["code"] == .string("note_locked"))
        #expect(cli(lib, "attachments", "list").err == "Error: Note ID or title is required\n")
    }

    // MARK: Contract (Fixtures/cli/cli-observed.json)

    private static func observed() throws -> JSONValue {
        try JSONValue(parsing: Data(contentsOf: ArgvParserTests.observedURL))
    }

    @Test func observedAttachmentErrorsAreReplayedWordForWord() throws {
        let lib = try TestLibrary.make()
        var checked = 0
        for entry in try Self.observed()["errors"]?.array ?? [] {
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            guard args.first == "attachments" else { continue }
            let run = self.run(lib, args)
            #expect(run.exit == Int32(entry["exit"]?.intValue ?? -1), "\(args)")
            #expect(run.out == (entry["stdout"]?.string ?? ""), "\(args)")
            #expect(run.err == (entry["stderr"]?.string ?? ""), "\(args)")
            checked += 1
        }
        #expect(checked >= 2)
    }

    private func run(_ lib: TestLibrary, _ args: [String]) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
    }

    private static func kind(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "bool"
        case .int, .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private static func sameShape(_ actual: JSONValue, _ template: JSONValue, path: String = "$") -> [String] {
        let wanted = template == .string("int") ? "number" : kind(template)
        guard kind(actual) == wanted else { return ["\(path): \(kind(actual)) instead of \(wanted)"] }
        switch (actual, template) {
        case (.object, .object):
            guard actual.keys == template.keys else { return ["\(path): keys \(actual.keys) instead of \(template.keys)"] }
            return template.keys.flatMap { sameShape(actual[$0]!, template[$0]!, path: path + "." + $0) }
        case (.array(let a), .array(let t)):
            guard a.count == t.count || t.isEmpty else { return ["\(path): \(a.count) items instead of \(t.count)"] }
            return zip(a, t).flatMap { sameShape($0, $1, path: path + "[]") }
        default:
            return []
        }
    }

    @Test func observedAttachmentListShapesAreReplayed() throws {
        let lib = try TestLibrary.make([TestNote(text: "# N\n![](one.jpg)\n![](two.png)"), TestNote(text: "# Bare")])
        let withFiles = try lib.id(titled: "N")
        let bare = try lib.id(titled: "Bare")
        try place(lib, withFiles, "one.jpg", Data([1, 2, 3]))
        try place(lib, withFiles, "two.png", Data([1, 2, 3, 4, 5]))
        var checked = 0
        var problems: [String] = []
        guard case .object(let shapes)? = try Self.observed()["shapes"] else { return }
        for (name, shape) in shapes {
            var args = (shape["args"]?.array ?? []).compactMap(\.string)
            guard args.first == "attachments" else { continue }
            args = args.map { $0 == "<ID-ATTACHMENTS>" ? withFiles : $0.hasPrefix("<ID") ? bare : $0 }
            let run = self.run(lib, args)
            if run.exit != Int32(shape["exit"]?.intValue ?? -1) { problems.append("\(name): exit \(run.exit) \(run.err)") }
            if args.contains("json") {
                problems += Self.sameShape(try run.json(), shape["stdout"] ?? .null).map { "\(name) \($0)" }
            } else if let rows = shape["stdout"]?.array {
                var lines = run.out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if args.contains("csv") { lines.removeFirst() }
                let templates = args.contains("csv") ? rows.dropFirst() : rows[...]
                if lines.count != templates.count { problems.append("\(name): \(lines.count) rows instead of \(templates.count)") }
                for (line, template) in zip(lines, templates) {
                    let cells = line.split(separator: args.contains("csv") ? "," : "\t", omittingEmptySubsequences: false)
                    if cells.count != (template.array?.count ?? 0) { problems.append("\(name): \(cells.count) cells in \(line)") }
                    if Int(cells.last ?? "") == nil { problems.append("\(name): size is no integer in \(line)") }
                }
                if args.contains("csv"), let header = rows.first?.array?.compactMap(\.string) {
                    #expect(run.out.hasPrefix(header.joined(separator: ",") + "\n"), "\(name)")
                }
            }
            checked += 1
        }
        #expect(problems.isEmpty, "\(problems)")
        #expect(checked >= 4)
    }
}
