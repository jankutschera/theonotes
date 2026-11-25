// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// M8's hostile-archive and round-trip cases (`BackupArchiveTests`, retired with the M8 backup),
/// ported onto the one backup format Jan chose (D2, 2026-10-26): ios's `.baerchen-backup` v1
/// (`LibraryBackup`). Every hostile archive is refused by `inspect` and by both restore modes, and
/// the target library stays exactly as it was: no note, attachment file or rolling copy changes.
@Suite struct LibraryBackupHostileArchiveTests {
    static let created = Date(timeIntervalSince1970: 1_735_787_045.123)
    static let modified = Date(timeIntervalSince1970: 1_738_555_506.456)
    static let photo = Data((0..<4096).map { UInt8($0 % 251) })

    struct Fixture {
        let source = try! LibraryBackupTests.Library()
        let target = try! LibraryBackupTests.Library()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("backup-hostile-\(UUID())")
        var notes: [Note] = []
        /// Set by `init(focus: true)`: the seeded focus state; `notes[3]` is then the locked note.
        var seeded: FocusBackupSupport.Seeded?

        init(focus: Bool = false) throws {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            func draft(_ text: String, location: NoteLocation = .notes, attachments: [ImportedAttachment] = []) -> ImportedNoteDraft {
                ImportedNoteDraft(text: text, createdAt: created, modifiedAt: modified, location: location, attachments: attachments)
            }
            notes.append(try source.store.importNote(draft(
                "# Plan 😀\n#work\n![](photo%202.jpg)\n[Ünï.pdf](%C3%9Cn%C3%AF.pdf)\n",
                attachments: [
                    ImportedAttachment(filename: "photo 2.jpg", data: photo),
                    ImportedAttachment(filename: "Ünï.pdf", data: Data("pdf bytes".utf8)),
                ])))
            notes.append(try source.store.importNote(draft(
                "Archived [b.txt](b.txt)", location: .archive, attachments: [ImportedAttachment(filename: "b.txt", data: Data("bee".utf8))])))
            notes.append(try source.store.importNote(draft("Trashed note", location: .trash)))
            _ = try target.store.importNote(ImportedNoteDraft(
                text: "Local [local.txt](local.txt)", createdAt: created, modifiedAt: modified,
                attachments: [ImportedAttachment(filename: "local.txt", data: Data("local".utf8))]))
            if focus {
                notes.append(try source.store.importNote(draft("# Secret\nthe vault line")))
                seeded = try FocusBackupSupport.seed(store: source.store, plain: notes[0], secret: notes[3])
                _ = try source.store.setPing(noteId: notes[1].id, anchor: nil, fireAt: FocusBackupSupport.millis(500), now: FocusBackupSupport.millis(0))
                _ = try source.store.takeSnapshot(noteId: notes[1].id, text: "Archived [b.txt](b.txt)\nolder", now: FocusBackupSupport.millis(30))
            }
        }

        func cleanup() {
            source.cleanup()
            target.cleanup()
            try? FileManager.default.removeItem(at: work)
        }

        /// A fresh backup of the source, unzipped into a new folder to be edited by hand.
        func validTree() throws -> URL {
            let archive = work.appendingPathComponent("valid-\(UUID()).baerchen-backup")
            try source.backup.create(at: archive)
            let tree = work.appendingPathComponent("tree-\(UUID())")
            try PortableZIP.extract(archive, to: tree)
            return tree
        }

        /// The tree zipped by the backup's own writer.
        func zip(_ tree: URL, name: String = "hostile") throws -> URL {
            let archive = work.appendingPathComponent("\(name)-\(UUID()).baerchen-backup")
            try PortableZIP.create(from: tree, at: archive)
            return archive
        }

        /// `ditto -c -k` keeps symbolic links as links, as a hostile archive would carry them.
        func zipKeepingLinks(_ tree: URL) throws -> URL {
            let archive = work.appendingPathComponent("links-\(UUID()).baerchen-backup")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", tree.path, archive.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            return archive
        }

        /// Rewrites `manifest.json` with the tree's real files, so a test reaches the checks behind
        /// the SHA-256 file list (an attacker can always do the same).
        func resign(_ tree: URL, version: Int = 2, noteIds edit: (inout [String]) -> Void = { _ in }) throws {
            let url = tree.appendingPathComponent("manifest.json")
            let old = try SyncPayloadCodec.decode(BackupManifest.self, from: Data(contentsOf: url))
            var ids = old.noteIds
            edit(&ids)
            let files = try LibraryBackup.fileManifest(tree).filter { $0.path != "manifest.json" }
            let manifest = BackupManifest(version: version, createdAt: old.createdAt, noteIds: ids, files: files)
            try SyncPayloadCodec.encoder().encode(manifest).write(to: url)
        }

        /// Edits one note's `record.json` as JSON.
        func editRecord(_ tree: URL, _ id: String, _ edit: (inout [String: Any]) throws -> Void) throws {
            let url = tree.appendingPathComponent(id + ".textbundle/record.json")
            var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            try edit(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }

        /// Notes (id, revision, text) and every file under the attachments folder, with sizes.
        func targetState() throws -> [String] {
            let notes = try target.db.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, revision, text FROM note ORDER BY id").map { "\($0["id"] as String) \($0["revision"] as Int) \($0["text"] as String)" }
            }
            let root = target.paths.attachments
            let files = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted().map { path in
                "\(path) \((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as? Int) ?? -1)"
            }
            // Every table's row count, and a hash of the text, snapshot, reminder and hide rows.
            let tables = try target.db.pool.read { db -> [String] in
                var lines: [String] = []
                for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
                    lines.append("rows \(name) \(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? -1)")
                }
                let hashes = [
                    ("note.text", "SELECT group_concat(id || text, char(31)) FROM (SELECT id,text FROM note ORDER BY id)"),
                    ("note_snapshot", "SELECT group_concat(id || noteId || takenAt || ifnull(text,'-') || ifnull(hex(sealedText),'-'), char(31)) FROM (SELECT * FROM note_snapshot ORDER BY id)"),
                    ("note_ping", "SELECT group_concat(id || noteId || ifnull(anchorLine,'-') || ifnull(anchorHash,'-') || fireAt || ifnull(firedAt,'-') || createdAt, char(31)) FROM (SELECT * FROM note_ping ORDER BY id)"),
                    ("focus_hide", "SELECT group_concat(candidateKey || hiddenUntil, char(31)) FROM (SELECT * FROM focus_hide ORDER BY candidateKey)"),
                ]
                for (name, sql) in hashes {
                    lines.append("hash \(name) \(SyncWire.hash(Data((try String.fetchOne(db, sql: sql) ?? "").utf8)))")
                }
                return lines
            }
            return notes + files + tables + ["backups \(try target.backup.localBackups().count)"]
        }

        /// `inspect` and both restore modes refuse `archive` (with `expected` when given) and the
        /// target library is unchanged.
        func expectRefused(_ archive: URL, _ expected: BackupError? = nil, _ what: String,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
            let before = try targetState()
            for attempt in 0..<3 {
                do {
                    switch attempt {
                    case 0: _ = try target.backup.inspect(archive)
                    case 1: _ = try target.backup.restore(archive, mode: .merge)
                    default: _ = try target.backup.restore(archive, mode: .replaceAll)
                    }
                    Issue.record("\(what): attempt \(attempt) was accepted", sourceLocation: sourceLocation)
                } catch {
                    if let expected {
                        #expect(error as? BackupError == expected, "\(what): attempt \(attempt) threw \(error)", sourceLocation: sourceLocation)
                    }
                }
            }
            #expect(try targetState() == before, "\(what): the target library changed", sourceLocation: sourceLocation)
        }

        func record(_ tree: URL, _ index: Int) -> URL { tree.appendingPathComponent(notes[index].id + ".textbundle") }
        func asset(_ tree: URL, _ index: Int, _ filename: String) -> URL { record(tree, index).appendingPathComponent("assets/" + filename) }
    }

    // MARK: - The state hash

    /// `targetState` is what "the library is unchanged" means: it must notice a change in any
    /// column of a reminder, or a hostile restore could alter one unseen.
    @Test func theStateHashSeesEveryPingColumn() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let note = try f.target.store.create(text: "# Hash me")
        func reset() throws {
            try f.target.db.pool.write { db in
                try db.execute(sql: "DELETE FROM note_ping")
                try db.execute(sql: """
                    INSERT INTO note_ping(id,noteId,anchorLine,anchorHash,fireAt,firedAt,createdAt)
                    VALUES('ping-1',?,2,'0123abcd','2027-01-15 08:00:00.000','2027-01-15 09:00:00.000','2027-01-14 08:00:00.000')
                    """, arguments: [note.id])
            }
        }
        try reset()
        let base = try f.targetState()
        for (column, value) in [("id", "'ping-2'"), ("anchorLine", "3"), ("anchorHash", "'ffffffff'"), ("fireAt", "'2028-01-15 08:00:00.000'"),
                                ("firedAt", "NULL"), ("createdAt", "'2026-01-14 08:00:00.000'")] {
            try f.target.db.pool.write { try $0.execute(sql: "UPDATE note_ping SET \(column) = \(value)") }
            #expect(try f.targetState() != base, "a change of \(column) is seen")
            try reset()
        }
        #expect(try f.targetState() == base)
    }

    // MARK: - Round trip

    @Test func everyNoteAttachmentAndLocationRoundTripsExactly() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let empty = try LibraryBackupTests.Library()
        defer { empty.cleanup() }
        let archive = f.work.appendingPathComponent("round-trip.baerchen-backup")
        try f.source.backup.create(at: archive)
        let summary = try empty.backup.inspect(archive)
        #expect(summary.noteCount == 3 && summary.attachmentCount == 3 && summary.lockedNoteCount == 0 && summary.missingAttachmentCount == 0)
        #expect(try empty.backup.restore(archive).restored == 3)
        for note in f.notes {
            let expected = try f.source.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) }
            #expect(try empty.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) } == expected, "\(note.title)")
            #expect(try empty.store.note(id: note.id)?.text == note.text)
        }
        for (index, filename, bytes) in [(0, "photo 2.jpg", Self.photo), (0, "Ünï.pdf", Data("pdf bytes".utf8)), (1, "b.txt", Data("bee".utf8))] {
            let url = empty.paths.attachments.appendingPathComponent(f.notes[index].id + "/" + filename)
            #expect(try Data(contentsOf: url) == bytes, "\(filename)")
        }
        #expect(try empty.store.note(id: f.notes[1].id)?.location == .archive)
        #expect(try empty.store.note(id: f.notes[2].id)?.location == .trash)
    }

    // MARK: - Hostile archives

    @Test func theUneditedTreeIsAccepted() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(try f.target.backup.inspect(try f.zip(try f.validTree())).noteCount == 3)
    }

    @Test func manifestAndVersionDamageIsRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        do {
            let tree = try f.validTree()
            try FileManager.default.removeItem(at: tree.appendingPathComponent("manifest.json"))
            try f.expectRefused(try f.zip(tree), .invalidManifest, "no manifest.json")
        }
        do {
            let tree = try f.validTree()
            try FileManager.default.removeItem(at: tree.appendingPathComponent("manifest.json"))
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("manifest.json"), withIntermediateDirectories: false)
            try f.expectRefused(try f.zip(tree), .invalidManifest, "manifest.json that is a folder")
        }
        do {
            let tree = try f.validTree()
            try Data("not json".utf8).write(to: tree.appendingPathComponent("manifest.json"))
            try f.expectRefused(try f.zip(tree), .invalidManifest, "manifest that is not JSON")
        }
        do {
            let tree = try f.validTree()
            try f.resign(tree, version: 3)
            try f.expectRefused(try f.zip(tree), .unsupportedVersion, "version 3")
            // A future version may change the whole shape: the version is read first.
            try Data(#"{"version":3,"notes":"elsewhere"}"#.utf8).write(to: tree.appendingPathComponent("manifest.json"))
            try f.expectRefused(try f.zip(tree), .unsupportedVersion, "version 3, new shape")
        }
        do {
            let renamed = f.work.appendingPathComponent("Bear.baerchen-backup")
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Fixtures/import/sample.bear2bk"), to: renamed)
            try f.expectRefused(renamed, .invalidManifest, "a Bear backup renamed to .baerchen-backup")
        }
    }

    @Test func identifiersThatClimbOrCollideAreRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let a = f.notes[0].id
        do {
            let tree = try f.validTree()
            try FileManager.default.moveItem(at: f.record(tree, 0), to: tree.appendingPathComponent("x.textbundle"))
            try f.resign(tree) { $0[0] = "../x" }
            try f.expectRefused(try f.zip(tree), nil, "note id ../x")
        }
        do {
            let tree = try f.validTree()
            try f.resign(tree) { $0.append(a) }
            try f.expectRefused(try f.zip(tree), .invalidManifest, "duplicate note id")
        }
        do {
            // Two ids that are one folder on APFS.
            let tree = try f.validTree()
            try f.resign(tree) { $0[1] = a.uppercased() }
            try f.expectRefused(try f.zip(tree), nil, "note ids differing in case")
        }
        do {
            let tree = try f.validTree()
            let photo = "photo 2.jpg"
            try FileManager.default.createDirectory(at: f.asset(tree, 0, "a"), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: f.asset(tree, 0, photo), to: f.asset(tree, 0, "a/b.png"))
            try f.editRecord(tree, a) { record in
                var attachments = record["attachments"] as! [[String: Any]]
                let index = try #require(attachments.firstIndex { $0["filename"] as? String == photo })
                attachments[index]["filename"] = "a/b.png"
                record["attachments"] = attachments
            }
            try f.resign(tree)
            try f.expectRefused(try f.zip(tree), nil, "attachment filename a/b.png")
        }
        do {
            let tree = try f.validTree()
            try f.editRecord(tree, f.notes[1].id) { record in
                var attachments = record["attachments"] as! [[String: Any]]
                attachments[0]["filename"] = ".."
                record["attachments"] = attachments
            }
            try f.resign(tree)
            try f.expectRefused(try f.zip(tree), nil, "attachment filename ..")
        }
        do {
            // The same attachment id in two notes, each file present and matching.
            let tree = try f.validTree()
            try FileManager.default.copyItem(at: f.asset(tree, 0, "photo 2.jpg"), to: f.asset(tree, 1, "photo 2.jpg"))
            var photo: [String: Any] = [:]
            try f.editRecord(tree, a) { record in
                photo = try #require((record["attachments"] as! [[String: Any]]).first { $0["filename"] as? String == "photo 2.jpg" })
            }
            try f.editRecord(tree, f.notes[1].id) { record in
                record["attachments"] = (record["attachments"] as! [[String: Any]]) + [photo]
                var note = record["note"] as! [String: Any]
                note["attachmentIds"] = (note["attachmentIds"] as! [String]) + [photo["id"] as! String]
                record["note"] = note
            }
            try f.resign(tree)
            try f.expectRefused(try f.zip(tree), nil, "duplicate attachment id across notes")
        }
    }

    @Test func contentEditedAfterTheBackupIsRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        do {
            let tree = try f.validTree()
            let text = f.record(tree, 0).appendingPathComponent("text.md")
            try (try Data(contentsOf: text) + Data("edited".utf8)).write(to: text)
            try f.expectRefused(try f.zip(tree), .checksumMismatch, "edited text.md")
        }
        do {
            let tree = try f.validTree()
            try Data("BEE".utf8).write(to: f.asset(tree, 1, "b.txt"))
            try f.expectRefused(try f.zip(tree), .checksumMismatch, "asset with other bytes of the same size")
        }
        do {
            let tree = try f.validTree()
            try FileManager.default.removeItem(at: f.asset(tree, 1, "b.txt"))
            try f.expectRefused(try f.zip(tree), nil, "missing asset")
        }
        do {
            let tree = try f.validTree()
            try FileManager.default.removeItem(at: f.record(tree, 1))
            try f.expectRefused(try f.zip(tree), nil, "missing bundle")
        }
        do {
            // text.md re-signed but no longer the record's text.
            let tree = try f.validTree()
            try Data("other text".utf8).write(to: f.record(tree, 0).appendingPathComponent("text.md"))
            try f.resign(tree)
            try f.expectRefused(try f.zip(tree), .invalidManifest, "text.md that differs from record.json")
        }
    }

    @Test func symbolicLinksAreRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        do {
            let tree = try f.validTree()
            try FileManager.default.removeItem(at: f.asset(tree, 1, "b.txt"))
            try FileManager.default.createSymbolicLink(atPath: f.asset(tree, 1, "b.txt").path, withDestinationPath: "/etc/hosts")
            try f.expectRefused(try f.zipKeepingLinks(tree), .invalidManifest, "asset symlinked to /etc/hosts")
        }
        do {
            let tree = try f.validTree()
            let outside = f.work.appendingPathComponent("outside-b.txt")
            try Data("bee".utf8).write(to: outside)
            try FileManager.default.removeItem(at: f.asset(tree, 1, "b.txt"))
            try FileManager.default.createSymbolicLink(atPath: f.asset(tree, 1, "b.txt").path, withDestinationPath: outside.path)
            try f.expectRefused(try f.zipKeepingLinks(tree), .invalidManifest, "asset symlinked to matching bytes outside")
        }
        do {
            let tree = try f.validTree()
            let outside = f.work.appendingPathComponent("outside-\(UUID()).textbundle")
            try FileManager.default.moveItem(at: f.record(tree, 1), to: outside)
            try FileManager.default.createSymbolicLink(at: f.record(tree, 1), withDestinationURL: outside)
            try f.expectRefused(try f.zipKeepingLinks(tree), .invalidManifest, "bundle symlinked outside")
        }
    }

    @Test func damagedZipsAreRefused() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let whole = try Data(contentsOf: try f.zip(try f.validTree(), name: "whole"))
        let truncated = f.work.appendingPathComponent("truncated.baerchen-backup")
        try whole.prefix(whole.count / 2).write(to: truncated)
        try f.expectRefused(truncated, .invalidManifest, "truncated zip")
        let garbage = f.work.appendingPathComponent("garbage.baerchen-backup")
        try Data(repeating: 0x41, count: 4096).write(to: garbage)
        try f.expectRefused(garbage, .invalidManifest, "not a zip")
    }

    /// Entries that would leave the extraction folder (`../x`, `/x`): refused, nothing lands outside.
    @Test func zipEntriesThatClimbOutAreRefusedAndNothingLeaks() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let archive = f.work.appendingPathComponent("climb.baerchen-backup")
        try HostileZip.write(
            [("../escape-1.txt", Data("1".utf8)), ("../../escape-2.txt", Data("2".utf8)),
             ("/escape-3.txt", Data("3".utf8)), ("notes/../../escape-4.txt", Data("4".utf8))],
            to: archive)
        try f.expectRefused(archive, .invalidManifest, "climbing entries")
        let temporary = FileManager.default.temporaryDirectory
        for n in 1...4 {
            #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("escape-\(n).txt").path))
            #expect(!FileManager.default.fileExists(atPath: f.work.appendingPathComponent("escape-\(n).txt").path))
        }
    }

    /// Size bombs: an entry that declares more than the per-file limit, and one whose data runs
    /// past the size it declares. Neither is inflated into the target.
    @Test func sizeBombsAreRefusedBeforeTheyExpand() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let declared = f.work.appendingPathComponent("declared.baerchen-backup")
        try HostileZip.write([("manifest.json", Data("{}".utf8))], declaredSize: 0x7FFF_FFFF, to: declared)
        try f.expectRefused(declared, .invalidManifest, "an entry declaring 2 GiB")
        let lying = f.work.appendingPathComponent("lying.baerchen-backup")
        try HostileZip.write([("manifest.json", Data(repeating: 0x20, count: 1 << 20))], declaredSize: 10, to: lying)
        try f.expectRefused(lying, nil, "an entry longer than it declares")
    }
}

/// A minimal PKZip writer (stored entries) for archives `ditto -c` cannot make: entry names with
/// `..` or a leading `/`, and sizes that lie (`declaredSize` replaces the uncompressed size).
enum HostileZip {
    static func write(_ entries: [(String, Data)], declaredSize: UInt32? = nil, to url: URL) throws {
        var out = Data()
        var central = Data()
        for (name, data) in entries {
            let offset = UInt32(out.count)
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let size = UInt32(data.count), claimed = declaredSize ?? UInt32(data.count)
            out.append(le32(0x0403_4b50))
            out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(0x21))
            out.append(le32(crc)); out.append(le32(size)); out.append(le32(claimed))
            out.append(le16(UInt16(nameBytes.count))); out.append(le16(0))
            out.append(nameBytes); out.append(data)

            central.append(le32(0x0201_4b50))
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc)); central.append(le32(size)); central.append(le32(claimed))
            central.append(le16(UInt16(nameBytes.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4b50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset)); out.append(le16(0))
        try out.write(to: url)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
