// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Testing
@testable import TheoNotesCore

@Suite @MainActor struct JournalRecoveryScanEvaluationTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func plainPair(_ id: String, directory: URL, suffix: String = "") throws {
        let base = JournalBase(storeRevision: 0, baseText: "Base")
        let entry = JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")]))
        try JSONEncoder().encode(base).write(to: directory.appendingPathComponent("\(id).base\(suffix)"))
        var bytes = try JSONEncoder().encode(entry); bytes.append(10)
        try bytes.write(to: directory.appendingPathComponent("\(id).jsonl\(suffix)"))
    }
    @Test func classifiesSingleAndExistingMovedAsideWithoutChangingFiles() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try plainPair("missing", directory: dir)
        try plainPair("existing", directory: dir, suffix: ".unreplayed")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let before = try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        let inventory = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: ["existing"], liveSessionIDs: [])
        let result = JournalRecoveryScan.classify(inventory, directory: dir, protection: .unprotected, access: nil)
        let missing = try #require(result.groups.first { $0.sourceID == "missing" })
        let existing = try #require(result.groups.first { $0.sourceID == "existing" })
        #expect(missing.disposition == .single(suffix: ""))
        #expect(existing.disposition == .existingMovedAside)
        #expect(missing.blockers.isEmpty && existing.blockers.isEmpty)
        #expect(result.unassociatedMarkers.isEmpty)
        #expect(try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) } == before)
    }
    @Test func readableLoneBaseMustBeSavedBeforeAnyQuarantine() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Saved text"))
            .write(to: dir.appendingPathComponent("lone.base.unreplayed"))
        let inventory = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: [], liveSessionIDs: [])
        let result = JournalRecoveryScan.classify(inventory, directory: dir, protection: .unprotected, access: nil)
        #expect(result.groups.first?.disposition == .loneBase(suffix: ".unreplayed"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lone.base.unreplayed").path))
    }
    @Test func dirtyLiveSessionAndPendingKeyStayOrthogonal() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let inventory = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: [], liveSessionIDs: ["orphan"])
        let result = JournalRecoveryScan.classify(inventory, directory: dir, protection: .waitingForSyncKey, access: nil, dirtyLiveSessionIDs: ["orphan"])
        let group = try #require(result.groups.first)
        #expect(!group.sourceExists && group.hasLiveSession)
        #expect(group.blockers.contains(.activeSession) && group.blockers.contains(.waitingForSyncKey))
        #expect(group.disposition == .none)
    }
    @Test func knownMarkerBlocksOnlyItsSourceAndUnknownMarkersRemainVisible() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try plainPair("blocked", directory: dir)
        try plainPair("other", directory: dir)
        let hash = SHA256.hash(data: Data("blocked".utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = ".variant-confirm-\(hash).json"
        try Data("marker".utf8).write(to: dir.appendingPathComponent(marker))
        try Data("unknown".utf8).write(to: dir.appendingPathComponent(".retirement-unmatched.json"))
        let inventory = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: [], liveSessionIDs: [])
        let result = JournalRecoveryScan.classify(inventory, directory: dir, protection: .unprotected, access: nil)
        let blocked = try #require(result.groups.first { $0.sourceID == "blocked" })
        #expect(blocked.blockers.contains(.pendingMarker) && blocked.disposition == .none)
        #expect(blocked.markerNames == [marker])
        #expect(result.groups.first { $0.sourceID == "other" }?.disposition == .single(suffix: ""))
        #expect(result.unassociatedMarkers == [".retirement-unmatched.json"])
    }
    @Test func syntheticTraversalAndMismatchedFilesFailClosed() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let inputs: [JournalRecoveryScan.Group] = [
            .init(sourceID: "../outside", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "../outside.jsonl", kind: .journal, suffix: "")]),
            .init(sourceID: "safe", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "../outside.jsonl", kind: .journal, suffix: "")]),
            .init(sourceID: "back\\slash", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "back\\slash.jsonl", kind: .journal, suffix: "")]),
            .init(sourceID: "null\0byte", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "null\0byte.jsonl", kind: .journal, suffix: "")]),
            .init(sourceID: "duplicate", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "duplicate.base", kind: .base, suffix: ""),
                          .init(name: "duplicate.base", kind: .base, suffix: "")]),
            .init(sourceID: "wrong-kind", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "wrong-kind.base", kind: .journal, suffix: "")]),
            .init(sourceID: "wrong-source", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "other.jsonl", kind: .journal, suffix: "")]),
            .init(sourceID: "wrong-suffix", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "wrong-suffix.jsonl.unreplayed", kind: .journal, suffix: "")]),
            .init(sourceID: "bad-suffix", sourceExists: false, hasLiveSession: false,
                  files: [.init(name: "bad-suffix.jsonl/../outside", kind: .journal, suffix: "/../outside")])
        ]
        let snapshot = JournalRecoveryScan.Snapshot(groups: inputs, markers: [])
        let result = JournalRecoveryScan.classify(snapshot, directory: dir, protection: .unprotected, access: nil)
        #expect(result.groups.count == inputs.count)
        for group in result.groups {
            #expect(group.blockers.contains(.unavailable))
            #expect(group.disposition == .none)
            #expect(group.committed.isEmpty && group.pendingActions.isEmpty)
        }
    }
    @Test func readFailureIsPerGroupAndNeverCreatesQuarantineAction() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try plainPair("good", directory: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("bad.jsonl").path, withDestinationPath: "/not-a-real-journal")
        try Data("{}".utf8).write(to: dir.appendingPathComponent("bad.base"))
        let inventory = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: [], liveSessionIDs: [])
        let result = JournalRecoveryScan.classify(inventory, directory: dir, protection: .unprotected, access: nil)
        #expect(result.groups.first { $0.sourceID == "bad" }?.blockers.contains(.unavailable) == true)
        #expect(result.groups.first { $0.sourceID == "bad" }?.disposition == JournalRecoveryScan.Disposition.none)
        #expect(result.groups.first { $0.sourceID == "good" }?.disposition == .single(suffix: ""))
    }
    @Test func authenticatedSealedPairIsRecoverableOnlyWithUnlockedAccess() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access()
        let id = "sealed-fixture"
        let journal = try EditJournal(directory: library.paths.journal, noteId: id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Base"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")])))
        let inventory = try JournalRecoveryScan.inventory(directory: library.paths.journal, existingNoteIDs: [], liveSessionIDs: [])
        let missingEnvelope = JournalRecoveryScan.classify(inventory, directory: library.paths.journal, protection: .unprotected, access: nil)
        #expect(missingEnvelope.groups.first?.blockers.contains(.waitingForSyncKey) == true)
        #expect(missingEnvelope.groups.first?.blockers.contains(.unlockRequired) == false)
        let locked = JournalRecoveryScan.classify(inventory, directory: library.paths.journal, protection: .locked, access: nil)
        #expect(locked.groups.first?.blockers.contains(.unlockRequired) == true)
        let unlocked = JournalRecoveryScan.classify(inventory, directory: library.paths.journal, protection: .unlocked, access: access)
        #expect(unlocked.groups.first?.disposition == .single(suffix: ""))
    }
    @Test func multiplePlainPairingsAreVariantsAndLockedBytesNeedUnlock() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try plainPair("plain", directory: dir)
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Else")).write(to: dir.appendingPathComponent("plain.base.unreplayed"))
        try Data("BJB1:invalid".utf8).write(to: dir.appendingPathComponent("sealed.base"))
        try Data("BJE1:invalid\n".utf8).write(to: dir.appendingPathComponent("sealed.jsonl"))
        let inventory = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: [], liveSessionIDs: [])
        let plain = JournalRecoveryScan.classify(inventory, directory: dir, protection: .unprotected, access: nil)
        #expect(plain.groups.first { $0.sourceID == "plain" }?.disposition == .variants)
        let result = JournalRecoveryScan.classify(inventory, directory: dir, protection: .locked, access: nil)
        #expect(result.groups.first { $0.sourceID == "plain" }?.disposition == JournalRecoveryScan.Disposition.none)
        #expect(result.groups.first { $0.sourceID == "sealed" }?.blockers.contains(.unlockRequired) == true)
        #expect(result.groups.first { $0.sourceID == "sealed" }?.disposition == JournalRecoveryScan.Disposition.none)
    }
}
