// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct BearCLIClientTests {
    @Test func testDecodesFixtureList() throws {
        let notes = try FakeBearCLI().listAll().records
        #expect(notes.count == 3)
        let a = notes[0]
        #expect(a.id == "SYN-0001")
        #expect(a.locked == false)
        #expect(a.tags == ["work", "multi word", "work/sub"])
        #expect(a.pins == [.global, .tag("work")])
        #expect(a.location == .notes)
        #expect(a.todos == 1 && a.done == 2)
        #expect(a.created == Date(timeIntervalSince1970: 1_735_787_045))
        #expect(a.content?.hasPrefix("# Synthetic plain note") == true)
        let b = notes[1]
        #expect(b.location == .trash)
        #expect(b.attachments == ["photo 2.jpg"])
        let c = notes[2]
        #expect(c.locked == true)
        #expect(c.location == .archive)
        #expect(c.content == nil)
    }

    @Test func testFakeServesAttachmentBytes() throws {
        let data = try FakeBearCLI().attachmentData(noteID: "SYN-0002", filename: "photo 2.jpg")
        #expect(data.starts(with: Data("SYNTHETIC-ATTACHMENT-BYTES".utf8)))
    }

    @Test func testForbiddenSubcommandRefused() throws {
        let cli = ProcessBearCLI(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let forbidden: [[String]] = [
            ["create", "--title", "x"], ["append", "id"], ["trash", "id"], ["tags", "rename", "a", "b"],
            ["tags", "delete", "a"], ["pin", "add", "id"], ["attachments", "delete", "id"],
            ["attachments", "add", "id"], ["edit", "id"], ["archive", "id"], [], ["--help"],
            ["tags"], ["pin"], ["attachments"], ["listx"], ["list-all"],
        ]
        for args in forbidden {
            #expect(throws: BearCLIError.forbiddenSubcommand(args.prefix(2).joined(separator: " "))) {
                _ = try cli.run(args)
            }
            // The raw-output entry point bear-oracle's parser check uses goes through the same gate.
            #expect(throws: BearCLIError.forbiddenSubcommand(args.prefix(2).joined(separator: " "))) {
                _ = try cli.output(args)
            }
        }
    }

    @Test func testAllowedSubcommandsPassTheGate() throws {
        let cli = ProcessBearCLI(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let allowed: [[String]] = [
            ["list"], ["search", "@readonly"], ["show", "id"], ["cat", "id"], ["tags", "list"],
            ["pin", "list"], ["attachments", "list", "id"], ["attachments", "save", "id", "--filename", "a"],
        ]
        for args in allowed { _ = try cli.run(args) }
    }

    @Test func testMissingBinaryIsReported() throws {
        let cli = ProcessBearCLI(executable: URL(fileURLWithPath: "/nonexistent/bearcli"))
        #expect(throws: BearCLIError.notInstalled) { _ = try cli.listAll() }
    }

    @Test func testNonZeroExitSurfacesStderr() throws {
        let cli = ProcessBearCLI(executable: URL(fileURLWithPath: "/usr/bin/false"))
        do {
            _ = try cli.run(["list"])
            Issue.record("expected failure")
        } catch let BearCLIError.failed(code, _) {
            #expect(code == 1)
        }
    }

    @Test func testJSONErrorOnStdoutBecomesBearError() throws {
        let script = try Self.script("""
        printf '{"error":{"code":"not_found","message":"no such note"}}'
        exit 1
        """)
        let cli = ProcessBearCLI(executable: script)
        #expect(throws: BearCLIError.bear(code: "not_found", message: "no such note")) { _ = try cli.run(["show", "x"]) }
    }

    @Test func testStderrIsCapturedOnFailure() throws {
        let script = try Self.script("echo 'boom on stderr' >&2\nexit 64")
        let cli = ProcessBearCLI(executable: script)
        do {
            _ = try cli.run(["list"])
            Issue.record("expected failure")
        } catch let BearCLIError.failed(code, stderr) {
            #expect(code == 64)
            #expect(stderr.contains("boom on stderr"))
        }
    }

    @Test func testLargeOutputOnBothPipesDoesNotDeadlock() throws {
        let script = try Self.script("""
        head -c 3000000 /dev/zero | tr '\\0' 'a' >&2
        head -c 5000000 /dev/zero | tr '\\0' 'b'
        """)
        let cli = ProcessBearCLI(executable: script)
        let out = try cli.run(["list"])
        #expect(out.count == 5_000_000)
    }

    @Test func testLiveBearSmoke() throws {
        guard ProcessInfo.processInfo.environment["BAERCHEN_LIVE_BEAR"] == "1" else { return }
        let notes = try ProcessBearCLI(executable: ProcessBearCLI.defaultPath).listAll().records
        print("LIVE_BEAR_COUNT=\(notes.count)")
        #expect(notes.count > 0)
    }

    @Test func testBinaryBytesPassThroughRun() throws {
        let script = try Self.script("printf 'A\\000\\377\\200\\000Z'")
        let out = try ProcessBearCLI(executable: script).run(["attachments", "save", "x", "--filename", "b.bin"])
        #expect(Array(out) == [0x41, 0x00, 0xFF, 0x80, 0x00, 0x5A])
    }

    @Test func testStderrIsTruncatedInFailure() throws {
        let script = try Self.script("head -c 100000 /dev/zero | tr '\\0' 'e' >&2\nexit 3")
        do {
            _ = try ProcessBearCLI(executable: script).run(["list"])
            Issue.record("expected failure")
        } catch let BearCLIError.failed(code, stderr) {
            #expect(code == 3)
            #expect(stderr.utf8.count <= 2048)
            #expect(stderr.hasPrefix("eee"))
        }
    }

    @Test func testHangingProcessTimesOut() throws {
        let script = try Self.script("exec sleep 30")
        let cli = ProcessBearCLI(executable: script, listTimeout: 0.3, attachmentTimeout: 0.3)
        let start = Date()
        #expect(throws: BearCLIError.timedOut) { _ = try cli.listAll() }
        #expect(throws: BearCLIError.timedOut) { _ = try cli.attachmentData(noteID: "x", filename: "y") }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func testUnknownLocationFailsOnlyThatRecord() throws {
        let json = """
        [{"id":"A","title":"a","created":"2025-01-01T00:00:00Z","modified":"2025-01-01T00:00:00Z","location":"notes","content":"a"},
         {"id":"B","title":"b","created":"2025-01-01T00:00:00Z","modified":"2025-01-01T00:00:00Z","location":"elsewhere","content":"secret body"},
         {"id":"C","title":"c","created":"2025-01-01T00:00:00Z","modified":"2025-01-01T00:00:00Z","location":"trash","content":"c"},
         {"title":"no id"}]
        """
        let list = try BearNoteRecord.decodeList(Data(json.utf8))
        #expect(list.records.map(\.id) == ["A", "C"])
        #expect(list.errors.count == 2)
        #expect(list.errors[0].hasPrefix("B: "))
        #expect(list.errors[0].contains("location"))
        #expect(!list.errors.joined().contains("secret body"))
        #expect(list.errors[1].hasPrefix("#4: "))
        #expect(list.undecodedIDs == ["B"])
    }

    @Test func testListThatIsNotAnArrayFails() throws {
        #expect(throws: (any Error).self) { _ = try BearNoteRecord.decodeList(Data("{}".utf8)) }
    }

    @Test func testNoteCountReadsCountJSON() throws {
        let script = try Self.script("""
            case "$*" in
              "list --location all --count --format json") echo '{"count":234}' ;;
              "list --location trash --count --format json") echo '{"count":90}' ;;
              *) echo "unexpected: $*" >&2; exit 9 ;;
            esac
            """)
        let cli = ProcessBearCLI(executable: script)
        #expect(try cli.noteCount(location: "all") == 234)
        #expect(try cli.noteCount(location: "trash") == 90)
    }

    @Test func testAttachmentSizesReadsListJSON() throws {
        let script = try Self.script("""
            [ "$*" = "attachments list N1 --format json --fields filename,size" ] || exit 9
            echo '[{"filename":"photo 2.jpg","size":138953},{"filename":"Ü.pdf","size":7}]'
            """)
        let sizes = try ProcessBearCLI(executable: script).attachmentSizes(noteID: "N1")
        #expect(sizes == ["photo 2.jpg": 138953, "Ü.pdf": 7])
    }

    static func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-bearcli-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
