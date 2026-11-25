// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Timing gates of the read commands on 10,000 notes (ruling R29: strict only in the serial perf pass).
@Suite(.tags(.perf), PerfGate.onlyInPerfPass) struct ReadCommandsPerfTests {
    private static func tenThousandNotes() throws -> TestLibrary {
        let lib = try TestLibrary.make()
        let vocabulary = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do"]
        var state: UInt64 = 42
        func word() -> String {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return vocabulary[Int((state >> 33) % UInt64(vocabulary.count))]
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try lib.library.database.pool.write { db in
            let insert = try db.makeStatement(
                sql: "INSERT INTO note (id, text, createdAt, modifiedAt) VALUES (?, ?, ?, ?)")
            for i in 0..<10_000 {
                var lines = ["Note \(i) " + word()]
                lines.append((0..<12).map { _ in word() }.joined(separator: " "))
                if i % 3 == 0 { lines.append("- [ ] task \(word())") }
                if i % 4 == 0 { lines.append("#tag\(i % 7)") }
                let text = lines.joined(separator: "\n")
                let date = now.addingTimeInterval(-Double(i) * 60)
                let id = "note-\(i)"
                try insert.execute(arguments: [id, text, date, date])
                try NoteIndexer.index(noteId: id, text: text, in: db)
            }
        }
        return lib
    }

    /// The best of three runs, in milliseconds, and the last output.
    private func best(_ lib: TestLibrary, _ args: [String]) -> (ms: Double, result: CLIResult) {
        var best = Double.infinity
        var last = CLIResult(exit: -1, out: "", outData: Data(), err: "")
        for _ in 0..<3 {
            let start = ContinuousClock.now
            last = cli(lib, args)
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        return (best, last)
    }

    private func cli(_ lib: TestLibrary, _ args: [String]) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
    }

    @Test func testPerfListAllFieldsJSON10k() throws {
        let lib = try Self.tenThousandNotes()
        let run = best(lib, ["list", "--fields", "all", "--format", "json"])
        print(String(format: "[perf] baerchen list --fields all --format json, 10k notes: %.1f ms", run.ms))
        let rows = try run.result.json().array?.count
        #expect(run.result.exit == 0 && rows == 10_000)
        #expect(run.ms < 500)
    }

    @Test func testPerfSearchJSON10k() throws {
        let lib = try Self.tenThousandNotes()
        let run = best(lib, ["search", "lorem @todo", "--format", "json"])
        print(String(format: "[perf] baerchen search \"lorem @todo\" --format json, 10k notes: %.1f ms", run.ms))
        let hits = try run.result.json().array?.count ?? 0
        #expect(run.result.exit == 0 && hits > 0)
        #expect(run.ms < 200)
    }
}
