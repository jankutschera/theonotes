// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

extension LibraryBackup {
    /// Daily SQLite recovery snapshot, retaining seven. Uses SQLite's online backup API;
    /// copying a live SQLite/WAL file is never safe. These are separate from portable archives.
    /// The writer serializes creation/cataloging against privacy transitions in other processes.
    @discardableResult public func createDailyDatabaseSnapshot(now: Date = .now) throws -> URL? {
        try database.pool.writeWithoutTransaction { db in
            let latest = try Date.fetchOne(db, sql: "SELECT MAX(createdAt) FROM backup_catalog WHERE filename LIKE '%.sqlite'")
            if let latest, now.timeIntervalSince(latest) < 86_400 { return nil }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM privacy_transition") == 0 else { throw BackupError.pendingFiles }
            let filename = "baerchen-\(UUIDv7.make(now: now)).sqlite"
            let output = paths.backups.appendingPathComponent(filename)
            var complete = false
            defer { if !complete { try? Self.removeManagedCopy(output) } }
            let destination = try DatabaseQueue(path: output.path)
            do {
                try destination.writeWithoutTransaction { target in
                    try db.backup(to: target, pagesPerStep: 256) { _ in try Task.checkCancellation() }
                    guard try String.fetchOne(target, sql: "PRAGMA integrity_check") == "ok" else { throw BackupError.invalidManifest }
                    try target.execute(sql: "PRAGMA journal_mode=DELETE")
                }
                try destination.close()
            } catch { try? destination.close(); throw error }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            let handle = try FileHandle(forWritingTo: output)
            try handle.synchronize(); try handle.close()
            let ids = try String.fetchAll(db, sql: "SELECT id FROM note WHERE isLocked=0")
            try db.execute(sql: "INSERT INTO backup_catalog(id,filename,createdAt,plaintextNoteIds) VALUES(?,?,?,?)",
                           arguments: [UUIDv7.make(), filename, now, String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)])
            complete = true
            for row in try Row.fetchAll(db, sql: "SELECT id,filename FROM backup_catalog WHERE filename LIKE '%.sqlite' ORDER BY createdAt DESC LIMIT -1 OFFSET 7") {
                let old: String = row["filename"]
                guard Self.isManagedName(old) else { throw BackupError.invalidManifest }
                let url = paths.backups.appendingPathComponent(old)
                try Self.removeManagedCopy(url)
                try db.execute(sql: "DELETE FROM backup_catalog WHERE id=?", arguments: [row["id"] as String])
            }
            return output
        }
    }
}
