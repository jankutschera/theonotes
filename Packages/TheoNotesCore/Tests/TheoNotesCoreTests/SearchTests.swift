// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// `LibraryQueries.search` over the synthetic library `Fixtures/search/library.json` with the
/// expectations in `queries.json` (`expected`: exact id set; `allExcept`: every note of the scope
/// but these). `now` = 2026-05-29 12:00 in Los Angeles, so UTC and local days differ.
@Suite struct SearchTests {
    struct LibraryNote: Decodable {
        let key: String
        let text: String
        let created: String
        let modified: String
        var location: String?
        var pinned: Bool?
        var readOnly: Bool?
        var locked: Bool?
    }

    struct QueryCase: Decodable {
        let name: String
        let query: String
        var scope: String?
        var expected: [String]?
        var allExcept: [String]?
    }

    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    let now = ISO8601DateFormatter().date(from: "2026-05-29T12:00:00-07:00")!
    let locale = Locale(identifier: "en_US")

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    static func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: SearchParserTests.fixtureDir.appendingPathComponent(name)))
    }

    /// Imports the fixture library; returns key ↔ note id.
    private func seedLibrary() throws -> (byKey: [String: String], byId: [String: String], notes: [LibraryNote]) {
        let notes = try Self.fixture("library.json", as: [LibraryNote].self)
        let iso = ISO8601DateFormatter()
        var byKey: [String: String] = [:]
        for n in notes {
            let note = try store.importNote(ImportedNoteDraft(
                text: n.text, createdAt: iso.date(from: n.created)!, modifiedAt: iso.date(from: n.modified)!,
                location: n.location.flatMap(NoteLocation.init(rawValue:)) ?? .notes,
                isPinnedGlobal: n.pinned ?? false, isReadOnly: n.readOnly ?? false
            ))
            if n.locked == true {
                try db.pool.write { db in
                    try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [note.id])
                    try NoteIndexer.index(noteId: note.id, text: "", in: db)
                }
            }
            byKey[n.key] = note.id
        }
        return (byKey, Dictionary(uniqueKeysWithValues: byKey.map { ($1, $0) }), notes)
    }

    private func scope(_ s: String?) -> SidebarScope {
        switch s {
        case nil, "notes": .notes
        case "archive": .archive
        case "trash": .trash
        case "todo": .todo
        case "pinned": .pinned
        case let s? where s.hasPrefix("tag:"): .tag(String(s.dropFirst(4)))
        case let s?: fatalError("unknown scope \(s)")
        }
    }

    private func search(_ query: String, _ scope: SidebarScope = .notes, limit: Int? = nil) throws -> SearchResult {
        try db.pool.read {
            try LibraryQueries.search(query, in: scope, sort: .modifiedDescending, now: now, calendar: calendar,
                                      locale: locale, limit: limit, db: $0)
        }
    }

    @Test func testQueryFixtures() throws {
        let library = try seedLibrary()
        let cases = try Self.fixture("queries.json", as: [QueryCase].self)
        #expect(cases.count >= 100)
        #expect(Set(cases.map(\.name)).count == cases.count, "duplicate case names")
        for c in cases {
            let scope = scope(c.scope)
            let actual = Set(try search(c.query, scope).items.map { library.byId[$0.id] ?? "?" })
            let expected: Set<String>
            if let list = c.expected {
                expected = Set(list)
            } else {
                let all = Set(try db.pool.read {
                    try LibraryQueries.notes(in: scope, sort: .modifiedDescending, now: now, calendar: calendar, db: $0)
                }.map { library.byId[$0.id]! })
                expected = all.subtracting(c.allExcept ?? [])
            }
            #expect(actual == expected, "\(c.name): \(c.query) → extra \(actual.subtracting(expected).sorted()) missing \(expected.subtracting(actual).sorted())")
        }
    }

    @Test func testResultsAreOrderedLikeTheNoteListWithPinnedFirst() throws {
        let library = try seedLibrary()
        let keys = try search("system or founder").items.map { library.byId[$0.id]! }
        // sys is pinned; the rest by modification date, newest first.
        #expect(keys == ["sys", "found", "build", "phrase", "wiki"])
        #expect(try search("system or founder", limit: 2).items.map { library.byId[$0.id]! } == ["sys", "found"])
    }

    /// The UI pages results (ruling R8): `limit` + `offset` walk the same order as the full list.
    @Test func testPagingWithLimitAndOffset() throws {
        let library = try seedLibrary()
        let page = { (offset: Int) in
            try self.db.pool.read {
                try LibraryQueries.search("system or founder", in: .notes, sort: .modifiedDescending, now: self.now,
                                          calendar: self.calendar, locale: self.locale, limit: 2, offset: offset, db: $0)
            }.items.map { library.byId[$0.id]! }
        }
        #expect(try page(0) == ["sys", "found"])
        #expect(try page(2) == ["build", "phrase"])
        #expect(try page(4) == ["wiki"])
        #expect(try page(6) == [])
    }

    @Test func testAtOcrFindsRecognizedText() throws {
        let texts = AttachmentTextStore(database: db)
        let scan = try store.create(text: "# Scan\n![](receipt.png)")
        let plain = try store.create(text: "# Plain\nno images, no words")
        let locked = try store.create(text: "# Locked\n![](secret.png)")
        try texts.record(OCRJob(noteId: scan.id, filename: "receipt.png"),
                         result: .text("Invoice 2026 total", sha256: "s", byteSize: 1, modifiedAt: now))
        try texts.record(OCRJob(noteId: locked.id, filename: "secret.png"),
                         result: .text("Invoice secret", sha256: "t", byteSize: 1, modifiedAt: now))
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [locked.id])
            try NoteIndexer.index(noteId: locked.id, text: "", in: db)
        }
        #expect(try search("@ocr invoice").items.map(\.id) == [scan.id])
        #expect(try search("invoice").items.map(\.id) == [scan.id])
        #expect(try search("@ocr plain").items.isEmpty)
        #expect(try search("plain").items.map(\.id) == [plain.id])
        #expect(try search("secret").items.isEmpty)
    }

    @Test func testHighlightTerms() throws {
        _ = try seedLibrary()
        let result = try search("system \"in a\" -founder #type @todo or system")
        #expect(result.terms == ["system", "in a", "#type"])
    }

    /// Review focus 1: FTS5 syntax in user input never errors and is matched literally.
    @Test func testFTSSpecialCharactersAreLiteral() throws {
        let library = try seedLibrary()
        let nasty = ["\"", "\"\"", "\"\"\"", "\"a\" OR \"b\"", "NEAR(a b)", "NEAR", "a:b", "title:x", "{title}:x", "title : x",
                     "*", "**", "x*", "^a", "-", "--", "(", ")", "()", "'", "\\", "%", "_", "AND", "OR NOT", "NOT", "a AND b",
                     "\"unterminated", "col:", ":", "+", "c++", "\u{0}", "\u{FEFF}", "🐻", "日", "@date(", "#", "!#", "#*/",
                     "-\"\"", "\"\" -\"\"", "a\"b\"c", "@title \"", "@title :", "@ocr *", "1 OR 1=1; DROP TABLE note; --",
                     "' OR '1'='1", "%_%", "\\%", "rowid", "note_fts MATCH 'x'"]
        for q in nasty {
            #expect(throws: Never.self, "\(q)") { _ = try search(q) }
        }
        #expect(Set(try search("NEAR(").items.map { library.byId[$0.id]! }) == ["fts"])
        #expect(Set(try search("col:on").items.map { library.byId[$0.id]! }) == ["fts"])
        #expect(Set(try search("c++").items.map { library.byId[$0.id]! }) == ["fts"])
        #expect(Set(try search("%").items.map { library.byId[$0.id]! }) == ["fts"])
        #expect(Set(try search("\"quotes\" AND").items.map { library.byId[$0.id]! }) == ["fts"])
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 22)
    }

    /// SQLite's expression depth limit (1000) must not be reachable from a query.
    @Test func testVeryLongQueriesDoNotThrow() throws {
        let library = try seedLibrary()
        let words = (0..<2000).map { "w\($0)" }
        #expect(try search(words.joined(separator: " ")).items.isEmpty)
        #expect(try search(words.joined(separator: " or ")).items.isEmpty)
        #expect(try search((["system"] + words).joined(separator: " or ")).items.count == 3)
        #expect(try search(words.map { "-" + $0 }.joined(separator: " ")).items.count
                == search("").items.count)
        _ = library
    }

    @Test func testNULInTermsAndPhrasesDoesNotThrow() throws {
        let library = try seedLibrary()
        #expect(throws: Never.self) { _ = try search("abc\u{0}def") }
        #expect(throws: Never.self) { _ = try search("\"abc\u{0}def\"") }
        #expect(Set(try search("sys\u{0}tem").items.map { library.byId[$0.id]! }) == ["sys", "wiki", "phrase"])
    }

    /// `@date(>9999)` must not match every note (dates are stored as `YYYY-…` text).
    @Test func testDateAfterYear9999MatchesNothing() throws {
        _ = try seedLibrary()
        #expect(try search("@date(>9999)").items.isEmpty)
        #expect(try search("@cdate(>9999-12-31)").items.isEmpty)
        #expect(try search("@date(9999)").items.isEmpty)
        #expect(try search("@date(<9999)").items.count == search("").items.count)
        #expect(try search("@date(<0001-01-02)").items.isEmpty)
    }

    /// Dates in a query are Gregorian whatever the user's calendar (Buddhist year 2569 = 2026).
    @Test func testDateFiltersAreGregorianInAnyCalendar() throws {
        let library = try seedLibrary()
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let ids = try db.pool.read {
            try LibraryQueries.search("@date(2026-05-29)", in: .notes, sort: .modifiedDescending, now: now,
                                      calendar: buddhist, locale: locale, db: $0).items.map { library.byId[$0.id]! }
        }
        #expect(Set(ids) == ["sys", "cafe"])
        let today = try db.pool.read {
            try LibraryQueries.search("@today", in: .notes, sort: .modifiedDescending, now: now,
                                      calendar: buddhist, locale: locale, db: $0).items.map { library.byId[$0.id]! }
        }
        #expect(Set(today) == ["sys", "cafe"])
    }

    /// `@lastXdays` counts calendar days across a DST change (LA, 2026-03-08 springs forward).
    @Test func testLastDaysAcrossDST() throws {
        let iso = ISO8601DateFormatter()
        let inside = try store.importNote(ImportedNoteDraft(
            text: "inside", createdAt: iso.date(from: "2026-03-07T00:30:00-08:00")!,
            modifiedAt: iso.date(from: "2026-03-07T00:30:00-08:00")!))
        _ = try store.importNote(ImportedNoteDraft(
            text: "outside", createdAt: iso.date(from: "2026-03-06T23:30:00-08:00")!,
            modifiedAt: iso.date(from: "2026-03-06T23:30:00-08:00")!))
        let afterDST = iso.date(from: "2026-03-10T12:00:00-07:00")!
        for query in ["@last3days", "@created3days"] {
            let ids = try db.pool.read {
                try LibraryQueries.search(query, in: .notes, sort: .modifiedDescending, now: afterDST,
                                          calendar: calendar, locale: locale, db: $0).items.map(\.id)
            }
            #expect(ids == [inside.id], "\(query)")
        }
    }

    // MARK: performance (spec §6: 10,000 notes, as-you-type p95 < 50 ms)

    @Test(.tags(.perf), PerfGate.onlyInPerfPass) func testPerfSearchOn10kNotes() throws {
        let vocabulary = SearchContentTests.vocabulary(count: 6000)
        var rng = SplitMix64(seed: 99)
        func word() -> String { vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }
        let tags = ["work", "work/projects", "home", "ideas/later", "type/ref", "type/idea", "paperclip", "x-articles"]
        let seedStart = DispatchTime.now().uptimeNanoseconds
        try db.pool.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO note (id, text, createdAt, modifiedAt, isPinnedGlobal) VALUES (?, ?, ?, ?, ?)
                """)
            for i in 0..<10_000 {
                var lines = ["# " + (0..<4).map { _ in word() }.joined(separator: " ")]
                for _ in 0..<5 { lines.append((0..<20).map { _ in word() }.joined(separator: " ")) }
                if i % 3 == 0 { lines.append("#" + tags[i % tags.count]) }
                if i % 7 == 0 { lines.append("- [ ] " + word()) }
                if i % 11 == 0 { lines.append("```\ncode \(word())\n```") }
                if i % 50 == 0 { lines.append("東京都の日本語メモ") }
                let text = lines.joined(separator: "\n")
                let id = "note-\(i)"
                let modified = now.addingTimeInterval(-Double(i) * 3_600)
                try insert.execute(arguments: [id, text, modified, modified, i % 500 == 0])
                try NoteIndexer.index(noteId: id, text: text, in: db)
            }
        }
        print(String(format: "[perf] seeded 10k notes (indexer) in %.1f s",
                     Double(DispatchTime.now().uptimeNanoseconds - seedStart) / 1e9))

        // As-you-type: every prefix of a few words, plus the other query shapes. Each query is
        // timed once (no warm repeats).
        var queries: [String] = []
        for w in vocabulary.prefix(8) {
            for n in 1...w.count { queries.append(String(w.prefix(n))) }
        }
        let a = vocabulary[10], b = vocabulary[11], c = vocabulary[12]
        queries += [
            "\(a) \(b)", "\(a) \(String(b.prefix(2)))", "\(a) or \(b) or \(c)", "\(a) -\(b)", "-\(a)",
            "\"\(a)\"", "\"\(a) \(b)\"", "#work", "#work \(String(a.prefix(3)))", "!#work", "#*/projects",
            "@todo \(String(a.prefix(4)))", "@code", "@today", "@last30days \(a)", "@title \(String(a.prefix(3)))",
            "日本", "日本語", "@untagged -@todo", "\(String(a.dropFirst(1).prefix(3)))",
        ]
        func p95(_ label: String, limit: Int?, workspace: Workspace? = nil) throws -> Double {
            var timed: [(ms: Double, query: String, hits: Int)] = []
            try db.pool.read { db in
                for q in queries {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let hits = try LibraryQueries.search(q, in: .notes, sort: .modifiedDescending, workspace: workspace, now: now,
                                                         calendar: calendar, locale: locale, limit: limit, db: db).items.count
                    timed.append((Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, q, hits))
                }
            }
            timed.sort { $0.ms < $1.ms }
            let p95 = timed[Int(Double(timed.count - 1) * 0.95)].ms
            print(String(format: "[perf] search %@: p50 %.2f ms, p95 %.2f ms, max %.2f ms (n=%d)",
                         label, timed[timed.count / 2].ms, p95, timed.last!.ms, timed.count))
            for t in timed.suffix(4).reversed() {
                print(String(format: "[perf]   slowest: %.2f ms %@ (%d hits)", t.ms, t.query, t.hits))
            }
            return p95
        }
        var listSamples: [Double] = []
        try db.pool.read { db in
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try LibraryQueries.notes(in: .notes, sort: .modifiedDescending, now: now, calendar: calendar, db: db)
                listSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        listSamples.sort()
        print(String(format: "[perf] baseline: plain Notes list of 10k (no search): p50 %.2f ms, max %.2f ms",
                     listSamples[10], listSamples.last!))
        // Gate (spec §6, ruling R8): the query the UI runs, i.e. the first page.
        #expect(try p95("first page, LIMIT 200", limit: 200) < 50)
        // The same gate with a workspace active (M4 Task 8): every query also needs the tag.
        #expect(try p95("first page, LIMIT 200, workspace #work", limit: 200, workspace: Workspace(path: "work")) < 50)
        // Logged metric with a loose bound: the whole list is dominated by building 10k items
        // (see the baseline above); catches a ~3x regression without flaking under load.
        #expect(try p95("full list (metric)", limit: nil) < 150)
    }

    /// Editing a 60 KB note re-indexes it: derived rows plus both FTS tables (per autosave).
    @Test(.tags(.perf)) func testPerfIndexingCostOf60KBNoteEdit() throws {
        let vocabulary = SearchContentTests.vocabulary(count: 3000)
        var rng = SplitMix64(seed: 5)
        var lines: [String] = ["# Big note"]
        var size = 0
        while size < 60_000 {
            let line = (0..<12).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }.joined(separator: " ")
            lines.append(lines.count % 25 == 0 ? "- [ ] " + line + " #work" : line)
            size += line.utf8.count + 1
        }
        var text = lines.joined(separator: "\n")
        var note = try store.create(text: text, now: now)
        var samples: [Double] = []
        for i in 0..<20 {
            text += " edit\(i)"
            let start = DispatchTime.now().uptimeNanoseconds
            note = try store.updateText(id: note.id, text: text, expectedRevision: note.revision)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "[perf] 60 KB note save (updateText + index + 2 FTS): p50 %.2f ms, p95 %.2f ms, max %.2f ms (%d bytes)",
                     samples[samples.count / 2], samples[Int(Double(samples.count - 1) * 0.95)], samples.last!, text.utf8.count))
        #expect(samples[samples.count / 2] < PerfGate.bound(250, sanity: 2_500))
        #expect(Set(try search("edit19").items.map(\.id)) == [note.id])
    }
}
