// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import OSLog
import Testing
@testable import TheoNotesCore

struct PrivacyCanaryTests {
    private func unsafeSessionLogCallCount(in source: String) -> Int {
        let allowed = [#"\(self.fileURL.lastPathComponent, privacy: .public)"#, #"\(self.noteId, privacy: .public)"#,
                       #"\(attempt)"#, #"\(copy.id, privacy: .public)"#]
        return source.split(separator: "\n").filter { line in
            guard line.contains("sessionLogger") else { return false }
            if line.trimmingCharacters(in: .whitespaces) == #"let sessionLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "session")"# { return false }
            let stripped = allowed.reduce(String(line)) { $0.replacingOccurrences(of: $1, with: "") }
            // Deliberately narrow: one complete call with a fixed literal on one line.
            // Multiline/raw-string calls and escaped or unapproved interpolations fail closed.
            return stripped.range(of: #"^\s*sessionLogger\.(fault|error|notice)\("[^"\\]*"\)\s*$"#,
                                  options: .regularExpression) == nil
        }.count
    }

    private func unsafeLogInterpolationCount() throws -> Int {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ["EditJournal.swift", "NoteSession.swift"].reduce(0) { count, file in
            let source = try String(contentsOf: root.appendingPathComponent("Sources/TheoNotesCore/Session/" + file), encoding: .utf8)
            return count + unsafeSessionLogCallCount(in: source)
        }
    }

    @Test func sessionLogPolicyRejectsMultilineAndUnapprovedCalls() {
        #expect(unsafeSessionLogCallCount(in: #"sessionLogger.error("note \(self.noteId, privacy: .public): failed")"#) == 0)
        #expect(unsafeSessionLogCallCount(in: #"sessionLogger.error("error \(error)")"#) == 1)
        #expect(unsafeSessionLogCallCount(in: "sessionLogger.error(\n    \"unsafe interpolation\"\n)") == 1)
        #expect(unsafeSessionLogCallCount(in: "sessionLogger\n    .error(\"unsafe\")") == 1)
    }

    @Test func sessionLogsNeverInterpolateArbitraryErrorsOrReasons() throws {
        #expect(try unsafeLogInterpolationCount() == 0,
                "Only fixed diagnostics, note IDs and retry counts may be logged")
    }

    @Test func completeProtectionCanaryGate() async throws {
        // Abort before creating secrets if a future change restores payload interpolation.
        try #require(try unsafeLogInterpolationCount() == 0)
        let library = try PrivacyTestLibrary()
        defer { library.cleanup() }
        let started = Date.now.addingTimeInterval(-1)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let markers = ["body": "body" + token, "filename": "file" + token,
                       "ocr": "ocr" + token, "password": "password" + token,
                       "attachment": "attachment" + token, "journal": "journal" + token]
        let scanner = PrivacyCanaryScanner(markers: markers)
        // Positive controls use memory, never secret-marker logging (even with private OSLog).
        for (label, marker) in markers { #expect(scanner.hits(Data(marker.utf8)) == [label]) }
        #expect(scanner.hits(Data("harmless".utf8)).isEmpty)
        let body = markers["body"]!, filename = markers["filename"]! + ".png"
        let text = "# Permitted title\n\(body)\n## \(body)\n[[\(body)]]\n#permittedtag\n![](\(filename))"
        let note = try library.store.create(text: text)
        let watch = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(),
            action: .append(noteID: note.id, revision: note.revision, text: body))
        guard case .applied = try library.store.applyWatchCommand(watch) else { Issue.record("Watch fixture did not apply"); return }
        let invalidTarget = WatchNoteCommand(id: UUID(), epoch: watch.epoch,
            action: .append(noteID: body, revision: 1, text: "fixture"))
        #expect(try library.store.applyWatchCommand(invalidTarget) == .refused(.missingTarget))
        #expect(try library.store.applyWatchCommand(invalidTarget) == .refused(.missingTarget))
        let bytes = Data(markers["attachment"]!.utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: filename, to: note.id)
        try AttachmentTextStore(database: library.db).record(OCRJob(noteId: note.id, filename: filename), result:
            .text(markers["ocr"]!, sha256: "fixture-hash", byteSize: bytes.count, modifiedAt: .now))
        let thumb = library.paths.thumbnails.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: thumb, withIntermediateDirectories: true)
        try bytes.write(to: thumb.appendingPathComponent("fixture.preview"))
        // This application has no core file-log writer; an actual readable benign fixture
        // proves Logs is traversed while OSLog below exercises the production logger.
        let logSentinel = "m9-benign-collector-" + UUID().uuidString
        try Data(logSentinel.utf8).write(to: library.paths.logs.appendingPathComponent("collector.log"))
        let logScanner = PrivacyCanaryScanner(markers: ["sentinel": logSentinel])
        #expect(try logScanner.files(in: library.paths.logs) == ["sentinel"])
        try await library.db.pool.write {
            try $0.execute(sql: "INSERT INTO note_ui_state(noteId,foldState,selection) VALUES(?,?,?)",
                           arguments: [note.id, "[\"\(body)\"]", "{\"fixture\":\"\(body)\"}"])
            try $0.execute(sql: "UPDATE sync_control SET accountId = ? WHERE id = 1", arguments: ["fixture-account"])
        }
        let backup = LibraryBackup(database: library.db, paths: library.paths)
        let oldBackup = try backup.createRolling()
        let beforeArchive = try scanner.archive(oldBackup)
        #expect(beforeArchive.entries > 0)
        #expect(beforeArchive.hits.isSuperset(of: ["body", "filename", "ocr", "attachment"]))
        let privacy = NotePrivacy(store: library.store)
        try privacy.checkpoint()
        #expect(scanner.hits(try Data(contentsOf: library.paths.database)).contains("body"))
        let access = try library.access(password: markers["password"]!, iterations: CryptoEnvelope.publicIterationRange.lowerBound)
        let current = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: text + "\n" + body, expectedRevision: current.revision)
        // A plaintext history entry of the note: the lock below must seal it.
        _ = try #require(try library.store.takeSnapshot(noteId: note.id, text: text, now: .now))
        let snapshotHoldsBody = try await library.db.pool.read {
            try String.fetchOne($0, sql: "SELECT text FROM note_snapshot WHERE noteId = ?", arguments: [note.id])
        }?.contains(body) == true
        #expect(snapshotHoldsBody)
        let wal = URL(fileURLWithPath: library.paths.database.path + "-wal")
        #expect(scanner.hits(try Data(contentsOf: wal)).contains("body"))
        try await library.db.pool.write { db throws -> Void in
            let names = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'"))
            #expect(names == Set(PrivacyCanaryScanner.tablePolicy.keys))
            let receipt = try #require(try Row.fetchOne(db, sql: "SELECT requestMetadata,result FROM watch_command_receipt WHERE commandID=?", arguments: [watch.id.uuidString]))
            #expect(scanner.hits(Data((receipt["requestMetadata"] as String).utf8)).isEmpty)
            #expect(scanner.hits(receipt["result"] as Data).isEmpty)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_command_receipt") == 2)
            let allReceipts = try Row.fetchAll(db, sql: "SELECT requestMetadata,result FROM watch_command_receipt")
            for row in allReceipts {
                #expect(scanner.hits(Data((row["requestMetadata"] as String).utf8)).isEmpty)
                #expect(scanner.hits(row["result"] as Data).isEmpty)
            }
            #expect(try scanner.tables(db).isSuperset(of: ["body", "filename", "ocr"]))
            let bodyIndexed = try PrivacyCanaryScanner.vocabulary(db).contains(body)
            #expect(bodyIndexed)
            #expect(try !PrivacyCanaryScanner.vocabulary(db, trigram: true).isEmpty)
            for table in ["heading", "wiki_link", "note_stats", "note_search_content", "note_ui_state"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")! > 0)
            }
        }
        #expect(try scanner.files(in: thumb) == ["attachment"])
        let reader = try library.pinnedReader()
        defer { try? reader.close() }
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id) }
        #expect(try library.pendingCount() == 1)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        let cleanup = Task { try await privacy.finishPendingCleanupWithRetry() }
        try await Task.sleep(for: .milliseconds(250))
        try await reader.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        try await cleanup.value
        #expect(try library.pendingCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: oldBackup.path))
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        let privateNote = try #require(try access.note(id: note.id))
        try journal.writeBase(JournalBase(storeRevision: privateNote.revision, baseText: privateNote.text))
        let entry = JournalEntry(txId: "fixture", baseRevision: 0,
            changeSet: ChangeSet(sections: [.retain(privateNote.text.utf16.count), .replace(deleteLength: 0, insert: markers["journal"]!)]))
        try journal.append(entry)
        let sealedEditRoundTrips = try journal.entries() == [entry]
        #expect(sealedEditRoundTrips)
        #expect(try Data(contentsOf: journal.fileURL).starts(with: Data("BJE1:".utf8)))
        #expect(try Data(contentsOf: journal.baseURL).starts(with: Data("BJB1:".utf8)))
        // Exercise a real session-log failure with a secret-bearing Error after the source
        // policy gate forbids interpolation. The thrown error remains available to the caller.
        struct FixtureError: Error, CustomStringConvertible { let description: String }
        journal.faultInjector = { _, _ in throw FixtureError(description: markers["password"]!) }
        #expect(throws: FixtureError.self) { try journal.append(entry) }
        #expect(journal.isPoisoned)
        journal.faultInjector = nil
        try await library.db.pool.write { db throws -> Void in
            #expect(try scanner.tables(db).isEmpty)
            #expect(try PrivacyCanaryScanner.vocabulary(db).isEmpty)
            #expect(try PrivacyCanaryScanner.vocabulary(db, trigram: true).isEmpty)
            #expect(try String.fetchOne(db, sql: "SELECT title FROM note WHERE id = ?", arguments: [note.id]) == "Permitted title")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_tag WHERE noteId = ?", arguments: [note.id]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_dirty")! > 0)
        }
        let remainingBackups = try backup.localBackups()
        #expect(!remainingBackups.isEmpty)
        for copy in remainingBackups {
            let scanned = try scanner.archive(copy.url)
            #expect(scanned.entries > 0 && scanned.hits.isEmpty)
            #expect(try backup.inspect(copy.url).lockedNoteCount == 1)
        }
        #expect(try scanner.files(in: library.paths.root).isEmpty)
        let logger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "privacy-test-probe")
        logger.notice("Collector probe \(logSentinel, privacy: .public)")
        let fault = "journal \(journal.fileURL.lastPathComponent): rollback failed, poisoned"
        let messages = try await PrivacyCanaryScanner.applicationLogs(since: started, sentinel: logSentinel, fault: fault)
        let observedProductionFailure = messages.contains { $0.contains(fault) }
        #expect(observedProductionFailure)
        #expect(scanner.hits(Data(messages.joined(separator: "\n").utf8)).isEmpty)
    }
}
