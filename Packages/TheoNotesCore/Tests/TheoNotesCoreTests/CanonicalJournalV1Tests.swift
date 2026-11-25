// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct CanonicalJournalV1Tests {
    private func install(_ f: CanonicalCryptoV1Fixture, directory: URL, noteId: String? = nil,
                         base: String? = nil, lines: [String]? = nil) throws {
        let id = noteId ?? f.noteId
        try Data((base ?? f.bjb1).utf8).write(to: directory.appendingPathComponent(id + ".base"))
        try Data(((lines ?? f.bje1).joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent(id + ".jsonl"))
    }

    private var expectedBase: JournalBase {
        var base = JournalBase(storeRevision: 7, baseText: "Synthetic base 漢字")
        base.v = 1
        return base
    }

    private var expectedEntries: [JournalEntry] {
        [expectedEntry(txId: "synthetic-tx-1", insert: "Synthetic edit 👩‍👩‍👧"),
         expectedEntry(txId: "synthetic-tx-2", insert: "Second edit")]
    }

    private func expectedEntry(txId: String, insert: String) -> JournalEntry {
        var entry = JournalEntry(txId: txId, baseRevision: 7,
                                 changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: insert)]))
        entry.v = 1
        return entry
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        // Ignore object key order while preserving every field, array element and JSON type.
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(object as? [String: Any])
        return try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }

    @Test func bjb1AndBje1ReadGoldenBaseAndChainedEntries() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try install(f, directory: dir)
        let journal = try EditJournal(directory: dir, noteId: f.noteId, encryptionKey: f.key)
        #expect(try journal.base() == expectedBase)
        #expect(try journal.entries() == expectedEntries)
        #expect(try Data(contentsOf: journal.baseURL) == Data(f.bjb1.utf8))
        #expect(try Data(contentsOf: journal.fileURL) == Data((f.bje1.joined(separator: "\n") + "\n").utf8))
        // A new writer must resume the existing v1 chain using the supplied vault key directly.
        let next = expectedEntry(txId: "synthetic-tx-3", insert: "Third edit")
        let nextJSON = #"{"v":1,"txId":"synthetic-tx-3","baseRevision":7,"changeSet":[[0,"Third edit"]]}"#
        try journal.append(next)
        let lines = try Data(contentsOf: journal.fileURL).split(separator: 10).map { Data($0) }
        #expect(lines.count == 3)
        let context = "entry:\(digest(Data(f.bjb1.utf8))):2:\(digest(Data(f.bje1[1].utf8)))"
        let aad = try JSONEncoder().encode(["baerchen-journal-v1", f.noteId, context])
        let decoded = try openRecord(try #require(lines.last), prefix: "BJE1:", key: f.key, aad: aad)
        #expect(try canonicalJSON(decoded) == canonicalJSON(Data(nextJSON.utf8)))
        #expect(try EditJournal(directory: dir, noteId: f.noteId, encryptionKey: f.key).entries() == expectedEntries + [next])
    }

    @Test func goldenJournalRejectsWrongKeyContextFramingAndTamperingWithoutMutation() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var changedBase = Array(f.bjb1.utf8); changedBase[changedBase.count - 4] ^= 1
        var changedEntry = Array(f.bje1[1].utf8); changedEntry[changedEntry.count - 4] ^= 1
        let cases: [(String, [String], String, SymmetricKey, JournalProtectionError)] = [
            (f.bjb1, f.bje1, f.noteId, SymmetricKey(data: Data(repeating: 255, count: 32)), .authenticationFailed),
            (f.bjb1, f.bje1, "different-note", f.key, .authenticationFailed),
            (String(decoding: changedBase, as: UTF8.self), f.bje1, f.noteId, f.key, .authenticationFailed),
            (f.bjb1, [f.bje1[0], String(decoding: changedEntry, as: UTF8.self)], f.noteId, f.key, .authenticationFailed),
            (f.bjb1, Array(f.bje1.reversed()), f.noteId, f.key, .authenticationFailed),
            (f.bjb1, [f.bje1[0], f.bje1[0]], f.noteId, f.key, .authenticationFailed),
            ("BJB2:" + f.bjb1.dropFirst(5), f.bje1, f.noteId, f.key, .plaintextInEncryptedJournal),
            (f.bjb1, ["BJE2:" + f.bje1[0].dropFirst(5)], f.noteId, f.key, .plaintextInEncryptedJournal),
            ("BJB1:!invalid!", f.bje1, f.noteId, f.key, .authenticationFailed),
            (f.bjb1, ["BJE1:!invalid!"], f.noteId, f.key, .authenticationFailed),
            (f.bje1[0], f.bje1, f.noteId, f.key, .plaintextInEncryptedJournal),
            (f.bjb1, ["BJE1:" + f.bjb1.dropFirst(5)], f.noteId, f.key, .authenticationFailed)]
        for (base, lines, id, key, error) in cases {
            try install(f, directory: dir, noteId: id, base: base, lines: lines)
            let baseURL = dir.appendingPathComponent(id + ".base"), fileURL = dir.appendingPathComponent(id + ".jsonl")
            let beforeBase = try Data(contentsOf: baseURL), beforeEntries = try Data(contentsOf: fileURL)
            #expect(throws: error) { try EditJournal(directory: dir, noteId: id, encryptionKey: key) }
            #expect(try Data(contentsOf: baseURL) == beforeBase)
            #expect(try Data(contentsOf: fileURL) == beforeEntries)
        }
        try install(f, directory: dir)
        #expect(throws: JournalProtectionError.keyRequired) { try EditJournal(directory: dir, noteId: f.noteId) }
    }

    @Test func goldenJournalAADAndRandomizedWriterUseCanonicalKindAndDigestFraming() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Literal AAD bytes are fixture expectations, including JSON escaping of base64 slashes.
        #expect(try JSONDecoder().decode([String].self, from: Data(f.baseAAD.utf8)) == ["baerchen-journal-v1", f.noteId, "base"])
        #expect(try openRecord(Data(f.bjb1.utf8), prefix: "BJB1:", key: f.key, aad: Data(f.baseAAD.utf8)) == Data(f.baseJSON.utf8))
        for index in f.bje1.indices {
            #expect(try openRecord(Data(f.bje1[index].utf8), prefix: "BJE1:", key: f.key,
                                   aad: Data(f.entryAAD[index].utf8)) == Data(f.entryJSON[index].utf8))
        }
        let journal = try EditJournal(directory: dir, noteId: f.noteId, encryptionKey: f.key)
        let base = expectedBase
        try journal.writeBase(base)
        let rawBase = try Data(contentsOf: journal.baseURL)
        let opened = try openRecord(rawBase, prefix: "BJB1:", key: f.key, aad: Data(f.baseAAD.utf8))
        #expect(try canonicalJSON(opened) == canonicalJSON(Data(f.baseJSON.utf8)))
        #expect(base.v == 1 && EditJournal.formatVersion == 1)
        var previous = ""
        #expect(f.entryJSON.count == expectedEntries.count)
        for (index, entry) in expectedEntries.enumerated() {
            try journal.append(entry)
            let raw = try #require(Data(contentsOf: journal.fileURL).split(separator: 10).last).withUnsafeBytes { Data($0) }
            let context = "entry:\(digest(rawBase)):\(index):\(previous)"
            let aad = try JSONEncoder().encode(["baerchen-journal-v1", f.noteId, context])
            let decoded = try openRecord(raw, prefix: "BJE1:", key: f.key, aad: aad)
            #expect(try canonicalJSON(decoded) == canonicalJSON(Data(f.entryJSON[index].utf8)))
            #expect(entry.v == 1)
            previous = digest(raw)
        }
    }

    @Test func authenticatedUnknownJSONVersionsAreRejectedAndPreserved() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (base, lines) in [(f.unsupportedBaseVersion, f.bje1), (f.bjb1, [f.unsupportedEntryVersion])] {
            try install(f, directory: dir, base: base, lines: lines)
            #expect(throws: JournalError.unsupportedVersion(2)) {
                try EditJournal(directory: dir, noteId: f.noteId, encryptionKey: f.key)
            }
            #expect(try Data(contentsOf: dir.appendingPathComponent(f.noteId + ".base")) == Data(base.utf8))
            #expect(try Data(contentsOf: dir.appendingPathComponent(f.noteId + ".jsonl")) == Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }

    private func digest(_ value: Data) -> String { Data(SHA256.hash(data: value)).base64EncodedString() }
    private func openRecord(_ raw: Data, prefix: String, key: SymmetricKey, aad: Data) throws -> Data {
        #expect(raw.starts(with: Data(prefix.utf8)))
        #expect(!raw.contains(10))
        let combined = try #require(Data(base64Encoded: raw.dropFirst(5)))
        return try CanonicalCryptoV1Fixture.open(combined, key: key, aad: aad)
    }
}
