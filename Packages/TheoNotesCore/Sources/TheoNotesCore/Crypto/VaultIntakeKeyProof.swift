// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public struct VaultIntakeLockedNotesMismatch: LocalizedError, Sendable {
    public let count: Int
    public static func partialMessage(count: Int) -> String {
        "\(count) protected \(count == 1 ? "note cannot" : "notes cannot") be opened with the current notes password. Their encrypted contents are kept."
    }
    public var errorDescription: String? {
        "\(count) locked \(count == 1 ? "note is" : "notes are") protected by a different notes password or key. To continue, find and permanently delete those notes, including any in Trash. Their contents will be lost."
    }
}

/// Journals stay recoverable as files; only existing locked note rows can block installing a key.
enum VaultIntakeKeyProof {
    static func unopenableCount(key: SymmetricKey, in db: Database) throws -> (Int, Int) {
        let rows = try Row.fetchAll(db, sql: "SELECT id,encryptedPayload FROM note WHERE isLocked=1 AND encryptedPayload IS NOT NULL")
        var mismatched = 0
        for row in rows {
            let id: String = row["id"], sealed: Data = row["encryptedPayload"]
            if (try? NoteCipher.open(sealed, vaultKey: key, context: id)) == nil { mismatched += 1 }
        }
        return (mismatched, rows.count)
    }

    static func requireMatch(key: SymmetricKey, in db: Database) throws {
        let (mismatched, total) = try unopenableCount(key: key, in: db)
        if total > 0 && mismatched == total { throw VaultIntakeLockedNotesMismatch(count: mismatched) }
    }
}
