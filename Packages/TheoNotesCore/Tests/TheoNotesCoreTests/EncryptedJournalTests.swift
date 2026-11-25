// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct EncryptedJournalTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-journal-\(UUID())")
    }

    private func entry(_ id: String, _ value: String) -> JournalEntry {
        JournalEntry(txId: id, baseRevision: 0,
                     changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: value)]))
    }

    @Test func acknowledgedEditsAndBaseRemainEncryptedAcrossRecovery() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let base = JournalBase(storeRevision: 7, baseText: "private base 漢字")
        let first = entry("one", "secret edit 👩‍👩‍👧")
        let second = entry("two", "second secret")
        do {
            let journal = try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
            try journal.writeBase(base)
            try journal.append(first)
        }
        let reopened = try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
        #expect(try reopened.base() == base)
        #expect(try reopened.entries() == [first])
        try reopened.append(second)
        #expect(try reopened.entries() == [first, second])
        for url in [reopened.baseURL, reopened.fileURL] {
            let raw = try String(contentsOf: url, encoding: .utf8)
            #expect(!raw.contains("private"))
            #expect(!raw.contains("secret"))
            #expect(!raw.contains("changeSet"))
        }
        try reopened.truncate()
        try reopened.writeBase(base)
        try reopened.append(second)
        #expect(try EditJournal(directory: dir, noteId: "note", encryptionKey: key).entries() == [second])
    }

    @Test func missingAndWrongKeyLeaveRecoveryBytesUntouched() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let journal = try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(entry("one", "private"))
        let handle = try FileHandle(forWritingTo: journal.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("torn trailing record".utf8))
        try handle.close()
        let before = try Data(contentsOf: journal.fileURL)
        #expect(throws: JournalProtectionError.keyRequired) {
            try EditJournal(directory: dir, noteId: "note")
        }
        #expect(throws: JournalProtectionError.authenticationFailed) {
            try EditJournal(directory: dir, noteId: "note", encryptionKey: SymmetricKey(size: .bits256))
        }
        #expect(try Data(contentsOf: journal.fileURL) == before)
        let recovered = try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
        #expect(try recovered.entries().map(\.txId) == ["one"])
        try recovered.append(entry("two", "retained"))
        #expect(try recovered.entries().map(\.txId) == ["one", "two"])
    }

    @Test func reorderedOrTamperedCompleteRecordsAreRejectedIncludingLastRecord() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let journal = try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(entry("one", "a"))
        try journal.append(entry("two", "b"))
        let original = try Data(contentsOf: journal.fileURL)
        let lines = original.split(separator: 10)
        let reordered = Data(lines[1]) + Data([10]) + Data(lines[0]) + Data([10])
        try reordered.write(to: journal.fileURL)
        #expect(throws: JournalProtectionError.authenticationFailed) {
            try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
        }
        var damaged = original
        damaged[damaged.count - 4] = damaged[damaged.count - 4] == 65 ? 66 : 65
        try damaged.write(to: journal.fileURL)
        #expect(throws: JournalProtectionError.authenticationFailed) {
            try EditJournal(directory: dir, noteId: "note", encryptionKey: key)
        }
        #expect(try Data(contentsOf: journal.fileURL) == damaged)
    }

    @Test func recordsCannotMoveBetweenNotesOrBaseGenerations() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let a = try EditJournal(directory: dir, noteId: "a", encryptionKey: key)
        let b = try EditJournal(directory: dir, noteId: "b", encryptionKey: key)
        let base = JournalBase(storeRevision: 1, baseText: "secret")
        try a.writeBase(base)
        try a.append(entry("one", "private"))
        let oldEntries = try Data(contentsOf: a.fileURL)
        try Data(contentsOf: a.baseURL).write(to: b.baseURL)
        #expect(throws: JournalProtectionError.authenticationFailed) {
            try EditJournal(directory: dir, noteId: "b", encryptionKey: key)
        }
        #expect(throws: JournalProtectionError.baseHasPendingEntries) { try a.writeBase(base) }
        try a.truncate()
        try a.writeBase(base)
        try oldEntries.write(to: a.fileURL)
        #expect(throws: JournalProtectionError.authenticationFailed) {
            try EditJournal(directory: dir, noteId: "a", encryptionKey: key)
        }
    }

    @Test func encryptionNeverSilentlyAdoptsPlaintextRecoveryData() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try EditJournal(directory: dir, noteId: "note")
        try plain.writeBase(JournalBase(storeRevision: 1, baseText: "still needs migration"))
        try plain.append(entry("one", "retained"))
        #expect(throws: JournalProtectionError.plaintextInEncryptedJournal) {
            try EditJournal(directory: dir, noteId: "note", encryptionKey: SymmetricKey(size: .bits256))
        }
        #expect(try plain.entries().map(\.txId) == ["one"])
    }
}
