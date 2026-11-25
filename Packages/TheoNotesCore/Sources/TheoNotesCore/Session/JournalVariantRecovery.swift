// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Darwin
import GRDB

/// Preserves every syntactically plausible plain journal/base pairing without guessing provenance.
public enum JournalVariantRecovery {
    public enum Failure: Error, Equatable { case noPairs, tooMany, changed, unavailable, requiresKey, sealedAmbiguous, partialReplayBlocked }
    fileprivate struct Source: Codable, Equatable, Sendable { let name: String; let hash: Data }
    private struct State: Codable, Sendable { let generation: Int; let sources: [Source]; let ids: [String] }
    private struct Marker: Codable {
        let noteId: String, stateKey: String, stateBytes: Data
        let sources: [Source], ids: [String]
        let protected: Bool
        let sourceRevision: Int?
        let abortedBytes: Data?
    }
    private struct Aborted: Codable { let noteId: String, files: [String] }
    public struct Retirement: Sendable {
        fileprivate let noteId: String, directory: URL, stateKey: String, stateBytes: Data
        fileprivate let sources: [Source], ids: [String], protected: Bool
        fileprivate let sourceRevision: Int?, abortedBytes: Data?
    }
    public struct Result: Sendable {
        public let notes: [Note]
        public let retirement: Retirement
        public var sourceNames: [String] { retirement.sources.map(\.name) }
    }
    private struct Pair { let journal: String, base: String, text: String }

    public static func recover(noteId: String, store: NoteStore, access: LockedNoteAccess?) throws -> Result {
        try recover(noteId: noteId, store: store, access: access, aborted: false)
    }
    public static func recoverAborted(noteId: String, store: NoteStore, access: LockedNoteAccess?) throws -> Result {
        try recover(noteId: noteId, store: store, access: access, aborted: true)
    }
    /// Existing-source recovery uses only explicitly moved-aside names. Canonical journals
    /// belong to the live note and are never considered for variant recovery or removal.
    public static func recoverMovedAside(noteId: String, store: NoteStore, access: LockedNoteAccess?) throws -> Result {
        try recover(noteId: noteId, store: store, access: access, aborted: false, movedAside: true)
    }
    private static func recover(noteId: String, store: NoteStore, access: LockedNoteAccess?, aborted: Bool,
                                movedAside: Bool = false, resuming: (marker: Marker, bytes: Data)? = nil) throws -> Result {
        guard !noteId.isEmpty, !noteId.contains("/"), !noteId.contains("\\"), !noteId.hasPrefix(".") else { throw Failure.unavailable }
        let dir = store.paths.journal
        // An empty marker payload is reserved for source-present moved-aside recovery;
        // valid aborted marker JSON is never empty. Older encoded markers remain unchanged.
        let abortedBytes: Data? = aborted ? try readRegular(abortedURL(noteId: noteId, directory: dir)) : movedAside ? Data() : nil
        let names: [String]
        if let resuming { names = resuming.marker.sources.map(\.name).filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }.sorted() }
        else { names = try (aborted ? abortedSourceFiles(noteId: noteId, store: store) : FileManager.default.contentsOfDirectory(atPath: dir.path)).sorted() }
        func allowed(_ name: String, _ prefix: String) -> Bool {
            guard name.hasPrefix(noteId + prefix) else { return false }
            let suffix = String(name.dropFirst(noteId.count + prefix.count))
            return JournalRecoveryFiles.validSuffix(suffix) && (!movedAside || !suffix.isEmpty)
        }
        let journals = names.filter { allowed($0, ".jsonl") }, bases = names.filter { allowed($0, ".base") }
        var bytes: [String: Data] = [:]
        for name in journals + bases { bytes[name] = try readRegular(dir.appendingPathComponent(name)) }
        var pairs: [Pair] = []
        // A lone base contains a complete saved text. It is only used in the explicitly
        // recorded aborted-source path; it is never replayed into the restored source.
        if (aborted || movedAside || resuming != nil), journals.isEmpty {
            if resuming != nil, bases.count > 4 { throw Failure.tooMany }
            for baseName in bases {
                let data = bytes[baseName]!
                if data.starts(with: Data("BJB1:".utf8)), resuming != nil {
                    guard let access else { throw Failure.requiresKey }
                    try access.verifyRecoveryClassification(directory: dir)
                    let suffix = String(baseName.dropFirst((noteId + ".base").count))
                    do {
                        let journal = try EditJournal(recoveryDirectory: dir, noteId: noteId, suffix: suffix, encryptionKey: access.journalKey(), baseOnly: true)
                        guard let base = try journal.base() else { throw Failure.noPairs }
                        pairs.append(Pair(journal: "", base: baseName, text: base.baseText))
                    } catch is JournalProtectionError { throw Failure.sealedAmbiguous }
                      catch is JournalError { throw Failure.sealedAmbiguous }
                      catch is DecodingError { throw Failure.sealedAmbiguous }
                    continue
                }
                guard !data.starts(with: Data("BJB1:".utf8)) else { continue }
                if let base = try? JSONDecoder().decode(JournalBase.self, from: data), base.v == EditJournal.formatVersion {
                    pairs.append(Pair(journal: "", base: baseName, text: base.baseText))
                    guard pairs.count <= 4 else { throw Failure.tooMany }
                }
            }
            if resuming != nil, pairs.count != bases.count { throw Failure.noPairs }
            if pairs.isEmpty, let baseName = bases.first(where: { bytes[$0]!.starts(with: Data("BJB1:".utf8)) }) {
                    guard let access else { throw Failure.requiresKey }
                    try access.verifyRecoveryClassification(directory: dir)
                    guard bases.count == 1 else { throw Failure.sealedAmbiguous }
                    let suffix = String(baseName.dropFirst((noteId + ".base").count))
                    do {
                        let journal = try EditJournal(recoveryDirectory: dir, noteId: noteId, suffix: suffix, encryptionKey: access.journalKey(), baseOnly: true)
                        guard let base = try journal.base() else { throw Failure.noPairs }
                        pairs.append(Pair(journal: "", base: baseName, text: base.baseText))
                    } catch is JournalProtectionError { throw Failure.sealedAmbiguous }
                      catch is JournalError { throw Failure.sealedAmbiguous }
                      catch is DecodingError { throw Failure.sealedAmbiguous }
            }
        }
        // Sealed ambiguous pairs require authenticated byte-preserving move-aside.
        if pairs.isEmpty, bytes.values.contains(where: { $0.starts(with: Data("BJB1:".utf8)) || $0.starts(with: Data("BJE1:".utf8)) }) {
            guard let access else { throw Failure.requiresKey }
            try access.verifyRecoveryClassification(directory: dir)
            guard (aborted || movedAside), journals.count == 1, bases.count == 1,
                  bytes[journals[0]]!.starts(with: Data("BJE1:".utf8)), bytes[bases[0]]!.starts(with: Data("BJB1:".utf8)) else { throw Failure.sealedAmbiguous }
            let journalSuffix = String(journals[0].dropFirst((noteId + ".jsonl").count))
            let baseSuffix = String(bases[0].dropFirst((noteId + ".base").count))
            do {
                let journal = try EditJournal(recoveryDirectory: dir, noteId: noteId, suffix: journalSuffix,
                                              encryptionKey: access.journalKey(), baseSuffix: baseSuffix)
                guard let base = try journal.base() else { throw Failure.noPairs }
                var text = base.baseText
                let entries = try journal.entries()
                guard !entries.isEmpty else { throw Failure.noPairs }
                for entry in entries { text = try entry.changeSet.apply(to: text) }
                pairs.append(Pair(journal: journals[0], base: bases[0], text: text))
            } catch is JournalProtectionError { throw Failure.sealedAmbiguous }
              catch is JournalError { throw Failure.sealedAmbiguous }
        }
        for journal in journals { for base in bases {
            guard let text = JournalRecoveryFiles.replayPlain(base: bytes[base]!, journal: bytes[journal]!) else { continue }
            pairs.append(Pair(journal: journal, base: base, text: text))
            guard pairs.count <= 4 else { throw Failure.tooMany }
        } }
        guard !pairs.isEmpty else { throw Failure.noPairs }
        let used = Set(pairs.flatMap { [$0.journal, $0.base] }.filter { !$0.isEmpty }).sorted()
        let stateKey = "journal.variants." + Data(SHA256.hash(data: Data(noteId.utf8))).map { String(format: "%02x", $0) }.joined()
        func commit(_ key: SymmetricKey?, _ db: Database) throws -> Result {
            let source = try Note.fetchOne(db, key: noteId)
            guard (aborted || movedAside) ? source != nil : source == nil else { throw Failure.changed }
            if let abortedBytes, !movedAside {
                guard try readRegular(abortedURL(noteId: noteId, directory: dir)) == abortedBytes else { throw Failure.changed }
            }
            if key == nil {
                guard try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: false),
                      try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true),
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition)") == false else { throw Failure.requiresKey }
            }
            for name in used { guard try readRegular(dir.appendingPathComponent(name)) == bytes[name] else { throw Failure.changed } }
            let sources = used.map { Source(name: $0, hash: digest(bytes[$0]!, noteId: noteId, key: key)) }
            let priorData = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [stateKey]).map { Data($0.utf8) }
            let prior = try priorData.map { try JSONDecoder().decode(State.self, from: $0) }
            if let resuming {
                let old = try JSONDecoder().decode(State.self, from: resuming.marker.stateBytes)
                let oldCopiesExist = try old.ids.allSatisfy { try Note.fetchOne(db, key: $0) != nil }
                guard resuming.marker.noteId == noteId,
                      ((!aborted && !movedAside && resuming.marker.sourceRevision == nil) ||
                       (movedAside && resuming.marker.sourceRevision == source?.revision && resuming.marker.abortedBytes == Data()) ||
                       (aborted && resuming.marker.sourceRevision == source?.revision && resuming.marker.abortedBytes == abortedBytes)),
                      resuming.marker.stateKey == stateKey, old.ids == resuming.marker.ids,
                      old.sources == resuming.marker.sources, !used.isEmpty, used.count == bases.count,
                      try readRegular(markerURL(resuming.marker, directory: dir)) == resuming.bytes,
                      sources.allSatisfy({ source in old.sources.contains(source) }),
                      resuming.marker.protected == (key != nil), let prior,
                      (prior.generation == old.generation && priorData == resuming.marker.stateBytes && !oldCopiesExist) ||
                      (old.generation < Int.max && prior.generation == old.generation + 1 && prior.sources == sources)
                else { throw Failure.changed }
            }
            if let prior, prior.sources == sources, prior.ids.count == pairs.count,
               try prior.ids.allSatisfy({ try Note.fetchOne(db, key: $0)?.deletedAt == nil && Note.fetchOne(db, key: $0) != nil }) {
                let notes = try prior.ids.map { try Note.fetchOne(db, key: $0)! }
                return Result(notes: notes, retirement: Retirement(noteId: noteId, directory: dir, stateKey: stateKey, stateBytes: priorData!, sources: sources, ids: prior.ids, protected: key != nil, sourceRevision: (aborted || movedAside) ? source?.revision : nil, abortedBytes: abortedBytes))
            }
            guard (prior?.generation ?? -1) < Int.max else { throw Failure.changed }
            let generation = (prior?.generation ?? -1) + 1
            var notes: [Note] = []
            for (index, pair) in pairs.enumerated() {
                let text = "# Recovered edits, variant \(index + 1) of \(pairs.count)\n\nThe original file pairing is uncertain.\n\n" + pair.text
                let identity = noteId + "\0variant\0\(generation)\0\(pair.journal)\0\(pair.base)"
                let id = BrowserRecoveryID.make(noteId: identity, text: text, baseRevision: generation, key: key)
                guard try Note.fetchOne(db, key: id) == nil else { throw Failure.changed }
                if let key, let access { notes.append(try access.insertRecoveryVariant(id: id, text: text, key: key, in: db)) }
                else { notes.append(try NoteStore.insert(id: id, text: text, now: .now, in: db)) }
            }
            let state = State(generation: generation, sources: sources, ids: notes.map(\.id))
            let encoded = try JSONEncoder().encode(state)
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [stateKey, String(decoding: encoded, as: UTF8.self)])
            return Result(notes: notes, retirement: Retirement(noteId: noteId, directory: dir, stateKey: stateKey, stateBytes: encoded, sources: sources, ids: state.ids, protected: key != nil, sourceRevision: (aborted || movedAside) ? source?.revision : nil, abortedBytes: abortedBytes))
        }
        if let access { return try access.withRecoveryVariantWriter(directory: dir) { try commit($0, $1) } }
        return try store.write { try commit(nil, $0) }
    }

    public static func removeAfterConfirmation(_ token: Retirement, store: NoteStore, access: LockedNoteAccess?) throws {
        try removeAfterConfirmation(token, store: store, access: access, afterRemove: {})
    }
    static func removeAfterConfirmation(_ token: Retirement, store: NoteStore, access: LockedNoteAccess?, afterRemove: () throws -> Void) throws {
        guard token.directory.standardizedFileURL == store.paths.journal.standardizedFileURL else { throw Failure.changed }
        let marker = Marker(noteId: token.noteId, stateKey: token.stateKey, stateBytes: token.stateBytes, sources: token.sources, ids: token.ids, protected: token.protected, sourceRevision: token.sourceRevision, abortedBytes: token.abortedBytes)
        try withProof(marker, store: store, access: access) { key, db in
            try verify(marker, directory: token.directory, key: key, db: db)
            let url = markerURL(marker, directory: token.directory)
            try JSONEncoder().encode(marker).write(to: url, options: .atomic)
            let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close(); try sync(token.directory)
            try removeFiles(marker, directory: token.directory, key: key, db: db, afterRemove: afterRemove)
            try FileManager.default.removeItem(at: url); try sync(token.directory)
            if let aborted = marker.abortedBytes, !aborted.isEmpty, try abortedSourceFiles(noteId: marker.noteId, store: store).isEmpty {
                try clearResolvedAbortedSourceFiles(noteId: marker.noteId, store: store)
            }
        }
    }

    static func isDamagedAbortedMarker(_ data: Data, name: String, directory: URL) -> Bool {
        guard let marker = try? JSONDecoder().decode(Aborted.self, from: data), !marker.noteId.isEmpty,
              abortedURL(noteId: marker.noteId, directory: directory).lastPathComponent == name else { return true }
        return false
    }
    static func isDamagedMarker(_ data: Data, name: String, directory: URL) -> Bool {
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data),
              !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"),
              markerURL(marker, directory: directory).lastPathComponent == name else { return true }
        return false
    }
    /// Validates only a confirmed variant marker's identity, source list and durable DB state.
    /// This does not authenticate or discard the contents of its remaining files.
    static func quarantineBinding(data: Data, name: String, directory: URL, db: Database, allowMoved: Bool = false) throws -> (id: String, movedAside: Bool, sources: [String], allSources: [String], aborted: String?, abortedBytes: Data?) {
        let marker = try JSONDecoder().decode(Marker.self, from: data)
        let state = try JSONDecoder().decode(State.self, from: marker.stateBytes)
        let expectedKey = "journal.variants." + Data(SHA256.hash(data: Data(marker.noteId.utf8))).map { String(format: "%02x", $0) }.joined()
        guard !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"), !marker.noteId.hasPrefix("."),
              markerURL(marker, directory: directory).lastPathComponent == name,
              marker.stateKey == expectedKey, state.ids == marker.ids, state.sources == marker.sources,
              !marker.ids.isEmpty, marker.ids.count <= 4, !marker.sources.isEmpty,
              Set(marker.sources.map(\.name)).count == marker.sources.count,
              try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [marker.stateKey]).map({ Data($0.utf8) }) == marker.stateBytes,
              try marker.ids.contains(where: { try Note.fetchOne(db, key: $0) == nil }) else { throw Failure.changed }
        let source = try Note.fetchOne(db, key: marker.noteId)
        let movedAside = marker.sourceRevision != nil
        guard movedAside ? source != nil : source == nil else { throw Failure.changed }
        for entry in marker.sources {
            guard entry.name.hasPrefix(marker.noteId + ".base"), !entry.name.contains("/"), !entry.name.contains("\\") else {
                // Previously deleted journal entries are allowed, but never selected.
                guard entry.name.hasPrefix(marker.noteId + ".jsonl"), !entry.name.contains("/"), !entry.name.contains("\\"),
                      !FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.name).path) else { throw Failure.changed }
                continue
            }
            let suffix = String(entry.name.dropFirst((marker.noteId + ".base").count))
            guard JournalRecoveryFiles.validSuffix(suffix), !movedAside || !suffix.isEmpty else { throw Failure.changed }
        }
        let remaining = marker.sources.map(\.name).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }.sorted()
        guard allowMoved || !remaining.isEmpty else { throw Failure.changed }
        let abortedName: String?
        if let aborted = marker.abortedBytes, !aborted.isEmpty {
            let path = abortedURL(noteId: marker.noteId, directory: directory)
            if FileManager.default.fileExists(atPath: path.path) { guard try readRegular(path) == aborted else { throw Failure.changed } }
            else if !allowMoved { throw Failure.changed }
            abortedName = path.lastPathComponent
        } else { abortedName = nil }
        return (marker.noteId, movedAside, remaining, marker.sources.map(\.name), abortedName, marker.abortedBytes)
    }
    @discardableResult public static func finishPending(store: NoteStore, access: LockedNoteAccess?, excluding: Set<String> = []) throws -> Set<String> {
        let dir = store.paths.journal
        var firstError: (any Error)?
        var skipped: Set<String> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix(".variant-confirm-") && name.hasSuffix(".json") {
            do {
            let url = dir.appendingPathComponent(name)
            let markerBytes = try readRegular(url)
            var marker = try JSONDecoder().decode(Marker.self, from: markerBytes)
            guard markerURL(marker, directory: dir) == url else { throw Failure.changed }
            if excluding.contains(marker.noteId) { skipped.insert(marker.noteId); continue }
            let missingCopy = try store.db.pool.read { db in try marker.ids.contains { try Note.fetchOne(db, key: $0) == nil } }
            if missingCopy {
                let present = marker.sources.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.name).path) }
                guard !present.isEmpty, present.allSatisfy({ $0.name.hasPrefix(marker.noteId + ".base") }) else { throw Failure.changed }
                guard present.count <= 4 else { throw Failure.tooMany }
                let movedAside = marker.sourceRevision != nil && marker.abortedBytes == Data()
                let aborted = marker.sourceRevision != nil && marker.abortedBytes != nil && marker.abortedBytes != Data()
                let saved = try recover(noteId: marker.noteId, store: store, access: access,
                                        aborted: aborted, movedAside: movedAside, resuming: (marker, markerBytes))
                let token = saved.retirement
                marker = Marker(noteId: token.noteId, stateKey: token.stateKey, stateBytes: token.stateBytes,
                                sources: token.sources, ids: token.ids, protected: token.protected,
                                sourceRevision: token.sourceRevision, abortedBytes: token.abortedBytes)
                guard try readRegular(url) == markerBytes else { throw Failure.changed }
                let bytes = try JSONEncoder().encode(marker)
                try bytes.write(to: url, options: .atomic)
                let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close(); try sync(dir)
            }
            try withProof(marker, store: store, access: access) { key, db in
                if marker.sourceRevision == nil, try Note.fetchOne(db, key: marker.noteId) != nil {
                    try verifyCommitted(marker, db: db)
                    // Source exists again: abandon the confirmed group cleanup without touching
                    // any remaining file. Record partial leftovers so they cannot be replayed as
                    // a complete pair merely because the source exists again.
                    let files = marker.sources.map(\.name).filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
                    if !files.isEmpty {
                        let aborted = abortedURL(noteId: marker.noteId, directory: dir)
                        try JSONEncoder().encode(Aborted(noteId: marker.noteId, files: files)).write(to: aborted, options: .atomic)
                        let handle = try FileHandle(forWritingTo: aborted); try handle.synchronize(); try handle.close(); try sync(dir)
                    }
                    try FileManager.default.removeItem(at: url); try sync(dir)
                    return
                }
                try verify(marker, directory: dir, key: key, db: db, allowMissing: true)
                try removeFiles(marker, directory: dir, key: key, db: db, afterRemove: {})
                try FileManager.default.removeItem(at: url); try sync(dir)
                if let aborted = marker.abortedBytes, !aborted.isEmpty, try abortedSourceFiles(noteId: marker.noteId, store: store).isEmpty {
                    try clearResolvedAbortedSourceFiles(noteId: marker.noteId, store: store)
                }
            }
            } catch { if firstError == nil { firstError = error } }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix(".variant-aborted-") && name.hasSuffix(".json") {
            do {
                let url = dir.appendingPathComponent(name)
                let aborted = try JSONDecoder().decode(Aborted.self, from: readRegular(url))
                guard abortedURL(noteId: aborted.noteId, directory: dir) == url else { throw Failure.changed }
                let id = aborted.noteId
                if excluding.contains(id) { skipped.insert(id); continue }
                if try abortedSourceFiles(noteId: id, store: store).isEmpty { try clearResolvedAbortedSourceFiles(noteId: id, store: store) }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        return skipped
    }
    private static func withProof(_ marker: Marker, store: NoteStore, access: LockedNoteAccess?, body: (SymmetricKey?, Database) throws -> Void) throws {
        if marker.protected {
            guard let access else { throw JournalProtectionError.keyRequired }
            try access.withRecoveryVariantWriter(directory: store.paths.journal) { key, db in
                for id in marker.ids {
                    guard let row = try Note.fetchOne(db, key: id), row.deletedAt == nil else { throw Failure.changed }
                    if row.isLocked { _ = try access.lockedText(row, key: key) }
                }
                try body(key, db)
            }
        } else { try store.write { try body(nil, $0) } }
    }
    private static func verifyCommitted(_ marker: Marker, db: Database) throws {
        let expectedKey = "journal.variants." + Data(SHA256.hash(data: Data(marker.noteId.utf8))).map { String(format: "%02x", $0) }.joined()
        let saved = try JSONDecoder().decode(State.self, from: marker.stateBytes)
        guard !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"),
              marker.ids.count > 0, marker.ids.count <= 4, !marker.sources.isEmpty,
              marker.stateKey == expectedKey, saved.ids == marker.ids, saved.sources == marker.sources,
              Set(marker.sources.map(\.name)).count == marker.sources.count,
              try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [marker.stateKey]).map({ Data($0.utf8) }) == marker.stateBytes else { throw Failure.changed }
        for id in marker.ids { guard let row = try Note.fetchOne(db, key: id), row.deletedAt == nil else { throw Failure.changed } }
    }
    private static func verify(_ marker: Marker, directory: URL, key: SymmetricKey?, db: Database, allowMissing: Bool = false) throws {
        try verifyCommitted(marker, db: db)
        try verifySource(marker, directory: directory, db: db)
        for source in marker.sources {
            guard !source.name.contains("/"), !source.name.contains("\\"), source.name.hasPrefix(marker.noteId + ".") else { throw Failure.changed }
            let url = directory.appendingPathComponent(source.name)
            if allowMissing && !FileManager.default.fileExists(atPath: url.path) { continue }
            guard digest(try readRegular(url), noteId: marker.noteId, key: key) == source.hash else { throw Failure.changed }
        }
    }
    private static func removeFiles(_ marker: Marker, directory: URL, key: SymmetricKey?, db: Database, afterRemove: () throws -> Void) throws {
        // Every journal is removed before any base; a crash therefore leaves recoverable
        // base text rather than an entry stream whose base has already disappeared.
        let ordered = marker.sources.sorted { left, right in
            let leftJournal = left.name.hasPrefix(marker.noteId + ".jsonl")
            let rightJournal = right.name.hasPrefix(marker.noteId + ".jsonl")
            return leftJournal == rightJournal ? left.name < right.name : leftJournal
        }
        for source in ordered {
            try verifySource(marker, directory: directory, db: db)
            let url = directory.appendingPathComponent(source.name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard digest(try readRegular(url), noteId: marker.noteId, key: key) == source.hash else { throw Failure.changed }
            try FileManager.default.removeItem(at: url); try sync(directory)
            try afterRemove()
        }
    }
    private static func verifySource(_ marker: Marker, directory: URL, db: Database) throws {
        let source = try Note.fetchOne(db, key: marker.noteId)
        if let revision = marker.sourceRevision, let expected = marker.abortedBytes {
            guard source?.revision == revision else { throw Failure.changed }
            if expected.isEmpty {
                // Recheck that the proof never authorizes canonical-note files, even if a
                // persisted marker is malformed or was created by a different version.
                guard marker.sources.allSatisfy({ source in
                    let prefixes = [marker.noteId + ".jsonl", marker.noteId + ".base"]
                    return prefixes.contains { prefix in
                        guard source.name.hasPrefix(prefix) else { return false }
                        let suffix = String(source.name.dropFirst(prefix.count))
                        return !suffix.isEmpty && JournalRecoveryFiles.validSuffix(suffix)
                    }
                }) else { throw Failure.changed }
            } else {
                guard try readRegular(abortedURL(noteId: marker.noteId, directory: directory)) == expected else { throw Failure.changed }
            }
        } else {
            guard marker.sourceRevision == nil, marker.abortedBytes == nil, source == nil else { throw Failure.changed }
        }
    }
    private static func markerURL(_ marker: Marker, directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(marker.noteId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(".variant-confirm-\(hash).json")
    }
    /// Called before opening any existing-note journal. Marker existence, including an invalid
    /// or locked marker, blocks only this note until its confirmed cleanup is resolved.
    static func requireReplaySafe(noteId: String, directory: URL) throws {
        let hash = SHA256.hash(data: Data(noteId.utf8)).map { String(format: "%02x", $0) }.joined()
        for prefix in [".variant-confirm-", ".variant-aborted-"] {
            let path = directory.appendingPathComponent(prefix + hash + ".json").path
            var info = stat()
            if lstat(path, &info) == 0 { throw prefix == ".variant-confirm-" ? Failure.requiresKey : Failure.partialReplayBlocked }
            guard errno == ENOENT else { throw Failure.unavailable }
        }
    }
    private static func abortedURL(noteId: String, directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(noteId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(".variant-aborted-\(hash).json")
    }
    public static func abortedSourceFiles(noteId: String, store: NoteStore) throws -> [String] {
        let directory = store.paths.journal, url = abortedURL(noteId: noteId, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let aborted = try JSONDecoder().decode(Aborted.self, from: readRegular(url))
        guard aborted.noteId == noteId, aborted.files.allSatisfy({ $0.hasPrefix(noteId + ".") && !$0.contains("/") && !$0.contains("\\") }) else { throw Failure.changed }
        return aborted.files.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
    public static func abortedNoteIDs(store: NoteStore) throws -> [String] {
        let dir = store.paths.journal
        var ids: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix(".variant-aborted-") && name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            let aborted = try JSONDecoder().decode(Aborted.self, from: readRegular(url))
            guard abortedURL(noteId: aborted.noteId, directory: dir) == url else { throw Failure.changed }
            _ = try abortedSourceFiles(noteId: aborted.noteId, store: store)
            ids.append(aborted.noteId)
        }
        return ids.sorted()
    }
    public static func pendingNoteIDs(store: NoteStore) throws -> [String] {
        let dir = store.paths.journal
        var ids: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix(".variant-confirm-") && name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            let marker = try JSONDecoder().decode(Marker.self, from: readRegular(url))
            guard markerURL(marker, directory: dir) == url else { throw Failure.changed }
            ids.append(marker.noteId)
        }
        return ids.sorted()
    }
    public static func clearResolvedAbortedSourceFiles(noteId: String, store: NoteStore) throws {
        guard try abortedSourceFiles(noteId: noteId, store: store).isEmpty else { throw Failure.changed }
        let url = abortedURL(noteId: noteId, directory: store.paths.journal)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url); try sync(store.paths.journal) }
    }
    /// After the restored source's canonical journal has finished replaying, expose only the
    /// previously committed group's remaining move-aside files for explicit quarantine.
    public static func restoredSourceLeftovers(noteId: String, store: NoteStore) throws -> [String] {
        guard !noteId.isEmpty, !noteId.contains("/"), !noteId.contains("\\"), !noteId.hasPrefix(".") else { throw Failure.changed }
        let directory = store.paths.journal
        let hash = SHA256.hash(data: Data(noteId.utf8)).map { String(format: "%02x", $0) }.joined()
        let stateKey = "journal.variants." + hash
        guard try store.db.pool.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM setting WHERE key=?)", arguments: [stateKey]) == true }) else { return [] }
        let canonicalJournal = directory.appendingPathComponent(noteId + ".jsonl")
        let canonicalBase = directory.appendingPathComponent(noteId + ".base")
        guard !FileManager.default.fileExists(atPath: canonicalBase.path) else { throw Failure.changed }
        if FileManager.default.fileExists(atPath: canonicalJournal.path) {
            guard try readRegular(canonicalJournal).isEmpty else { throw Failure.changed }
        }
        return try store.db.pool.read { db in
            guard try Note.fetchOne(db, key: noteId) != nil,
                  let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [stateKey]) else { return [] }
            let state = try JSONDecoder().decode(State.self, from: Data(json.utf8))
            guard !state.ids.isEmpty, state.ids.count <= 4 else { throw Failure.changed }
            for id in state.ids { guard let note = try Note.fetchOne(db, key: id), note.deletedAt == nil else { throw Failure.changed } }
            var remaining: [String] = []
            for source in state.sources {
                guard !source.name.contains("/"), !source.name.contains("\\"), source.name.hasPrefix(noteId + ".") else { throw Failure.changed }
                guard source.name.contains(".unreplayed") else { continue }
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.name).path) { remaining.append(source.name) }
            }
            return remaining.sorted()
        }
    }
    private static func sync(_ dir: URL) throws { try JournalRecoveryFiles.syncDirectory(dir, failure: Failure.unavailable) }
    private static func readRegular(_ url: URL) throws -> Data { try JournalRecoveryFiles.readRegular(url, failure: Failure.unavailable) }
    private static func digest(_ bytes: Data, noteId: String, key: SymmetricKey?) -> Data {
        JournalRecoveryFiles.digest(bytes, noteId: noteId, info: "journal-variants-v1", key: key)
    }

}
