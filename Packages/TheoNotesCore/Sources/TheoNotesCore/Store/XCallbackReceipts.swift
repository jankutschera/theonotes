// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import os

/// Creating link requests whose answer may not have reached the caller.
/// A `create` is recorded the moment it succeeds and settled once the app has handed its answer
/// back; a request that comes again while its receipt is open gets the first note instead of a
/// second one. Device-local (a `setting` row outside the sync and backup allowlists), at most
/// `capacity` entries, each for at most `lifetime`: expired entries are removed when the library
/// opens and before every lookup and write.
public struct XCallbackReceipts: Sendable {
    public static let lifetime: TimeInterval = 3600
    public static let capacity = 32
    static let key = "xcallback.receipts"
    private static let log = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "xcallback")

    struct Entry: Codable, Equatable {
        var fingerprint: String
        var noteID: String
        var recordedAt: Date
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// What identifies a request: its action and parameters, minus the callback targets and the
    /// token, plus the clipboard text when the request reads it.
    public static func fingerprint(action: String, parameters: [String: String], clipboard: String?) -> String {
        let ignored: Set<String> = ["x-success", "x-error", "x-cancel", "token"]
        var fields = [action]
        for (name, value) in parameters.sorted(by: { $0.key < $1.key }) where !ignored.contains(name) {
            fields += [name, value]
        }
        if let clipboard { fields += ["\u{1}clipboard", clipboard] }
        let encoded = fields.map { String($0.utf8.count) + ":" + $0 }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The note an open, unexpired receipt names, if that note is still in the library outside the
    /// Trash (`LibraryQueries.item`'s rule; an archived note counts).
    public func noteID(for fingerprint: String, now: Date) -> String? {
        var found: String?
        update(now: now) { entries, db in
            guard let entry = entries.last(where: { $0.fingerprint == fingerprint }) else { return }
            if try LibraryQueries.item(id: entry.noteID, db: db) != nil { found = entry.noteID }
        }
        return found
    }

    public func record(_ fingerprint: String, noteID: String, now: Date) {
        update(now: now) { entries, _ in
            entries.removeAll { $0.fingerprint == fingerprint }
            entries.append(Entry(fingerprint: fingerprint, noteID: noteID, recordedAt: now))
        }
    }

    /// The answer reached the caller: a later identical request is a new one.
    public func settle(_ fingerprint: String, now: Date = .now) {
        update(now: now) { entries, _ in entries.removeAll { $0.fingerprint == fingerprint } }
    }

    /// Library open: drops expired entries even if no request ever comes again.
    static func removeExpired(in pool: any DatabaseWriter, now: Date = .now) {
        do {
            try pool.write { try prune(in: $0, now: now) { _, _ in } }
        } catch {
            log.error("x-callback receipts not pruned: \(error)")
        }
    }

    var count: Int { (try? database.pool.read { try Self.entries(in: $0).count }) ?? 0 }

    private func update(now: Date, _ change: (inout [Entry], Database) throws -> Void) {
        do {
            try database.pool.write { try Self.prune(in: $0, now: now, change) }
        } catch {
            // Losing a receipt only loses the duplicate guard; the request itself already succeeded.
            Self.log.error("x-callback receipts not saved: \(error)")
        }
    }

    /// Applies `change` to the live entries and writes the row back when anything differs.
    private static func prune(in db: Database, now: Date, _ change: (inout [Entry], Database) throws -> Void) throws {
        let stored = try entries(in: db)
        // One dated after `now` (a clock set back) counts as expired too.
        var entries = stored.filter { $0.recordedAt <= now && now.timeIntervalSince($0.recordedAt) < lifetime }
        try change(&entries, db)
        entries = Array(entries.suffix(capacity))
        guard entries != stored else { return }
        let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        try db.execute(
            sql: "INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            arguments: [key, json])
    }

    private static func entries(in db: Database) throws -> [Entry] {
        guard let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [key]) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: Data(json.utf8))) ?? []
    }
}
