// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Testing
@testable import TheoNotesCore

@Suite struct JournalRecoveryFilesTests {
    @Test func suffixesAndPlainReplayMatchRecoveryRules() throws {
        #expect(JournalRecoveryFiles.validSuffix(""))
        #expect(JournalRecoveryFiles.validSuffix(".unreplayed"))
        #expect(JournalRecoveryFiles.validSuffix(".unreplayed.12"))
        #expect(!JournalRecoveryFiles.validSuffix(".unreplayed.no"))
        let base = try JSONEncoder().encode(JournalBase(storeRevision: 1, baseText: "base"))
        let entry = JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")]))
        let line = try JSONEncoder().encode(entry)
        #expect(JournalRecoveryFiles.replayPlain(base: base, journal: line + Data("\n".utf8)) == "base!")
        #expect(JournalRecoveryFiles.replayPlain(base: base, journal: line) == nil)
        #expect(JournalRecoveryFiles.replayPlain(base: Data("bad".utf8), journal: line + Data("\n".utf8)) == nil)
    }

    @Test func scanGroupsFilesAndLiveSessionsWithoutChangingDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["a.jsonl", "a.base", "a.base.unreplayed.2", "ignored.txt"]
        for name in names { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
        let before = try names.map { name in
            let url = dir.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (try Data(contentsOf: url), attributes[.modificationDate] as? Date, attributes[.posixPermissions] as? NSNumber)
        }
        let snapshot = try JournalRecoveryScan.inventory(directory: dir, existingNoteIDs: ["a"], liveSessionIDs: ["a", "b"])
        #expect(snapshot.groups.map(\.sourceID) == ["a", "b"])
        #expect(snapshot.groups[0].source == .liveSession && snapshot.groups[0].sourceExists && snapshot.groups[0].hasLiveSession && snapshot.groups[0].files.count == 3)
        #expect(snapshot.groups[1].source == .liveSession && !snapshot.groups[1].sourceExists && snapshot.groups[1].hasLiveSession && snapshot.groups[1].files.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == names.sorted())
        for (index, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(try Data(contentsOf: url) == before[index].0)
            #expect((attributes[.modificationDate] as? Date) == before[index].1)
            #expect((attributes[.posixPermissions] as? NSNumber) == before[index].2)
        }
    }

    @Test func digestKeepsExistingPurposeDomains() {
        let bytes = Data("fixture".utf8), key = SymmetricKey(data: Data(repeating: 42, count: 32))
        for info in ["journal-variants-v1", "editor-journal-recovery-hash-v1", "editor-journal-recovery-removal-v1", "editor-journal-recovery-marker-v1"] {
            let previous = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("note-id".utf8), info: Data(info.utf8), outputByteCount: 32)
            #expect(JournalRecoveryFiles.digest(bytes, noteId: "note-id", info: info, key: key) == Data(HMAC<SHA256>.authenticationCode(for: bytes, using: previous)))
        }
        #expect(JournalRecoveryFiles.digest(bytes, noteId: "note-id", info: "ignored", key: nil) == Data(SHA256.hash(data: bytes)))
    }
}
