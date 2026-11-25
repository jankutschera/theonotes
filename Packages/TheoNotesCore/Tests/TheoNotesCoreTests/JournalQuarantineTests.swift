// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct JournalQuarantineTests {
    @Test func damagedMarkerRequiresExplicitConfirmationAndKeepsBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let name = ".retirement-" + String(repeating: "a", count: 64) + ".json"
        let bytes = Data("not valid json".utf8)
        try bytes.write(to: journal.appendingPathComponent(name))
        let selection = try JournalQuarantine.inspectDamagedMarker(libraryRoot: root, fileName: name)
        let confirmation = try JournalQuarantine.confirm(selection)
        try JournalQuarantine.resume(confirmation)
        #expect(try Data(contentsOf: confirmation.directory.appendingPathComponent(name)) == bytes)
        #expect(confirmation.directory.lastPathComponent.wholeMatch(of: /\d{8}T\d{6}Z-[0-9a-f]{8}/) != nil)
        #expect(!FileManager.default.fileExists(atPath: journal.appendingPathComponent(name).path))
    }
    @Test func markerReplacedAfterInspectionIsNotMoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let name = ".retirement-" + String(repeating: "b", count: 64) + ".json"
        let url = journal.appendingPathComponent(name)
        try Data("broken".utf8).write(to: url)
        let selection = try JournalQuarantine.inspectDamagedMarker(libraryRoot: root, fileName: name)
        try Data("replacement bytes".utf8).write(to: url)
        #expect(throws: (any Error).self) { try JournalQuarantine.confirm(selection) }
        #expect(try Data(contentsOf: url) == Data("replacement bytes".utf8))
        #expect(throws: (any Error).self) { try JournalQuarantine.inspectDamagedMarker(libraryRoot: root, fileName: ".retirement-../../other.json") }
        #expect(throws: (any Error).self) { try JournalQuarantine.inspectDamagedMarker(libraryRoot: root, fileName: ".retirement-" + String(repeating: "c", count: 64) + ".json") }
    }
    @Test func damagedPairSurvivesPartialMoveAndResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let bytes = [Data("broken\nplain".utf8), Data([0, 255, 31, 0])]
        let names = ["note.jsonl", "note.base"]
        for (name, data) in zip(names, bytes) { try data.write(to: journal.appendingPathComponent(name)) }
        let selection = try JournalQuarantine.inspect(libraryRoot: root, fileNames: names)
        let confirmation = try JournalQuarantine.confirm(selection)
        #expect(throws: (any Error).self) {
            try JournalQuarantine.resume(confirmation, afterMove: { index in if index == 0 { throw CocoaError(.fileWriteUnknown) } })
        }
        try JournalQuarantine.resume(confirmation)
        for (name, data) in zip(names, bytes) {
            #expect(try Data(contentsOf: confirmation.directory.appendingPathComponent(name)) == data)
            #expect(!FileManager.default.fileExists(atPath: journal.appendingPathComponent(name).path))
        }
        let later = journal.appendingPathComponent(names[0])
        try Data("a new journal".utf8).write(to: later)
        try JournalQuarantine.resume(confirmation)
        #expect(try Data(contentsOf: later) == Data("a new journal".utf8))
    }

    @Test func replacementAndSymlinkAreNeverMoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("x.jsonl")
        try Data("original".utf8).write(to: file)
        let selection = try JournalQuarantine.inspect(libraryRoot: root, fileNames: ["x.jsonl"])
        try FileManager.default.removeItem(at: file)
        try Data("replacement".utf8).write(to: file)
        #expect(throws: (any Error).self) { try JournalQuarantine.confirm(selection) }
        let link = dir.appendingPathComponent("x.base")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try JournalQuarantine.inspect(libraryRoot: root, fileNames: ["x.base"]) }
    }
}
