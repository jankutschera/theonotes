// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct EditJournalTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-journal-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ id: String, _ base: Int, _ insert: String) -> JournalEntry {
        JournalEntry(
            txId: id, baseRevision: base,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: insert)])
        )
    }

    @Test func testJournalAppendAndReplay() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        #expect(try journal.entries().isEmpty)
        let a = entry("t1", 0, "line\nwith newline 👩‍👩‍👧")
        let b = entry("t2", 1, "漢字")
        try journal.append(a)
        try journal.append(b)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("n1.jsonl").path))

        let reopened = try EditJournal(directory: dir, noteId: "n1")
        let entries = try reopened.entries()
        #expect(entries.count == 2)
        #expect(entries[0].txId == "t1")
        #expect(entries[0].baseRevision == 0)
        #expect(entries[0].changeSet == a.changeSet)
        #expect(entries[1].txId == "t2")
        #expect(entries[1].changeSet == b.changeSet)

        let raw = try String(contentsOf: dir.appendingPathComponent("n1.jsonl"), encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 2)
    }

    @Test func testJournalTruncate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.append(entry("t1", 0, "a"))
        try journal.truncate()
        #expect(try journal.entries().isEmpty)
        try journal.append(entry("t2", 1, "b"))
        #expect(try journal.entries().map(\.txId) == ["t2"])
    }

    @Test func testTornTrailingLineIsDroppedOnOpen() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.append(entry("t1", 0, "a"))
        let url = dir.appendingPathComponent("n1.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"txId":"t2","base"#.utf8))
        try handle.close()

        let reopened = try EditJournal(directory: dir, noteId: "n1")
        try reopened.append(entry("t3", 1, "c"))
        #expect(try reopened.entries().map(\.txId) == ["t1", "t3"])
    }

    private func appendRaw(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    @Test func testLinesAndBaseCarryFormatVersion() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "x"))
        try journal.append(entry("t1", 0, "a"))
        for name in ["n1.jsonl", "n1.base"] {
            let raw = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            #expect(raw.contains(#""v":\#(EditJournal.formatVersion)"#), "\(name): \(raw)")
        }
        #expect(try journal.base()?.v == EditJournal.formatVersion)
        #expect(try journal.entries().map(\.v) == [EditJournal.formatVersion])
    }

    @Test func testUndecodableLastCompleteLineIsSkipped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.append(entry("t1", 0, "a"))
        try appendRaw(#"{"v":1,"txId":"t2","base"#, to: journal.fileURL)
        #expect(try journal.entries().map(\.txId) == ["t1"])
    }

    @Test func testUndecodableMiddleLineThrows() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.append(entry("t1", 0, "a"))
        try appendRaw("not json", to: journal.fileURL)
        try journal.append(entry("t3", 1, "c"))
        #expect(throws: JournalError.corruptEntry(line: 2)) { try journal.entries() }
    }

    @Test func testUnknownVersionThrows() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.append(entry("t1", 0, "a"))
        // Even as the last line: a well-formed record of another format is not a torn write.
        try appendRaw(#"{"v":2,"txId":"t2","baseRevision":1,"changeSet":[[0,"b"]]}"#, to: journal.fileURL)
        #expect(throws: JournalError.unsupportedVersion(2)) { try journal.entries() }
        try journal.truncate()
        try appendRaw(#"{"txId":"old","baseRevision":0,"changeSet":[[0,"b"]]}"#, to: journal.fileURL)
        #expect(throws: JournalError.unsupportedVersion(nil)) { try journal.entries() }

        let base = JournalBase(storeRevision: 1, baseText: "x")
        try journal.writeBase(base)
        let raw = try String(contentsOf: journal.baseURL, encoding: .utf8)
        try raw.replacingOccurrences(of: #""v":1"#, with: #""v":7"#).write(to: journal.baseURL, atomically: true, encoding: .utf8)
        #expect(throws: JournalError.unsupportedVersion(7)) { try journal.base() }
    }
}

@Suite struct EditJournalFailureTests {
    private struct InjectedFault: Error {}

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-journal-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ id: String) -> JournalEntry {
        JournalEntry(txId: id, baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: id)]))
    }

    @Test func testBaseRecordIsWrittenAndRemovedByTruncate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        #expect(try journal.base() == nil)
        try journal.writeBase(JournalBase(storeRevision: 3, baseText: "漢字\n👩‍👩‍👧"))
        try journal.append(entry("t1"))
        #expect(try EditJournal(directory: dir, noteId: "n1").base() == JournalBase(storeRevision: 3, baseText: "漢字\n👩‍👩‍👧"))
        try journal.truncate()
        #expect(try journal.base() == nil)
        #expect(try journal.entries().isEmpty)
    }

    @Test func testPartialWriteIsRolledBack() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.append(entry("t1"))
        journal.faultInjector = { op, handle in
            if case .write(let data) = op {
                try handle.write(contentsOf: data.prefix(data.count / 2))
                throw InjectedFault()
            }
        }
        #expect(throws: InjectedFault.self) { try journal.append(entry("t2")) }
        #expect(!journal.isPoisoned)
        journal.faultInjector = nil
        try journal.append(entry("t3"))
        #expect(try EditJournal(directory: dir, noteId: "n1").entries().map(\.txId) == ["t1", "t3"])
    }

    @Test func testFailedSyncIsRolledBack() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        journal.faultInjector = { op, _ in if case .synchronize = op { throw InjectedFault() } }
        #expect(throws: InjectedFault.self) { try journal.append(entry("t1")) }
        journal.faultInjector = nil
        #expect(try journal.entries().isEmpty)
    }

    @Test func testFailedRollbackPoisonsUntilTruncate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        journal.faultInjector = { op, _ in
            switch op {
            case .synchronize, .truncate: throw InjectedFault()
            case .write, .synchronizeTruncation: break
            }
        }
        #expect(throws: InjectedFault.self) { try journal.append(entry("t1")) }
        #expect(journal.isPoisoned)
        journal.faultInjector = nil
        try journal.truncate()
        #expect(!journal.isPoisoned)
        #expect(try journal.entries().isEmpty)
    }

    @Test func testMoveAsideKeepsFilesAndStartsFresh() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try EditJournal(directory: dir, noteId: "n1")
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "b"))
        try journal.append(entry("t1"))
        try journal.moveAside()
        #expect(try journal.entries().isEmpty)
        #expect(try journal.base() == nil)
        let aside = dir.appendingPathComponent("n1.jsonl.unreplayed")
        #expect(try String(contentsOf: aside, encoding: .utf8).contains("\"t1\""))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("n1.base.unreplayed").path))
        try journal.append(entry("t2"))
        try journal.moveAside()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("n1.jsonl.unreplayed.1").path))
    }
}
