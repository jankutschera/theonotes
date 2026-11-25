// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Synchronization

/// Test seam: runs inside `lock`'s transaction right after the pending-journal check, for the
/// note it was set for (lets a test act in the window between that check and the purge).
enum LockTestHooks {
    static let afterJournalCheck = Mutex<[String: @Sendable () -> Void]>([:])
    static func runAfterJournalCheck(_ noteId: String) { afterJournalCheck.withLock { $0[noteId] }?() }

    /// The same window in the sync materializer's note commit (FOC-R303).
    static let afterRemoteJournalCheck = Mutex<[String: @Sendable () -> Void]>([:])
    static func runAfterRemoteJournalCheck(_ noteId: String) { afterRemoteJournalCheck.withLock { $0[noteId] }?() }
}

public enum NotePrivacyError: Error, Equatable, Sendable {
    case passwordAlreadySet
    case passwordNotSet
    case accessRevoked
    case pendingEdits
    case pendingAttachments
    case cleanupPending
    case invalidPayload
    case attachmentMissing(String)
    /// An attachment is larger than the caller allows to hold in memory.
    case attachmentTooLarge
}

/// Private content is decoded only in an explicitly authorized access object. Attachment
/// filenames are inside this ciphertext; the filesystem contains opaque blob identifiers.
struct LockedNotePayload: Codable, Sendable {
    var version = 1
    var text: String
    var attachments: [String: String]
    var attachmentIDs: [String: String]? = nil

    var indexIDs: [String: String] {
        attachmentIDs ?? attachments.mapValues { String($0.dropLast(4)) }
    }
}

public struct NotePrivacy: Sendable {
    let store: NoteStore
    public init(store: NoteStore) { self.store = store }

    public var hasPassword: Bool {
        get throws { try envelope() != nil }
    }

    public func envelope() throws -> CryptoEnvelope? {
        try store.db.pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id = 1") else { return nil }
            return try JSONDecoder().decode(CryptoEnvelope.self, from: data)
        }
    }

    public func setPassword(_ password: String) throws -> LockedNoteAccess {
        let (envelope, key) = try CryptoEnvelope.create(password: password)
        let encoded = try JSONEncoder().encode(envelope)
        try store.write { db in
            guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM crypto_envelope)")! else {
                throw NotePrivacyError.passwordAlreadySet
            }
            try db.execute(sql: "INSERT INTO crypto_envelope(id, envelope) VALUES(1, ?)", arguments: [encoded])
        }
        return LockedNoteAccess(store: store, key: key, envelope: envelope)
    }

    public func unlock(password: String) throws -> LockedNoteAccess {
        guard let envelope = try envelope() else { throw NotePrivacyError.passwordNotSet }
        return LockedNoteAccess(store: store, key: try envelope.unwrap(password: password), envelope: envelope)
    }

    /// Restores a key obtained from the platform's authenticated Keychain. The envelope
    /// comparison rejects a cache from a replaced library or an old password enrollment.
    public func restoreAccess(vaultKey: SymmetricKey, matching cachedEnvelope: CryptoEnvelope) throws -> LockedNoteAccess {
        guard let current = try envelope(), current == cachedEnvelope,
              vaultKey.bitCount == 256 else { throw NotePrivacyError.accessRevoked }
        if let note = try store.db.pool.read({ try Note.fetchOne($0, sql: "SELECT * FROM note WHERE isLocked = 1 AND encryptedPayload IS NOT NULL LIMIT 1") }),
           let encrypted = note.encryptedPayload {
            _ = try NoteCipher.open(encrypted, vaultKey: vaultKey, context: note.id)
        }
        return LockedNoteAccess(store: store, key: vaultKey, envelope: current)
    }

    /// Only the wrapped key changes. Existing note, attachment and journal ciphertext stays valid.
    public func changePassword(from oldPassword: String, to newPassword: String) throws {
        guard let previous = try envelope() else { throw NotePrivacyError.passwordNotSet }
        let updated = try previous.rewrapped(oldPassword: oldPassword, newPassword: newPassword)
        try store.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id = 1"),
                  try JSONDecoder().decode(CryptoEnvelope.self, from: data) == previous else {
                throw NotePrivacyError.accessRevoked
            }
            try db.execute(sql: "UPDATE crypto_envelope SET envelope = ? WHERE id = 1",
                           arguments: [try JSONEncoder().encode(updated)])
        }
    }

    /// Completes a committed lock transition after a crash. Never removes an acknowledged
    /// encrypted journal. Called after AttachmentFiles.recover and before exposing the library.
    public func finishPendingCleanup() throws {
        let ids = try store.db.pool.read { try String.fetchAll($0, sql: "SELECT noteId FROM privacy_transition") }
        for id in ids { try finishTransition(noteId: id) }
    }

    /// Retries transient cleanup blockers off MainActor. Exhaustion or cancellation keeps
    /// the durable transition for a later lifecycle/recovery attempt. SQLite's individual
    /// checkpoint may still wait for its configured busy timeout.
    @concurrent public func finishPendingCleanupWithRetry() async throws {
        try await Self.retryCleanup { try finishPendingCleanup() }
    }

    @concurrent static func retryCleanup(_ cleanup: @Sendable () throws -> Void) async throws {
        for attempt in 0..<5 {
            try Task.checkCancellation()
            do {
                try cleanup()
                return
            } catch NotePrivacyError.cleanupPending {
                try Task.checkCancellation()
                guard attempt < 4 else { throw NotePrivacyError.cleanupPending }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// How often `finishTransition` tries the cleanup lock, 10 ms apart (about half a second). A lock
    /// that looks held for a moment is usually not: a process spawned while the lock was open keeps
    /// a copy of its file descriptor until it execs, and a flock belongs to the open file
    /// description, so the lock outlives its owner's `close` (FOC-R306).
    static let cleanupLockAttempts = 50

    /// The lock file is never removed: all processes must keep locking the same inode.
    /// Take it before reading a transition, through marker deletion, so a second cleanup
    /// cannot retain a manifest after the first completes and writes become legal again.
    func finishTransition(noteId: String) throws {
        guard let lock = try BatchLock.acquire(store.paths.root.appendingPathComponent(".privacy-cleanup.lock").path,
                                               attempts: Self.cleanupLockAttempts) else {
            throw NotePrivacyError.cleanupPending
        }
        defer { lock.release() }
        guard let row = try store.db.pool.read({ try Row.fetchOne($0, sql: "SELECT * FROM privacy_transition WHERE noteId = ?", arguments: [noteId]) }) else { return }
        let pending = try store.db.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId = ?)", arguments: [noteId])!
        }
        guard !pending else { throw NotePrivacyError.cleanupPending }
        let locked: Bool = row["targetLocked"]
        let names = try JSONDecoder().decode([String].self, from: Data((row["filenames"] as String).utf8))
        let keeping = Set(names.map(AttachmentFiles.fileSystemKey))
        let dir = store.paths.attachments.appendingPathComponent(noteId)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                where !keeping.contains(AttachmentFiles.fileSystemKey(url.lastPathComponent)) {
                try fm.removeItem(at: url)
            }
        }
        if locked {
            try cleanup(noteId: noteId)
            try checkpoint()
        } else {
            let journal = store.paths.journal.appendingPathComponent(noteId + ".jsonl")
            if fm.fileExists(atPath: journal.path), !(try Data(contentsOf: journal)).isEmpty {
                throw NotePrivacyError.pendingEdits
            }
            for ext in ["jsonl", "base"] {
                let url = store.paths.journal.appendingPathComponent(noteId + "." + ext)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
        }
        try store.write { try $0.execute(sql: "DELETE FROM privacy_transition WHERE noteId = ?", arguments: [noteId]) }
    }

    /// Call inside the mutation's writer transaction, before touching any file or reference.
    /// A durable marker freezes content until cleanup succeeds, including between retries.
    static func requireNoPendingTransition(_ noteId: String, in db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition WHERE noteId = ?)", arguments: [noteId]) == true {
            throw NotePrivacyError.cleanupPending
        }
    }

    func cleanup(noteId: String) throws {
        let files = AttachmentFiles(paths: store.paths, database: store.db)
        let pending = try store.db.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId = ?)", arguments: [noteId])!
        }
        guard !pending else { throw NotePrivacyError.cleanupPending }
        let fm = FileManager.default
        let thumbs = store.paths.thumbnails.appendingPathComponent(noteId)
        if fm.fileExists(atPath: thumbs.path) { try fm.removeItem(at: thumbs) }
        for url in try fm.contentsOfDirectory(at: store.paths.journal, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(noteId + ".") {
            let data = try Data(contentsOf: url)
            if data.starts(with: Data("BJE1:".utf8)) || data.starts(with: Data("BJB1:".utf8)) { continue }
            // A plaintext recovery journal must be resolved before locking, never discarded.
            if url.lastPathComponent.contains(".jsonl"), !data.isEmpty { throw NotePrivacyError.pendingEdits }
            try fm.removeItem(at: url)
        }
        // No old plaintext names may remain after a replacing batch is reported complete.
        let names = (try? fm.contentsOfDirectory(atPath: files.directory(for: noteId).path)) ?? []
        guard names.allSatisfy({ UUID(uuidString: String($0.dropLast(4))) != nil && $0.hasSuffix(".bch") }) else {
            throw NotePrivacyError.cleanupPending
        }
        try LibraryBackup(database: store.db, paths: store.paths).prunePlaintextCopies(noteID: noteId)
    }

    func checkpoint() throws {
        try store.db.pool.writeWithoutTransaction { db in
            // In-memory databases report -1 for the log/frame counts. A busy on-disk checkpoint
            // is not completion: the caller must retry before reporting the privacy transition.
            let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            if let row, (row[0] as Int) != 0 { throw NotePrivacyError.cleanupPending }
        }
    }
}

/// Revocable authorization for the lock vault. Every content operation holds the key lock,
/// so revoke waits for a current write to finish and later reads/writes are refused.
public final class LockedNoteAccess: NoteSessionStore, Sendable {
    let store: NoteStore
    private let key: Mutex<SymmetricKey?>
    private let envelopeAtUnlock: Mutex<CryptoEnvelope?>

    init(store: NoteStore, key: SymmetricKey, envelope: CryptoEnvelope? = nil) {
        self.store = store
        self.key = Mutex(key)
        self.envelopeAtUnlock = Mutex(envelope)
    }

    public func revoke() { key.withLock { $0 = nil } }

    public func journalKey() throws -> SymmetricKey { try withKey { $0 } }

    /// Accept only a password rewrap that demonstrably unwraps to this access object's key.
    public func acceptPasswordRewrap(password: String) throws {
        try withKey { existingKey in
            guard let current = try NotePrivacy(store: store).envelope() else { throw NotePrivacyError.accessRevoked }
            let candidate = try current.unwrap(password: password)
            let challenge = Data("recovery-key-identity-v1".utf8)
            let mac = HMAC<SHA256>.authenticationCode(for: challenge, using: existingKey)
            guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: challenge, using: candidate) else {
                throw NotePrivacyError.accessRevoked
            }
            envelopeAtUnlock.withLock { $0 = current }
        }
    }

    private func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        try key.withLock { key in
            guard let key else { throw NotePrivacyError.accessRevoked }
            return try body(key)
        }
    }

    /// The snapshot key seam (FOC-R16): `body` runs under the key lock, so `revoke()` waits for it
    /// and every later call throws `accessRevoked`. The key must not escape the closure. Not
    /// reentrant: `body` must not call another member of this access.
    func withVaultKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T { try withKey(body) }

    func verifyRecoveryClassification(directory: URL) throws {
        guard store.paths.journal.standardizedFileURL == directory.standardizedFileURL else { throw NotePrivacyError.accessRevoked }
        try withKey { _ in
            try store.db.pool.read { db in
                guard let expected = envelopeAtUnlock.withLock({ $0 }),
                      let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"),
                      try JSONDecoder().decode(CryptoEnvelope.self, from: data) == expected else { throw NotePrivacyError.accessRevoked }
            }
        }
    }

    func withRecoveryVariantWriter<T>(directory: URL, _ body: (SymmetricKey, Database) throws -> T) throws -> T {
        guard store.paths.journal.standardizedFileURL == directory.standardizedFileURL else { throw NotePrivacyError.accessRevoked }
        return try withKey { key in
            try store.write { db in
                guard let expected = envelopeAtUnlock.withLock({ $0 }),
                      let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"),
                      try JSONDecoder().decode(CryptoEnvelope.self, from: data) == expected else { throw NotePrivacyError.accessRevoked }
                return try body(key, db)
            }
        }
    }

    func insertRecoveryVariant(id: String, text: String, key: SymmetricKey, in db: Database) throws -> Note {
        let now = Date(), payload = LockedNotePayload(text: text, attachments: [:])
        let meta = NoteParser.metadata(for: text)
        var copy = Note(id: id, text: "", title: meta.title, titleKey: TitleKey.make(meta.title),
                        createdAt: NoteStore.roundedToMillis(now), modifiedAt: NoteStore.roundedToMillis(now),
                        isLocked: true, encryptedPayload: try ciphertext(payload, noteId: id, key: key))
        try copy.insert(db); try NoteIndexer.writeLockedTags(meta.tags, noteId: id, in: db)
        copy.text = text
        return copy
    }

    /// Hold revocation and the database writer while proving the current envelope and copy.
    func withCurrentRecoveryLease<T>(noteId: String, journalDirectory: URL, _ body: (SymmetricKey) throws -> T) throws -> T {
        try withCurrentRecoveryLease(noteId: noteId, journalDirectory: journalDirectory) { key, _ in try body(key) }
    }

    func withCurrentRecoveryLease<T>(noteId: String, journalDirectory: URL, _ body: (SymmetricKey, Database) throws -> T) throws -> T {
        guard store.paths.journal.standardizedFileURL == journalDirectory.standardizedFileURL else { throw NotePrivacyError.accessRevoked }
        return try withKey { key in
            try store.db.pool.write { db in
                guard let expected = envelopeAtUnlock.withLock({ $0 }),
                      let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"),
                      try JSONDecoder().decode(CryptoEnvelope.self, from: data) == expected,
                      let note = try Note.fetchOne(db, key: noteId), note.deletedAt == nil else { throw NotePrivacyError.accessRevoked }
                if note.isLocked { _ = try payload(note, key: key) }
                return try body(key, db)
            }
        }
    }

    /// The decrypted text of a locked note, for a caller that already holds the key.
    func lockedText(_ note: Note, key: SymmetricKey) throws -> String { try payload(note, key: key).text }

    private func payload(_ note: Note, key: SymmetricKey) throws -> LockedNotePayload {
        guard note.isLocked, let encrypted = note.encryptedPayload else { throw NotePrivacyError.invalidPayload }
        let decoded = try JSONDecoder().decode(LockedNotePayload.self,
            from: NoteCipher.open(encrypted, vaultKey: key, context: note.id))
        guard decoded.version == 1 else { throw NotePrivacyError.invalidPayload }
        for (filename, id) in decoded.indexIDs {
            try AttachmentFiles.validate(filename)
            guard UUID(uuidString: id) != nil else { throw NotePrivacyError.invalidPayload }
        }
        for (filename, blob) in decoded.attachments {
            try AttachmentFiles.validate(filename)
            guard UUID(uuidString: String(blob.dropLast(4))) != nil, blob.hasSuffix(".bch") else {
                throw NotePrivacyError.invalidPayload
            }
        }
        return decoded
    }

    private func ciphertext(_ payload: LockedNotePayload, noteId: String, key: SymmetricKey) throws -> Data {
        try NoteCipher.seal(JSONEncoder().encode(payload), vaultKey: key, context: noteId)
    }

    public func note(id: String) throws -> Note? {
        try withKey { key in
            guard var note = try store.note(id: id) else { return nil }
            guard note.isLocked else { return note }
            note.text = try payload(note, key: key).text
            return note
        }
    }

    /// Caller must flush and detach the ordinary editor session first. Staging and the database
    /// transition share the writer lock with attachment mutations; no plaintext insert can race it.
    public func lock(noteId: String) throws { try lock(noteId: noteId, installFiles: true) }

    // Test seam: simulate the process exiting after the durable transaction, before file install.
    func lock(noteId: String, installFiles: Bool) throws {
        try withKey { key in
            let files = AttachmentFiles(paths: store.paths, database: store.db)
            var staged: AttachmentFiles.Staged?
            do {
                try store.write { db in
                    let note = try NoteStore.require(noteId, in: db)
                    if note.isLocked { _ = try payload(note, key: key); return }
                    try NotePrivacy.requireNoPendingTransition(noteId, in: db)
                    // The checks that do not depend on a capture come first: a lock that fails them
                    // leaves a running voice capture and its recording alone (FOC-R300).
                    guard !store.retention.contains(noteId) else { throw NotePrivacyError.pendingEdits }
                    guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId = ?)", arguments: [noteId])!,
                          !files.hasStagedFiles(for: noteId), !files.isCopySource(noteId) else {
                        throw NotePrivacyError.pendingAttachments
                    }
                    // A voice capture stops before the journal is checked, so it cannot journal
                    // text after the check (FOC-R199 addendum 3).
                    try CaptureLockGuard.noteWillLock(noteId)
                    try requireNoPendingJournal(noteId)
                    LockTestHooks.runAfterJournalCheck(noteId)
                    let originals = try regularFiles(noteId: noteId)
                    var ids: [String: String] = [:]
                    for row in try Row.fetchAll(db, sql: "SELECT filename, id FROM attachment WHERE noteId = ?", arguments: [noteId]) {
                        ids[row["filename"] as String] = row["id"] as String
                    }
                    for name in originals.keys {
                        if let prior = ids.keys.first(where: { AttachmentFiles.fileSystemKey($0) == AttachmentFiles.fileSystemKey(name) }) {
                            let id = ids.removeValue(forKey: prior)!
                            ids[name] = id
                        } else { ids[name] = UUIDv7.make() }
                    }
                    let manifest = Dictionary(uniqueKeysWithValues: originals.keys.map { ($0, ids[$0]! + ".bch") })
                    let reverse = Dictionary(uniqueKeysWithValues: manifest.map { ($0.value, $0.key) })
                    var batch = try files.stageTransformed(Array(reverse.keys).sorted(), noteId: noteId) { blob, output in
                        try ChunkedCipher.encrypt(input: originals[reverse[blob]!]!, output: output,
                                                  keyEncryptionKey: key, context: blob)
                    }
                    batch.replacing = true
                    staged = batch
                    try AttachmentFiles.record(batch, in: db)
                    let payload = LockedNotePayload(text: note.text, attachments: manifest, attachmentIDs: ids)
                    let encrypted = try ciphertext(payload, noteId: noteId, key: key)
                    try db.execute(sql: "UPDATE note SET text = '', subtitle = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                                   arguments: [encrypted, noteId])
                    // The slash cannot occur in a real filename key. This temporary namespace
                    // avoids collisions when a user filename happens to equal another blob id.
                    try db.execute(sql: "UPDATE attachment SET filenameKey = '/' || id WHERE noteId = ?", arguments: [noteId])
                    try writeLockedAttachments(payload, noteId: noteId, db: db)
                    try NoteSnapshots.sealAll(noteId: noteId, key: key, in: db)
                    try purgeDerivedContent(noteId: noteId, db: db)
                    try recordTransition(noteId: noteId, locked: true, filenames: Array(manifest.values), db: db)
                }
            } catch {
                if let staged { files.discard(staged) }
                throw error
            }
            if installFiles, let staged { files.install(staged) }
            try NotePrivacy(store: store).finishTransition(noteId: noteId)
        }
    }

    public func updateText(id: String, text: String, expectedRevision: Int, now: Date = .now) throws -> Note {
        try withKey { key in
            try store.write { db in
                try writeLockedText(id: id, text: text, expectedRevision: expectedRevision, now: now, key: key, in: db)
            }
        }
    }

    /// `updateText` inside a caller's write transaction (Replace This Note on a locked note).
    func writeLockedText(id: String, text: String, expectedRevision: Int, now: Date, key: SymmetricKey,
                         in db: Database) throws -> Note {
        let current = try NoteStore.require(id, in: db)
        try NotePrivacy.requireNoPendingTransition(id, in: db)
        guard current.revision == expectedRevision else { throw StoreError.revisionConflict(current: current.revision) }
        var payload = try payload(current, key: key)
        payload.text = TextNormalization.normalizeLineEndings(text)
        let meta = NoteParser.metadata(for: payload.text)
        var ids = payload.indexIDs
        for file in meta.attachments where !ids.keys.contains(where: { AttachmentFiles.fileSystemKey($0) == AttachmentFiles.fileSystemKey(file.filename) }) {
            ids[file.filename] = UUIDv7.make()
        }
        payload.attachmentIDs = ids
        try db.execute(sql: """
            UPDATE note SET encryptedPayload = ?, title = ?, titleKey = ?, modifiedAt = ?, revision = revision + 1
            WHERE id = ?
            """, arguments: [try ciphertext(payload, noteId: id, key: key), meta.title,
                               TitleKey.make(meta.title), NoteStore.roundedToMillis(now), id])
        try NoteIndexer.writeLockedTags(meta.tags, noteId: id, in: db)
        try writeLockedAttachments(payload, noteId: id, db: db)
        var result = try NoteStore.require(id, in: db)
        result.text = payload.text
        return result
    }

    /// A protected recovery never writes plaintext or stages attachment files.
    public func preserveBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date) throws -> BrowserRecoveryResult {
        try preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: baseRevision, now: now, sourceWasProtected: false, journalContext: nil)
    }

    /// For a session that was opened protected even if its source has since been unlocked.
    public func preserveProtectedBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date) throws -> BrowserRecoveryResult {
        try preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: baseRevision, now: now, sourceWasProtected: true, journalContext: nil)
    }

    func preserveOrphanJournalRecovery(noteId: String, text: String, baseRevision: Int, now: Date, journalContext: JournalRecoveryContext) throws -> BrowserRecoveryResult {
        try preserveBrowserRecovery(noteId: noteId, text: text, baseRevision: baseRevision, now: now, sourceWasProtected: false, journalContext: journalContext)
    }

    private func preserveBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date, sourceWasProtected: Bool, journalContext: JournalRecoveryContext?) throws -> BrowserRecoveryResult {
        let text = TextNormalization.normalizeLineEndings(text)
        let result = try withKey { key in
            return try store.write { db in
                guard let expectedEnvelope = envelopeAtUnlock.withLock({ $0 }),
                      let data = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id = 1"),
                      try JSONDecoder().decode(CryptoEnvelope.self, from: data) == expectedEnvelope else {
                    throw NotePrivacyError.accessRevoked
                }
                if let original = try Note.fetchOne(db, key: noteId) {
                    guard original.isLocked || sourceWasProtected else { throw CocoaError(.fileWriteNoPermission) }
                    if original.isLocked { _ = try payload(original, key: key) }
                }
                var generation = try journalContext.map { try JournalRecoveryGeneration.next($0, in: db) } ?? 0
                var id = ""
                while true {
                    let identity = generation == 0 ? noteId : noteId + "\0orphan-generation:\(generation)"
                    id = BrowserRecoveryID.make(noteId: identity, text: text, baseRevision: baseRevision, key: key)
                    guard var existing = try Note.fetchOne(db, key: id) else { break }
                    let recorded = try journalContext.map { try JournalRecoveryGeneration.matches($0, generation: generation, id: id, in: db) } ?? false
                    let existingText = existing.isLocked ? try? payload(existing, key: key).text : existing.text
                    guard existing.deletedAt == nil, existing.isLocked || recorded, let existingText,
                          recorded || (existing.location == .notes && TextNormalization.identical(existingText, text)) else {
                        // Q4: a copy the user edited, trashed, archived or unlocked keeps this id; journal
                        // recovery moves to the next generation in this same transaction (ruling 4).
                        guard journalContext != nil, generation < Int.max else { throw CocoaError(.fileWriteFileExists) }
                        generation += 1; continue
                    }
                    existing.text = existingText
                    if let journalContext { try JournalRecoveryGeneration.save(journalContext, generation: generation, id: id, in: db) }
                    return (existing, false)
                }
                let contents = LockedNotePayload(text: text, attachments: [:])
                let meta = NoteParser.metadata(for: text)
                var copy = Note(id: id, text: "", title: meta.title, titleKey: TitleKey.make(meta.title),
                                createdAt: NoteStore.roundedToMillis(now), modifiedAt: NoteStore.roundedToMillis(now),
                                isLocked: true, encryptedPayload: try ciphertext(contents, noteId: id, key: key))
                try copy.insert(db)
                try NoteIndexer.writeLockedTags(meta.tags, noteId: id, in: db)
                if let journalContext { try JournalRecoveryGeneration.save(journalContext, generation: generation, id: id, in: db) }
                copy.text = text
                return (copy, true)
            }
        }
        // Decrypt a committed readback before acknowledging the browser.
        guard let committed = try (result.0.isLocked ? note(id: result.0.id) : store.note(id: result.0.id)),
              (committed.isLocked || journalContext != nil), committed.deletedAt == nil,
              (journalContext != nil || (committed.location == .notes && TextNormalization.identical(committed.text, text))) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return BrowserRecoveryResult(note: committed, created: result.1)
    }

    public func createConflictCopy(of noteId: String, text: String, now: Date = .now) throws -> Note {
        try createCopy(of: noteId, text: text, now: now, preservingConflictMetadata: true)
    }

    /// Copies selected Markdown without exposing a plaintext note or changing the source's metadata.
    public func createFromSelection(of noteId: String, text: String, now: Date = .now) throws -> Note {
        try createCopy(of: noteId, text: text, now: now, preservingConflictMetadata: false)
    }

    private func createCopy(of noteId: String, text: String, now: Date, preservingConflictMetadata: Bool) throws -> Note {
        return try withKey { key in
            let files = AttachmentFiles(paths: store.paths, database: store.db)
            let id = UUIDv7.make(now: now)
            var staged: AttachmentFiles.Staged?
            let copy: Note
            do {
                copy = try store.write { db in
                    let original = try NoteStore.require(noteId, in: db)
                    var payload = try payload(original, key: key)
                    payload.text = TextNormalization.normalizeLineEndings(text)
                    let existing = try regularFiles(noteId: noteId)
                    let originalManifest = payload.attachments
                    payload.attachmentIDs = payload.indexIDs.mapValues { _ in UUIDv7.make() }
                    payload.attachments = Dictionary(uniqueKeysWithValues: originalManifest.keys.map { ($0, payload.indexIDs[$0]! + ".bch") })
                    let oldByNew = Dictionary(uniqueKeysWithValues: payload.attachments.map { ($0.value, originalManifest[$0.key]!) })
                    let batch = try files.stageTransformed(Array(oldByNew.keys).sorted(), noteId: id) { name, output in
                        let old = oldByNew[name]!
                        guard let source = existing[old] else { throw NotePrivacyError.attachmentMissing(old) }
                        try ChunkedCipher.reencrypt(input: source, output: output, keyEncryptionKey: key,
                                                    fromContext: old, toContext: name)
                    }
                    staged = batch
                    try AttachmentFiles.record(batch, in: db)
                    let meta = NoteParser.metadata(for: payload.text)
                    var copy = Note(id: id, text: "", title: meta.title, titleKey: TitleKey.make(meta.title),
                                    createdAt: preservingConflictMetadata ? original.createdAt : NoteStore.roundedToMillis(now),
                                    modifiedAt: NoteStore.roundedToMillis(now),
                                    location: preservingConflictMetadata ? original.location : .notes,
                                    trashedAt: preservingConflictMetadata ? original.trashedAt : nil,
                                    archivedAt: preservingConflictMetadata ? original.archivedAt : nil,
                                    isPinnedGlobal: preservingConflictMetadata && original.isPinnedGlobal, isLocked: true,
                                    encryptedPayload: try ciphertext(payload, noteId: id, key: key))
                    try copy.insert(db)
                    try NoteIndexer.writeLockedTags(meta.tags, noteId: id, in: db)
                    try writeLockedAttachments(payload, noteId: id, db: db)
                    if preservingConflictMetadata {
                        try db.execute(sql: "INSERT INTO note_pin(noteId, tagId) SELECT ?, tagId FROM note_pin WHERE noteId = ? AND tagId IN (SELECT tagId FROM note_tag WHERE noteId = ?)", arguments: [id, noteId, id])
                        try db.execute(sql: "UPDATE external_ref SET noteId = ?, importedRevision = ? WHERE noteId = ? AND importedTextHash = ?",
                                       arguments: [id, copy.revision, noteId, NoteStore.textHash(payload.text)])
                    }
                    copy.text = payload.text
                    return copy
                }
            } catch {
                if let staged { files.discard(staged) }
                throw error
            }
            if let staged { files.install(staged) }
            return copy
        }
    }

    public func addAttachment(data: Data, filename: String, to noteId: String) throws -> String {
        try addAttachment(filename: filename, to: noteId) { key, blob, output in
            try ChunkedCipher.encrypt(data: data, output: output, keyEncryptionKey: key, context: blob)
        }
    }

    public func addAttachment(fileAt input: URL, to noteId: String) throws -> String {
        try addAttachment(filename: input.lastPathComponent, to: noteId) { key, blob, output in
            try ChunkedCipher.encrypt(input: input, output: output, keyEncryptionKey: key, context: blob)
        }
    }

    private func addAttachment(filename: String, to noteId: String,
                               encrypt: (SymmetricKey, String, URL) throws -> Void) throws -> String {
        try withKey { key in
            let files = AttachmentFiles(paths: store.paths, database: store.db)
            var staged: AttachmentFiles.Staged?
            let name: String
            do {
                name = try store.write { db in
                    let note = try NoteStore.require(noteId, in: db)
                    var payload = try payload(note, key: key)
                    try requireNoPendingBatch(noteId, db: db)
                    let existing = Set(payload.attachments.keys.map(AttachmentFiles.fileSystemKey))
                    let name = AttachmentFiles.uniqueCandidates(AttachmentStore.usableName(filename))
                        .first { !existing.contains(AttachmentFiles.fileSystemKey($0)) }!
                    var ids = payload.indexIDs
                    let prior = ids.keys.first { AttachmentFiles.fileSystemKey($0) == AttachmentFiles.fileSystemKey(name) }
                    let attachmentID = prior.flatMap { ids.removeValue(forKey: $0) } ?? UUIDv7.make()
                    ids[name] = attachmentID
                    payload.attachmentIDs = ids
                    let blob = attachmentID + ".bch"
                    let batch = try files.stageTransformed([blob], noteId: noteId) { _, output in
                        try encrypt(key, blob, output)
                    }
                    staged = batch
                    try AttachmentFiles.record(batch, in: db)
                    payload.attachments[name] = blob
                    try writeLockedAttachments(payload, noteId: noteId, db: db)
                    try db.execute(sql: "UPDATE note SET encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                                   arguments: [try ciphertext(payload, noteId: noteId, key: key), noteId])
                    return name
                }
            } catch {
                if let staged { files.discard(staged) }
                throw error
            }
            if let staged { files.install(staged) }
            try store.db.pool.read { try requireNoPendingBatch(noteId, db: $0) }
            return name
        }
    }

    /// Encrypt and commit the entire incoming batch with one manifest/staging transaction.
    public func addAttachments(_ inputs: [ImportedAttachment], to noteId: String, validatingSource source: AttachmentSourceGuard? = nil) throws -> [String] {
        guard !inputs.isEmpty else { return [] }
        return try withKey { key in
            let files = AttachmentFiles(paths: store.paths, database: store.db)
            var staged: AttachmentFiles.Staged?
            let names: [String]
            do {
                names = try store.write { db in
                    let note = try NoteStore.require(noteId, in: db)
                    var payload = try payload(note, key: key)
                    try requireNoPendingBatch(noteId, db: db)
                    if let source {
                        try source.validate(note: note)
                        // Already inside withKey and this writer: never re-enter attachmentData/pool.
                        let matching = payload.attachments.first { AttachmentFiles.fileSystemKey($0.key) == AttachmentFiles.fileSystemKey(source.filename) }
                        guard let blob = matching?.value,
                              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE noteId=? AND filename=? AND deletedAt IS NULL)", arguments: [noteId, blob]) == true,
                              let file = try regularFiles(noteId: noteId)[blob] else {
                            throw AttachmentSourceGuard.Failure.changed
                        }
                        let bytes = try ChunkedCipher.decrypt(input: file, keyEncryptionKey: key, context: blob, maximumBytes: source.maximumBytes)
                        try source.validate(bytes: bytes)
                    }
                    var reserved = Set(payload.attachments.keys.map(AttachmentFiles.fileSystemKey))
                    var ids = payload.indexIDs
                    var dataByBlob: [String: Data] = [:]
                    var names: [String] = []
                    for input in inputs {
                        let name = AttachmentFiles.uniqueCandidates(AttachmentStore.usableName(input.filename)).first {
                            !reserved.contains(AttachmentFiles.fileSystemKey($0))
                        }!
                        reserved.insert(AttachmentFiles.fileSystemKey(name))
                        let id = UUIDv7.make(), blob = id + ".bch"
                        ids[name] = id
                        payload.attachments[name] = blob
                        names.append(name)
                        dataByBlob[blob] = input.data
                    }
                    payload.attachmentIDs = ids
                    let batch = try files.stageTransformed(dataByBlob.keys.sorted(), noteId: noteId) { blob, output in
                        try ChunkedCipher.encrypt(data: dataByBlob[blob]!, output: output, keyEncryptionKey: key, context: blob)
                    }
                    staged = batch
                    try AttachmentFiles.record(batch, in: db)
                    try writeLockedAttachments(payload, noteId: noteId, db: db)
                    try db.execute(sql: "UPDATE note SET encryptedPayload=?,revision=revision+1 WHERE id=?",
                        arguments: [try ciphertext(payload, noteId: noteId, key: key), noteId])
                    return names
                }
            } catch {
                if let staged { files.discard(staged) }
                throw error
            }
            if let staged { files.install(staged) }
            try store.db.pool.read { try requireNoPendingBatch(noteId, db: $0) }
            return names
        }
    }

    /// Removes password protection only after all acknowledged edits have been committed.
    /// A crash after the transaction finishes installing the already-staged plaintext files on
    /// launch; a crash before it leaves the encrypted note intact.
    public func removeLock(noteId: String) throws {
        try withKey { key in
            let files = AttachmentFiles(paths: store.paths, database: store.db)
            var staged: AttachmentFiles.Staged?
            let droppedSnapshots: Int
            do {
                droppedSnapshots = try store.write { db in
                    let note = try NoteStore.require(noteId, in: db)
                    let payload = try payload(note, key: key)
                    guard !store.retention.contains(noteId) else { throw NotePrivacyError.pendingEdits }
                    try requireNoPendingJournal(noteId)
                    try requireNoPendingBatch(noteId, db: db)
                    let existing = try regularFiles(noteId: noteId)
                    var batch = try files.stageTransformed(Array(payload.attachments.keys).sorted(), noteId: noteId) { name, output in
                        let blob = payload.attachments[name]!
                        guard let source = existing[blob] else { throw NotePrivacyError.attachmentMissing(name) }
                        try ChunkedCipher.decrypt(input: source, output: output, keyEncryptionKey: key, context: blob)
                    }
                    batch.replacing = true
                    staged = batch
                    try AttachmentFiles.record(batch, in: db)
                    try db.execute(sql: "UPDATE note SET text = ?, isLocked = 0, encryptedPayload = NULL, revision = revision + 1 WHERE id = ?",
                                   arguments: [payload.text, noteId])
                    let dropped = try NoteSnapshots.openAll(noteId: noteId, key: key, in: db)
                    try writeLockedAttachments(payload, noteId: noteId, db: db)
                    try db.execute(sql: "UPDATE attachment SET filenameKey = '/' || id WHERE noteId = ?", arguments: [noteId])
                    for (name, attachmentID) in payload.indexIDs {
                        try db.execute(sql: "UPDATE attachment SET filename = ?, filenameKey = ? WHERE id = ? AND noteId = ?",
                                       arguments: [name, AttachmentFiles.fileSystemKey(name), attachmentID, noteId])
                    }
                    try NoteIndexer.index(noteId: noteId, text: payload.text, in: db)
                    try recordTransition(noteId: noteId, locked: false, filenames: Array(payload.attachments.keys), db: db)
                    return dropped
                }
            } catch {
                if let staged { files.discard(staged) }
                throw error
            }
            NoteSnapshots.logDropped(droppedSnapshots, noteId: noteId)
            if let staged { files.install(staged) }
            try NotePrivacy(store: store).finishTransition(noteId: noteId)
        }
    }

    private func recordTransition(noteId: String, locked: Bool, filenames: [String], db: Database) throws {
        let names = String(decoding: try JSONEncoder().encode(filenames.sorted()), as: UTF8.self)
        try db.execute(sql: "INSERT OR REPLACE INTO privacy_transition(noteId, targetLocked, filenames) VALUES(?, ?, ?)",
                       arguments: [noteId, locked, names])
    }

    private func requireNoPendingBatch(_ noteId: String, db: Database) throws {
        try NotePrivacy.requireNoPendingTransition(noteId, in: db)
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId = ?)", arguments: [noteId]) == true {
            throw NotePrivacyError.pendingAttachments
        }
    }

    /// Materializes one verified file only to a caller-owned private preview/export destination.
    /// The app removes that directory when access is revoked and at the next launch.
    public func decryptAttachment(_ filename: String, noteId: String, to output: URL) throws {
        try withKey { key in
            guard let note = try store.note(id: noteId) else { throw StoreError.noteNotFound(id: noteId) }
            let payload = try payload(note, key: key)
            let matching = payload.attachments.first { AttachmentFiles.fileSystemKey($0.key) == AttachmentFiles.fileSystemKey(filename) }
            guard let blob = matching?.value, let source = try regularFiles(noteId: noteId)[blob] else {
                throw NotePrivacyError.attachmentMissing(filename)
            }
            try ChunkedCipher.decrypt(input: source, output: output, keyEncryptionKey: key, context: blob)
        }
    }

    /// The encrypted file and its blob name for `filename` (from the authenticated payload).
    private func attachmentBlob(_ filename: String, noteId: String, key: SymmetricKey) throws -> (blob: String, file: URL) {
        guard let note = try store.note(id: noteId) else { throw StoreError.noteNotFound(id: noteId) }
        let payload = try payload(note, key: key)
        let matching = payload.attachments.first { AttachmentFiles.fileSystemKey($0.key) == AttachmentFiles.fileSystemKey(filename) }
        guard let blob = matching?.value, let source = try regularFiles(noteId: noteId)[blob] else {
            throw NotePrivacyError.attachmentMissing(filename)
        }
        return (blob, source)
    }

    /// The plaintext size of one attachment, from the file's size: nothing is decrypted.
    public func attachmentSize(_ filename: String, noteId: String) throws -> Int {
        try withKey { key in try ChunkedCipher.plaintextSize(of: attachmentBlob(filename, noteId: noteId, key: key).file) }
    }

    /// The verified plaintext of one attachment, in memory only: for a viewer that serves it
    /// without writing a file (the Mac note window). Larger than `maximumBytes` is refused before
    /// anything is allocated. The caller drops the data when access is revoked.
    public func attachmentData(_ filename: String, noteId: String, maximumBytes: Int) throws -> Data {
        try withKey { key in
            let (blob, source) = try attachmentBlob(filename, noteId: noteId, key: key)
            return try ChunkedCipher.decrypt(input: source, keyEncryptionKey: key, context: blob, maximumBytes: maximumBytes)
        }
    }

    private func requireNoPendingJournal(_ id: String) throws {
        for url in try FileManager.default.contentsOfDirectory(at: store.paths.journal, includingPropertiesForKeys: [.fileSizeKey])
            where url.lastPathComponent.hasPrefix(id + ".") {
            if url.lastPathComponent.contains(".unreplayed") { throw NotePrivacyError.pendingEdits }
            if url.pathExtension == "jsonl", (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 {
                throw NotePrivacyError.pendingEdits
            }
        }
    }

    private func regularFiles(noteId: String) throws -> [String: URL] {
        try AttachmentFiles.validate(noteId)
        let dir = store.paths.attachments.appendingPathComponent(noteId)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [:] }
        guard (try dir.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw NotePrivacyError.invalidPayload }
        var result: [String: URL] = [:]
        for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NotePrivacyError.invalidPayload }
            result[file.lastPathComponent] = file
        }
        return result
    }

    private func writeLockedAttachments(_ payload: LockedNotePayload, noteId: String, db: Database) throws {
        let live = Set(NoteParser.metadata(for: payload.text).attachments.map { AttachmentFiles.fileSystemKey($0.filename) })
        for (name, id) in payload.indexIDs {
            let opaque = id + ".bch"
            let now = Date()
            let deletedAt: Date? = live.contains(AttachmentFiles.fileSystemKey(name)) ? nil : now
            try db.execute(sql: """
                INSERT INTO attachment(id, noteId, filename, filenameKey, createdAt, updatedAt, deletedAt, ocrState)
                VALUES(?, ?, ?, ?, ?, ?, ?, 'locked')
                ON CONFLICT(id) DO UPDATE SET filename = excluded.filename, filenameKey = excluded.filenameKey,
                    updatedAt = excluded.updatedAt, deletedAt = excluded.deletedAt, ocrState = 'locked',
                    ocrText = NULL, ocrAt = NULL, ocrVersion = NULL, uti = NULL, width = NULL, height = NULL,
                    byteSize = NULL, fileModifiedAt = NULL, sha256 = NULL
                WHERE attachment.noteId = excluded.noteId
                """, arguments: [id, noteId, opaque, AttachmentFiles.fileSystemKey(opaque), now, now, deletedAt])
            guard db.changesCount == 1 else { throw NotePrivacyError.invalidPayload }
        }
    }

    private func purgeDerivedContent(noteId: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM note_search_content WHERE noteId = ?", arguments: [noteId])
        try db.execute(sql: "DELETE FROM heading WHERE noteId = ?", arguments: [noteId])
        try db.execute(sql: "DELETE FROM wiki_link WHERE sourceNoteId = ?", arguments: [noteId])
        try db.execute(sql: "DELETE FROM note_stats WHERE noteId = ?", arguments: [noteId])
        try db.execute(sql: "DELETE FROM note_ui_state WHERE noteId = ?", arguments: [noteId])
        try FocusPurge.purgeLocalLock(noteId: noteId, in: db)
        // Older segments may predate secure-delete. A rebuild discards those postings too.
        try db.execute(sql: "INSERT INTO note_fts(note_fts) VALUES('rebuild')")
        try db.execute(sql: "INSERT INTO note_fts_trigram(note_fts_trigram) VALUES('rebuild')")
    }
}
