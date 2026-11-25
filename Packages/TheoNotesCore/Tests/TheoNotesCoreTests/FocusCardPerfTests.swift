// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Review Focus 5: a 10,000-note library. Runs in the serial perf pass only (R29).
@Suite(.tags(.perf), PerfGate.onlyInPerfPass) struct FocusCardPerfTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 10k notes: every 3rd has an open to-do, every 7th a done one, every 50th is a template,
    /// every 100th a capture (half of them opened), every 40th is archived; 200 reminders.
    private func library(todos: Bool) async throws -> NoteStore {
        let tmp = try TempPaths()
        let db = try AppDatabase.inMemory()
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        try await db.pool.write { db in
            var rng = SplitMix64(seed: 11)
            let insert = try db.makeStatement(sql: """
                INSERT INTO note (id, text, createdAt, modifiedAt, location, captureSource) VALUES (?, ?, ?, ?, ?, ?)
                """)
            for i in 0..<10_000 {
                var lines = ["Note \(i)"]
                for j in 0..<6 { lines.append("body \(i) \(j) lorem ipsum dolor sit amet consectetur") }
                if todos, i % 3 == 0 { lines.insert("- [ ] todo for note \(i)", at: 2) }
                if i % 7 == 0 { lines.append("- [x] finished \(i)") }
                if i % 50 == 0 { lines.append("#template") }
                let date = Self.now.addingTimeInterval(-Double(i) * 600)
                let capture: String? = i % 100 == 0 ? "share" : nil
                try insert.execute(arguments: [
                    "note-\(i)", lines.joined(separator: "\n"), date, date, i % 40 == 0 ? "archive" : "notes", capture,
                ])
                try NoteIndexer.index(noteId: "note-\(i)", text: lines.joined(separator: "\n"), in: db)
            }
            for i in 0..<10_000 where i % 200 == 0 {
                try db.execute(sql: "INSERT INTO note_ui_state(noteId, lastOpenedAt) VALUES (?, ?)",
                               arguments: ["note-\(i)", Self.now.addingTimeInterval(-Double(rng.next() % 1_000_000))])
            }
            for i in 0..<200 {
                try db.execute(sql: """
                    INSERT INTO note_ping(id, noteId, fireAt, createdAt) VALUES (?, ?, ?, ?)
                    """, arguments: ["ping-\(i)", "note-\(i * 3 + 1)", Self.now.addingTimeInterval(3600 + Double(i)), Self.now])
            }
        }
        return store
    }

    private func p95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
    }

    private func measure(_ store: NoteStore, label: String) throws -> Double {
        let card = FocusCard(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        _ = try card.next(now: Self.now, calendar: calendar)
        var samples: [Double] = []
        for _ in 0..<40 {
            let start = ContinuousClock.now
            _ = try card.next(now: Self.now, calendar: calendar)
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let result = p95(samples)
        print(String(format: "[perf] next candidate, %@: p95 %.1f ms, min %.1f ms", label, result, samples.min() ?? 0))
        return result
    }

    @Test func testPerfNextCandidateOnTenThousandNotes() async throws {
        let store = try await library(todos: true)
        let withTodos = try measure(store, label: "10k notes, 3.3k with an open to-do")
        #expect(withTodos < 50, "p95 \(withTodos) ms")

        // Worst case for the other steps: no to-do anywhere, so the capture scan runs on every read.
        let bare = try await library(todos: false)
        let withoutTodos = try measure(bare, label: "10k notes, no to-do (capture scan)")
        #expect(withoutTodos < 50, "p95 \(withoutTodos) ms")
    }
}
