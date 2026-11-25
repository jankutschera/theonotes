// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesCore

/// Records how it is called; the text it returns is the file's name.
final class FakeExtractor: TextExtracting {
    struct State {
        var started: [String] = []
        var hashes: [String: String?] = [:]
        var running = 0
        var maxRunning = 0
        var ranOnMainThread = false
        var priorities: [TaskPriority] = []
        var duringExtraction: (@Sendable (URL) -> Void)?
        var delay: Duration = .milliseconds(1)
        var result: Result = .text

        enum Result { case text, none, failed }
    }

    let state = Mutex(State())

    var started: [String] { state.withLock(\.started) }
    var maxRunning: Int { state.withLock(\.maxRunning) }
    var ranOnMainThread: Bool { state.withLock(\.ranOnMainThread) }
    var priorities: [TaskPriority] { state.withLock(\.priorities) }
    func hash(of name: String) -> String?? { state.withLock { $0.hashes[name] } }

    func configure(
        delay: Duration? = nil, result: State.Result? = nil, duringExtraction: (@Sendable (URL) -> Void)? = nil
    ) {
        state.withLock {
            if let delay { $0.delay = delay }
            if let result { $0.result = result }
            $0.duringExtraction = duringExtraction
        }
    }

    func extract(from url: URL) async -> OCRResult {
        await extract(from: url, knownSHA256: nil)
    }

    func extract(from url: URL, knownSHA256: String?) async -> OCRResult {
        let priority = Task.currentPriority
        let (hook, delay, kind) = state.withLock { state -> ((@Sendable (URL) -> Void)?, Duration, State.Result) in
            state.started.append(url.lastPathComponent)
            state.hashes[url.lastPathComponent] = .some(knownSHA256)
            state.priorities.append(priority)
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            if Thread.isMainThread { state.ranOnMainThread = true }
            return (state.duringExtraction, state.delay, state.result)
        }
        hook?(url)
        try? await Task.sleep(for: delay)
        state.withLock { $0.running -= 1 }
        let sha256 = AttachmentTextExtractor.sha256(of: url) ?? "none"
        switch kind {
        case .failed: return .failed
        case .none: return .none(sha256: sha256)
        case .text:
            let facts = OCRFileFacts(url: url)
            return .text(
                url.lastPathComponent, sha256: sha256, byteSize: facts?.size ?? 0, modifiedAt: facts?.modifiedAt ?? Date())
        }
    }
}

@Suite struct OCRQueueTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let texts: AttachmentTextStore
    let files: AttachmentStore
    let fake = FakeExtractor()

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        texts = AttachmentTextStore(database: db)
        files = AttachmentStore(paths: tmp.paths, database: db)
    }

    func queue(pause: Duration = .zero, batchSize: Int = 20) -> OCRQueue {
        OCRQueue(store: texts, files: files, extractor: fake, pause: pause, batchSize: batchSize)
    }

    /// A note linking `names`, each file on disk with `bytes(name)`.
    @discardableResult
    func note(_ names: [String], bytes: (String) -> Data = { Data($0.utf8) }) throws -> Note {
        let note = try store.create(text: "# T\n" + names.map { "![](\($0))" }.joined(separator: "\n"))
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try bytes(name).write(to: dir.appendingPathComponent(name)) }
        return note
    }

    func rows(_ noteId: String) throws -> [String: (state: String, text: String?)] {
        try db.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT filename, ocrState, ocrText FROM attachment WHERE noteId = ?", arguments: [noteId])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["filename"] as String, ($0["ocrState"] as String, $0["ocrText"] as String?)) })
        }
    }

    func eventually(_ what: String = "condition", _ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "\(what)")
    }

    // MARK: Tests

    @Test func testBacklogRecognizesEveryPendingAttachment() async throws {
        let one = try note(["a.png", "b.png"])
        let two = try note(["c.pdf"])
        let queue = queue()
        await queue.runBacklog()
        #expect(try rows(one.id)["a.png"]?.text == "a.png" && rows(one.id)["b.png"]?.state == "done")
        #expect(try rows(two.id)["c.pdf"]?.state == "done")
        #expect(try texts.pendingJobs(limit: 10).isEmpty)
        #expect(fake.started.sorted() == ["a.png", "b.png", "c.pdf"])
    }

    @Test @MainActor func testExtractionNeverRunsOnTheMainThread() async throws {
        let n = try note(["a.png", "b.png"])
        let queue = queue()
        // Both entry points, called from the main actor.
        await queue.enqueue([OCRJob(noteId: n.id, filename: "a.png")])
        await queue.startBacklog()
        // Polled, not awaited: awaiting the worker from the main actor would raise its priority.
        let fake = fake
        for _ in 0..<1000 where fake.started.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(fake.started.count == 2)
        #expect(!fake.ranOnMainThread)
        // Detached at utility priority, not the caller's.
        #expect(fake.priorities.count == 2 && fake.priorities.allSatisfy { $0 == .utility }, "\(fake.priorities)")
    }

    @Test func testThePauseBetweenJobsIsKept() async throws {
        try note(["a.png", "b.png", "c.png"])
        let started = ContinuousClock.now
        await queue(pause: .milliseconds(120)).runBacklog()
        #expect(fake.started.count == 3)
        #expect(ContinuousClock.now - started >= .milliseconds(230), "two pauses of 120 ms")
    }

    @Test func testOnlyFilesTheExtractorReadsAreHashedAndTheHashIsPassedOn() async throws {
        let n = try note(["a.png", "movie.mov"])
        await queue().runBacklog()
        let sha = try #require(AttachmentTextExtractor.sha256(
            of: tmp.paths.attachments.appendingPathComponent(n.id).appendingPathComponent("a.png")))
        #expect(fake.hash(of: "a.png") == .some(.some(sha)))
        #expect(fake.hash(of: "movie.mov") == .some(nil), "no hash for a type the extractor cannot read")
    }

    @Test func testCancelDropsWhatIsWaiting() async throws {
        let n = try note(["a.png", "b.png", "c.png"])
        fake.configure(delay: .milliseconds(80))
        let queue = queue()
        let run = Task { await queue.runBacklog() }
        await eventually("first job started") { fake.started.count == 1 }
        await queue.enqueue([OCRJob(noteId: n.id, filename: "c.png")])
        await queue.cancel()
        await run.value
        #expect(fake.started.count == 1)
    }

    @Test func testOneJobAtATime() async throws {
        let names = (1...6).map { "f\($0).png" }
        let n = try note(names)
        fake.configure(delay: .milliseconds(20))
        let queue = queue()
        async let backlog: Void = queue.runBacklog()
        for name in names.prefix(3) { await queue.enqueue([OCRJob(noteId: n.id, filename: name)]) }
        await backlog
        await queue.waitUntilIdle()
        #expect(fake.maxRunning == 1)
        #expect(Set(fake.started) == Set(names))
    }

    @Test func testInsertJobsRunBeforeBacklog() async throws {
        let n = try note(["b1.png", "b2.png", "b3.png"])
        let inserted = try note(["new.png"])
        fake.configure(delay: .milliseconds(80))
        let queue = queue()
        // The inserted note's row is the newest: after the backlog in the store's order.
        let backlog = Task { await queue.runBacklog() }
        await eventually("first backlog job started") { fake.started.count == 1 }
        await queue.enqueue([OCRJob(noteId: inserted.id, filename: "new.png")])
        await backlog.value
        let order = fake.started
        #expect(order.count == 4)
        #expect(order[1] == "new.png", "insert job runs next, before the remaining backlog: \(order)")
        #expect(try rows(n.id).values.allSatisfy { $0.state == "done" })
    }

    @Test func testPauseStopsBacklogButNotInsertJobs() async throws {
        let n = try note(["b1.png", "b2.png", "b3.png", "b4.png"])
        let inserted = try note(["new.png"])
        fake.configure(delay: .milliseconds(80))
        let queue = queue()
        let backlog = Task { await queue.runBacklog() }
        await eventually("first backlog job started") { fake.started.count == 1 }
        await queue.pauseBacklog()
        await queue.enqueue([OCRJob(noteId: inserted.id, filename: "new.png")])
        await backlog.value
        await queue.waitUntilIdle()
        #expect(fake.started.count == 2 && fake.started[1] == "new.png", "\(fake.started)")
        #expect(try rows(inserted.id)["new.png"]?.state == "done")
        #expect(try rows(n.id).values.filter { $0.state == "pending" }.count == 3)
        // Resuming picks the rest up.
        await queue.runBacklog()
        #expect(try rows(n.id).values.allSatisfy { $0.state == "done" })
    }

    @Test func testSha256ReuseSkipsExtraction() async throws {
        let same = { (_: String) in Data("identical bytes".utf8) }
        let one = try note(["a.png"], bytes: same)
        let two = try note(["copy.png"], bytes: same)
        let queue = queue()
        await queue.runBacklog()
        #expect(fake.started.count == 1, "the second file has the first one's hash: \(fake.started)")
        let texts = try [rows(one.id)["a.png"], rows(two.id)["copy.png"]].map { $0?.text }
        #expect(texts[0] != nil && texts[0] == texts[1])
        #expect(try rows(two.id)["copy.png"]?.state == "done")
    }

    @Test func testLockedNoteIsNeverExtracted() async throws {
        let locked = try note(["secret.png"])
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [locked.id])
            try NoteIndexer.index(noteId: locked.id, text: "", in: db)
        }
        let queue = queue()
        await queue.enqueue([OCRJob(noteId: locked.id, filename: "secret.png")])
        await queue.runBacklog()
        await queue.waitUntilIdle()
        #expect(fake.started.isEmpty)
        #expect(try rows(locked.id)["secret.png"]?.state == "locked")
    }

    @Test func testANoteLockedWhileItsFileIsReadStoresNothing() async throws {
        let n = try note(["a.png"])
        let db = db
        fake.configure { _ in
            try? db.pool.write { db in
                try db.execute(sql: "UPDATE note SET isLocked = 1, text = '' WHERE id = ?", arguments: [n.id])
                try NoteIndexer.index(noteId: n.id, text: "", in: db)
            }
        }
        await queue().runBacklog()
        #expect(fake.started.count == 1)
        let row = try #require(try rows(n.id)["a.png"])
        #expect(row.state == "locked" && row.text == nil)
    }

    @Test func testNotesWithAStagedBatchAreLeftAlone() async throws {
        let n = try note(["a.png"])
        try await db.pool.write {
            try $0.execute(
                sql: "INSERT INTO staging_batch (id, noteId, replacing, filenames, createdAt) VALUES ('b', ?, 0, '[]', ?)",
                arguments: [n.id, Date()])
        }
        let queue = queue()
        await queue.enqueue([OCRJob(noteId: n.id, filename: "a.png")])
        await queue.runBacklog()
        await queue.waitUntilIdle()
        #expect(fake.started.isEmpty)
        #expect(try rows(n.id)["a.png"]?.state == "pending")
        try await db.pool.write { try $0.execute(sql: "DELETE FROM staging_batch") }
        await queue.runBacklog()
        #expect(try rows(n.id)["a.png"]?.state == "done")
    }

    @Test func testAFileReplacedWhileItIsReadKeepsTheRowPending() async throws {
        let n = try note(["a.png"])
        let path = tmp.paths.attachments.appendingPathComponent(n.id).appendingPathComponent("a.png")
        fake.configure { _ in try? Data("replaced with longer bytes".utf8).write(to: path) }
        let queue = queue()
        await queue.runBacklog()
        #expect(try rows(n.id)["a.png"]?.state == "pending")
        // The next pass reads the new bytes.
        fake.configure()
        await queue.runBacklog()
        #expect(try rows(n.id)["a.png"]?.state == "done")
        #expect(fake.started.count == 2)
    }

    @Test func testAMissingFileIsRecordedMissingAndRetriedLater() async throws {
        let n = try note(["a.png"])
        try FileManager.default.removeItem(at: tmp.paths.attachments.appendingPathComponent(n.id).appendingPathComponent("a.png"))
        let queue = queue()
        await queue.runBacklog()
        #expect(fake.started.isEmpty)
        #expect(try rows(n.id)["a.png"]?.state == "missing")
        // Not offered again within the backoff, so the run ends.
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
    }

    @Test func testRowsFromAnOlderRecognizerAreRecognizedAgain() async throws {
        let n = try note(["a.png"])
        let job = OCRJob(noteId: n.id, filename: "a.png")
        try texts.record(job, result: .text("old", sha256: "x", byteSize: 1, modifiedAt: Date()), recognizerVersion: 0)
        try await db.pool.write { try $0.execute(sql: "UPDATE attachment SET ocrAt = ?", arguments: [Date(timeIntervalSince1970: 1_000_000)]) }
        await queue().runBacklog()
        #expect(fake.started == ["a.png"])
        #expect(try rows(n.id)["a.png"]?.text == "a.png")
        #expect(try texts.pendingJobs(limit: 5).isEmpty)
    }

    @Test func testTheSameInsertJobIsQueuedOnce() async throws {
        let n = try note(["a.png"])
        // "No text" is stored as `none`, which the scheduler's queries never re-offer, but the
        // queue itself would run the job again: only the in-flight check stops that.
        fake.configure(delay: .milliseconds(80), result: .none)
        let queue = queue()
        let job = OCRJob(noteId: n.id, filename: "a.png")
        await queue.enqueue([job, job])
        await eventually("job started") { fake.started.count == 1 }
        await queue.enqueue([job])
        await queue.waitUntilIdle()
        #expect(fake.started == ["a.png"])
    }

    @Test func testAFailedRerunKeepsTheOldTextAndWaitsBeforeTheNextTry() async throws {
        let n = try note(["a.png"])
        let job = OCRJob(noteId: n.id, filename: "a.png")
        let url = tmp.paths.attachments.appendingPathComponent(n.id).appendingPathComponent("a.png")
        let facts = try #require(OCRFileFacts(url: url))
        try texts.record(job, result: .text("old words", sha256: "x", byteSize: facts.size, modifiedAt: facts.modifiedAt), recognizerVersion: 0)
        try await db.pool.write { try $0.execute(sql: "UPDATE attachment SET ocrAt = ?", arguments: [Date(timeIntervalSince1970: 1_000_000)]) }
        fake.configure(result: .failed)
        let queue = queue()
        await queue.runBacklog()
        #expect(fake.started == ["a.png"])
        let row = try #require(try rows(n.id)["a.png"])
        #expect(row.text == "old words" && row.state == "done", "\(row)")
        // Not tried again in the next pass: it waits out the backoff.
        await queue.runBacklog()
        #expect(fake.started.count == 1)
    }

    @Test func testAFailedFileIsTriedAgainWhenItChanges() async throws {
        let n = try note(["a.png"])
        let url = tmp.paths.attachments.appendingPathComponent(n.id).appendingPathComponent("a.png")
        fake.configure(result: .failed)
        let queue = queue()
        await queue.runBacklog()
        #expect(try rows(n.id)["a.png"]?.state == "failed")
        // Same file: no second try inside the backoff.
        await queue.runBacklog()
        #expect(fake.started.count == 1)
        // Replaced (e.g. by a sync): tried at once.
        fake.configure(result: .text)
        try Data("a fixed, larger file".utf8).write(to: url)
        await queue.runBacklog()
        #expect(fake.started.count == 2)
        #expect(try rows(n.id)["a.png"]?.state == "done")
    }

    @Test func testAJobThatCannotBeStoredDoesNotSpinTheBacklog() async throws {
        let n = try note(["a.png"])
        // Every attachment write fails, so the row stays pending after each attempt.
        try await db.pool.write {
            try $0.execute(sql: "CREATE TEMP TRIGGER no_updates BEFORE UPDATE ON attachment BEGIN SELECT RAISE(ABORT, 'no'); END")
        }
        await queue().runBacklog()
        #expect(fake.started.count == 1)
        #expect(try rows(n.id)["a.png"]?.state == "pending")
    }
}
