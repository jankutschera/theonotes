// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import GRDB
import Testing
import TheoNotesCore
import UIKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileEditorRecoveryTests {
    @Test func failedJournalRecoveryBlocksUntilExplicitRetrySucceeds() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let journal = paths.journal.appendingPathComponent("\(id).jsonl")
        let valid = try Data(contentsOf: journal)
        try Data("broken\n".utf8).write(to: journal)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(throws: MobileMissingJournalRecoveryError.self) { try library.requireSyncRecoveryReady() }
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
        try valid.write(to: journal)
        library.retryMissingJournalRecovery()
        #expect(!library.recoveredJournalNotices.isEmpty)
        try library.requireSyncRecoveryReady() // committed copy permits sync even with leftovers
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
    }
    @Test func failedRecoveryRemainsBlockedAfterRelaunchAndRetriesOnLaunch() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let journal = paths.journal.appendingPathComponent("\(id).jsonl")
        let valid = try Data(contentsOf: journal)
        try Data("broken\n".utf8).write(to: journal)
        do {
            let library = try MobileLibrary(paths: paths)
            #expect(throws: MobileMissingJournalRecoveryError.self) { try library.requireSyncRecoveryReady() }
            try? library.close()
        }
        do {
            let library = try MobileLibrary(paths: paths)
            #expect(throws: MobileMissingJournalRecoveryError.self) { try library.requireSyncRecoveryReady() }
            try? library.close()
        }
        try valid.write(to: journal)
        let recovered = try MobileLibrary(paths: paths)
        defer { try? recovered.close() }
        #expect(!recovered.recoveredJournalNotices.isEmpty)
        try recovered.requireSyncRecoveryReady()
    }
    @Test func unavailableJournalDirectoryBlocksUntilRetry() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let saved = paths.root.appendingPathComponent("journal temporarily unavailable")
        try FileManager.default.moveItem(at: paths.journal, to: saved)
        library.retryMissingJournalRecovery()
        #expect(library.missingJournalRecoveryUnresolved)
        #expect(throws: MobileMissingJournalRecoveryError.self) { try library.requireSyncRecoveryReady() }
        try FileManager.default.moveItem(at: saved, to: paths.journal)
        library.retryMissingJournalRecovery()
        #expect(!library.missingJournalRecoveryUnresolved)
        try library.requireSyncRecoveryReady()
    }
    @Test func onlyDamagedJournalOffersMoveAsideAndKeepsOriginalBytes() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let journalName = "\(id).jsonl", baseName = "\(id).base"
        let journalURL = paths.journal.appendingPathComponent(journalName)
        let bad = Data("broken\n".utf8)
        try bad.write(to: journalURL)
        let base = try Data(contentsOf: paths.journal.appendingPathComponent(baseName))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let plan = try library.prepareJournalQuarantine()
        #expect(Set(plan.fileNames) == Set([journalName, baseName]))
        try await library.moveJournalFilesAfterConfirmation(plan)
        let folder = paths.root.appendingPathComponent("Recovery/Quarantine", isDirectory: true)
        let dirs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let saved = try #require(dirs.first)
        #expect(try Data(contentsOf: saved.appendingPathComponent(journalName)) == bad)
        #expect(try Data(contentsOf: saved.appendingPathComponent(baseName)) == base)
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(library.recoveryMessage?.contains("separately") == true)
    }
    @Test func quarantineStopsWhenDamagedJournalBecomesReadableAfterPrompt() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let url = paths.journal.appendingPathComponent("\(id).jsonl")
        let valid = try Data(contentsOf: url)
        try Data("broken\n".utf8).write(to: url)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let plan = try library.prepareJournalQuarantine()
        try valid.write(to: url)
        await #expect(throws: (any Error).self) { try await library.moveJournalFilesAfterConfirmation(plan) }
        #expect(try Data(contentsOf: url) == valid)
        #expect(library.quarantinableJournalFiles.isEmpty)
        #expect(!library.recoveredJournalNotices.isEmpty)
    }
    @Test func ambiguousPlainPairsBecomeVariantsBeforeBackup() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let extraName = "\(id).base.unreplayed"
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Else")).write(to: paths.journal.appendingPathComponent(extraName))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let notice = try #require(library.recoveredVariantNotices.first)
        #expect(notice.noteIDs.count == 2)
        for id in notice.noteIDs {
            #expect(try library.store.note(id: id)?.text.contains("pairing is uncertain") == true)
        }
        #expect(library.quarantinableJournalFiles.isEmpty)
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
        try await library.removeRecoveredVariantAfterConfirmation(id: notice.id)
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
        for id in notice.noteIDs { #expect(try library.store.note(id: id) != nil) }
    }
    @Test func restoredSourcePreventsVariantUnlinkAndAllowsNormalReplay() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Else")).write(to: paths.journal.appendingPathComponent("\(id).base.unreplayed"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let notice = try #require(library.recoveredVariantNotices.first)
        let journal = paths.journal.appendingPathComponent("\(id).jsonl")
        let before = try Data(contentsOf: journal)
        try await library.database.pool.write { db in
            let date = Date()
            try Note(id: id, text: "Base", title: "", titleKey: "", createdAt: date, modifiedAt: date, revision: 0).insert(db)
        }
        await #expect(throws: (any Error).self) { try await library.removeRecoveredVariantAfterConfirmation(id: notice.id) }
        #expect(try Data(contentsOf: journal) == before)
        let session = try library.session(for: id)
        try session.flush()
        #expect(try library.store.note(id: id)?.text == "Base saved")
        for noteID in notice.noteIDs { #expect(try library.store.note(id: noteID) != nil) }
        library.retryMissingJournalRecovery()
        #expect(library.quarantinableJournalFiles == ["\(id).base.unreplayed"])
        let plan = try library.prepareJournalQuarantine()
        try await library.moveJournalFilesAfterConfirmation(plan)
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    @Test func sealedAmbiguousGroupRequiresUnlockBeforeMoveAside() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: true)
        let base = paths.journal.appendingPathComponent("\(id).base")
        try FileManager.default.copyItem(at: base, to: paths.journal.appendingPathComponent("\(id).base.unreplayed"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(library.quarantinableJournalFiles.isEmpty)
        #expect(throws: (any Error).self) { try library.prepareJournalQuarantine() }
        try await library.unlockNotes(password: "fixture")
        #expect(library.recoveredVariantNotices.isEmpty)
        #expect(Set(library.quarantinableJournalFiles) == Set(["\(id).jsonl", "\(id).base", "\(id).base.unreplayed"]))
        let plan = try library.prepareJournalQuarantine()
        try await library.moveJournalFilesAfterConfirmation(plan)
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    @Test func sealedAuthenticationFailureOfferedOnlyAfterUnlock() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: true)
        let url = paths.journal.appendingPathComponent("\(id).jsonl")
        var bytes = try Data(contentsOf: url)
        let index = bytes.index(bytes.startIndex, offsetBy: 8)
        bytes[index] = bytes[index] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        try bytes.write(to: url)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(library.quarantinableJournalFiles.isEmpty)
        try await library.unlockNotes(password: "fixture")
        #expect(library.quarantinableJournalFiles.contains("\(id).jsonl"))
        let plan = try library.prepareJournalQuarantine()
        try await library.moveJournalFilesAfterConfirmation(plan)
        let root = paths.root.appendingPathComponent("Recovery/Quarantine")
        let folder = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: folder.appendingPathComponent("\(id).jsonl")) == bytes)
    }
    @Test func abortedVariantRemainderNeverReplaysOntoRestoredSource() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let baseName = "\(id).base"
        let baseURL = paths.journal.appendingPathComponent(baseName)
        let bytes = try Data(contentsOf: baseURL)
        try FileManager.default.removeItem(at: paths.journal.appendingPathComponent("\(id).jsonl"))
        let db = try AppDatabase(path: paths.database)
        try await db.pool.write { db in
            let now = Date()
            try Note(id: id, text: "Restored source", title: "", titleKey: "", createdAt: now, modifiedAt: now).insert(db)
        }
        try db.pool.close()
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = try JSONSerialization.data(withJSONObject: ["noteId": id, "files": [baseName]])
        try marker.write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(throws: (any Error).self) { try library.session(for: id) }
        try library.requireSyncRecoveryReady()
        let notice = try #require(library.recoveredVariantNotices.first)
        #expect(notice.sourceMustExist && !notice.noteIDs.isEmpty)
        #expect(try Data(contentsOf: baseURL) == bytes)
        for recoveryID in notice.noteIDs { #expect(try library.store.note(id: recoveryID) != nil) }
        try await library.removeRecoveredVariantAfterConfirmation(id: notice.id)
        let session = try library.session(for: id)
        #expect(session.text == "Restored source")
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: id, store: library.store).isEmpty)
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    @Test func abortedCompletePairIsSavedSeparatelyBeforeRestoredSourceReopens() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let names = ["\(id).base", "\(id).jsonl"]
        let original = try names.map { try Data(contentsOf: paths.journal.appendingPathComponent($0)) }
        let db = try AppDatabase(path: paths.database)
        try await db.pool.write { db in
            let now = Date()
            try Note(id: id, text: "Restored source", title: "", titleKey: "", createdAt: now, modifiedAt: now).insert(db)
        }
        try db.pool.close()
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = try JSONSerialization.data(withJSONObject: ["noteId": id, "files": names])
        try marker.write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(try library.store.note(id: id)?.text == "Restored source")
        #expect(throws: (any Error).self) { try library.session(for: id) }
        #expect(try names.map { try Data(contentsOf: paths.journal.appendingPathComponent($0)) } == original)
        let notice = try #require(library.recoveredVariantNotices.first)
        #expect(notice.sourceMustExist && !notice.noteIDs.isEmpty)
        try await library.removeRecoveredVariantAfterConfirmation(id: notice.id)
        let session = try library.session(for: id)
        #expect(session.text == "Restored source")
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    @Test func readablePlainJournalRecoversWithoutQuarantineOffer() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = try seedMissingJournal(paths: paths, protected: false)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(!library.recoveredJournalNotices.isEmpty)
        #expect(library.quarantinableJournalFiles.isEmpty)
        #expect(throws: (any Error).self) { try library.prepareJournalQuarantine() }
    }
    @Test func confirmedQuarantineResumesAfterRelaunchAndKeepsBytes() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let journalName = "\(id).jsonl", baseName = "\(id).base"
        let bad = Data("damaged journal".utf8)
        try bad.write(to: paths.journal.appendingPathComponent(journalName))
        let base = try Data(contentsOf: paths.journal.appendingPathComponent(baseName))
        let selection = try JournalQuarantine.inspect(libraryRoot: paths.root, fileNames: [journalName, baseName])
        let confirmed = try JournalQuarantine.confirm(selection)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(throws: MobileMissingJournalRecoveryError.self) { try library.requireSyncRecoveryReady() }
        try await library.resumeConfirmedJournalQuarantines()
        #expect(try Data(contentsOf: confirmed.directory.appendingPathComponent(journalName)) == bad)
        #expect(try Data(contentsOf: confirmed.directory.appendingPathComponent(baseName)) == base)
        #expect(!FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent(journalName).path))
        try library.requireSyncRecoveryReady()
        #expect(library.recoveryMessage?.contains("separately") == true)
    }
    @Test func oversizedRecoveryJournalDoesNotPreventLibraryLaunch() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let url = paths.journal.appendingPathComponent("\(id).jsonl")
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 64 * 1_024 * 1_024 + 1)
        try file.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(library.missingJournalRecoveryUnresolved)
        #expect(library.quarantinableJournalFiles.isEmpty)
        #expect(throws: MobileMissingJournalRecoveryError.self) { try library.requireSyncRecoveryReady() }
    }
    @Test(arguments: [".variant-confirm-", ".variant-aborted-"])
    func variantMarkerBlocksOnlyItsNoteDuringLibraryLaunch(prefix: String) throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: nil, paths: paths)
        let blocked = try store.create(text: "Blocked original")
        let other = try store.create(text: "Other note")
        let journal = try EditJournal(directory: paths.journal, noteId: blocked.id)
        try journal.writeBase(JournalBase(storeRevision: blocked.revision, baseText: "Blocked original"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(16), .replace(deleteLength: 0, insert: " edit")])))
        let journalURL = paths.journal.appendingPathComponent("\(blocked.id).jsonl")
        let before = try Data(contentsOf: journalURL)
        let hash = SHA256.hash(data: Data(blocked.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data("invalid marker".utf8).write(to: paths.journal.appendingPathComponent(prefix + hash + ".json"))
        try db.pool.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(try library.store.note(id: blocked.id)?.text == "Blocked original")
        #expect(try Data(contentsOf: journalURL) == before)
        #expect(throws: (any Error).self) { try library.session(for: blocked.id) }
        let otherSession = try library.session(for: other.id)
        #expect(otherSession.text == "Other note")
        try library.requireSyncRecoveryReady()
        #expect(library.recoveryMessage != nil)
    }
    @Test func ordinaryOpenNoteJournalDoesNotBlockBackupAsVariantRemainder() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let note = try library.store.create(text: "Original")
        let session = try library.session(for: note.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(8), .replace(deleteLength: 0, insert: " edited")]), origin: nil) == .acked(revision: 1))
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try library.store.note(id: note.id)?.text == "Original edited")
    }
    @Test func unlockingSkipsOnlyLockedNoteWithPartialVariantMarker() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: nil, paths: paths)
        let access = try NotePrivacy(store: store).setPassword("fixture")
        let source = try store.create(text: "Protected source")
        let other = try store.create(text: "Other protected note")
        try access.lock(noteId: source.id)
        try access.lock(noteId: other.id)
        let journal = try EditJournal(directory: paths.journal, noteId: source.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "Protected source"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(16), .replace(deleteLength: 0, insert: " edit")])))
        let names = ["\(source.id).jsonl", "\(source.id).base"]
        let before = try names.map { try Data(contentsOf: paths.journal.appendingPathComponent($0)) }
        let hash = SHA256.hash(data: Data(source.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = try JSONSerialization.data(withJSONObject: ["noteId": source.id, "files": names])
        try marker.write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        access.revoke()
        try db.pool.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.unlockNotes(password: "fixture")
        let unlockedAccess = try #require(library.privateAccess)
        #expect(try unlockedAccess.note(id: other.id)?.text == "Other protected note")
        #expect(try unlockedAccess.note(id: source.id)?.text == "Protected source")
        #expect(throws: (any Error).self) { try library.session(for: source.id) }
        #expect(try names.map { try Data(contentsOf: paths.journal.appendingPathComponent($0)) } == before)
        #expect(library.recoveredVariantNotices.contains { $0.sourceID == source.id && $0.sourceMustExist })
    }
    @Test func damagedLockedJournalDoesNotRelockOtherNotesAndOffersMoveAside() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: nil, paths: paths)
        let access = try NotePrivacy(store: store).setPassword("fixture")
        let source = try store.create(text: "Protected source")
        let other = try store.create(text: "Other protected note")
        try access.lock(noteId: source.id); try access.lock(noteId: other.id)
        let journal = try EditJournal(directory: paths.journal, noteId: source.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "Protected source"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(16), .replace(deleteLength: 0, insert: " edit")])))
        let url = paths.journal.appendingPathComponent("\(source.id).jsonl")
        var bytes = try Data(contentsOf: url)
        let index = bytes.index(bytes.startIndex, offsetBy: 8)
        bytes[index] = bytes[index] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        try bytes.write(to: url)
        access.revoke(); try db.pool.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.unlockNotes(password: "fixture")
        let unlocked = try #require(library.privateAccess)
        #expect(try unlocked.note(id: other.id)?.text == "Other protected note")
        #expect(try unlocked.note(id: source.id)?.text == "Protected source")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(library.quarantinableJournalFiles.contains("\(source.id).jsonl"))
        let plan = try library.prepareJournalQuarantine()
        try await library.moveJournalFilesAfterConfirmation(plan)
        #expect(try unlocked.note(id: source.id)?.text == "Protected source")
    }
    @Test func committedRecoveryNoticeDoesNotBlockExclusiveSync() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = try seedMissingJournal(paths: paths, protected: false)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(!library.recoveredJournalNotices.isEmpty)
        try SyncQueue(database: library.database).configure(accountID: "account")
        let transport = MobileSyncResponsivenessTests.GatedTransport()
        let engine = SyncEngine(database: library.database, paths: paths, accountID: "account", vaultKey: SymmetricKey(size: .bits256),
                                transport: transport, blobs: MobileSyncResponsivenessTests.NoBlobs())
        _ = try await library.synchronize(using: engine, exclusive: true)
        #expect(!library.recoveredJournalNotices.isEmpty)
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
        await engine.shutdown()
    }
    @Test func damagedRetirementMarkerOffersMoveAsideThatUnblocksBackup() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let name = ".retirement-" + String(repeating: "a", count: 64) + ".json"
        let marker = paths.journal.appendingPathComponent(name)
        try Data("invalid".utf8).write(to: marker)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(library.recoveryMessage?.localizedCaseInsensitiveContains("recovery") == true)
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
        #expect(library.quarantinableMarkers == [name])
        let plan = try library.prepareJournalQuarantine()
        try await library.moveJournalFilesAfterConfirmation(plan)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    private func seedMissingJournal(paths: AppPaths, protected: Bool) throws -> String {
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close() }
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        let access = protected ? try NotePrivacy(store: store).setPassword("fixture") : nil
        let id = UUID().uuidString.lowercased()
        let journal = try EditJournal(directory: paths.journal, noteId: id, encryptionKey: try access?.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Base"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " saved")])))
        return id
    }

    @Test(arguments: [false, true])
    func launchRecoversMissingJournalOrWaitsForUnlock(protected: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: protected)
        let journalURL = paths.journal.appendingPathComponent("\(id).jsonl")
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        if protected {
            #expect(FileManager.default.fileExists(atPath: journalURL.path))
            #expect(library.recoveryMessage?.localizedCaseInsensitiveContains("unlock") == true)
            await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
            try await library.unlockNotes(password: "fixture")
            let copy = try #require(try library.store.allNotes().first)
            #expect(copy.isLocked && copy.text.isEmpty)
            #expect(try #require(library.privateAccess).note(id: copy.id)?.text == "Base saved")
        } else {
            #expect(try library.store.allNotes().first?.text == "Base saved")
        }
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        let notice = try #require(library.recoveredJournalNotices.first)
        try library.removeRecoveredJournalAfterConfirmation(id: notice.id)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }
    @Test func protectedLeftoverCannotBeRemovedAfterKeyRevocation() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: true)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.unlockNotes(password: "fixture")
        let notice = try #require(library.recoveredJournalNotices.first)
        try #require(library.privateAccess).revoke()
        #expect(throws: MobileMissingJournalRecoveryError.unlockRequired) { try library.removeRecoveredJournalAfterConfirmation(id: notice.id) }
        #expect(FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(id).jsonl").path))
        #expect(FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(id).base").path))
    }
    @Test func resetWithProtectedPendingJournalsStopsOnChangedSecondPair() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = try seedMissingJournal(paths: paths, protected: true)
        do {
            let db = try AppDatabase(path: paths.database)
            let store = NoteStore(db: db, notifier: nil, paths: paths)
            let access = try NotePrivacy(store: store).unlock(password: "fixture")
            let journal = try EditJournal(directory: paths.journal, noteId: UUID().uuidString.lowercased(), encryptionKey: access.journalKey())
            try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Second"))
            try journal.append(JournalEntry(txId: "two", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: " edit")])))
            access.revoke()
            try db.pool.close()
        }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let plan = try library.prepareResetJournalDiscard()
        #expect(plan.items.count == 2)
        let first = try #require(plan.items.first), second = try #require(plan.items.last)
        let secondURL = paths.journal.appendingPathComponent("\(second.noteID).jsonl\(second.suffix)")
        let valid = try Data(contentsOf: secondURL)
        try (valid + Data(" ".utf8)).write(to: secondURL)
        await #expect(throws: (any Error).self) { try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan) }
        let stillHasPassword = try NotePrivacy(store: library.store).hasPassword
        #expect(stillHasPassword)
        // Every pair is re-validated before the first unlink, so nothing was discarded.
        #expect(FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(first.noteID).jsonl\(first.suffix)").path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        try valid.write(to: secondURL)
        let retry = try library.prepareResetJournalDiscard()
        try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(retry)
        let passwordAfterReset = try NotePrivacy(store: library.store).hasPassword
        #expect(!passwordAfterReset)
    }
    @Test func confirmedResetInvalidatesRetainedEvictedHolderBeforeDeletingJournal() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let source = try library.store.create(text: "Original")
        let access = try #require(library.privateAccess)
        try access.lock(noteId: source.id)
        // This retained session is deliberately outside the host cache, just like an old holder
        // after eviction. The weak Core registry must still locate and invalidate it.
        let held = try NoteSession(noteId: source.id, store: access, journalDirectory: paths.journal,
                                   journalKey: access.journalKey(), commitDelay: .seconds(60))
        #expect(held.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [source.id]) }
        access.revoke()
        let plan = try library.prepareResetJournalDiscard()
        try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan)
        #expect(held.isInvalidated)
        #expect(held.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: []), origin: nil) == .needsFullText(currentRevision: held.revision))
        #expect(throws: NoteSessionError.sessionClosed) { try held.flush() }
        #expect(!FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(source.id).jsonl").path))
    }
    @Test func resetConsentExpiresWhenRetainedHolderChangesRevision() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let source = try library.store.create(text: "Original")
        let access = try #require(library.privateAccess)
        try access.lock(noteId: source.id)
        let held = try NoteSession(noteId: source.id, store: access, journalDirectory: paths.journal,
                                   journalKey: access.journalKey(), commitDelay: .seconds(60))
        #expect(held.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [source.id]) }
        access.revoke()
        let plan = try library.prepareResetJournalDiscard()
        #expect(held.apply(txId: "two", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(7), .replace(deleteLength: 0, insert: "!")]), origin: nil) == .acked(revision: 2))
        let url = paths.journal.appendingPathComponent("\(source.id).jsonl")
        let bytes = try Data(contentsOf: url)
        await #expect(throws: NoteSessionFenceError.stale) { try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan) }
        #expect(!held.isInvalidated && held.text == "Unsaved!")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try NotePrivacy(store: library.store).hasPassword)
    }
    @Test(arguments: [false, true])
    func ramOnlyOrphanResetRequiresCurrentExplicitSessionFence(stale: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        // S3: only protected RAM-only text is ever part of the reset discard.
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let source = try library.store.create(text: "Original")
        let access = try #require(library.privateAccess)
        try access.lock(noteId: source.id)
        let session = try library.session(for: source.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        access.revoke()
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [source.id]) }
        try? FileManager.default.removeItem(at: paths.journal.appendingPathComponent("\(source.id).jsonl"))
        try? FileManager.default.removeItem(at: paths.journal.appendingPathComponent("\(source.id).base"))
        #expect(throws: MobileMissingJournalRecoveryError.unlockRequired) { try library.requireNoOrphanSessionsBeforeEviction() }
        let plan = try library.prepareResetJournalDiscard()
        #expect(plan.ramOnlyNoteIDs == [source.id])
        if stale {
            #expect(session.apply(txId: "two", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(7), .replace(deleteLength: 0, insert: "!")]), origin: nil) == .acked(revision: 2))
            await #expect(throws: NoteSessionFenceError.stale) { try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan) }
            #expect(!session.isInvalidated && session.text == "Unsaved!")
            #expect(library.hasCachedSession(for: source.id))
            #expect(try NotePrivacy(store: library.store).hasPassword)
        } else {
            try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan)
            #expect(session.isInvalidated && !library.hasCachedSession(for: source.id))
            #expect(throws: NoteSessionError.sessionClosed) { try session.flush() }
            let hasPassword = try NotePrivacy(store: library.store).hasPassword
            #expect(!hasPassword)
        }
    }
    @Test func ramOnlyResetDoesNotInvalidateIfSourceReappears() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let original = try library.store.create(text: "Original")
        let access = try #require(library.privateAccess)
        try access.lock(noteId: original.id)
        let session = try library.session(for: original.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        access.revoke()
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [original.id]) }
        try? FileManager.default.removeItem(at: paths.journal.appendingPathComponent("\(original.id).jsonl"))
        try? FileManager.default.removeItem(at: paths.journal.appendingPathComponent("\(original.id).base"))
        let plan = try library.prepareResetJournalDiscard()
        try await library.database.pool.write { db in
            let now = Date()
            try Note(id: original.id, text: "Restored", title: "", titleKey: "", createdAt: now, modifiedAt: now).insert(db)
        }
        await #expect(throws: (any Error).self) { try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan) }
        #expect(!session.isInvalidated && session.text == "Unsaved")
        #expect(library.hasCachedSession(for: original.id))
        #expect(try library.store.note(id: original.id)?.text == "Restored")
    }
    @Test func unlockedReplayFailureIsRetryableAndTryAgainReplays() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id: String
        do {
            try paths.createDirectories()
            let database = try AppDatabase(path: paths.database)
            defer { try? database.pool.close() }
            let store = NoteStore(db: database, notifier: nil, paths: paths)
            let access = try NotePrivacy(store: store).setPassword("fixture")
            let note = try store.create(text: "base")
            try access.lock(noteId: note.id)
            id = note.id
            let journal = try EditJournal(directory: paths.journal, noteId: id, encryptionKey: access.journalKey())
            try journal.writeBase(JournalBase(storeRevision: try #require(try store.note(id: id)).revision, baseText: "base"))
            try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
            access.revoke()
        }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try await library.database.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_replay BEFORE UPDATE ON note BEGIN SELECT RAISE(ABORT, 'test'); END") }
        try await library.unlockNotes(password: "fixture")
        #expect(library.privateAccess != nil && !library.awaitsMissingJournalSyncKey)
        #expect(library.recoveryMessage?.localizedCaseInsensitiveContains("unlock") == false)
        #expect(library.recoveryMessage?.localizedCaseInsensitiveContains("try again") == true)
        try await library.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_replay") }
        library.retryMissingJournalRecovery()
        #expect(!library.missingJournalRecoveryUnresolved)
        #expect(try library.privateAccess?.note(id: id)?.text == "base!")
    }
    /// Q2: plain RAM-only text of a deleted note is never discarded by a reset and is saved once the vault is gone.
    private func plainRamOnlyOrphan(_ library: MobileLibrary, paths: AppPaths) async throws -> (id: String, session: NoteSession) {
        let note = try library.store.create(text: "Original")
        let session = try library.session(for: note.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Plain unsaved")]), origin: nil) == .acked(revision: 1))
        let id = note.id
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) }
        for name in [id + ".jsonl", id + ".base"] { try? FileManager.default.removeItem(at: paths.journal.appendingPathComponent(name)) }
        return (id, session)
    }
    @Test func plainResetKeepsPlainRamOnlyOrphanAndSavesItAfterVaultIsGone() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        try SyncQueue(database: library.database).enable(accountID: "account")  // B5: a synced library
        try await library.unlockNotes(password: "fixture", createPassword: true)
        // Held weakly, as in the app: only the library cache owns the orphan session.
        weak var orphanSession: NoteSession?
        let orphanID: String
        do { let orphan = try await plainRamOnlyOrphan(library, paths: paths); orphanID = orphan.id; orphanSession = orphan.session }
        try #require(library.privateAccess).revoke()  // the password is forgotten
        try await library.deleteNotesPassword()
        #expect(try !NotePrivacy(store: library.store).hasPassword)
        #expect(try library.store.allNotes().filter { $0.text == "Plain unsaved" }.count == 1)
        #expect(orphanSession?.isInvalidated != true && !library.hasCachedSession(for: orphanID))
        #expect(!library.awaitsMissingJournalSyncKey)
        try library.requireSyncRecoveryReady()
    }
    @Test func confirmedResetDiscardsSealedPairButSavesPlainRamOnlyOrphan() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sealed = try seedMissingJournal(paths: paths, protected: true)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let orphan = try await plainRamOnlyOrphan(library, paths: paths)
        let plan = try library.prepareResetJournalDiscard()
        #expect(plan.items.map(\.noteID) == [sealed] && plan.ramOnlyNoteIDs.isEmpty)
        try await library.deleteNotesPasswordAfterConfirmedJournalDiscard(plan)
        #expect(try !NotePrivacy(store: library.store).hasPassword)
        #expect(!FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(sealed).jsonl").path))
        #expect(try library.store.allNotes().filter { $0.text == "Plain unsaved" }.count == 1)
        #expect(!orphan.session.isInvalidated && !library.hasCachedSession(for: orphan.id))
    }
    @Test func resetNeverDiscardsPlainPendingJournal() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(throws: (any Error).self) { try library.prepareResetJournalDiscard() }
        #expect(FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(id).jsonl").path))
    }
    @Test func launchKeepsJournalWhileSyncKeyIsPending() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let database = try AppDatabase(path: paths.database)
        try await database.pool.write { db in try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')") }
        try database.pool.close()
        let journalURL = paths.journal.appendingPathComponent("\(id).jsonl")
        let before = try Data(contentsOf: journalURL)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(library.recoveryMessage?.localizedCaseInsensitiveContains("another device") == true)
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
        let accepted = try await library.recoverPendingSyncKey(scan: { () -> Bool? in
            #expect(!library.sceneEditorAdmissionBlocked)  // S7: the download holds no fence
            let capturedJournal = try Data(contentsOf: journalURL)
            #expect(capturedJournal == before)
            return nil
        }, install: { _ in Issue.record("nothing was found to install"); return false })
        #expect(!accepted && !library.libraryOperationBusy)
        #expect(try Data(contentsOf: journalURL) == before)
    }
    @Test func pendingJournalRecoversAfterAnEnabledSyncInstallsEnvelope() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: true)
        let database = try AppDatabase(path: paths.database)
        let envelope = try await database.pool.write { db -> Data in
            let data = try #require(try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"))
            try db.execute(sql: "DELETE FROM crypto_envelope")
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')")
            return data
        }
        try database.pool.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(library.awaitsMissingJournalSyncKey)
        try await library.database.pool.write { db in try db.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [envelope]) }
        try library.refreshMissingJournalRecovery()
        #expect(!library.awaitsMissingJournalSyncKey)
        #expect(library.recoveryMessage?.localizedCaseInsensitiveContains("unlock") == true)
        try await library.unlockNotes(password: "fixture")
        let saved = try #require(try library.store.allNotes().first)
        let recoveredText = try #require(library.privateAccess).note(id: saved.id)?.text
        #expect(saved.isLocked && recoveredText == "Base saved")
        #expect(FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(id).jsonl").path))
    }
    @Test func fencedKeyIntakePrecedesRecoveryConfirmationAndRealBackup() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: true)
        let initial = try AppDatabase(path: paths.database)
        let envelope = try await initial.pool.write { db -> Data in
            let data = try #require(try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"))
            try db.execute(sql: "DELETE FROM crypto_envelope")
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')")
            return data
        }
        try initial.pool.close()
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let existing = try library.store.create(text: "Existing note")
        let before = try library.store.allNotes()
        let journalURL = paths.journal.appendingPathComponent("\(id).jsonl")
        let journalBefore = try Data(contentsOf: journalURL)
        let installed = try await library.recoverPendingSyncKey(scan: { () -> Bool? in
            #expect(!library.sceneEditorAdmissionBlocked)
            return true
        }, install: { _ in
            #expect(library.sceneEditorAdmissionBlocked && !library.libraryOperationBusy)
            try await library.database.pool.write { db in try db.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [envelope]) }
            #expect(try library.store.allNotes() == before)
            #expect(try Data(contentsOf: journalURL) == journalBefore)
            return true
        })
        #expect(installed && !library.libraryOperationBusy)
        try await library.unlockNotes(password: "fixture")
        #expect(try library.store.note(id: existing.id)?.text == "Existing note")
        let notice = try #require(library.recoveredJournalNotices.first)
        await #expect(throws: MobileMissingJournalRecoveryError.self) { try await library.makeBackup() }
        // A failed backup rescans and issues a fresh hash-bound notice.
        let refreshed = try #require(library.recoveredJournalNotices.first)
        #expect(notice.sourceID == refreshed.sourceID)
        try library.removeRecoveredJournalAfterConfirmation(id: refreshed.id)
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    @Test func launchRecoversUniquelyPairedMovedAsideJournal() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        for suffix in ["jsonl", "base"] {
            let original = paths.journal.appendingPathComponent("\(id).\(suffix)")
            try FileManager.default.moveItem(at: original, to: paths.journal.appendingPathComponent("\(id).\(suffix).unreplayed"))
        }
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        #expect(try library.store.allNotes().first?.text == "Base saved")
        let notice = try #require(library.recoveredJournalNotices.first)
        try library.removeRecoveredJournalAfterConfirmation(id: notice.id)
        #expect(!FileManager.default.fileExists(atPath: paths.journal.appendingPathComponent("\(id).jsonl.unreplayed").path))
    }
    @Test func changedLeftoverIsRecoveredAgainAndNeverRemoved() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = try seedMissingJournal(paths: paths, protected: false)
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let notice = try #require(library.recoveredJournalNotices.first)
        let url = paths.journal.appendingPathComponent("\(id).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8)); try handle.close()
        #expect(throws: (any Error).self) { try library.removeRecoveredJournalAfterConfirmation(id: notice.id) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test(arguments: ["edited", "trashed", "hardDeleted"])
    func recoveryCopyChangesKeepLeftoverRemovalSafe(change: String) throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sourceID = try seedMissingJournal(paths: paths, protected: false)
        let journalURL = paths.journal.appendingPathComponent("\(sourceID).jsonl")
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close() }
        let notice = try #require(library.recoveredJournalNotices.first)
        let copy = try #require(try library.store.note(id: notice.noteID))
        switch change {
        case "edited": _ = try library.store.updateText(id: copy.id, text: "User edited recovery", expectedRevision: copy.revision, now: .now)
        case "trashed": try library.store.trash([copy.id])
        default: try library.store.deletePermanently([copy.id])
        }
        if change == "hardDeleted" {
            #expect(throws: (any Error).self) { try library.removeRecoveredJournalAfterConfirmation(id: notice.id) }
            #expect(FileManager.default.fileExists(atPath: journalURL.path))
            let replacement = try #require(library.recoveredJournalNotices.first)
            #expect(replacement.noteID != copy.id)
        } else {
            try library.removeRecoveredJournalAfterConfirmation(id: notice.id)
            #expect(!FileManager.default.fileExists(atPath: journalURL.path))
            #expect(try library.store.note(id: copy.id) != nil)
        }
    }
    @Test(arguments: ["edited", "trashed"])
    func recoveredCopyRemainsValidAcrossForegroundRetryAndRelaunch(change: String) throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = try seedMissingJournal(paths: paths, protected: false)
        var copyID = ""
        do {
            let library = try MobileLibrary(paths: paths)
            let notice = try #require(library.recoveredJournalNotices.first)
            let copy = try #require(try library.store.note(id: notice.noteID))
            copyID = copy.id
            if change == "edited" {
                _ = try library.store.updateText(id: copy.id, text: "User edited recovery", expectedRevision: copy.revision, now: .now)
            } else { try library.store.trash([copy.id]) }
            library.retryMissingJournalRecovery()
            #expect(library.recoveredJournalNotices.first?.noteID == copyID)
            try library.requireSyncRecoveryReady()
            try? library.close()
        }
        let reopened = try MobileLibrary(paths: paths)
        defer { try? reopened.close() }
        #expect(reopened.recoveredJournalNotices.first?.noteID == copyID)
        try reopened.requireSyncRecoveryReady()
        let notice = try #require(reopened.recoveredJournalNotices.first)
        try reopened.removeRecoveredJournalAfterConfirmation(id: notice.id)
        #expect(try reopened.store.note(id: copyID) != nil)
    }
    @Test func passwordChangeKeepsUnlockedOrphanRecoveryUsable() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        try await library.unlockNotes(password: "old password", createPassword: true)
        let note = try library.store.create(text: "Original")
        let access = try #require(library.privateAccess)
        try NotePrivacy(store: library.store).changePassword(from: "old password", to: "new password")
        try await library.acceptNotePasswordRewrap("new password")
        let id = note.id
        try await library.database.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) }
        let recovered = try access.preserveBrowserRecovery(noteId: id, text: "Recovery", baseRevision: 0, now: .now)
        #expect(try access.note(id: recovered.note.id)?.text == "Recovery")
        #expect(recovered.note.isLocked)
    }
    @Test func protectedSessionWhoseSourceBecamePlainIsRecoveredSealed() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let note = try library.store.create(text: "Original")
        try library.lockNote(note.id)
        let session = try library.session(for: note.id)
        #expect(session.wasOriginallyLocked)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Protected orphan")]), origin: nil) == .acked(revision: 1))
        let id = note.id
        try await library.database.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked=0, encryptedPayload=NULL, text='Original' WHERE id=?", arguments: [id])
        }
        try library.requireNoOrphanSessionsBeforeEviction()
        let copy = try #require(try library.store.allNotes().first { $0.id != id })
        #expect(copy.isLocked && copy.text.isEmpty)
        #expect(try #require(library.privateAccess).note(id: copy.id)?.text == "Protected orphan")
    }
    @Test func pendingVaultWithoutEnvelopeWaitsForKeyWithoutDiscard() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        let session = try library.session(for: note.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        try library.database.pool.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id])
            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')")
        }
        #expect(throws: MobileMissingJournalRecoveryError.waitingForSyncKey) { try library.requireNoOrphanSessionsBeforeEviction() }
        #expect(session.text == "Unsaved")
    }
    @Test func refreshSkipsDeletedSessionWithoutBlockingOtherChanges() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let orphan = try library.store.create(text: "Original"), other = try library.store.create(text: "Other")
        let session = try library.session(for: orphan.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")]), origin: nil) == .acked(revision: 1))
        let external = try AppDatabase(path: paths.database)
        defer { try? external.pool.close() }
        try NoteStore(db: external, notifier: nil, paths: paths).deletePermanently([orphan.id])
        _ = try library.store.updateText(id: other.id, text: "Changed", expectedRevision: other.revision, now: .now)
        try library.refreshSessions()
        #expect(session.text == "Unsaved" && library.hasCachedSession(for: orphan.id))
        #expect(try library.store.note(id: other.id)?.text == "Changed")
    }
    @Test func orphanSessionIsSealedBeforeCloseWhenVaultIsUnlocked() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let original = try library.store.create(text: "Original")
        let session = try library.session(for: original.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Secret orphan")]), origin: nil) == .acked(revision: 1))
        let external = try AppDatabase(path: paths.database)
        defer { try? external.pool.close() }
        try NoteStore(db: external, notifier: nil, paths: paths).deletePermanently([original.id])
        try library.close()
        let reopened = try AppDatabase(path: paths.database)
        defer { try? reopened.pool.close() }
        let store = NoteStore(db: reopened, notifier: nil, paths: paths)
        let stored = try #require(try store.allNotes().first)
        #expect(stored.isLocked && stored.text.isEmpty)
        let access = try NotePrivacy(store: store).unlock(password: "fixture")
        #expect(try access.note(id: stored.id)?.text == "Secret orphan")
    }
    @Test func hardDeleteWithoutVaultKeyRequiresUnlockAndRetainsRAMText() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original")
        let session = try library.session(for: original.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "RAM-only")]), origin: nil) == .acked(revision: 1))
        let access = try NotePrivacy(store: library.store).setPassword("fixture")
        access.revoke()
        let external = try AppDatabase(path: paths.database)
        defer { try? external.pool.close() }
        try NoteStore(db: external, notifier: nil, paths: paths).deletePermanently([original.id])
        #expect(throws: MobileMissingJournalRecoveryError.unlockRequired) { try library.close() }
        #expect(session.text == "RAM-only" && library.hasCachedSession(for: original.id))
        #expect(!library.isClosed)
    }
    @Test func cleanDeletedCachedNoteIsNotResurrectedOnClose() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Deleted deliberately")
        _ = try library.session(for: original.id)
        let external = try AppDatabase(path: paths.database)
        defer { try? external.pool.close() }
        try NoteStore(db: external, notifier: nil, paths: paths).deletePermanently([original.id])
        try library.close()
        let reopened = try AppDatabase(path: paths.database)
        defer { try? reopened.pool.close() }
        #expect(try NoteStore(db: reopened, notifier: nil, paths: paths).allNotes().isEmpty)
    }
    @Test func confirmedDiscardOnlyClosesTheBoundPage() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original")
        let editor = MobileEditor(library: library)
        try editor.open(original.id)
        let page = ObjectIdentifier(editor.webView), generation = editor.documentLoadGeneration
        #expect(!editor.discardBrowserTextAfterConfirmation(noteID: original.id, pageID: page, documentGeneration: generation + 1))
        #expect(!editor.isClosedForPrivacy && editor.session?.noteId == original.id)
        #expect(editor.discardBrowserTextAfterConfirmation(noteID: original.id, pageID: page, documentGeneration: generation))
        #expect(editor.isClosedForPrivacy && editor.session == nil)
    }
    @Test func orphanDoesNotBlockOtherSessionFlushAndRemainsRecoverable() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original")
        let orphan = try library.session(for: original.id)
        #expect(orphan.apply(txId: "orphan-edit", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Pending orphan")]), origin: nil) == .acked(revision: 1))
        let externalDatabase = try AppDatabase(path: paths.database)
        defer { try? externalDatabase.pool.close() }
        let externalStore = NoteStore(db: externalDatabase, notifier: nil, paths: paths)
        try externalStore.deletePermanently([original.id])
        let other = try library.store.create(text: "Other")
        _ = try library.session(for: other.id)
        try library.flush()
        #expect(library.hasCachedSession(for: original.id))
        #expect(orphan.text == "Pending orphan")
        try library.close()
        let reopened = try AppDatabase(path: paths.database)
        defer { try? reopened.pool.close() }
        let store = NoteStore(db: reopened, notifier: nil, paths: paths)
        #expect(try store.allNotes().contains { $0.text == "Pending orphan" })
    }
    @Test func privacyRecoveryAttemptsOtherScenesAfterAFailure() async {
        var attempted: [Int] = []
        let attempts: [@MainActor () async -> Bool] = [
            { attempted.append(1); return false },
            { attempted.append(2); return true },
        ]
        let result = await MobileLibrary.attemptPrivacyRecoveries(attempts, deadline: Date().addingTimeInterval(3))
        #expect(!result)
        #expect(attempted == [1, 2])
    }
    @Test func privacyRecoveryDoesNotStartWhenBudgetIsTooShort() async throws {
        let now = Date()
        #expect(MobileEditor.privacyRecoveryCanStart(deadline: now.addingTimeInterval(0.31), now: now))
        #expect(!MobileEditor.privacyRecoveryCanStart(deadline: now.addingTimeInterval(0.3), now: now))
        #expect(!MobileEditor.privacyRecoveryCanStart(deadline: now.addingTimeInterval(-1), now: now))
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original")
        let editor = MobileEditor(library: library)
        try editor.open(original.id)
        #expect(!(await editor.preserveBrowserTextBeforePrivacyClose(deadline: Date().addingTimeInterval(0.2))))
        #expect(try library.store.allNotes().count == 1)
    }
    @Test func protectedRecoveryRequiresTheLiveOriginalKey() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Protected original")
        try await library.unlockNotes(password: "browser-recovery-test", createPassword: true)
        let access = try #require(library.privateAccess)
        try access.lock(noteId: original.id)
        let editor = MobileEditor(library: library)
        try editor.open(original.id)
        #expect(try editor.preserveBrowserRecovery(noteId: original.id, baseRevision: 0, text: "Protected browser text") == .acked(revision: 0))
        let copies = try library.store.allNotes().filter { $0.id != original.id }
        let copy = try #require(copies.first)
        #expect(copies.count == 1 && copy.isLocked && copy.text.isEmpty)
        #expect(try access.note(id: copy.id)?.text == "Protected browser text")
        access.revoke()
        #expect(throws: (any Error).self) {
            try editor.preserveBrowserRecovery(noteId: original.id, baseRevision: 0, text: "No plaintext fallback")
        }
        #expect(try library.store.allNotes().count == 2)
    }
    @Test func recoveryAfterSourceBecomesLockedIsNeverPlaintext() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original")
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let editor = MobileEditor(library: library)
        try editor.open(original.id)
        let access = try #require(library.privateAccess)
        let externalDatabase = try AppDatabase(path: paths.database)
        defer { try? externalDatabase.pool.close() }
        let externalStore = NoteStore(db: externalDatabase, notifier: nil, paths: paths)
        try NotePrivacy(store: externalStore).unlock(password: "fixture").lock(noteId: original.id)
        #expect(try editor.preserveBrowserRecovery(noteId: original.id, baseRevision: 0, text: "Browser secret") == .acked(revision: 0))
        let copy = try #require(try library.store.allNotes().first { $0.id != original.id })
        #expect(copy.isLocked && copy.text.isEmpty)
        #expect(try access.note(id: copy.id)?.text == "Browser secret")
    }
    @Test func protectionMismatchDisablesTheExistingEditorBeforeRebind() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original")
        try await library.unlockNotes(password: "fixture", createPassword: true)
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(original.id)
        for _ in 0..<200 where !editor.ready || !editor.editable { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.ready && editor.editable)
        for _ in 0..<200 {
            if (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String == "Original" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let externalDatabase = try AppDatabase(path: paths.database)
        defer { try? externalDatabase.pool.close() }
        let externalStore = NoteStore(db: externalDatabase, notifier: nil, paths: paths)
        try NotePrivacy(store: externalStore).unlock(password: "fixture").lock(noteId: original.id)
        let page = editor.webView
        editor.loadNote()
        #expect(!page.isUserInteractionEnabled)
        #expect(!editor.editable)
        #expect(editor.session?.wasOriginallyLocked == false)
        let before = try await page.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()") as? String
        editor.command(.insertText, args: ["text": .string("must not be written")])
        try await Task.sleep(for: .milliseconds(100))
        let after = try await page.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()") as? String
        #expect(before == "Original" && after == before)
        #expect(editor.session?.text == "Original")
    }
    @Test func recoveryKeepsOriginalIdentityAcrossSelectionAndRepeatedAcknowledgement() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let original = try library.store.create(text: "Original"), other = try library.store.create(text: "Other")
        let editor = MobileEditor(library: library)
        try editor.open(original.id)
        #expect(try editor.preserveBrowserRecovery(noteId: original.id, baseRevision: 0, text: "Unacknowledged original") == .acked(revision: 0))
        #expect(try editor.preserveBrowserRecovery(noteId: original.id, baseRevision: 0, text: "Unacknowledged original") == .acked(revision: 0))
        #expect(try library.store.allNotes().filter { $0.text == "Unacknowledged original" }.count == 1)
        try editor.open(other.id)
        #expect(throws: (any Error).self) {
            try editor.preserveBrowserRecovery(noteId: original.id, baseRevision: 0, text: "Unacknowledged original")
        }
        #expect(editor.session?.noteId == other.id)
        #expect(try library.store.note(id: original.id)?.text == "Original")
        #expect(try library.store.note(id: other.id)?.text == "Other")
        #expect(try library.store.allNotes().filter { $0.text == "Unacknowledged original" }.count == 1)
        #expect(throws: (any Error).self) {
            try editor.preserveBrowserRecovery(noteId: UUID().uuidString, baseRevision: 0, text: "Unknown source")
        }
    }
}
