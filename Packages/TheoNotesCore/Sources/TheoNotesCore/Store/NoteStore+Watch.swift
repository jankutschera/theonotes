// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public struct WatchNoteCommand: Codable, Equatable, Sendable {
    public enum Action: Codable, Equatable, Sendable {
        case create(text: String)
        case append(noteID: String, revision: Int, text: String)
        case setTask(noteID: String, revision: Int, sourceSHA256: String, utf16Offset: Int, expectedMarker: String, checked: Bool)
    }
    public let id: UUID
    public let epoch: UUID
    public let createdAt: Date
    public let action: Action
    public init(id: UUID, epoch: UUID, createdAt: Date = .now, action: Action) {
        self.id = id; self.epoch = epoch; self.createdAt = createdAt; self.action = action
    }
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum WatchNoteRefusal: String, Codable, Sendable {
    case epochMismatch, identifierReused, privacy, missingTarget, staleTarget, readOnly, invalidCommand, expired
}
public enum WatchNoteResult: Codable, Equatable, Sendable {
    case applied(noteID: String, revision: Int)
    case appliedArchived(noteID: String, revision: Int)
    case appliedTrashed(noteID: String, revision: Int)
    case refused(WatchNoteRefusal)
}
public enum WatchNoteError: Error { case corruptEpoch, corruptLibraryID, corruptReceipt, receiptCapacity, clock, futureCommand }

private struct WatchRequestMetadata: Codable {
    let kind: String
    let epoch: UUID
    let createdAt: Date
    init(_ command: WatchNoteCommand) {
        epoch = command.epoch; createdAt = command.createdAt
        switch command.action {
        case .create: kind = "create"
        case .append: kind = "append"
        case .setTask: kind = "task"
        }
    }
}

private enum WatchReceiptOutcome: Codable {
    case applied(revision: Int, createdNoteID: String?)
    case refused(WatchNoteRefusal)
}

extension NoteStore {
    /// Device-local logical identity: moving the library/container must not strand queued dictation.
    public func watchLibraryID() throws -> String {
        try db.pool.write { db in
            if let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key='watch.libraryID'") {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(json.utf8)),
                      value.utf8.count == 64,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw WatchNoteError.corruptLibraryID }
                return value
            }
            let value = SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
                bytes.map { String(format: "%02x", $0) }.joined()
            }
            let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES('watch.libraryID',?)", arguments: [json])
            return value
        }
    }

    public func watchEpoch() throws -> UUID { try db.pool.write { try Self.watchEpoch(in: $0) } }

    @discardableResult public func rotateWatchEpoch() throws -> UUID {
        try db.pool.write { try Self.rotateWatchEpoch(in: $0) }
    }

    static func watchEpoch(in db: Database) throws -> UUID {
        if let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key='watch.epoch'") {
            guard let value = try? JSONDecoder().decode(UUID.self, from: Data(json.utf8)) else { throw WatchNoteError.corruptEpoch }
            return value
        }
        return try rotateWatchEpoch(in: db)
    }

    @discardableResult static func rotateWatchEpoch(in db: Database) throws -> UUID {
        let value = UUID(), json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute(sql: "INSERT INTO setting(key,value) VALUES('watch.epoch',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [json])
        return value
    }

    /// Receipt and mutation commit together; a UUID identifies one intent without retaining a digest of its text.
    public func applyWatchCommand(_ command: WatchNoteCommand, now: Date = .now) throws -> WatchNoteResult {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try write { db in
            let epoch = try Self.watchEpoch(in: db)
            let metadata = WatchRequestMetadata(command)
            let request = String(decoding: try encoder.encode(metadata), as: UTF8.self)
            if let receipt = try Row.fetchOne(db, sql: "SELECT requestMetadata,result FROM watch_command_receipt WHERE epoch=? AND commandID=?", arguments: [command.epoch.uuidString, command.id.uuidString]) {
                let prior = try JSONDecoder().decode(WatchRequestMetadata.self, from: Data((receipt["requestMetadata"] as String).utf8))
                guard prior.kind == metadata.kind, prior.createdAt == metadata.createdAt else { return .refused(.invalidCommand) }
                if epoch != command.epoch, metadata.kind != "create" { return .refused(.epochMismatch) }
                let outcome = try JSONDecoder().decode(WatchReceiptOutcome.self, from: receipt["result"] as Data)
                switch outcome {
                case .refused(let refusal): return .refused(refusal)
                case .applied(let revision, let createdID):
                    let id: String
                    switch command.action {
                    case .create:
                        guard let createdID, UUID(uuidString: createdID) != nil else { throw WatchNoteError.corruptReceipt }
                        id = createdID
                    case .append(let target, _, _), .setTask(let target, _, _, _, _, _):
                        guard createdID == nil else { throw WatchNoteError.corruptReceipt }
                        id = target
                    }
                    guard let note = try Note.fetchOne(db, key: id), note.deletedAt == nil else { return .refused(.missingTarget) }
                    switch note.location {
                    case .notes: return .applied(noteID: id, revision: revision)
                    case .archive: return .appliedArchived(noteID: id, revision: revision)
                    case .trash: return .appliedTrashed(noteID: id, revision: revision)
                    }
                }
            }
            guard command.epoch == epoch else { return .refused(.epochMismatch) }
            guard now.timeIntervalSince1970.isFinite, command.createdAt.timeIntervalSince1970.isFinite else { throw WatchNoteError.clock }
            var highWater = now
            if let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key='watch.commandClock'") {
                guard let previous = try? JSONDecoder().decode(Date.self, from: Data(json.utf8)),
                      previous.timeIntervalSince1970.isFinite else { throw WatchNoteError.clock }
                highWater = max(previous, now)
            }
            guard command.createdAt.timeIntervalSince(now) <= 5 else { throw WatchNoteError.futureCommand }
            let clock = String(decoding: try encoder.encode(highWater), as: UTF8.self)
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES('watch.commandClock',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [clock])
            // Persist the high-water clock even on expiry: an evicted command cannot revive after rollback.
            guard highWater.timeIntervalSince(command.createdAt) <= 7 * 86_400 else { return .refused(.expired) }
            try db.execute(sql: "DELETE FROM watch_command_receipt WHERE recordedAt < ?", arguments: [highWater.addingTimeInterval(-14 * 86_400)])
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_command_receipt")! >= 4096 {
                // Only receipts beyond every command's validity window may make room at the reserve cap.
                try db.execute(sql: "DELETE FROM watch_command_receipt WHERE recordedAt < ?", arguments: [highWater.addingTimeInterval(-7 * 86_400)])
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_command_receipt")! < 4096 else { throw WatchNoteError.receiptCapacity }
            let result: WatchNoteResult
            if try Self.watchPrivacyBlocked(in: db) { result = .refused(.privacy) }
            else { result = try Self.applyWatchAction(command.action, now: now, in: db) }
            let stored: WatchReceiptOutcome
            switch result {
            case .refused(let refusal): stored = .refused(refusal)
            case .applied(let noteID, let revision), .appliedArchived(let noteID, let revision), .appliedTrashed(let noteID, let revision):
                if case .create = command.action { stored = .applied(revision: revision, createdNoteID: noteID) }
                else { stored = .applied(revision: revision, createdNoteID: nil) }
            }
            try db.execute(sql: "INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result,recordedAt) VALUES(?,?,?,?,?)",
                arguments: [command.epoch.uuidString, command.id.uuidString, request, try encoder.encode(stored), max(now, command.createdAt)])
            return result
        }
    }

    private static func watchPrivacyBlocked(in db: Database) throws -> Bool {
        for key in ["mobile.appLock", "appLockEnabled"] {
            guard let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [key]) else { continue }
            guard let enabled = try? JSONDecoder().decode(Bool.self, from: Data(json.utf8)), !enabled else { return true }
        }
        return false
    }

    private static func applyWatchAction(_ action: WatchNoteCommand.Action, now: Date, in db: Database) throws -> WatchNoteResult {
        func validText(_ text: String) -> Bool {
            text.utf8.count <= 16_384 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("\0")
        }
        if case .create(let text) = action {
            guard validText(text) else { return .refused(.invalidCommand) }
            let note = try insert(text: text, now: now, captureSource: .voice, in: db)
            return .applied(noteID: note.id, revision: note.revision)
        }
        let id: String, revision: Int
        switch action {
        case .append(let target, let expected, _), .setTask(let target, let expected, _, _, _, _): id = target; revision = expected
        case .create: preconditionFailure("Create handled above")
        }
        guard !id.isEmpty, id.utf8.count <= 256, !id.contains("\0"), revision >= 0, revision < Int.max - 1 else { return .refused(.invalidCommand) }
        guard let note = try Note.fetchOne(db, key: id), note.deletedAt == nil, note.location == .notes else { return .refused(.missingTarget) }
        guard !note.isLocked else { return .refused(.privacy) }
        guard !note.isReadOnly else { return .refused(.readOnly) }
        guard note.revision == revision else { return .refused(.staleTarget) }
        let text: String
        switch action {
        case .append(_, _, let addition):
            guard validText(addition), note.text.utf8.count + addition.utf8.count + 1 <= 1_048_576 else { return .refused(.invalidCommand) }
            text = note.text + "\n" + addition
        case .setTask(_, _, let hash, let offset, let marker, let checked):
            guard WatchNoteCommand.fingerprint(note.text) == hash,
                  ["[ ]", "[x]", "[X]"].contains(marker), offset >= 0,
                  offset <= note.text.utf16.count - 3,
                  let range = Range(NSRange(location: offset, length: 3), in: note.text),
                  String(note.text[range]) == marker else { return .refused(.staleTarget) }
            let line = note.text[..<range.lowerBound].unicodeScalars.filter { $0 == "\n" }.count + 1
            var flipped = note.text
            flipped.replaceSubrange(range, with: marker == "[ ]" ? "[x]" : "[ ]")
            guard TodoLines.toggled(note.text, line: line) == flipped else { return .refused(.staleTarget) }
            if checked == (marker != "[ ]") { return .applied(noteID: id, revision: revision) }
            text = flipped
        case .create: preconditionFailure("Create handled above")
        }
        let updated = try writeText(id: id, text: text, expectedRevision: revision, now: now, in: db)
        return .applied(noteID: id, revision: updated.revision)
    }
}
