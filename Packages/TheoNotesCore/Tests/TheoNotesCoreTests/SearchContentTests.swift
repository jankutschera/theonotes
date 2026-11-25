// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// `note_search_content` + its two FTS5 indexes (`note_fts`, `note_fts_trigram`).
@Suite struct SearchContentTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    struct SearchRow: Equatable {
        var title: String
        var body: String
        var attachmentNames: String
        var ocrText: String
    }

    private func row(_ noteId: String) throws -> SearchRow? {
        try db.pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT title, body, attachmentNames, ocrText FROM note_search_content WHERE noteId = ?
                """, arguments: [noteId])
                .map { SearchRow(title: $0[0], body: $0[1], attachmentNames: $0[2], ocrText: $0[3]) }
        }
    }

    /// Note ids whose `note_fts` row matches the FTS5 expression (bound, never interpolated).
    private func words(_ match: String) throws -> [String] {
        try db.pool.read { try matchIds($0, table: "note_fts", match) }
    }

    private func trigram(_ match: String) throws -> [String] {
        try db.pool.read { try matchIds($0, table: "note_fts_trigram", match) }
    }

    private func checkIntegrity() throws {
        try db.pool.write { db in
            // `rank = 1`: also compares the index with the external content table.
            try db.execute(sql: "INSERT INTO note_fts(note_fts, rank) VALUES ('integrity-check', 1)")
            try db.execute(sql: "INSERT INTO note_fts_trigram(note_fts_trigram, rank) VALUES ('integrity-check', 1)")
        }
    }

    // MARK: SQLite capabilities

    @Test func testSQLiteHasFTS5AndTrigramTokenizer() throws {
        let (version, options) = try db.pool.read { db in
            (try String.fetchOne(db, sql: "SELECT sqlite_version()")!,
             try String.fetchAll(db, sql: "SELECT compile_options FROM pragma_compile_options"))
        }
        print("SQLite \(version)")
        #expect(options.contains("ENABLE_FTS5"))
        // trigram `remove_diacritics` needs 3.45.
        let parts = version.split(separator: ".").compactMap { Int($0) }
        #expect(parts.lexicographicallyPrecedes([3, 45]) == false)
        let tokenizers = try db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT sql FROM sqlite_master WHERE name IN ('note_fts', 'note_fts_trigram') ORDER BY name
                """)
        }
        #expect(tokenizers.count == 2)
        #expect(tokenizers[0].contains("unicode61 remove_diacritics 2"))
        #expect(tokenizers[0].contains("prefix='2 3'"))
        #expect(tokenizers[1].contains("trigram"))
    }

    // MARK: indexer

    /// Bear searches the Markdown source (oracle: `**`, `](` and link URLs match), folded so
    /// `ß` matches `ss` (docs/oracle/m4-search.md).
    @Test func testIndexerWritesFoldedRawText() throws {
        let text = """
            # Plan **bold** for #work
            See [the site](https://example.com/HiddenPath) and [[Other Note/Head|the alias]].
            Straße · Müller
            ![](Photo.jpg)
            [report.pdf](report.pdf)<!-- {"embed":"true"} -->
            """
        let note = try store.create(text: text)
        let r = try #require(try row(note.id))
        #expect(r.title == "plan bold for #work")
        #expect(r.attachmentNames == "photo.jpg report.pdf")
        #expect(r.ocrText == "")
        #expect(r.body == SearchText.fold(text))
        for kept in ["# plan **bold** for #work", "](https://example.com/hiddenpath)", "[[other note/head|the alias]]",
                     "strasse · muller", "![](photo.jpg)", "<!-- {\"embed\":\"true\"} -->"] {
            #expect(r.body.contains(kept), "body lacks \(kept): \(r.body)")
        }
        #expect(try trigram("\"hiddenpath\"") == [note.id])
        #expect(try trigram("\"strasse\"") == [note.id])
        #expect(try words("\"alias\"") == [note.id])
    }

    @Test func testFoldingMatchesSearchOffsets() {
        #expect(SearchText.fold("Straße MÜLLER Café") == "strasse muller cafe")
        #expect(SearchText.fold("ASCII Only") == "ascii only")
        #expect(SearchText.fold("日本語") == "日本語")
        #expect(SearchText.fold("한국어") == "한국어")
    }

    @Test func testFTSStaysInSyncOnInsertUpdateDelete() throws {
        let a = try store.create(text: "Alpha note\nsomething unique")
        let b = try store.create(text: "Other\nalpha again")
        #expect(Set(try words("\"alpha\"")) == [a.id, b.id])
        #expect(try trigram("\"uniq\"") == [a.id])

        let a2 = try store.updateText(id: a.id, text: "Beta note\nreplaced", expectedRevision: a.revision)
        #expect(try words("\"alpha\"") == [b.id])
        #expect(try words("\"beta\"") == [a.id])
        #expect(try trigram("\"uniq\"") == [])
        #expect(try trigram("\"eplac\"") == [a.id])
        try checkIntegrity()

        // Trash keeps the row (search inside Trash); permanent deletion cascades to the FTS rows.
        try store.trash([a2.id])
        #expect(try words("\"beta\"") == [a.id])
        try store.deletePermanently([a.id])
        #expect(try row(a.id) == nil)
        #expect(try words("\"beta\"") == [])
        #expect(try trigram("\"eplac\"") == [])
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_search_content") } == 1)
        try checkIntegrity()
    }

    @Test func testRowidIsStableAcrossEdits() throws {
        let note = try store.create(text: "One")
        let rowid = { try self.db.pool.read {
            try Int64.fetchOne($0, sql: "SELECT rowid FROM note_search_content WHERE noteId = ?", arguments: [note.id])
        } }
        let before = try rowid()
        _ = try store.updateText(id: note.id, text: "Two", expectedRevision: note.revision)
        #expect(try rowid() == before)
    }

    @Test func testDiacriticsAndCaseInsensitive() throws {
        let umlaut = try store.create(text: "Herr Müller\nCafé crème")
        let plain = try store.create(text: "Frau Muller\ncafe")
        let both = Set([umlaut.id, plain.id])
        #expect(Set(try words("\"muller\"")) == both)
        #expect(Set(try words("\"MÜLLER\"")) == both)
        #expect(Set(try words("\"mül\"*")) == both)
        #expect(Set(try words("\"cafe\"")) == both)
        #expect(Set(try trigram("\"ülle\"")) == both)
        #expect(Set(try trigram("\"ULLE\"")) == both)
    }

    @Test func testPrefixAndCJKSubstring() throws {
        let latin = try store.create(text: "Programming notes\nabout Bearings")
        let cjk = try store.create(text: "メモ\nこれは日本語のテキストです")
        let zh = try store.create(text: "笔记\n我们在学习中文搜索")
        #expect(try words("\"prog\"*") == [latin.id])
        #expect(try words("\"pr\"*") == [latin.id])
        // unicode61 sees a CJK run as one token: substrings need the trigram index.
        #expect(try words("\"日本語\"") == [])
        #expect(try trigram("\"日本語\"") == [cjk.id])
        #expect(try trigram("\"語のテ\"") == [cjk.id])
        #expect(try trigram("\"学习中\"") == [zh.id])
        #expect(try trigram("\"ear\"") == [latin.id])
    }

    @Test func testFTSSyntaxInContentIsInert() throws {
        let note = try store.create(text: "Weird \"quotes\" AND NEAR( x * y ) -minus col:on")
        #expect(try words("\"near\"") == [note.id])
        #expect(try words("\"col on\"") == [note.id])
        try checkIntegrity()
    }

    @Test func testLockedNoteHasNoSearchRow() throws {
        let note = try store.create(text: "Secret plans\nhidden words")
        #expect(try row(note.id) != nil)
        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [note.id])
            try NoteIndexer.index(noteId: note.id, text: "", in: db)
        }
        #expect(try row(note.id) == nil)
        #expect(try words("\"secret\"") == [])
        #expect(try trigram("\"hidden\"") == [])
        try checkIntegrity()

        try db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 0, text = 'Open again' WHERE id = ?", arguments: [note.id])
            try NoteIndexer.index(noteId: note.id, text: "Open again", in: db)
        }
        #expect(try words("\"open\"") == [note.id])
    }

    // MARK: migration

    @Test func testMigrationV4BackfillsSearchContent() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Migrations.migrator.migrate(queue, upTo: "v3")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt)
                VALUES ('n1', '# Grüße **aus** #home' || char(10) || '[link](https://x.example/secret) 日本語テキスト' || char(10) || '![](a.png)',
                        'Grüße aus #home', '', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000');
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt, isLocked)
                VALUES ('locked', '', '', '', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 1);
                INSERT INTO note_stats (noteId, attachmentNames) VALUES ('n1', 'a.png' || char(10) || 'b.pdf');
                """)
        }
        try Migrations.migrator.migrate(queue, upTo: "v4")
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT noteId, title, body, attachmentNames FROM note_search_content")
            #expect(rows.count == 1)
            let r = try #require(rows.first)
            #expect(r["noteId"] as String == "n1")
            #expect(r["title"] as String == "Grüße aus #home")
            #expect(r["body"] as String == "Grüße aus home\nlink 日本語テキスト")
            #expect(r["attachmentNames"] as String == "a.png b.pdf")
            #expect(try matchIds(db, table: "note_fts", "\"aus\"") == ["n1"])
            #expect(try matchIds(db, table: "note_fts", "\"secret\"") == [])
            #expect(try matchIds(db, table: "note_fts_trigram", "\"本語テ\"") == ["n1"])
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO note_fts(note_fts, rank) VALUES ('integrity-check', 1)")
            try db.execute(sql: "INSERT INTO note_fts_trigram(note_fts_trigram, rank) VALUES ('integrity-check', 1)")
        }
    }

    @Test func testMigrationV5RefoldsSearchContentToRawText() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Migrations.migrator.migrate(queue, upTo: "v3")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt)
                VALUES ('n1', '# Straße **aus** #home' || char(10) || '[link](https://x.example/Secret)',
                        'Straße aus #home', '', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000');
                INSERT INTO note_stats (noteId, attachmentNames) VALUES ('n1', 'A.png' || char(10) || 'b.pdf');
                """)
        }
        try Migrations.migrator.migrate(queue)
        try queue.read { db in
            let r = try #require(try Row.fetchOne(db, sql: "SELECT title, body, attachmentNames FROM note_search_content"))
            #expect(r["title"] as String == "strasse aus #home")
            #expect(r["body"] as String == "# strasse **aus** #home\n[link](https://x.example/secret)")
            #expect(r["attachmentNames"] as String == "a.png b.pdf")
            #expect(try matchIds(db, table: "note_fts_trigram", "\"x.example/secret\"") == ["n1"])
            #expect(try matchIds(db, table: "note_fts", "\"strasse\"") == ["n1"])
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO note_fts(note_fts, rank) VALUES ('integrity-check', 1)")
            try db.execute(sql: "INSERT INTO note_fts_trigram(note_fts_trigram, rank) VALUES ('integrity-check', 1)")
        }
    }

    @Test func testMigrationFromV1StillRuns() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt)
                VALUES ('n1', 'Hello' || char(10) || 'old world', 'x', 'x', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')
                """)
        }
        try Migrations.migrator.migrate(queue)
        let ids = try queue.read { try matchIds($0, table: "note_fts", "\"world\"") }
        #expect(ids == ["n1"])
    }

    // MARK: performance (spec §6: 10,000 notes, p95 < 50 ms)

    @Test(.tags(.perf), PerfGate.onlyInPerfPass) func testPerfSearchContentOn10kNotes() throws {
        let vocabulary = Self.vocabulary(count: 6000)
        var rng = SplitMix64(seed: 42)
        try db.pool.write { db in
            let insertNote = try db.makeStatement(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt)
                VALUES (?, '', ?, '', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')
                """)
            let insertContent = try db.makeStatement(sql: """
                INSERT INTO note_search_content (noteId, title, body, attachmentNames) VALUES (?, ?, ?, '')
                """)
            for i in 0..<10_000 {
                let title = (0..<4).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }.joined(separator: " ")
                var body = (0..<100).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }
                if i % 50 == 0 { body.append("東京都の日本語メモ") }
                let id = "note-\(i)"
                try insertNote.execute(arguments: [id, title])
                try insertContent.execute(arguments: [id, title, body.joined(separator: " ")])
            }
        }

        func measure(_ label: String, _ queries: [String], sql: String) throws -> Double {
            var samples: [Double] = []
            var hits = 0
            try db.pool.read { db in
                for q in queries + queries {
                    let start = DispatchTime.now().uptimeNanoseconds
                    hits = try String.fetchAll(db, sql: sql, arguments: [q]).count
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
            }
            samples.sort()
            let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
            print(String(format: "[perf] %@: p50 %.2f ms, p95 %.2f ms, max %.2f ms (last query %d hits, n=%d)",
                         label, samples[samples.count / 2], p95, samples.last!, hits, samples.count))
            return p95
        }

        let prefixes = vocabulary.prefix(20).map { "\"\(String($0.prefix(3)))\"*" }
            + vocabulary.dropFirst(20).prefix(10).map { "\"\(String($0.prefix(2)))\"*" }
        let prefixP95 = try measure("note_fts prefix MATCH", prefixes, sql: """
            SELECT noteId FROM note_search_content
            WHERE rowid IN (SELECT rowid FROM note_fts WHERE note_fts MATCH ?)
            """)
        let substrings = vocabulary.dropFirst(40).prefix(20).map { "\"\(String($0.dropFirst(1).prefix(4)))\"" }
            + vocabulary.dropFirst(60).prefix(10).map { "\"\(String($0.dropFirst(1).prefix(3)))\"" }
            + ["\"日本語\"", "\"京都の\""]
        let trigramP95 = try measure("note_fts_trigram substring MATCH", substrings, sql: """
            SELECT noteId FROM note_search_content
            WHERE rowid IN (SELECT rowid FROM note_fts_trigram WHERE note_fts_trigram MATCH ?)
            """)
        #expect(prefixP95 < 50)
        #expect(trigramP95 < 50)
    }

    /// Pseudo-words of 4–9 lowercase letters, deterministic.
    static func vocabulary(count: Int) -> [String] {
        var rng = SplitMix64(seed: 7)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return (0..<count).map { _ in
            let length = 4 + Int(rng.next() % 6)
            return String((0..<length).map { _ in letters[Int(rng.next() % 26)] })
        }
    }
}

func matchIds(_ db: Database, table: String, _ match: String) throws -> [String] {
    try String.fetchAll(db, sql: """
        SELECT c.noteId FROM \(table) f JOIN note_search_content c ON c.rowid = f.rowid
        WHERE \(table) MATCH ? ORDER BY c.noteId
        """, arguments: [match])
}

@Suite struct SearchOffsetsTests {
    private func strings(_ ranges: [Range<Int>], in text: String) -> [String] {
        let utf16 = Array(text.utf16)
        return ranges.map { String(decoding: utf16[$0], as: UTF16.self) }
    }

    @Test func testCaseAndDiacriticInsensitiveRanges() {
        let text = "Herr Müller met MULLER and muller."
        let ranges = SearchOffsets.sourceRanges(for: ["muller"], in: text)
        #expect(strings(ranges, in: text) == ["Müller", "MULLER", "muller"])
        #expect(ranges.first == 5..<11)
    }

    @Test func testRangesAreUTF16AndSorted() {
        let text = "😀 café 😀 Cafe"
        let ranges = SearchOffsets.sourceRanges(for: ["cafe", "😀"], in: text)
        #expect(ranges == [0..<2, 3..<7, 8..<10, 11..<15])
        #expect(strings(ranges, in: text) == ["😀", "café", "😀", "Cafe"])
    }

    @Test func testDecomposedSourceAndCJK() {
        let text = "Mu\u{0308}ller · これは日本語です"
        let ranges = SearchOffsets.sourceRanges(for: ["MÜLLER", "日本"], in: text)
        #expect(strings(ranges, in: text) == ["Mu\u{0308}ller", "日本"])
    }

    @Test func testFirstMatchPrefersWordStart() {
        let text = "Start the art class"
        #expect(SearchOffsets.firstMatch(for: ["art"], in: text) == 10..<13)
        #expect(SearchOffsets.firstMatch(for: ["tart"], in: text) == 1..<5)  // only inside a word
        #expect(SearchOffsets.firstMatch(for: ["start"], in: text) == 0..<5)
        #expect(SearchOffsets.firstMatch(for: ["zzz"], in: text) == nil)
        #expect(SearchOffsets.firstMatch(for: ["art"], in: "😀art") == 2..<5)
        #expect(SearchOffsets.firstMatch(for: ["ss"], in: "Straße · ss") == 9..<11)
    }

    @Test func testOverlapsMergeAndEmptyTermsIgnored() {
        let text = "aaaa banana abab"
        #expect(SearchOffsets.sourceRanges(for: ["aa"], in: text) == [0..<4])
        #expect(SearchOffsets.sourceRanges(for: ["ana", "nan"], in: text) == [6..<11])
        #expect(SearchOffsets.sourceRanges(for: ["ab"], in: text) == [12..<14, 14..<16])
        #expect(SearchOffsets.sourceRanges(for: ["", " "], in: text) == [])
    }
}
