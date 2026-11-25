// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// I1: the Backlinks tab's query on 10,000 notes, read in the background as the app does.
@Suite(.tags(.perf), PerfGate.onlyInPerfPass) struct BacklinksPerformanceTests {
    @Test func testPerfBacklinksOn10kNotesWithACommonTitle() async throws {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let vocabulary = SearchContentTests.vocabulary(count: 6000)
        var rng = SplitMix64(seed: 5)
        func word() -> String { vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }
        let common = vocabulary[0]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var texts: [String] = []
        for i in 0..<10_000 {
            var lines = ["Note " + word() + " " + word()]
            for _ in 0..<5 { lines.append((0..<20).map { _ in word() }.joined(separator: " ")) }
            // Every 5th note mentions the common title in prose, every 3rd carries it as a tag,
            // every 40th links to it; every 2nd carries `#tagonly`.
            if i % 5 == 0 { lines.append("about \(common) today") }
            if i % 3 == 0 { lines.append("#\(common)") }
            if i % 40 == 0 { lines.append("[[\(common)]]") }
            if i % 2 == 0 { lines.append("#tagonly") }
            texts.append(lines.joined(separator: "\n"))
        }
        try await db.pool.write { [texts] db in
            let insert = try db.makeStatement(sql: "INSERT INTO note (id, text, createdAt, modifiedAt) VALUES (?, ?, ?, ?)")
            for (i, text) in texts.enumerated() {
                let date = now.addingTimeInterval(-Double(i) * 60)
                try insert.execute(arguments: ["note-\(i)", text, date, date])
                try NoteIndexer.index(noteId: "note-\(i)", text: text, in: db)
            }
            try db.execute(sql: "INSERT INTO note (id, text, createdAt, modifiedAt) VALUES ('target', ?, ?, ?)",
                           arguments: [common, now.addingTimeInterval(60), now.addingTimeInterval(60)])
            try NoteIndexer.index(noteId: "target", text: common, in: db)
            // A title 5,000 notes carry only as a tag: candidates that never verify.
            try db.execute(sql: "INSERT INTO note (id, text, createdAt, modifiedAt) VALUES ('tagged', 'tagonly', ?, ?)",
                           arguments: [now.addingTimeInterval(60), now.addingTimeInterval(60)])
            try NoteIndexer.index(noteId: "tagged", text: "tagonly", in: db)
        }

        func measure(_ id: String) async throws -> (ms: Double, result: Backlinks) {
            let start = ContinuousClock.now
            let result = try await store.backlinksInBackground(to: id)
            let elapsed = ContinuousClock.now - start
            return (Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000, result)
        }
        var samples: [Double] = []
        var last = Backlinks()
        for _ in 0..<5 {
            let run = try await measure("target")
            samples.append(run.ms)
            last = run.result
        }
        samples.sort()
        print(String(format: "[perf] backlinks 10k, common title: min %.1f ms, median %.1f ms, max %.1f ms (linked %d, unlinked notes %d)",
                     samples[0], samples[2], samples[4], last.linked.count, last.unlinked.count))
        #expect(last.linked.count == Backlinks.linkedNoteLimit && last.linkedTruncated)
        #expect(last.unlinked.flatMap(\.mentions).count >= Backlinks.unlinkedMentionLimit)
        // Budget: 100 ms in a debug build; the best of 5 runs, since other suites run in parallel.
        #expect(samples[0] < 100, "best \(samples[0]) ms")

        let tagOnly = try await measure("tagged")
        print(String(format: "[perf] backlinks 10k, tag-only title (5,000 candidates that never verify): %.1f ms, truncated %@",
                     tagOnly.ms, tagOnly.result.unlinkedTruncated ? "yes" : "no"))
        #expect(tagOnly.result.unlinked.isEmpty)
    }
}
