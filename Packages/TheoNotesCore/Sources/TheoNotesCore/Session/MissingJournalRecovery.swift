// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Darwin
import GRDB

public enum MissingJournalRecovery {
    fileprivate struct FileIdentity: Codable, Hashable, Sendable {
        let device: UInt64, inode: UInt64, size: Int64, seconds: Int64, nanoseconds: Int64
        init(_ url: URL) throws {
            let info = try JournalRecoveryFiles.identity(url, failure: CocoaError(.fileReadNoSuchFile))
            device = info.device; inode = info.inode; size = info.size
            seconds = info.seconds; nanoseconds = info.nanos
        }
    }
    fileprivate struct DiscardMarker: Codable, Sendable {
        let noteId: String, suffix: String, stateKey: String, recoveryID: String?
        let generation: Int?
        let journal: FileIdentity, base: FileIdentity
    }
    public struct DiscardToken: Sendable {
        fileprivate let database: AppDatabase
        fileprivate let directory: URL
        fileprivate let marker: DiscardMarker
    }
    public struct Retirement: Sendable {
        fileprivate let store: NoteStore
        fileprivate let journal: URL, base: URL
        fileprivate let journalHash: Data, baseHash: Data
        fileprivate let noteId: String, suffix: String, recoveryId: String
        fileprivate let isProtected: Bool
    }
    private struct Marker: Codable {
        let noteId: String, suffix: String, recoveryId: String
        let journalHash: Data, baseHash: Data
        let isProtected: Bool?
    }
    static func isDamagedMarker(_ data: Data, name: String, directory: URL) -> Bool {
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data),
              !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"),
              JournalRecoveryFiles.validSuffix(marker.suffix),
              markerPath(directory: directory, noteId: marker.noteId, suffix: marker.suffix).lastPathComponent == name else { return true }
        return false
    }
    static func isDamagedDiscardMarker(_ data: Data, name: String, directory: URL) -> Bool {
        guard let marker = try? JSONDecoder().decode(DiscardMarker.self, from: data),
              !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"),
              JournalRecoveryFiles.validSuffix(marker.suffix),
              discardMarkerPath(directory: directory, noteId: marker.noteId, suffix: marker.suffix).lastPathComponent == name else { return true }
        return false
    }
    public struct RecoveredJournal: Sendable {
        public let note: Note
        public let created: Bool
        public let retirement: Retirement
    }
    public enum RetirementError: Error, Equatable { case changed }
    public struct Candidate: Sendable {
        public let noteId: String
        public let suffix: String
    }

    /// Capture only filesystem identity in memory when presenting the explicit discard prompt.
    public static func prepareDiscard(noteId: String, suffix: String = "", store: NoteStore, forVaultReset: Bool = false) throws -> DiscardToken {
        let directory = store.paths.journal
        guard forVaultReset, try store.note(id: noteId) == nil,
              try candidates(directory: directory).contains(where: { $0.noteId == noteId && $0.suffix == suffix }) else { throw RetirementError.changed }
        let journalURL = directory.appendingPathComponent("\(noteId).jsonl\(suffix)")
        let baseURL = directory.appendingPathComponent("\(noteId).base\(suffix)")
        guard try isSealed(journalURL, prefix: "BJE1:"), try isSealed(baseURL, prefix: "BJB1:") else { throw RetirementError.changed }
        let stateKey = generationKey(noteId: noteId, suffix: suffix)
        let state = try store.db.pool.read { db -> JournalRecoveryGeneration.State? in
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [stateKey]) else {
                return nil
            }
            let state = try JSONDecoder().decode(JournalRecoveryGeneration.State.self, from: Data(value.utf8))
            return state
        }
        let marker = DiscardMarker(noteId: noteId, suffix: suffix, stateKey: stateKey, recoveryID: state?.recoveryID,
            generation: state?.generation, journal: try FileIdentity(directory.appendingPathComponent("\(noteId).jsonl\(suffix)")),
            base: try FileIdentity(directory.appendingPathComponent("\(noteId).base\(suffix)")))
        return DiscardToken(database: store.db, directory: directory, marker: marker)
    }

    /// Forgotten-password reset proposal: every sealed missing-note pair plus each dirty live
    /// session whose note is gone and has no file. Any other non-empty journal refuses the plan.
    public struct ResetDiscardPlan: Sendable {
        public let items: [(noteID: String, suffix: String, token: DiscardToken)]
        public let ramOnlyNoteIDs: [String]
        public let sessionFence: NoteSessionFence
        public var noteIDs: [String] { Set(items.map(\.noteID) + ramOnlyNoteIDs).sorted() }
    }

    @MainActor public static func prepareResetDiscard(store: NoteStore) throws -> ResetDiscardPlan {
        let directory = store.paths.journal
        var items: [(noteID: String, suffix: String, token: DiscardToken)] = []
        for candidate in try candidates(directory: directory) {
            guard try store.note(id: candidate.noteId) == nil else { throw BackupError.pendingFiles }
            items.append((candidate.noteId, candidate.suffix,
                          try prepareDiscard(noteId: candidate.noteId, suffix: candidate.suffix, store: store, forVaultReset: true)))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        func nonEmpty(_ name: String) throws -> Bool {
            (try directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
        }
        let fileIDs = Set(items.map(\.noteID))
        var ramOnly: [String] = []
        for id in NoteSessionRegistry.dirtyProtectedLiveSessionIDs(directory: directory).sorted() where !fileIDs.contains(id) {
            guard try store.note(id: id) == nil else { continue }
            // An incomplete or otherwise unplanned file is never implicitly discarded.
            for name in names where name.hasPrefix(id + ".jsonl") || name.hasPrefix(id + ".base") {
                if try nonEmpty(name) { throw BackupError.pendingFiles }
            }
            ramOnly.append(id)
        }
        guard !items.isEmpty || !ramOnly.isEmpty else { throw BackupError.pendingFiles }
        let expected = Set(items.map { "\($0.noteID).jsonl\($0.suffix)" })
        for name in names where name.contains(".jsonl") && !expected.contains(name) {
            if try nonEmpty(name) { throw BackupError.pendingFiles }
        }
        let affected = Set(items.map(\.noteID) + ramOnly)
        return ResetDiscardPlan(items: items, ramOnlyNoteIDs: ramOnly,
                                sessionFence: NoteSession.captureSessionFence(journalDirectory: directory, noteIDs: affected))
    }

    public static func resetWarning(noteIDs: [String]) -> String {
        let ids = Set(noteIDs).sorted()
        return "\(ids.count) affected notes (ids: \(ids.joined(separator: ", "))). Resetting permanently discards their unsaved edits, including any protected recovery files. If text is still visible in an open editor, cancel and select and copy it before resetting. You may also recover access with the password or another device."
    }

    /// Vault-reset step under one writer: every token and its files still match, each source is
    /// absent, then the live holders captured in `fence` are invalidated. Nothing is unlinked here.
    @MainActor public static func validateDiscardsAndInvalidate(_ tokens: [DiscardToken], store: NoteStore, matching fence: NoteSessionFence) throws {
        try store.db.pool.write { db in
            guard NoteSession.captureSessionFence(journalDirectory: store.paths.journal, noteIDs: fence.noteIDs) == fence else { throw NoteSessionFenceError.stale }
            for token in tokens {
                guard token.database === store.db, token.directory.standardizedFileURL == store.paths.journal.standardizedFileURL else { throw RetirementError.changed }
                try validateDiscard(token.marker, in: db)
                let journal = token.directory.appendingPathComponent("\(token.marker.noteId).jsonl\(token.marker.suffix)")
                let base = token.directory.appendingPathComponent("\(token.marker.noteId).base\(token.marker.suffix)")
                guard try FileIdentity(journal) == token.marker.journal, try FileIdentity(base) == token.marker.base else { throw RetirementError.changed }
            }
            for id in fence.noteIDs { guard try Note.fetchOne(db, key: id) == nil else { throw RetirementError.changed } }
            try NoteSession.invalidateSessions(journalDirectory: store.paths.journal, noteIDs: fence.noteIDs, matching: fence)
        }
    }

    public static func discardLeftoverAfterConfirmation(_ token: DiscardToken, store: NoteStore) throws {
        try discardLeftoverAfterConfirmation(token, store: store, afterJournalRemoved: {})
    }
    static func discardLeftoverAfterConfirmation(_ token: DiscardToken, store: NoteStore, afterJournalRemoved: () throws -> Void) throws {
        guard token.database === store.db, token.directory.standardizedFileURL == store.paths.journal.standardizedFileURL else { throw RetirementError.changed }
        try store.db.pool.write { db in
            let marker = token.marker
            try validateDiscard(marker, in: db)
            let journal = token.directory.appendingPathComponent("\(marker.noteId).jsonl\(marker.suffix)")
            let base = token.directory.appendingPathComponent("\(marker.noteId).base\(marker.suffix)")
            guard try FileIdentity(journal) == marker.journal, try FileIdentity(base) == marker.base,
                  try isSealed(journal, prefix: "BJE1:"), try isSealed(base, prefix: "BJB1:") else { throw RetirementError.changed }
            let url = discardMarkerPath(directory: token.directory, noteId: marker.noteId, suffix: marker.suffix)
            try saveDiscardMarker(marker, to: url)
            try FileManager.default.removeItem(at: journal); try syncDirectory(token.directory)
            try afterJournalRemoved()
            guard try FileIdentity(base) == marker.base else { throw RetirementError.changed }
            try FileManager.default.removeItem(at: base); try syncDirectory(token.directory)
            try FileManager.default.removeItem(at: url); try syncDirectory(token.directory)
        }
    }

    /// Only uniquely paired files are replayed. Independently numbered old move-aside files
    /// cannot be matched safely if multiple pairs exist.
    public static func candidates(directory: URL) throws -> [Candidate] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var journals: [String: [String]] = [:], bases: [String: [String]] = [:]
        for name in names {
            for (marker, isJournal) in [(".jsonl", true), (".base", false)] {
                guard let range = name.range(of: marker) else { continue }
                let id = String(name[..<range.lowerBound]), suffix = String(name[range.upperBound...])
                guard !id.isEmpty, JournalRecoveryFiles.validSuffix(suffix) else { continue }
                if isJournal {
                    let size = (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 0 { journals[id, default: []].append(suffix) }
                }
                else { bases[id, default: []].append(suffix) }
            }
        }
        var result: [Candidate] = []
        for (id, suffixes) in journals {
            guard let base = bases[id] else { continue }
            if suffixes.count == 1, base.count == 1, base[0] == suffixes[0] {
                result.append(Candidate(noteId: id, suffix: suffixes[0]))
            }
        }
        return result
    }

    @discardableResult public static func recover(noteId: String, directory: URL, suffix: String = "", store: NoteStore,
                                                    access: LockedNoteAccess?, avoidingRecoveryID: String? = nil) throws -> RecoveredJournal {
        guard try store.note(id: noteId) == nil,
              try candidates(directory: directory).contains(where: { $0.noteId == noteId && $0.suffix == suffix }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if access == nil, try !store.canRecoverMissingJournalPlain() { throw JournalProtectionError.keyRequired }
        let journalURL = directory.appendingPathComponent("\(noteId).jsonl\(suffix)")
        let baseURL = directory.appendingPathComponent("\(noteId).base\(suffix)")
        let keyHash = SHA256.hash(data: Data((noteId + "\0" + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
        let vaultKey = try access?.journalKey()
        // S6: an unchanged pair whose committed copy still matches is not read, replayed or hashed again.
        let cacheKey = DigestCacheKey(path: journalURL.standardizedFileURL.path, journal: try FileIdentity(journalURL),
                                      base: try FileIdentity(baseURL), keyed: vaultKey != nil)
        if let hit = digestLock.withLock({ digestCache[cacheKey] }),
           let note = try committedCopy("journal.recovery.generation." + keyHash, hit, avoiding: avoidingRecoveryID, store: store, access: access) {
            return RecoveredJournal(note: note, created: false, retirement: Retirement(store: store, journal: journalURL, base: baseURL,
                journalHash: hit.removalJournal, baseHash: hit.removalBase, noteId: noteId, suffix: suffix, recoveryId: note.id, isProtected: vaultKey != nil))
        }
        let originalJournal = try Data(contentsOf: journalURL), originalBase = try Data(contentsOf: baseURL)
        let journal: EditJournal
        do { journal = try EditJournal(recoveryDirectory: directory, noteId: noteId, suffix: suffix, encryptionKey: nil) }
        catch JournalProtectionError.keyRequired {
            guard let access else { throw JournalProtectionError.keyRequired }
            journal = try EditJournal(recoveryDirectory: directory, noteId: noteId, suffix: suffix, encryptionKey: access.journalKey())
        }
        guard let base = try journal.base() else { throw JournalProtectionError.missingBase }
        let entries = try journal.entries()
        guard !entries.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var text = base.baseText
        for entry in entries { text = try entry.changeSet.apply(to: text) }
        let journalHash = digest(originalJournal, noteId: noteId, purpose: "hash", key: vaultKey).map { String(format: "%02x", $0) }.joined()
        let baseHash = digest(originalBase, noteId: noteId, purpose: "hash", key: vaultKey).map { String(format: "%02x", $0) }.joined()
        let context = JournalRecoveryContext(key: "journal.recovery.generation." + keyHash,
            journalHash: journalHash, baseHash: baseHash, avoidingID: avoidingRecoveryID)
        let result: BrowserRecoveryResult
        if let access { result = try access.preserveOrphanJournalRecovery(noteId: noteId, text: text, baseRevision: base.storeRevision, now: .now, journalContext: context) }
        else { result = try store.preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: base.storeRevision, now: .now, journalContext: context) }
        guard try Data(contentsOf: journalURL) == originalJournal, try Data(contentsOf: baseURL) == originalBase else {
            throw CocoaError(.fileWriteUnknown)
        }
        // A writer may still have an open descriptor, including one from an older app build.
        // No cross-process journal fence exists, so moving or removing either file could hide
        // a later acknowledged append. Retain both and leave pending-edit gates in force.
        let removalJournal = digest(originalJournal, noteId: noteId, purpose: "removal", key: vaultKey)
        let removalBase = digest(originalBase, noteId: noteId, purpose: "removal", key: vaultKey)
        digestLock.withLock { digestCache[cacheKey] = CachedDigests(journalHash: journalHash, baseHash: baseHash, removalJournal: removalJournal, removalBase: removalBase) }
        return RecoveredJournal(note: result.note, created: result.created,
            retirement: Retirement(store: store, journal: journalURL, base: baseURL, journalHash: removalJournal, baseHash: removalBase,
                noteId: noteId, suffix: suffix, recoveryId: result.note.id, isProtected: vaultKey != nil))
    }

    private struct DigestCacheKey: Hashable { let path: String; let journal: FileIdentity, base: FileIdentity; let keyed: Bool }
    private struct CachedDigests { let journalHash: String, baseHash: String; let removalJournal: Data, removalBase: Data }
    // shortcut: unbounded, one small entry per recovered pair per process; bound it if libraries ever hold many.
    nonisolated(unsafe) private static var digestCache: [DigestCacheKey: CachedDigests] = [:]
    private static let digestLock = NSLock()

    /// The copy a cache hit may reuse: the recorded state still names these exact hashes and a
    /// live copy. A keyed hash only matches under the same vault key; anything else is a miss.
    private static func committedCopy(_ key: String, _ hit: CachedDigests, avoiding: String?, store: NoteStore, access: LockedNoteAccess?) throws -> Note? {
        guard let value = try store.db.pool.read({ try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key=?", arguments: [key]) }),
              let state = try? JSONDecoder().decode(JournalRecoveryGeneration.State.self, from: Data(value.utf8)),
              state.journalHash == hit.journalHash, state.baseHash == hit.baseHash, state.recoveryID != avoiding,
              let note = try access?.note(id: state.recoveryID) ?? store.note(id: state.recoveryID), note.deletedAt == nil else { return nil }
        return note
    }

    /// Only after an explicit user confirmation. A concurrent writer between this check and
    /// deletion remains an accepted limitation until all app instances share a writer fence.
    public static func removeLeftover(_ retirement: Retirement, access: LockedNoteAccess? = nil) throws {
        try removeLeftover(retirement, access: access, afterJournalRemoved: {})
    }

    static func removeLeftover(_ retirement: Retirement, access: LockedNoteAccess? = nil, beforeJournalRemoved: () throws -> Void = {}, afterJournalRemoved: () throws -> Void) throws {
        if retirement.isProtected || access != nil {
            guard let access else { throw JournalProtectionError.keyRequired }
            return try access.withCurrentRecoveryLease(noteId: retirement.recoveryId, journalDirectory: retirement.journal.deletingLastPathComponent()) { key, db in
                try verifyRows(db, sourceId: retirement.noteId, recoveryId: retirement.recoveryId, allowLocked: true)
                try removeLeftover(retirement, key: retirement.isProtected ? key : nil, beforeJournalRemoved: beforeJournalRemoved, afterJournalRemoved: afterJournalRemoved)
            }
        }
        try retirement.store.db.pool.write { db in
            try verifyRows(db, sourceId: retirement.noteId, recoveryId: retirement.recoveryId)
            try removeLeftover(retirement, key: nil, beforeJournalRemoved: beforeJournalRemoved, afterJournalRemoved: afterJournalRemoved)
        }
    }

    private static func verifyRows(_ db: Database, sourceId: String, recoveryId: String, allowLocked: Bool = false) throws {
        guard try Note.fetchOne(db, key: sourceId) == nil,
              let copy = try Note.fetchOne(db, key: recoveryId), copy.deletedAt == nil else { throw RetirementError.changed }
        if copy.isLocked && !allowLocked { throw JournalProtectionError.keyRequired }
    }

    private static func removeLeftover(_ retirement: Retirement, key: SymmetricKey?, beforeJournalRemoved: () throws -> Void, afterJournalRemoved: () throws -> Void) throws {
        let journalBytes = try Data(contentsOf: retirement.journal), baseBytes = try Data(contentsOf: retirement.base)
        guard digest(journalBytes, noteId: retirement.noteId, purpose: "removal", key: key) == retirement.journalHash,
              digest(baseBytes, noteId: retirement.noteId, purpose: "removal", key: key) == retirement.baseHash else { throw RetirementError.changed }
        let directory = retirement.journal.deletingLastPathComponent()
        let marker = Marker(noteId: retirement.noteId, suffix: retirement.suffix, recoveryId: retirement.recoveryId,
                            journalHash: digest(journalBytes, noteId: retirement.noteId, purpose: "marker", key: key),
                            baseHash: digest(baseBytes, noteId: retirement.noteId, purpose: "marker", key: key), isProtected: retirement.isProtected)
        let markerURL = markerPath(directory: directory, noteId: marker.noteId, suffix: marker.suffix)
        try saveMarker(marker, to: markerURL)
        try beforeJournalRemoved()
        try FileManager.default.removeItem(at: retirement.journal)
        try syncDirectory(directory)
        try afterJournalRemoved()
        guard digest(try Data(contentsOf: retirement.base), noteId: retirement.noteId, purpose: "removal", key: key) == retirement.baseHash else { throw RetirementError.changed }
        try FileManager.default.removeItem(at: retirement.base)
        try syncDirectory(directory)
        try FileManager.default.removeItem(at: markerURL)
        try syncDirectory(directory)
        let path = retirement.journal.standardizedFileURL.path  // N4: a retired pair leaves no cache entry
        digestLock.withLock { digestCache = digestCache.filter { $0.key.path != path } }
    }

    /// Finish confirmed removals after a crash. A changed lone base is saved before cleanup.
    @discardableResult public static func finishRetirements(directory: URL, store: NoteStore, access: LockedNoteAccess?, excluding: Set<String> = []) throws -> Set<String> {
        var firstError: (any Error)?
        var skipped: Set<String> = []
        do { skipped.formUnion(try finishDiscards(directory: directory, store: store, excluding: excluding)) } catch { firstError = error }
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(".retirement-") && name.hasSuffix(".json") {
            do {
            let markerURL = directory.appendingPathComponent(name)
            var marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
            guard !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"),
                  JournalRecoveryFiles.validSuffix(marker.suffix),
                  markerURL == markerPath(directory: directory, noteId: marker.noteId, suffix: marker.suffix) else { throw CocoaError(.fileReadCorruptFile) }
            if excluding.contains(marker.noteId) { skipped.insert(marker.noteId); continue }
            var key = try protectionKey(marker.isProtected == true, access: access)
            let journalURL = directory.appendingPathComponent("\(marker.noteId).jsonl\(marker.suffix)")
            let baseURL = directory.appendingPathComponent("\(marker.noteId).base\(marker.suffix)")
            // S5: an empty journal holds no text (a lone-base marker records none); treat it as absent.
            let journalExists = fm.fileExists(atPath: journalURL.path)
            let journalSize = journalExists ? try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 : 0
            let hasJournal = journalSize > 0
            let hasBase = fm.fileExists(atPath: baseURL.path)
            if try store.note(id: marker.recoveryId) == nil {
                if hasJournal {
                    // Keep the complete pair pending for a fresh, generation-bound recovery.
                    try fm.removeItem(at: markerURL); try syncDirectory(directory)
                    continue
                }
                guard hasBase else { throw RetirementError.changed }
                let original = try Data(contentsOf: baseURL)
                let journal: EditJournal
                do { journal = try EditJournal(recoveryDirectory: directory, noteId: marker.noteId, suffix: marker.suffix, encryptionKey: nil, baseOnly: true) }
                catch JournalProtectionError.keyRequired {
                    guard let access else { throw JournalProtectionError.keyRequired }
                    journal = try EditJournal(recoveryDirectory: directory, noteId: marker.noteId, suffix: marker.suffix, encryptionKey: access.journalKey(), baseOnly: true)
                }
                guard let base = try journal.base() else { throw JournalProtectionError.missingBase }
                let replacementKey = try access?.journalKey()
                let context = JournalRecoveryContext(key: generationKey(noteId: marker.noteId, suffix: marker.suffix),
                    journalHash: "lone-base:" + marker.journalHash.map { String(format: "%02x", $0) }.joined(),
                    baseHash: digest(original, noteId: marker.noteId, purpose: "hash", key: replacementKey).map { String(format: "%02x", $0) }.joined(),
                    avoidingID: marker.recoveryId)
                let replacement: BrowserRecoveryResult
                if let access { replacement = try access.preserveOrphanJournalRecovery(noteId: marker.noteId, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context) }
                else { replacement = try store.preserveBrowserRecovery(noteId: marker.noteId, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context) }
                guard try Data(contentsOf: baseURL) == original else { throw RetirementError.changed }
                marker = Marker(noteId: marker.noteId, suffix: marker.suffix, recoveryId: replacement.note.id,
                                journalHash: marker.journalHash, baseHash: digest(original, noteId: marker.noteId, purpose: "marker", key: replacementKey), isProtected: replacementKey != nil)
                try saveMarker(marker, to: markerURL)
                key = replacementKey
            }
            if hasJournal {
                guard hasBase else { throw RetirementError.changed }
                let currentJournal = try Data(contentsOf: journalURL), currentBase = try Data(contentsOf: baseURL)
                if digest(currentJournal, noteId: marker.noteId, purpose: "marker", key: key) != marker.journalHash || digest(currentBase, noteId: marker.noteId, purpose: "marker", key: key) != marker.baseHash {
                    try fm.removeItem(at: markerURL); try syncDirectory(directory)
                    continue
                }
                try removeRetirementFile(journalURL, marker: marker, expected: marker.journalHash, store: store, access: access)
            }
            if hasBase {
                let original = try Data(contentsOf: baseURL)
                if digest(original, noteId: marker.noteId, purpose: "marker", key: key) != marker.baseHash {
                    if access == nil, try !store.canRecoverMissingJournalPlain() { throw JournalProtectionError.keyRequired }
                    let journal: EditJournal
                    do { journal = try EditJournal(recoveryDirectory: directory, noteId: marker.noteId, suffix: marker.suffix, encryptionKey: nil, baseOnly: true) }
                    catch JournalProtectionError.keyRequired {
                        guard let access else { throw JournalProtectionError.keyRequired }
                        journal = try EditJournal(recoveryDirectory: directory, noteId: marker.noteId, suffix: marker.suffix, encryptionKey: access.journalKey(), baseOnly: true)
                    }
                    guard let base = try journal.base() else { throw JournalProtectionError.missingBase }
                    let replacementKey = try access?.journalKey()
                    let context = JournalRecoveryContext(key: generationKey(noteId: marker.noteId, suffix: marker.suffix),
                        journalHash: "changed-base:" + marker.journalHash.map { String(format: "%02x", $0) }.joined(),
                        baseHash: digest(original, noteId: marker.noteId, purpose: "hash", key: replacementKey).map { String(format: "%02x", $0) }.joined(),
                        avoidingID: marker.recoveryId)
                    let copy: BrowserRecoveryResult
                    if let access { copy = try access.preserveOrphanJournalRecovery(noteId: marker.noteId, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context) }
                    else { copy = try store.preserveBrowserRecovery(noteId: marker.noteId, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context) }
                    guard try Data(contentsOf: baseURL) == original else { throw RetirementError.changed }
                    let updated = Marker(noteId: marker.noteId, suffix: marker.suffix, recoveryId: copy.note.id,
                                         journalHash: marker.journalHash, baseHash: digest(original, noteId: marker.noteId, purpose: "marker", key: replacementKey), isProtected: replacementKey != nil)
                    try saveMarker(updated, to: markerURL)
                }
                let currentMarker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
                try removeRetirementFile(baseURL, marker: currentMarker, expected: currentMarker.baseHash, store: store, access: access)
            }
            // An empty moved-aside journal would keep backup blocked; an empty canonical one is harmless.
            if journalExists && !hasJournal && !marker.suffix.isEmpty { try fm.removeItem(at: journalURL) }
            try fm.removeItem(at: markerURL)
            try syncDirectory(directory)
            } catch { if firstError == nil { firstError = error } }
        }
        // A lone base (every journal sibling empty or absent) of a deleted note: an interrupted
        // cleanup, a crash before the first append, or a row deleted by sync. Ruling 3: save it
        // as a note first, then retire it. Ids with a live session wait for the next pass.
        let remaining = try fm.contentsOfDirectory(atPath: directory.path)
        func isEmpty(_ name: String) -> Bool {
            (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0
        }
        for name in remaining where !name.hasPrefix(".") && name.contains(".base") {
            do {
            guard let range = name.range(of: ".base"), !name[..<range.lowerBound].isEmpty else { continue }
            let id = String(name[..<range.lowerBound]), suffix = String(name[range.upperBound...])
            guard JournalRecoveryFiles.validSuffix(suffix),
                  remaining.filter({ $0.hasPrefix(id + ".base") }).count == 1,
                  remaining.filter({ $0.hasPrefix(id + ".jsonl") }).allSatisfy(isEmpty),
                  try store.note(id: id) == nil else { continue }
            if excluding.contains(id) { skipped.insert(id); continue }
            try recoverLoneBase(noteId: id, suffix: suffix, directory: directory, store: store, access: access)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        return skipped
    }

    /// Ruling 3 for one lone base: saved as a note (generation-bound), then the base and its
    /// empty moved-aside journals are retired. An empty canonical journal is harmless and stays.
    static func recoverLoneBase(noteId id: String, suffix: String, directory: URL, store: NoteStore, access: LockedNoteAccess?) throws {
        let fm = FileManager.default
        if access == nil, try !store.canRecoverMissingJournalPlain() { throw JournalProtectionError.keyRequired }
        let baseURL = directory.appendingPathComponent("\(id).base\(suffix)"), original = try Data(contentsOf: baseURL)
        let journal: EditJournal
        do { journal = try EditJournal(recoveryDirectory: directory, noteId: id, suffix: suffix, encryptionKey: nil, baseOnly: true) }
        catch JournalProtectionError.keyRequired {
            guard let access else { throw JournalProtectionError.keyRequired }
            journal = try EditJournal(recoveryDirectory: directory, noteId: id, suffix: suffix, encryptionKey: access.journalKey(), baseOnly: true)
        }
        guard let base = try journal.base() else { throw JournalProtectionError.missingBase }
        let key = try access?.journalKey()
        let context = JournalRecoveryContext(key: generationKey(noteId: id, suffix: suffix), journalHash: "lone-base",
            baseHash: digest(original, noteId: id, purpose: "hash", key: key).map { String(format: "%02x", $0) }.joined(), avoidingID: nil)
        let copy: BrowserRecoveryResult
        if let access { copy = try access.preserveOrphanJournalRecovery(noteId: id, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context) }
        else { copy = try store.preserveBrowserRecovery(noteId: id, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context) }
        guard try Data(contentsOf: baseURL) == original else { throw RetirementError.changed }
        let marker = Marker(noteId: id, suffix: suffix, recoveryId: copy.note.id,
                            journalHash: Data(), baseHash: digest(original, noteId: id, purpose: "marker", key: key), isProtected: key != nil)
        let markerURL = markerPath(directory: directory, noteId: id, suffix: suffix)
        try saveMarker(marker, to: markerURL)
        try removeRetirementFile(baseURL, marker: marker, expected: marker.baseHash, store: store, access: access)
        // Empty moved-aside journals hold no text but would keep backup blocked (`.unreplayed`).
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(id + ".jsonl.unreplayed") {
            let url = directory.appendingPathComponent(name)
            if (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 { try fm.removeItem(at: url) }
        }
        try fm.removeItem(at: markerURL); try syncDirectory(directory)
    }

    private static func markerPath(directory: URL, noteId: String, suffix: String) -> URL {
        let digest = SHA256.hash(data: Data((noteId + "\0" + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(".retirement-\(digest).json")
    }
    private static func generationKey(noteId: String, suffix: String) -> String {
        let digest = SHA256.hash(data: Data((noteId + "\0" + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
        return "journal.recovery.generation." + digest
    }
    private static func isSealed(_ url: URL, prefix: String) throws -> Bool {
        let size = try FileIdentity(url).size
        guard size > 0, size <= 64 * 1_024 * 1_024 else { return false }
        let data = try Data(contentsOf: url)
        let lines: [Data]
        if prefix == "BJE1:" {
            guard data.last == UInt8(ascii: "\n") else { return false }
            let segments = data.dropLast().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            guard !segments.isEmpty else { return false }
            lines = segments.map { Data($0) }
        } else { lines = [data] }
        let prefixBytes = Data(prefix.utf8)
        return lines.allSatisfy { line in
            guard line.starts(with: prefixBytes) else { return false }
            let encoded = Data(line.dropFirst(prefixBytes.count))
            guard let decoded = Data(base64Encoded: encoded), decoded.count >= 28 else { return false }
            return Data(decoded.base64EncodedString().utf8) == encoded
        }
    }
    private static func validateDiscard(_ marker: DiscardMarker, in db: Database) throws {
        guard !marker.noteId.isEmpty, !marker.noteId.contains("/"), !marker.noteId.contains("\\"),
              JournalRecoveryFiles.validSuffix(marker.suffix),
              marker.stateKey == generationKey(noteId: marker.noteId, suffix: marker.suffix),
              try Note.fetchOne(db, key: marker.noteId) == nil else { throw RetirementError.changed }
        let value = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [marker.stateKey])
        if let recoveryID = marker.recoveryID, let generation = marker.generation, let value {
            let state = try JSONDecoder().decode(JournalRecoveryGeneration.State.self, from: Data(value.utf8))
            guard state.recoveryID == recoveryID, state.generation == generation else { throw RetirementError.changed }
        } else {
            guard marker.recoveryID == nil, marker.generation == nil, value == nil else { throw RetirementError.changed }
        }
    }
    private static func discardMarkerPath(directory: URL, noteId: String, suffix: String) -> URL {
        directory.appendingPathComponent(".discard-" + String(generationKey(noteId: noteId, suffix: suffix).dropFirst("journal.recovery.generation.".count)) + ".json")
    }
    private static func saveDiscardMarker(_ marker: DiscardMarker, to url: URL) throws {
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close(); try syncDirectory(url.deletingLastPathComponent())
    }
    private static func finishDiscards(directory: URL, store: NoteStore, excluding: Set<String>) throws -> Set<String> {
        guard directory.standardizedFileURL == store.paths.journal.standardizedFileURL else { throw RetirementError.changed }
        let fm = FileManager.default
        var firstError: (any Error)?
        var skipped: Set<String> = []
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(".discard-") && name.hasSuffix(".json") {
            do {
            let url = directory.appendingPathComponent(name)
            let marker = try JSONDecoder().decode(DiscardMarker.self, from: Data(contentsOf: url))
            guard url == discardMarkerPath(directory: directory, noteId: marker.noteId, suffix: marker.suffix) else { throw RetirementError.changed }
            if excluding.contains(marker.noteId) { skipped.insert(marker.noteId); continue }
            try store.db.pool.write { db in
                try validateDiscard(marker, in: db)
                let journal = directory.appendingPathComponent("\(marker.noteId).jsonl\(marker.suffix)")
                let base = directory.appendingPathComponent("\(marker.noteId).base\(marker.suffix)")
                if fm.fileExists(atPath: journal.path) {
                    guard try FileIdentity(journal) == marker.journal, try FileIdentity(base) == marker.base,
                          try isSealed(journal, prefix: "BJE1:"), try isSealed(base, prefix: "BJB1:") else { throw RetirementError.changed }
                    try fm.removeItem(at: journal); try syncDirectory(directory)
                }
                if fm.fileExists(atPath: base.path) {
                    guard try FileIdentity(base) == marker.base, try isSealed(base, prefix: "BJB1:") else { throw RetirementError.changed }
                    try fm.removeItem(at: base); try syncDirectory(directory)
                }
                try fm.removeItem(at: url); try syncDirectory(directory)
            }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        return skipped
    }
    private static func protectionKey(_ required: Bool, access: LockedNoteAccess?) throws -> SymmetricKey? {
        guard required else { return nil }
        guard let access else { throw JournalProtectionError.keyRequired }
        return try access.journalKey()
    }
    private static func removeRetirementFile(_ url: URL, marker: Marker, expected: Data, store: NoteStore, access: LockedNoteAccess?) throws {
        func remove(_ key: SymmetricKey?) throws {
            guard digest(try Data(contentsOf: url), noteId: marker.noteId, purpose: "marker", key: key) == expected else { throw RetirementError.changed }
            try FileManager.default.removeItem(at: url)
            try syncDirectory(url.deletingLastPathComponent())
        }
        if marker.isProtected == true || access != nil {
            guard let access else { throw JournalProtectionError.keyRequired }
            try access.withCurrentRecoveryLease(noteId: marker.recoveryId, journalDirectory: url.deletingLastPathComponent()) { key, db in
                try verifyRows(db, sourceId: marker.noteId, recoveryId: marker.recoveryId, allowLocked: true)
                try remove(marker.isProtected == true ? key : nil)
            }
        } else {
            try store.db.pool.write { db in
                try verifyRows(db, sourceId: marker.noteId, recoveryId: marker.recoveryId)
                try remove(nil)
            }
        }
    }
    private static func digest(_ bytes: Data, noteId: String, purpose: String, key: SymmetricKey?) -> Data {
        JournalRecoveryFiles.digest(bytes, noteId: noteId, info: "editor-journal-recovery-\(purpose)-v1", key: key)
    }
    private static func saveMarker(_ marker: Marker, to url: URL) throws {
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close()
        try syncDirectory(url.deletingLastPathComponent())
    }
    private static func syncDirectory(_ directory: URL) throws {
        try JournalRecoveryFiles.syncDirectory(directory, failure: CocoaError(.fileWriteUnknown))
    }

}
