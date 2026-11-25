// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Backup v2 (C9, FOC-R5): every rule that checks the focus state of an archive, one test per
/// rule. Each case edits a valid v2 archive's `record.json` (or `library.json`), signs the edit
/// again so it reaches the checks behind the file hashes, and expects `invalidManifest` from
/// `inspect` and both restore modes with the target library unchanged (row counts of every table
/// and a hash of the note texts, snapshots, reminders and hides). Every group also has a control
/// that is accepted, so a refusal is never an accident of the edit itself.
@Suite struct LibraryBackupFocusHostileTests {
    typealias JSON = [String: Any]
    typealias Fixture = LibraryBackupHostileArchiveTests.Fixture
    static let valid = Int64(1_800_000_000_000)
    static let limit = SyncWire.maximumRevision

    /// The valid focus archive of `Fixture(focus: true)`, extracted once.
    ///
    /// | Index | Note     | Focus state                                                     |
    /// |-------|----------|-----------------------------------------------------------------|
    /// | 0     | plain    | voice capture, opened, 2 pings (1 anchored), 3 hides, 2 snapshots |
    /// | 1     | archived | 1 whole-note ping, 1 snapshot                                   |
    /// | 2     | trashed  | none                                                            |
    /// | 3     | locked   | command capture, 1 whole-note ping, 2 sealed snapshots          |
    struct Cases {
        let f: Fixture
        let base: URL

        init() throws {
            f = try Fixture(focus: true)
            base = try f.validTree()
            // The cases index into these arrays: an archive without the focus state fails here, not in a crash.
            let plain = try FocusBackupSupport.record(base, f.notes[0].id), locked = try FocusBackupSupport.record(base, f.notes[3].id)
            for key in ["pings", "hides", "snapshots"] { try #require((plain[key] as? [Any])?.isEmpty == false, "the archive has no \(key)") }
            for key in ["pings", "snapshots"] { try #require((locked[key] as? [Any])?.isEmpty == false, "the locked note has no \(key)") }
        }

        func cleanup() { f.cleanup() }
        func id(_ index: Int) -> String { f.notes[index].id }
        func baseRecord(_ index: Int) throws -> JSON { try FocusBackupSupport.record(base, id(index)) }
        func array(_ record: JSON, _ key: String) -> [JSON] { record[key] as? [JSON] ?? [] }
        func firstID(_ index: Int, _ key: String) throws -> String {
            try #require(array(try baseRecord(index), key).first?["id"] as? String)
        }

        func copy() throws -> URL {
            let tree = f.work.appendingPathComponent("case-\(UUID())")
            try FileManager.default.copyItem(at: base, to: tree)
            return tree
        }

        func edit(_ tree: URL, record index: Int, _ change: (inout JSON) -> Void) throws {
            try f.editRecord(tree, id(index)) { change(&$0) }
        }

        func editLibrary(_ tree: URL, _ change: (inout JSON) -> Void) throws {
            let url = tree.appendingPathComponent("library.json")
            var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON)
            change(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }

        /// Edits `key`'s array of a record.
        func change(_ record: inout JSON, _ key: String, _ body: (inout [JSON]) -> Void) {
            var items = record[key] as? [JSON] ?? []
            body(&items)
            record[key] = items
        }

        /// A copy of the valid tree with record `index` edited must be refused everywhere.
        func refuse(_ what: String, record index: Int = 0, _ change: (inout JSON) -> Void,
                    sourceLocation: SourceLocation = #_sourceLocation) throws {
            let tree = try copy()
            try edit(tree, record: index, change)
            try refuse(tree, what, sourceLocation: sourceLocation)
        }

        func refuse(_ tree: URL, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            try f.resign(tree)
            try f.expectRefused(try f.zip(tree), .invalidManifest, what, sourceLocation: sourceLocation)
        }

        /// The same edit is accepted: `inspect` takes it.
        func accept(_ what: String, record index: Int = 0, _ change: (inout JSON) -> Void,
                    sourceLocation: SourceLocation = #_sourceLocation) throws {
            let tree = try copy()
            try edit(tree, record: index, change)
            try accept(tree, what, sourceLocation: sourceLocation)
        }

        func accept(_ tree: URL, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            try f.resign(tree)
            do { _ = try f.target.backup.inspect(try f.zip(tree)) }
            catch { Issue.record("\(what): control was refused with \(error)", sourceLocation: sourceLocation) }
        }

        func ping(_ id: String, line: Int? = nil, hash: String? = nil, fireAt: Int64 = LibraryBackupFocusHostileTests.valid) -> JSON {
            var ping: JSON = ["id": id, "fireAt": fireAt, "createdAt": LibraryBackupFocusHostileTests.valid]
            if let line { ping["anchorLine"] = line }
            if let hash { ping["anchorHash"] = hash }
            return ping
        }

        func hide(_ key: String, until: Int64 = LibraryBackupFocusHostileTests.valid) -> JSON {
            ["candidateKey": key, "hiddenUntil": until]
        }
    }

    // MARK: - Control

    @Test func theUneditedFocusArchiveIsAcceptedAndCarriesEveryField() throws {
        let c = try Cases(); defer { c.cleanup() }
        let summary = try c.f.target.backup.inspect(try c.f.zip(c.base))
        #expect(summary.noteCount == 4 && summary.lockedNoteCount == 1)
        let plain = try c.baseRecord(0)
        for key in ["captureSource", "lastOpenedAt", "pings", "hides", "snapshots"] { #expect(plain[key] != nil, "\(key) on the plain note") }
        #expect(c.array(plain, "pings").count == 2 && c.array(plain, "hides").count == 3 && c.array(plain, "snapshots").count == 2)
        let locked = try c.baseRecord(3)
        #expect(locked["captureSource"] != nil && locked["lastOpenedAt"] == nil && locked["hides"] == nil)
        #expect(c.array(locked, "pings").count == 1 && c.array(locked, "snapshots").count == 2)
        #expect(c.array(locked, "snapshots").allSatisfy { $0["sealedText"] is String && $0["text"] == nil })
        let library = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: c.base.appendingPathComponent("library.json"))) as? JSON)
        #expect(library["notTodayUntil"] != nil && library["version"] as? Int == 2)
    }

    // MARK: - Version gating

    @Test func focusFieldsInAV1ManifestAreRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        let fields = ["captureSource", "lastOpenedAt", "pings", "hides", "snapshots"]
        /// A v1 copy that keeps only `field` (or nothing).
        func v1(keeping field: String?) throws -> URL {
            let tree = try c.copy()
            for index in 0..<4 {
                try c.edit(tree, record: index) { record in
                    for key in fields where key != field { record[key] = nil }
                    // Hides of a ping would dangle without its ping; keep only the isolating ones.
                    if field == "hides" { c.change(&record, "hides") { $0.removeAll { ($0["candidateKey"] as? String)?.hasPrefix("ping:") == true } } }
                }
            }
            try c.editLibrary(tree) { library in
                library["version"] = 1
                if field != "notTodayUntil" { library["notTodayUntil"] = nil }
            }
            try c.f.resign(tree, version: 1)
            return tree
        }
        let control = try v1(keeping: nil)
        #expect(try c.f.target.backup.inspect(try c.f.zip(control)).noteCount == 4, "a clean v1 manifest is accepted")
        for field in fields + ["notTodayUntil"] {
            let tree = try v1(keeping: field)
            try c.f.expectRefused(try c.f.zip(tree), .invalidManifest, "v1 manifest with \(field)")
        }
        // A v2 manifest over a v1 library.json (or the other way round) is not a coherent archive.
        let mismatched = try c.copy()
        try c.editLibrary(mismatched) { $0["version"] = 1 }
        try c.refuse(mismatched, "v2 manifest, v1 library.json")
    }

    /// The brief wants the fields absent in v1: a key that is present as `null` is not absent.
    @Test func explicitNullsInAV1ManifestAreRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        let fields = ["captureSource", "lastOpenedAt", "pings", "hides", "snapshots"]
        /// A clean v1 tree: no new field anywhere, v1 library.json and manifest.
        func v1() throws -> URL {
            let tree = try c.copy()
            for index in 0..<4 {
                try c.edit(tree, record: index) { record in for key in fields { record[key] = nil } }
            }
            try c.editLibrary(tree) { library in library["version"] = 1; library["notTodayUntil"] = nil }
            try c.f.resign(tree, version: 1)
            return tree
        }
        #expect(try c.f.target.backup.inspect(try c.f.zip(try v1())).noteCount == 4, "the clean v1 tree is accepted")
        for field in fields {
            let tree = try v1()
            try c.edit(tree, record: 0) { $0[field] = NSNull() }
            try c.f.resign(tree, version: 1)
            try c.f.expectRefused(try c.f.zip(tree), .invalidManifest, "v1 record with \(field): null")
            // The same key as null on the locked note's record.
            let locked = try v1()
            try c.edit(locked, record: 3) { $0[field] = NSNull() }
            try c.f.resign(locked, version: 1)
            try c.f.expectRefused(try c.f.zip(locked), .invalidManifest, "v1 locked record with \(field): null")
        }
        let library = try v1()
        try c.editLibrary(library) { $0["notTodayUntil"] = NSNull() }
        try c.f.resign(library, version: 1)
        try c.f.expectRefused(try c.f.zip(library), .invalidManifest, "v1 library.json with notTodayUntil: null")
    }

    // MARK: - captureSource

    @Test func captureSourceMustBeACaptureSourceOrAbsent() throws {
        let c = try Cases(); defer { c.cleanup() }
        for source in CaptureSource.allCases { try c.accept("source \(source.rawValue)") { $0["captureSource"] = source.rawValue } }
        try c.accept("no source") { $0["captureSource"] = nil }
        for bad in ["telepathy", "", "VOICE", " voice", "voice\n"] {
            try c.refuse("source \(bad)") { $0["captureSource"] = bad }
        }
        try c.refuse("source 7") { $0["captureSource"] = 7 }
        let tree = try c.copy()
        try c.edit(tree, record: 3) { $0["captureSource"] = "nope" }
        try c.refuse(tree, "bad source on the locked note")
    }

    // MARK: - Identifiers

    @Test func pingAndSnapshotIdsMustBeValid() throws {
        let c = try Cases(); defer { c.cleanup() }
        let long = String(repeating: "a", count: 129)
        // The whole-note ping: no hide names it, so only its id is wrong in these cases.
        func whole(_ items: inout [JSON]) -> Int { items.firstIndex { $0["anchorLine"] == nil }! }
        for bad in ["", "../x", "a b", "a/b", "ünï", long, "a:b"] {
            try c.refuse("ping id \(bad)") { c.change(&$0, "pings") { items in let index = whole(&items); items[index]["id"] = bad } }
            try c.refuse("snapshot id \(bad)") { c.change(&$0, "snapshots") { $0[0]["id"] = bad } }
        }
        try c.accept("ping id of 128 characters") { c.change(&$0, "pings") { items in let index = whole(&items); items[index]["id"] = String(repeating: "a", count: 128) } }
    }

    @Test func duplicatePingIdsAreRejectedAcrossNotesAndWithinOne() throws {
        let c = try Cases(); defer { c.cleanup() }
        let taken = try c.firstID(0, "pings")
        try c.refuse("ping id of another note", record: 1) { c.change(&$0, "pings") { $0[0]["id"] = taken } }
        try c.refuse("ping id of the locked note", record: 3) { c.change(&$0, "pings") { $0[0]["id"] = taken } }
        try c.refuse("ping id twice in one note") { record in
            c.change(&record, "pings") { $0.append(c.ping(taken, line: 9, hash: "0123abcd")) }
        }
    }

    @Test func duplicateSnapshotIdAcrossNotesIsRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        let taken = try c.firstID(0, "snapshots")
        try c.refuse("snapshot id of another note", record: 1) { c.change(&$0, "snapshots") { $0[0]["id"] = taken } }
        try c.refuse("snapshot id of the locked note", record: 3) { c.change(&$0, "snapshots") { $0[0]["id"] = taken } }
        try c.refuse("snapshot id twice in one note") { record in
            c.change(&record, "snapshots") { $0[1]["id"] = $0[0]["id"] }
        }
        try c.accept("a fresh snapshot id", record: 1) { c.change(&$0, "snapshots") { $0[0]["id"] = "fresh-snapshot-id" } }
    }

    @Test func aPingAndASnapshotCannotShareAnId() throws {
        let c = try Cases(); defer { c.cleanup() }
        let ping = try c.firstID(0, "pings")
        try c.refuse("snapshot with a ping's id", record: 1) { c.change(&$0, "snapshots") { $0[0]["id"] = ping } }
    }

    // MARK: - Reminder anchors and targets

    @Test func pingAnchorsAreAllOrNothingAndInRange() throws {
        let c = try Cases(); defer { c.cleanup() }
        func ping(_ record: inout JSON, _ body: (inout JSON) -> Void) {
            c.change(&record, "pings") { items in
                var anchored = items.first { $0["anchorLine"] != nil }!
                items.removeAll { $0["anchorLine"] != nil }
                body(&anchored)
                items.append(anchored)
            }
        }
        try c.refuse("line without hash") { ping(&$0) { $0["anchorHash"] = nil } }
        try c.refuse("hash without line") { ping(&$0) { $0["anchorLine"] = nil } }
        for line in [0, -1, 1_000_001, Int(Int32.max)] { try c.refuse("line \(line)") { ping(&$0) { $0["anchorLine"] = line } } }
        for hash in ["0123ABCD", "0123abc", "0123abcde", "0123abcg", "", "0123 abc", "０１２３abcd"] {
            try c.refuse("hash \(hash)") { ping(&$0) { $0["anchorHash"] = hash } }
        }
        try c.refuse("line as a string") { ping(&$0) { $0["anchorLine"] = "2" } }
        try c.accept("line 1") { ping(&$0) { $0["anchorLine"] = 1 } }
        try c.accept("line 1000000") { ping(&$0) { $0["anchorLine"] = 1_000_000 } }
    }

    @Test func anchoredPingOnALockedNoteIsRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("anchored ping on the locked note", record: 3) {
            $0["pings"] = [c.ping(try! c.firstID(3, "pings"), line: 2, hash: "0123abcd")]
        }
        try c.accept("whole-note ping on the locked note", record: 3) { _ in }
    }

    @Test func aLockedNoteHasAtMostOnePing() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("two pings on the locked note", record: 3) { c.change(&$0, "pings") { $0.append(c.ping("second-locked-ping")) } }
        // The same two pings on an unlocked note would be one target twice, so this is the lock rule
        // alone only when the second one is anchored; that is refused as well.
        try c.refuse("a second, anchored ping on the locked note", record: 3) {
            c.change(&$0, "pings") { $0.append(c.ping("second-locked-ping", line: 3, hash: "0123abcd")) }
        }
        try c.accept("no ping on the locked note", record: 3) { $0["pings"] = nil }
    }

    @Test func twoPingsOnOneTargetAreRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("second whole-note ping") { c.change(&$0, "pings") { $0.append(c.ping("whole-again")) } }
        let anchored = try #require(c.array(try c.baseRecord(0), "pings").first { $0["anchorLine"] != nil })
        let line = try #require(anchored["anchorLine"] as? Int), hash = try #require(anchored["anchorHash"] as? String)
        try c.refuse("second ping on the same line and hash") { c.change(&$0, "pings") { $0.append(c.ping("anchored-again", line: line, hash: hash)) } }
        try c.accept("same line, other hash") { c.change(&$0, "pings") { $0.append(c.ping("same-line", line: line, hash: "ffffffff")) } }
        try c.accept("same hash, other line") { c.change(&$0, "pings") { $0.append(c.ping("same-hash", line: line + 1, hash: hash)) } }
        try c.accept("the whole-note target of another note", record: 2) { $0["pings"] = [c.ping("other-note-whole")] }
    }

    // MARK: - Hides

    @Test func hideForAnotherNoteIsRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        let other = c.id(1), foreignPing = try c.firstID(1, "pings")
        try c.refuse("note hide of another note") { c.change(&$0, "hides") { $0.append(c.hide("note:\(other)")) } }
        try c.refuse("to-do hide of another note") { c.change(&$0, "hides") { $0.append(c.hide("todo:\(other):2:0123abcd")) } }
        try c.refuse("ping hide of another note's ping") { c.change(&$0, "hides") { $0.append(c.hide("ping:\(foreignPing)")) } }
        try c.refuse("ping hide of a ping nobody has") { c.change(&$0, "hides") { $0.append(c.hide("ping:nobody-has-this")) } }
        try c.accept("note hide of this note, other time") { c.change(&$0, "hides") { $0[0]["hiddenUntil"] = Self.valid + 1 } }
    }

    @Test func hideKeysFollowTheGrammar() throws {
        let c = try Cases(); defer { c.cleanup() }
        let id = c.id(0)
        let bad = ["", "banana", "note:", "note:\(id)x", "note: \(id)", "ping:", "ping:../x", "todo:\(id)", "todo:\(id):1", "todo:\(id):1:0123abcd:x",
                   "todo:\(id):0:0123abcd", "todo:\(id):-1:0123abcd", "todo:\(id):1000001:0123abcd", "todo:\(id):1:0123ABCD", "todo:\(id):1:0123abc",
                   "todo:\(id):one:0123abcd", "Todo:\(id):1:0123abcd", "NOTE:\(id)", "todo::1:0123abcd"]
        for key in bad { try c.refuse("hide key \(key)") { c.change(&$0, "hides") { $0.append(c.hide(key)) } } }
        try c.accept("to-do hide on line 1") { c.change(&$0, "hides") { $0.append(c.hide("todo:\(id):1:0123abcd")) } }
        try c.accept("to-do hide on line 1000000") { c.change(&$0, "hides") { $0.append(c.hide("todo:\(id):1000000:0123abcd")) } }
    }

    @Test func notTodayUntilIsTheOnlyPoolHide() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("pool hide in a record") { c.change(&$0, "hides") { $0.append(c.hide("pool")) } }
        try c.refuse("pool hide in the locked note's record", record: 3) { $0["hides"] = [c.hide("pool")] }
    }

    @Test func duplicateHideKeysAreRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("a hide key twice") { c.change(&$0, "hides") { $0.append($0[0]) } }
    }

    @Test func aLockedNoteHasNoHides() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("note hide on the locked note", record: 3) { $0["hides"] = [c.hide("note:\(c.id(3))")] }
        try c.refuse("to-do hide on the locked note", record: 3) { $0["hides"] = [c.hide("todo:\(c.id(3)):1:0123abcd")] }
        try c.refuse("ping hide on the locked note", record: 3) {
            $0["hides"] = [c.hide("ping:\(try! c.firstID(3, "pings"))")]
        }
        try c.accept("empty hides on the locked note", record: 3) { $0["hides"] = [] as [JSON] }
    }

    // MARK: - Snapshots

    @Test func plaintextSnapshotForALockedNoteIsRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("plaintext snapshot on the locked note", record: 3) { record in
            c.change(&record, "snapshots") { $0[0]["sealedText"] = nil; $0[0]["text"] = "the vault line" }
        }
        try c.refuse("plaintext added to a sealed snapshot", record: 3) { c.change(&$0, "snapshots") { $0[0]["text"] = "the vault line" } }
    }

    @Test func sealedSnapshotForAnUnlockedNoteIsRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        let sealed = try #require(c.array(try c.baseRecord(3), "snapshots").first?["sealedText"] as? String)
        try c.refuse("sealed snapshot on an unlocked note") { record in
            c.change(&record, "snapshots") { $0[0]["text"] = nil; $0[0]["sealedText"] = sealed }
        }
        try c.refuse("sealed snapshot on an archived note", record: 1) { record in
            c.change(&record, "snapshots") { $0[0]["text"] = nil; $0[0]["sealedText"] = sealed }
        }
    }

    @Test func aSnapshotHasExactlyOneBody() throws {
        let c = try Cases(); defer { c.cleanup() }
        let sealed = try #require(c.array(try c.baseRecord(3), "snapshots").first?["sealedText"] as? String)
        try c.refuse("text and sealedText") { c.change(&$0, "snapshots") { $0[0]["sealedText"] = sealed } }
        try c.refuse("neither text nor sealedText") { c.change(&$0, "snapshots") { $0[0]["text"] = nil } }
        try c.refuse("no body on the locked note", record: 3) { c.change(&$0, "snapshots") { $0[0]["sealedText"] = nil } }
        try c.refuse("text of the wrong type") { c.change(&$0, "snapshots") { $0[0]["text"] = 5 } }
        try c.accept("an empty text") { c.change(&$0, "snapshots") { $0[0]["text"] = "" } }
    }

    @Test func aSealedSnapshotStartsWithTheNoteCipherMagic() throws {
        let c = try Cases(); defer { c.cleanup() }
        for bytes in [Data(), Data("BNC".utf8), Data("XXXX".utf8 + Data(repeating: 1, count: 100)), Data("bnc1".utf8 + Data(repeating: 1, count: 100)),
                      Data("BCH1".utf8 + Data(repeating: 1, count: 100))] {
            try c.refuse("sealed text \(bytes.count) bytes") { c.change(&$0, "snapshots") { $0[0]["sealedText"] = SyncWire.base64(bytes) } }
            try c.refuse("sealed text \(bytes.count) bytes on the locked note", record: 3) {
                c.change(&$0, "snapshots") { $0[0]["sealedText"] = SyncWire.base64(bytes) }
            }
        }
        try c.refuse("sealed text that is not base64", record: 3) { c.change(&$0, "snapshots") { $0[0]["sealedText"] = "***" } }
        try c.accept("a sealed text with the magic", record: 3) {
            c.change(&$0, "snapshots") { $0[0]["sealedText"] = SyncWire.base64(Data("BNC1".utf8) + Data(repeating: 1, count: 100)) }
        }
    }

    @Test func oversizedSnapshotIsRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("500001 units") { c.change(&$0, "snapshots") { $0[0]["text"] = String(repeating: "a", count: 500_001) } }
        // UTF-16 units, not characters: 250001 emoji are 500002 units.
        try c.refuse("emoji over the limit in UTF-16 units") { c.change(&$0, "snapshots") { $0[0]["text"] = String(repeating: "😀", count: 250_001) } }
        try c.accept("500000 units") { c.change(&$0, "snapshots") { $0[0]["text"] = String(repeating: "a", count: 500_000) } }
        try c.accept("emoji at the limit in UTF-16 units") { c.change(&$0, "snapshots") { $0[0]["text"] = String(repeating: "😀", count: 250_000) } }
    }

    @Test func atMostAHundredSnapshotsPerNote() throws {
        let c = try Cases(); defer { c.cleanup() }
        func snapshots(_ count: Int) -> [JSON] {
            (0..<count).map { ["id": "bulk-snapshot-\($0)", "takenAt": Self.valid + Int64($0), "text": "x"] }
        }
        try c.refuse("101 snapshots") { $0["snapshots"] = snapshots(101) }
        try c.accept("100 snapshots") { $0["snapshots"] = snapshots(100) }
        let sealed = try #require(c.array(try c.baseRecord(3), "snapshots").first?["sealedText"] as? String)
        try c.refuse("101 snapshots on the locked note", record: 3) {
            $0["snapshots"] = (0..<101).map { ["id": "bulk-sealed-\($0)", "takenAt": Self.valid, "sealedText": sealed] as JSON }
        }
    }

    // MARK: - Dates

    @Test func datesOutsideTheRevisionRangeAreRejected() throws {
        let c = try Cases(); defer { c.cleanup() }
        for value in [Self.limit + 1, -Self.limit - 1, Int64.max, Int64.min, LibraryBackup.latestDate + 1, LibraryBackup.earliestDate - 1, Self.limit] {
            try c.refuse("ping fireAt \(value)") { c.change(&$0, "pings") { $0[0]["fireAt"] = value } }
            try c.refuse("ping firedAt \(value)") { c.change(&$0, "pings") { $0[0]["firedAt"] = value } }
            try c.refuse("ping createdAt \(value)") { c.change(&$0, "pings") { $0[0]["createdAt"] = value } }
            try c.refuse("snapshot takenAt \(value)") { c.change(&$0, "snapshots") { $0[0]["takenAt"] = value } }
            try c.refuse("snapshot takenAt on the locked note \(value)", record: 3) { c.change(&$0, "snapshots") { $0[0]["takenAt"] = value } }
            try c.refuse("hide hiddenUntil \(value)") { c.change(&$0, "hides") { $0[0]["hiddenUntil"] = value } }
            try c.refuse("lastOpenedAt \(value)") { $0["lastOpenedAt"] = value }
            let tree = try c.copy()
            try c.editLibrary(tree) { $0["notTodayUntil"] = value }
            try c.refuse(tree, "notTodayUntil \(value)")
        }
        try c.refuse("a date as a string") { $0["lastOpenedAt"] = "2027-01-15" }
        try c.refuse("a date as a fraction") { $0["lastOpenedAt"] = 1.5 }
        for value in [LibraryBackup.latestDate, LibraryBackup.earliestDate, 0] {
            try c.accept("dates at \(value)") { record in
                record["lastOpenedAt"] = value
                c.change(&record, "pings") { $0[0]["fireAt"] = value; $0[0]["createdAt"] = value }
                c.change(&record, "snapshots") { $0[0]["takenAt"] = value }
                c.change(&record, "hides") { $0[0]["hiddenUntil"] = value }
            }
        }
    }

    /// The brief's range (plus or minus the sync revision limit) reaches year 287396, which SQLite
    /// stores as text GRDB cannot read back: such a row would break every later read (FOC-R275).
    @Test func datesAtTheEdgesOfTheRangeRestoreAndReadBack() throws {
        let c = try Cases(); defer { c.cleanup() }
        for value in [LibraryBackup.latestDate, LibraryBackup.earliestDate] {
            let tree = try c.copy()
            try c.edit(tree, record: 0) { record in
                record["lastOpenedAt"] = value
                c.change(&record, "pings") { $0[0]["fireAt"] = value; $0[0]["firedAt"] = value; $0[0]["createdAt"] = value }
                c.change(&record, "snapshots") { $0[0]["takenAt"] = value }
                c.change(&record, "hides") { $0[0]["hiddenUntil"] = value }
            }
            try c.editLibrary(tree) { $0["notTodayUntil"] = value }
            try c.f.resign(tree)
            _ = try c.f.target.backup.restore(try c.f.zip(tree), mode: .replaceAll)
            let expected = Date(timeIntervalSince1970: Double(value) / 1000)
            try c.f.target.db.pool.read { db throws -> Void in
                for column in ["fireAt", "firedAt", "createdAt"] {
                    #expect(try Date.fetchAll(db, sql: "SELECT \(column) FROM note_ping WHERE \(column) IS NOT NULL").contains(expected), "\(column) at \(value)")
                }
                #expect(try Date.fetchAll(db, sql: "SELECT takenAt FROM note_snapshot").contains(expected))
                #expect(try Date.fetchAll(db, sql: "SELECT hiddenUntil FROM focus_hide").filter { $0 == expected }.count == 2)
                #expect(try Date.fetchAll(db, sql: "SELECT lastOpenedAt FROM note_ui_state WHERE lastOpenedAt IS NOT NULL") == [expected])
            }
        }
    }

    @Test func aLockedNoteHasNoLastOpenedAt() throws {
        let c = try Cases(); defer { c.cleanup() }
        try c.refuse("lastOpenedAt on the locked note", record: 3) { $0["lastOpenedAt"] = Self.valid }
        try c.accept("lastOpenedAt on an unlocked note", record: 1) { $0["lastOpenedAt"] = Self.valid }
    }

    // MARK: - Caps

    @Test func perNoteCapsAreEnforced() throws {
        let c = try Cases(); defer { c.cleanup() }
        func pings(_ count: Int) -> [JSON] { (1...count).map { c.ping("bulk-ping-\($0)", line: $0, hash: "0123abcd") } }
        func hides(_ count: Int) -> [JSON] { (1...count).map { c.hide("todo:\(c.id(0)):\($0):0123abcd") } }
        // The old reminders go, and with them the hide that names one.
        func replacePings(_ record: inout JSON, _ count: Int) {
            record["pings"] = pings(count)
            c.change(&record, "hides") { $0.removeAll { ($0["candidateKey"] as? String)?.hasPrefix("ping:") == true } }
        }
        try c.refuse("1001 pings") { replacePings(&$0, 1001) }
        try c.accept("1000 pings") { replacePings(&$0, 1000) }
        try c.refuse("1001 hides") { $0["hides"] = hides(1001) }
        try c.accept("1000 hides") { $0["hides"] = hides(1000) }
    }
}
