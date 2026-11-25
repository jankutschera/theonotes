// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import GRDB

struct JournalRecoveryContext: Sendable {
    let key: String
    let journalHash: String
    let baseHash: String
    let avoidingID: String?
}

enum JournalRecoveryGeneration {
    struct State: Codable { let generation: Int; let journalHash: String; let baseHash: String; let recoveryID: String }
    static func next(_ context: JournalRecoveryContext, in db: Database) throws -> Int {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [context.key]) else {
            return context.avoidingID == nil ? 0 : 1
        }
        let state = try JSONDecoder().decode(State.self, from: Data(value.utf8))
        guard state.generation >= 0, state.generation < Int.max else { throw CocoaError(.fileReadCorruptFile) }
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE id=? AND deletedAt IS NULL)", arguments: [state.recoveryID]) == true
        if exists && context.avoidingID != state.recoveryID && state.journalHash == context.journalHash && state.baseHash == context.baseHash {
            return state.generation
        }
        return state.generation + 1
    }
    static func save(_ context: JournalRecoveryContext, generation: Int, id: String, in db: Database) throws {
        let state = State(generation: generation, journalHash: context.journalHash, baseHash: context.baseHash, recoveryID: id)
        let value = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try db.execute(sql: "INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [context.key, value])
    }
    static func matches(_ context: JournalRecoveryContext, generation: Int, id: String, in db: Database) throws -> Bool {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [context.key]) else { return false }
        let state = try JSONDecoder().decode(State.self, from: Data(value.utf8))
        return state.generation == generation && state.recoveryID == id && state.journalHash == context.journalHash && state.baseHash == context.baseHash
    }
}

public struct BrowserRecoveryResult: Sendable {
    public let note: Note
    public let created: Bool
    public init(note: Note, created: Bool) { self.note = note; self.created = created }
}

/// The content boundary used by durable editing. A locked-note implementation decrypts only
/// for an authorized session and encrypts every write and conflict copy before persistence.
public protocol NoteSessionStore: Sendable {
    func note(id: String) throws -> Note?
    func updateText(id: String, text: String, expectedRevision: Int, now: Date) throws -> Note
    func createConflictCopy(of noteId: String, text: String, now: Date) throws -> Note
    func preserveBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date) throws -> BrowserRecoveryResult
}

extension NoteSessionStore {
    // Unrecognised stores must fail closed instead of falling back to a plaintext copy.
    public func preserveBrowserRecovery(noteId: String, text: String, baseRevision: Int, now: Date) throws -> BrowserRecoveryResult {
        throw CocoaError(.fileWriteUnknown)
    }
}

enum BrowserRecoveryID {
    static func make(noteId: String, text: String, baseRevision: Int, key: SymmetricKey? = nil) -> String {
        let data = Data("editor-browser-recovery\0\(noteId)\0\(baseRevision)\0\(text)".utf8)
        let bytes: [UInt8]
        if let key {
            let scoped = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(noteId.utf8),
                                                info: Data("editor-browser-recovery-id-v1".utf8), outputByteCount: 32)
            bytes = Array(HMAC<SHA256>.authenticationCode(for: data, using: scoped).prefix(16))
        }
        else { bytes = Array(SHA256.hash(data: data).prefix(16)) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }
}

extension NoteStore: NoteSessionStore {
    public func updateText(id: String, text: String, expectedRevision: Int, now: Date) throws -> Note {
        try updateText(id: id, text: text, expectedRevision: expectedRevision, now: now, preservingModifiedDate: false)
    }
}
