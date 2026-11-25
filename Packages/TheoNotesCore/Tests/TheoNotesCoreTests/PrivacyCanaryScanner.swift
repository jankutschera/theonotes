// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import OSLog
import ZIPFoundation
import Testing
@testable import TheoNotesCore

/// Reports labels only: failed assertions must never print the secret being sought.
struct PrivacyCanaryScanner {
    let markers: [String: String]
    func hits(_ data: Data) -> Set<String> {
        Set(markers.compactMap { label, marker in data.range(of: Data(marker.utf8)) == nil ? nil : label })
    }
    func files(in root: URL) throws -> Set<String> {
        var found = Set<String>()
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            found.formUnion(hits(Data(file.lastPathComponent.utf8)))
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            found.formUnion(hits(try Data(contentsOf: file)))
            if file.pathExtension == "baerchen-backup" { found.formUnion(try archive(file).hits) }
        }
        return found
    }
    func archive(_ url: URL) throws -> (hits: Set<String>, entries: Int) {
        let archive = try Archive(url: url, accessMode: .read)
        var found = Set<String>(), count = 0
        for entry in archive where entry.type == .file {
            count += 1
            found.formUnion(hits(Data(entry.path.utf8)))
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            found.formUnion(hits(bytes))
        }
        return (found, count)
    }
    func tables(_ db: Database) throws -> Set<String> {
        var found = Set<String>()
        for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'") {
            // Identifiers originate in SQLite, quoted even when a new unclassified table appears.
            let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
            for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(quoted)\"") {
                for (_, value) in row {
                    if let text = String.fromDatabaseValue(value) { found.formUnion(hits(Data(text.utf8))) }
                    if let bytes = Data.fromDatabaseValue(value) { found.formUnion(hits(bytes)) }
                }
            }
        }
        return found
    }
    static func vocabulary(_ db: Database, trigram: Bool = false) throws -> [String] {
        let table = trigram ? "note_fts_trigram" : "note_fts"
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS temp.\(table)_vocab USING fts5vocab(main, \(table), row)")
        return try String.fetchAll(db, sql: "SELECT term FROM temp.\(table)_vocab")
    }

    /// No wildcard acceptance: new application or FTS shadow tables require privacy review.
    static let tablePolicy: [String: String] = [
        "note": "ciphertext plus permitted title/tags/IDs/dates; no body/subtitle",
        "attachment": "opaque blob names; no OCR or original file facts",
        "crypto_envelope": "wrapped key only", "privacy_transition": "opaque names; empty after cleanup",
        "heading": "purged", "wiki_link": "purged", "note_stats": "purged",
        "note_search_content": "purged", "note_ui_state": "purged",
        "note_fts": "purged", "note_fts_data": "rebuilt", "note_fts_idx": "rebuilt",
        "note_fts_docsize": "rebuilt", "note_fts_config": "secure-delete enabled",
        "note_fts_trigram": "purged", "note_fts_trigram_data": "rebuilt",
        "note_fts_trigram_idx": "rebuilt", "note_fts_trigram_docsize": "rebuilt",
        "note_fts_trigram_config": "secure-delete enabled",
        "tag": "permitted visible tags", "note_tag": "permitted tag membership",
        "note_pin": "permitted pin membership", "workspace": "permitted tag recents",
        "setting": "preferences, no note/password/key data", "external_ref": "IDs and source hash",
        "staging_batch": "opaque staging, empty after cleanup", "backup_catalog": "backup names and IDs",
        "sync_control": "account/control metadata", "sync_dirty": "IDs and generations",
        "sync_entity_state": "IDs and revisions", "sync_outbox": "encrypted wire payload",
        "sync_shadow": "encrypted wire payload", "sync_cursor": "sequence",
        "sync_device": "wrapped account key/device metadata", "sync_blob_state": "encrypted blobs",
        "sync_attachment_cache": "encrypted descriptor/opaque fingerprint",
        "sync_inbox": "encrypted wire payload", "sync_conflict": "IDs and revisions",
        "sync_receipt": "mutation ID/hash", "sync_import_cleanup": "note IDs",
        "focus_hide": "IDs, line hashes of unlocked notes, dates; purged on lock",
        "note_ping": "IDs, line anchors of unlocked notes, dates; one title-only row per locked note",
        "note_snapshot": "plaintext of unlocked notes, sealed for locked notes",
        "capture_receipt": "IDs and dates",
        "watch_command_receipt": "command/epoch IDs, action kind, dates and outcome; create result may include its generated note ID; no target ID or text",
        "notification_ledger": "random notification ids, ping/note IDs, content hashes of unlocked notes only, dates",
        "ck_state": "account/zone control metadata and opaque engine state; no note content",
        "ck_record": "change-tag archive and sealed ancestor ciphertext; IDs, versions",
        "ck_inflight": "sealed snapshot ciphertext; IDs, generations",
        "ck_send_result": "opaque save outcome; no note content",
        "ck_remote": "sealed ciphertext or pinned-file path; IDs, versions",
        "ck_quarantine": "record fields as received (ciphertext only); pinned-file paths",
        "ck_missing": "IDs and versions", "ck_blob_part": "blob part hashes and sizes",
        "grdb_migrations": "migration IDs", "sqlite_sequence": "SQLite counters"
    ]

    /// Own process and app subsystem only. A successful empty collector is impossible.
    static func applicationLogs(since start: Date, sentinel: String, fault: String) async throws -> [String] {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: start), matching:
                NSPredicate(format: "subsystem == %@", "com.truebrewbirdie.baerchen"))
            let messages = entries.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            if messages.contains(where: { $0.contains(sentinel) }),
               messages.contains(where: { $0.contains(fault) }) { return messages }
        }
        throw LogCollectorError.requiredRecordsNotObserved
    }
    enum LogCollectorError: Error { case requiredRecordsNotObserved }
}
