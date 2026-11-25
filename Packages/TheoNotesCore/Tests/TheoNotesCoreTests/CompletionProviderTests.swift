// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// M3 Task 7: what the editor's `#`, `[[`, `[[Title/` and `:` completions list, in which order.
@Suite struct CompletionProviderTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let provider: CompletionProvider
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        provider = CompletionProvider(db: db)
    }

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// `NoteTitleIndex` reads its fingerprint `INDEXED BY note_on_modifiedAt`, so the index must
    /// keep that name through every migration (triage #44: M9 rebuilds the note table).
    @Test func testTheFingerprintIndexSurvivesTheMigrations() throws {
        let names = try db.pool.read { try $0.indexes(on: "note").map(\.name) }
        #expect(names.contains("note_on_modifiedAt"))
        try note("Plan")
        #expect(labels(try provider.notes(matching: "pla", sourceNoteId: "o")) == ["Plan"])
        // Without it every note completion fails.
        try db.pool.write { try $0.execute(sql: "DROP INDEX note_on_modifiedAt") }
        provider.invalidateCaches()
        #expect(throws: (any Error).self) { try provider.notes(matching: "pla", sourceNoteId: "o") }
    }

    @discardableResult
    private func note(_ text: String, _ seconds: Double = 0) throws -> Note {
        try store.create(text: text, now: at(seconds))
    }

    private func labels(_ items: [CompletionItem]) -> [String] { items.map(\.label) }

    // MARK: Tags

    @Test func testTagsRankPathPrefixThenComponentThenSubstringByNoteCountThenName() throws {
        try note("a #work #homework #network")
        try note("b #work #homework #network")
        try note("c #work #wonder #school/workshop")
        try note("d #wonder")
        let items = try provider.tags(matching: "wo", sourceNoteId: "other")
        // Path prefix (work 3 notes, wonder 2), then a component prefix (school/workshop), then
        // substrings (homework and network: 2 notes each, by name).
        #expect(labels(items) == ["work", "wonder", "school/workshop", "homework", "network"])
        #expect(items[0] == CompletionItem(label: "work", insert: "#work ", detail: "3", icon: "briefcase"))
    }

    @Test func testTagsInsertTheClosedFormWhenTheOpenOneWouldNotParse() throws {
        try note("x #my tag# #2021# #work/projects #a.b#")
        let items = try provider.tags(matching: "", sourceNoteId: "other")
        let inserts = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0.insert) })
        #expect(inserts["my tag"] == "#my tag# ")
        #expect(inserts["2021"] == "#2021# ")
        #expect(inserts["work/projects"] == "#work/projects ")
        #expect(inserts["work"] == "#work ")
        #expect(inserts["a.b"] == "#a.b# ")
    }

    @Test func testTagsSkipTrashedNotesAndTheNoteBeingEdited() throws {
        let trashed = try note("t #trashonly #shared")
        try store.trash([trashed.id])
        let editing = try note("e #wor #shared")
        try note("o #shared")
        // `wor` exists only because the debounced commit indexed the tag being typed.
        #expect(labels(try provider.tags(matching: "", sourceNoteId: editing.id)) == ["shared"])
        #expect(try provider.tags(matching: "shared", sourceNoteId: editing.id).first?.detail == "1")
        #expect(labels(try provider.tags(matching: "", sourceNoteId: "other")) == ["shared", "wor"])
    }

    @Test func testTagIconsUseTheCustomIconElseTheTagConTable() throws {
        try note("x #work #Reisen #misc #home")
        try store.setTagIcon("misc", symbol: "star.fill")
        let icons = Dictionary(uniqueKeysWithValues: try provider.tags(matching: "", sourceNoteId: "o").map { ($0.label, $0.icon) })
        #expect(icons["work"] == "briefcase")
        #expect(icons["Reisen"] == "airplane")
        #expect(icons["misc"] == "star.fill")
        #expect(icons["home"] == "house")
        let map = try provider.tagIconMap()
        #expect(map["reisen"] == "airplane")
        #expect(map["misc"] == "star.fill")
    }

    @Test func testTagMatchingIgnoresCaseAndDiacritics() throws {
        try note("x #Büro #Ärger")
        #expect(labels(try provider.tags(matching: "bu", sourceNoteId: "o")) == ["Büro"])
        #expect(labels(try provider.tags(matching: "ÄR", sourceNoteId: "o")) == ["Ärger"])
    }

    // MARK: Notes

    @Test func testNotesRankPrefixThenWordThenSubstringThenFuzzyThenRecency() throws {
        try note("Project Plan", 1)
        try note("Plan B", 2)
        try note("Old plans", 3)
        try note("Airplane", 4)
        try note("Pick a lane", 5)
        try note("Unrelated", 6)
        let items = try provider.notes(matching: "pla", sourceNoteId: "o")
        #expect(labels(items) == ["Plan B", "Old plans", "Project Plan", "Airplane", "Pick a lane"])
        #expect(items[0] == CompletionItem(label: "Plan B", insert: "Plan B", detail: nil, icon: nil))
    }

    @Test func testNotesWithAnEmptyQueryAreMostRecentFirstWithArchiveLast() throws {
        let archived = try note("Archived", 9)
        try store.archive([archived.id], now: at(9))
        try note("Older", 1)
        try note("Newer", 2)
        let items = try provider.notes(matching: "", sourceNoteId: "o")
        #expect(labels(items) == ["Newer", "Older", "Archived"])
        #expect(items.last?.detail == "Archive")
    }

    @Test func testArchivedNotesRankBelowNotesInTheSameTier() throws {
        let archived = try note("Plan archived", 9)
        try store.archive([archived.id], now: at(9))
        try note("Plan live", 1)
        try note("A plan", 2)
        #expect(labels(try provider.notes(matching: "plan", sourceNoteId: "o")) == ["Plan live", "Plan archived", "A plan"])
    }

    /// R16: one item per title, the note links resolve to (Trash excluded); never the source note.
    @Test func testNotesFollowTheWikiLinkResolutionRule() throws {
        let trashed = try note("Dup", 5)
        try store.trash([trashed.id], now: at(5))
        try note("Dup", 1)
        let source = try note("Source", 3)
        try note("Kept", 0)
        let gone = try note("Gone", 0)
        try store.trash([gone.id])
        let items = try provider.notes(matching: "", sourceNoteId: source.id)
        #expect(labels(items) == ["Dup", "Kept"])

        // A newer duplicate in the source note itself: links to the title resolve there.
        let selfDup = try note("Dup", 8)
        #expect(labels(try provider.notes(matching: "dup", sourceNoteId: selfDup.id)) == [])
    }

    @Test func testNoteInsertsEscapeSlashesAndUnlinkableTitlesAreLeftOut() throws {
        try note("2024/25 Budget", 3)
        try note("Bracket [x] note", 2)
        try note("Pipe | note", 1)
        let items = try provider.notes(matching: "", sourceNoteId: "o")
        #expect(items.map(\.insert) == ["2024\\/25 Budget"])
    }

    /// Fix round 1 (I2): every keystroke in `[[…` is one request. 10k notes, debug build:
    /// p95 < 20 ms per request once the folded titles are cached (the first request fills it).
    @Test(.tags(.perf), PerfGate.onlyInPerfPass) func testPerfNoteCompletionAt10kNotes() throws {
        let words = ["Project", "Plan", "Meeting", "Notes", "Budget", "Ideas", "Travel", "Recipe", "Journal", "Weekly",
                     "Review", "Müller", "Straße", "Café", "Q3", "Roadmap", "Kunde", "Angebot", "Draft", "Archive"]
        try db.pool.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO note (id, text, title, titleKey, createdAt, modifiedAt, location) VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            for i in 0..<10_000 {
                let title = "\(words[i % 20]) \(words[(i / 20) % 20]) \(words[(i / 400) % 20]) \(i)"
                try insert.execute(arguments: [
                    String(format: "perf-%05d", i), title, title, CanonicalKey.make(title), at(0), at(Double(i)),
                    i % 10 == 0 ? "archive" : "notes",
                ])
            }
        }
        let queries = ["", "p", "pl", "pla", "plan", "plan meet", "müll", "strasse", "zzz", "q3 ro", "1234", "pmn"]
        // CPU time of this thread (GRDB runs the read on it): the work a request costs, not the
        // wait for a core while parallel tests (or other builds) load the machine. Wall time is
        // printed next to it.
        func measure(_ body: () throws -> Void) rethrows -> (cpu: Double, wall: Double) {
            var start = timespec(), end = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
            let wallStart = DispatchTime.now().uptimeNanoseconds
            try body()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
            let cpu = Double(end.tv_sec - start.tv_sec) * 1000 + Double(end.tv_nsec - start.tv_nsec) / 1e6
            return (cpu, Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1e6)
        }
        let cold = try measure { _ = try provider.notes(matching: "pla", sourceNoteId: "x") }
        var cpu: [Double] = [], wall: [Double] = []
        for _ in 0..<5 {
            for query in queries {
                var count = 0
                let t = try measure { count = try provider.notes(matching: query, sourceNoteId: "x").count }
                cpu.append(t.cpu)
                wall.append(t.wall)
                #expect(count <= CompletionProvider.limit)
            }
        }
        cpu.sort()
        wall.sort()
        let pct = { (a: [Double], p: Int) in a[min(a.count - 1, a.count * p / 100)] }
        let f = { (v: Double) in String(format: "%.1f", v) }
        // A write (the debounced commit of the note being typed in) rebuilds the cache, folding
        // only the changed title.
        let later = at(20_000)
        try db.pool.write {
            try $0.execute(sql: """
                UPDATE note SET title = 'Plan renamed', titleKey = 'plan renamed', revision = revision + 1, modifiedAt = ?
                WHERE id = 'perf-00007'
                """, arguments: [later])
        }
        var renamed: [CompletionItem] = []
        let rebuild = try measure { renamed = try provider.notes(matching: "plan renamed", sourceNoteId: "x") }
        #expect(renamed.first?.label == "Plan renamed")
        print("""
            note completion, 10k notes (debug), CPU ms: cold \(f(cold.cpu)), after a write \(f(rebuild.cpu)), \
            p50 \(f(pct(cpu, 50))), p95 \(f(pct(cpu, 95))), max \(f(cpu.last!)); wall ms: cold \(f(cold.wall)), \
            after a write \(f(rebuild.wall)), p50 \(f(pct(wall, 50))), p95 \(f(pct(wall, 95)))
            """)
        #expect(pct(cpu, 95) < 20)
        #expect(rebuild.cpu < 100)
    }

    /// Edits and new notes refresh the cached titles by themselves; a move to the Archive (no new
    /// `modifiedAt`) after `invalidateCaches()`, which the app calls on every change notification.
    @Test func testCachedTitlesFollowWrites() throws {
        let plan = try note("Plan", 1)
        #expect(labels(try provider.notes(matching: "pl", sourceNoteId: "o")) == ["Plan"])
        try note("Plane", 2)
        _ = try store.updateText(id: plan.id, text: "Planet", expectedRevision: plan.revision, now: at(3))
        #expect(labels(try provider.notes(matching: "pl", sourceNoteId: "o")) == ["Planet", "Plane"])
        try store.archive([plan.id], now: at(4))
        provider.invalidateCaches()
        #expect(try provider.notes(matching: "pl", sourceNoteId: "o").map(\.detail) == [nil, "Archive"])
    }

    /// Fix round 2 (N1, N2): `invalidate()` (main thread) never waits for a rebuild, and a
    /// rebuild that raced an invalidation is not kept.
    @Test func testInvalidateNeverWaitsAndARacedRebuildIsNotKept() throws {
        // A file database (WAL pool): a write can commit while the rebuild's read is open.
        try FileManager.default.createDirectory(at: tmp.paths.database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try AppDatabase(path: tmp.paths.database)
        let store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        let provider = CompletionProvider(db: db)
        let plan = try store.create(text: "Plan", now: at(1))
        _ = try store.create(text: "Plane", now: at(2))
        _ = try provider.notes(matching: "pl", sourceNoteId: "o")
        _ = try store.create(text: "Planet", now: at(3)) // the next request rebuilds

        let inRebuild = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let index = provider.titleIndex
        index.rebuildHook = {
            index.rebuildHook = nil
            inRebuild.signal()
            proceed.wait()
        }
        let done = DispatchSemaphore(value: 0)
        // Own threads, not GCD's global pool: in a full parallel run other tests block that pool,
        // and a starved block would look like a hang of the code under test.
        Thread {
            _ = try? provider.notes(matching: "pl", sourceNoteId: "o")
            done.signal()
        }.start()
        #expect(inRebuild.wait(timeout: .now() + 10) == .success)

        // During the rebuild: archive a note (no new modifiedAt) and invalidate, as the app does.
        try db.pool.write {
            try $0.execute(sql: "UPDATE note SET location = 'archive', revision = revision + 1 WHERE id = ?", arguments: [plan.id])
        }
        let invalidated = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        Thread {
            index.invalidate()
            invalidated.signal()
        }.start()
        let returned = invalidated.wait(timeout: .now() + 1)
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        proceed.signal()
        #expect(returned == .success, "invalidate() waited for the rebuild")
        #expect(waited < 100)
        #expect(done.wait(timeout: .now() + 10) == .success)

        // The raced snapshot (read before the archive) was not stored: the next request sees it.
        let items = try provider.notes(matching: "pl", sourceNoteId: "o")
        #expect(items.first { $0.label == "Plan" }?.detail == "Archive")
    }

    @Test func testANoteScanStopsWhenItsTaskIsCancelled() async throws {
        let date = t0
        try await db.pool.write { db in
            for i in 0..<3_000 {
                try db.execute(sql: "INSERT INTO note (id, title, titleKey, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: ["c-\(i)", "Title \(i)", "title \(i)", date, date])
            }
        }
        let provider = provider
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try provider.notes(matching: "ti", sourceNoteId: "x")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func testLiveHeadingsAreParsedOncePerRevision() throws {
        let source = try note("Doc")
        for _ in 0..<3 {
            _ = try provider.headings(noteTitle: "", matching: "", sourceNoteId: source.id, sourceText: "Doc\n## A", sourceRevision: 4)
        }
        let items = try provider.headings(noteTitle: "", matching: "", sourceNoteId: source.id, sourceText: "Doc\n## B", sourceRevision: 5)
        #expect(items.map(\.label) == ["B"])
        #expect(provider.liveHeadingParses == 2)
        // N3: a re-opened session starts its revisions over; another text at a known revision
        // is parsed, not served from the cache.
        let reopened = try provider.headings(noteTitle: "", matching: "", sourceNoteId: source.id, sourceText: "Doc\n## C", sourceRevision: 5)
        #expect(reopened.map(\.label) == ["C"])
        #expect(provider.liveHeadingParses == 3)
    }

    @Test func testNotesAreLimited() throws {
        for i in 0..<(CompletionProvider.limit + 5) { try note("Note \(i)", Double(i)) }
        #expect(try provider.notes(matching: "note", sourceNoteId: "o").count == CompletionProvider.limit)
    }

    // MARK: Headings

    @Test func testHeadingsOfTheNoteTheTitleResolvesTo() throws {
        try note("Plan\n## Old heading", 1)
        try note("plan\n# Intro\n## Next   Steps\n### Notes on intro\n## Stray | pipe", 2)
        let items = try provider.headings(noteTitle: "PLAN", matching: "", sourceNoteId: "o", sourceText: nil)
        #expect(labels(items) == ["Intro", "Next Steps", "Notes on intro"])
        #expect(items[1] == CompletionItem(label: "Next Steps", insert: "Next Steps", detail: "H2", icon: nil))
        #expect(labels(try provider.headings(noteTitle: "Plan", matching: "in", sourceNoteId: "o", sourceText: nil))
            == ["Intro", "Notes on intro"])
        #expect(try provider.headings(noteTitle: "Absent", matching: "", sourceNoteId: "o", sourceText: nil).isEmpty)
    }

    @Test func testHeadingsOfTheCurrentNoteComeFromItsLiveText() throws {
        let source = try note("Doc\n## Stored")
        let items = try provider.headings(noteTitle: "", matching: "", sourceNoteId: source.id, sourceText: "Doc\n## Typed\n## Second")
        #expect(labels(items) == ["Typed", "Second"])
        // Without live text: the indexed headings.
        #expect(labels(try provider.headings(noteTitle: "", matching: "", sourceNoteId: source.id, sourceText: nil)) == ["Stored"])
    }

    /// The completion inserts what navigation (`headingIndex`) finds again.
    @Test func testAnInsertedHeadingNavigates() throws {
        let target = try note("Target\n## Next   Steps\n## Ünïcode Heading")
        for item in try provider.headings(noteTitle: "Target", matching: "", sourceNoteId: "o", sourceText: nil) {
            let resolved = try store.resolveOrCreateWikiLink(title: "Target", heading: item.insert, from: "o")
            #expect(resolved.noteId == target.id)
            #expect(resolved.headingIndex != nil)
            let link = try store.resolveWikiLink(WikiLinkRef(target: "Target", heading: item.insert), from: "o")
            #expect(link?.headingOrdinal == resolved.headingIndex)
        }
    }

    // MARK: Emoji

    @Test func testEmojiMatchEnglishAndGermanNames() {
        let cat = CompletionProvider.emoji(matching: "cat")
        #expect(cat.first == CompletionItem(label: "🐈 cat", insert: "🐈", detail: nil, icon: nil))
        #expect(cat.contains { $0.insert == "🐱" })
        let katze = CompletionProvider.emoji(matching: "katze")
        #expect(katze.first?.insert == "🐈")
        #expect(katze.first?.label == "🐈 Katze")
        #expect(CompletionProvider.emoji(matching: "Herz").contains { $0.insert == "❤️" })
        #expect(CompletionProvider.emoji(matching: "thumbs").first?.insert == "👍")
        #expect(CompletionProvider.emoji(matching: "zzqx").isEmpty)
        #expect(CompletionProvider.emoji(matching: "").isEmpty)
        #expect(CompletionProvider.emoji(matching: "a").count <= CompletionProvider.emojiLimit)
    }

    @Test func testEmojiDataIsBundledWithBothLanguages() throws {
        let entries = CompletionProvider.emojiEntries
        #expect(entries.count >= 1_400 && entries.count <= 1_600)
        #expect(entries.allSatisfy { !$0.en.isEmpty })
        #expect(entries.filter { !$0.de.isEmpty }.count > 1_400)
    }

    // MARK: Dispatch

    @Test func testItemsDispatchByKind() throws {
        try note("Work note\n#work", 1)
        let source = try note("Source\n## Here")
        #expect(labels(try provider.items(kind: .tag, query: "wo", noteTitle: nil, sourceNoteId: source.id, sourceText: nil)) == ["work"])
        #expect(labels(try provider.items(kind: .note, query: "work", noteTitle: nil, sourceNoteId: source.id, sourceText: nil)) == ["Work note"])
        #expect(labels(try provider.items(kind: .heading, query: "", noteTitle: nil, sourceNoteId: source.id, sourceText: "Source\n## Here")) == ["Here"])
        #expect(try provider.items(kind: .emoji, query: "cat", noteTitle: nil, sourceNoteId: source.id, sourceText: nil).first?.insert == "🐈")
    }
}
