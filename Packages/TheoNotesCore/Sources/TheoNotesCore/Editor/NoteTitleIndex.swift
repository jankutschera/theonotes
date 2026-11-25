// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// The folded note titles `[[` completion scores, cached between requests (one request per
/// keystroke). `invalidate()` (the app calls it on every database change notification) marks it
/// stale; each request also compares a cheap fingerprint read from the `modifiedAt` index (row
/// count, latest change), which catches new, deleted and edited notes even without a
/// notification. A rebuild folds only titles that changed.
final class NoteTitleIndex: @unchecked Sendable {
    /// One title a link can name: the R16 winner among the notes with that `titleKey`.
    struct Entry: Sendable {
        var id: String
        var title: String
        var archived: Bool
        /// `CompletionProvider.Match.fold(title)` as UTF-8.
        var key: [UInt8]
        /// Byte offsets in `key` where a word starts (after the first one at 0).
        var wordStarts: [Int]
    }

    fileprivate struct Fingerprint: Equatable {
        var count: Int
        var modified: Date?
    }

    private typealias Folded = [String: (title: String, key: [UInt8], wordStarts: [Int])]

    /// Guards the fields below; held only to read or write them, never during a rebuild, so
    /// `invalidate()` (called on the main thread) never waits.
    private let lock = NSLock()
    /// Bumped by `invalidate()`. A rebuild stores its result only if no invalidation happened
    /// since it started (its read transaction may predate the change).
    private var generation = 0
    private var cache: (fingerprint: Fingerprint, generation: Int, entries: [Entry])?
    /// Folded titles by note id, reused by the next rebuild (correct whatever the generation).
    private var folded: Folded = [:]
    /// Test hook: runs once per rebuild, after the first row.
    var rebuildHook: (@Sendable () -> Void)?

    /// Marks the cache stale (trash, archive and restore change no `modifiedAt`). Never waits.
    func invalidate() {
        lock.withLock { generation += 1 }
    }

    /// The entries in R16 order (most recent first), current as of this read. Throws
    /// `CancellationError` when the calling task is cancelled during a rebuild.
    func entries(in db: Database) throws -> [Entry] {
        // Both from the `note_on_modifiedAt` index, not the table. The hint ties this query to
        // the index name: migrations must keep it (Migrations.swift, CompletionProviderTests).
        let now = try Fingerprint(row: Row.fetchOne(db, sql: "SELECT count(*), max(modifiedAt) FROM note INDEXED BY note_on_modifiedAt")!)
        let (startGeneration, cached, reusable) = lock.withLock { (generation, cache, folded) }
        if let cached, cached.fingerprint == now, cached.generation == startGeneration { return cached.entries }

        let cursor = try Row.fetchCursor(db, sql: """
            SELECT id, title, titleKey, location = 'archive' FROM note WHERE \(WikiLinkResolver.liveNotes)
            ORDER BY \(WikiLinkResolver.order)
            """)
        var seen = Set<String>()
        var next: [Entry] = []
        var nextFolded: Folded = [:]
        next.reserveCapacity(cached?.entries.count ?? 0)
        nextFolded.reserveCapacity(reusable.count)
        var count = 0
        while let row = try cursor.next() {
            count += 1
            if count & 1023 == 0, Task.isCancelled { throw CancellationError() }
            guard seen.insert(row[2]).inserted else { continue }
            let id: String = row[0]
            let title: String = row[1]
            let parts = reusable[id].flatMap { $0.title == title ? $0 : nil } ?? Self.fold(title)
            nextFolded[id] = parts
            next.append(Entry(id: id, title: title, archived: row[3], key: parts.key, wordStarts: parts.wordStarts))
            if count == 1 { rebuildHook?() }
        }
        lock.withLock {
            folded = nextFolded
            // Invalidated meanwhile: this snapshot may miss the change, so it is not kept.
            if generation == startGeneration { cache = (now, startGeneration, next) }
        }
        return next
    }

    static func fold(_ title: String) -> (title: String, key: [UInt8], wordStarts: [Int]) {
        let key = CompletionProvider.Match.fold(title)
        var starts: [Int] = []
        var offset = 0
        var previousIsWord = false
        for scalar in key.unicodeScalars {
            let isWord = scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            if isWord && !previousIsWord && offset > 0 { starts.append(offset) }
            previousIsWord = isWord
            offset += UTF8.width(scalar)
        }
        return (title, Array(key.utf8), starts)
    }

    /// 0 equal, 1 starts with, 2 a word starts with, 3 contains, 4 fuzzy (the query's characters
    /// in order); nil no match. `q` is folded UTF-8, not empty.
    static func tier(_ entry: Entry, _ q: UnsafeBufferPointer<UInt8>) -> Int? {
        entry.key.withUnsafeBufferPointer { key in
            let n = key.count, m = q.count
            guard m <= n else { return nil }
            if memcmp(key.baseAddress!, q.baseAddress!, m) == 0 { return n == m ? 0 : 1 }
            for start in entry.wordStarts where start + m <= n {
                if memcmp(key.baseAddress! + start, q.baseAddress!, m) == 0 { return 2 }
            }
            if memmem(key.baseAddress!, n, q.baseAddress!, m) != nil { return 3 }
            return isSubsequence(q, of: key) ? 4 : nil
        }
    }

    /// Whole UTF-8 sequences of `q` appear in `s` in order (a sequence only matches at a
    /// character start).
    private static func isSubsequence(_ q: UnsafeBufferPointer<UInt8>, of s: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0, j = 0
        while i < q.count {
            var length = 1
            while i + length < q.count && q[i + length] & 0xC0 == 0x80 { length += 1 }
            var found = false
            while j + length <= s.count {
                if s[j] & 0xC0 != 0x80 && memcmp(s.baseAddress! + j, q.baseAddress! + i, length) == 0 {
                    found = true
                    j += length
                    break
                }
                j += 1
            }
            guard found else { return false }
            i += length
        }
        return true
    }
}

/// The headings of the edited note's live text (`[[/`), parsed once per session revision. A hit
/// needs the same note, revision and text, so a re-opened session (revisions start over) never
/// reuses another text's headings; the text comparison is a storage-identity check in the
/// common case.
final class LiveHeadings: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (noteId: String, revision: Int, text: String, headings: [(level: Int, text: String)])?
    /// Parses calls, for tests.
    private(set) var parses = 0

    func headings(noteId: String, revision: Int?, text: String) -> [(level: Int, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        if let revision, let cached, cached.noteId == noteId, cached.revision == revision, cached.text == text {
            return cached.headings
        }
        parses += 1
        let headings = NoteParser.metadata(for: text).headings.map { (level: $0.level, text: $0.text) }
        if let revision { cached = (noteId, revision, text, headings) }
        return headings
    }
}

private extension NoteTitleIndex.Fingerprint {
    init(row: Row) {
        count = row[0]
        modified = row[1]
    }
}
