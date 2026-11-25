// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// M8 Task 2: export from a temporary library A, import into a fresh temporary library B.
@Suite struct ExportRoundTripTests {
    struct Library {
        let tmp: TempPaths
        let db: AppDatabase
        let store: NoteStore

        init() throws {
            tmp = try TempPaths()
            db = try AppDatabase.inMemory()
            store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        }

        func notes() throws -> [Note] {
            try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY createdAt, id") }
        }

        func pins(_ noteId: String) throws -> [String] {
            try db.pool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT tag.displayPath FROM note_pin JOIN tag ON tag.id = note_pin.tagId
                    WHERE noteId = ? ORDER BY tag.pathKey
                    """, arguments: [noteId])
            }
        }

        func attachments(_ note: Note) -> [String: String] {
            let dir = tmp.paths.attachments.appendingPathComponent(note.id)
            var out: [String: String] = [:]
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let data = (try? Data(contentsOf: URL(fileURLWithPath: dir.path + "/" + name))) ?? Data()
                out[name] = sha256(data)
            }
            return out
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    let a: Library
    let b: Library
    let scratch: Scratch
    let base = 1_760_000_000.0

    init() throws {
        a = try Library()
        b = try Library()
        scratch = try Scratch()
    }

    private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    @discardableResult
    private func add(
        _ text: String, _ n: Double, location: NoteLocation = .notes, pinned: Bool = false,
        tagPins: [String] = [], readOnly: Bool = false, files: [(String, Data)] = []
    ) throws -> Note {
        try a.store.importNote(ImportedNoteDraft(
            text: text, createdAt: Date(timeIntervalSince1970: base + n + 0.123),
            modifiedAt: Date(timeIntervalSince1970: base + n + 500.456), location: location,
            isPinnedGlobal: pinned, tagPins: tagPins, isReadOnly: readOnly,
            attachments: files.map { ImportedAttachment(filename: $0.0, data: $0.1) }))
    }

    /// Plans and writes `ids` flat into a fresh folder.
    @discardableResult
    private func export(
        _ ids: [String], _ format: FileExportFormat, keepTags: Bool = true, folder: String = "out"
    ) throws -> (dir: URL, files: [ExportedFiles], plan: ExportPlan.Result) {
        let dir = try scratch.dir(folder)
        let plan = ExportPlan.selection(try a.store.exportCandidates(ids: ids))
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        let files = try plan.items.map {
            try exporter.write($0, format: format, under: dir, options: ExportOptions(keepTags: keepTags))
        }
        return (dir, files, plan)
    }

    @discardableResult
    private func reimport(_ dir: URL) throws -> FileImportReport {
        let importer = FileImporter(
            store: b.store, paths: b.tmp.paths, temporaryDirectory: scratch.url.appendingPathComponent("import-tmp"))
        let report = try importer.importItems([dir])
        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
        return report
    }

    private func match(_ note: Note, in notes: [Note]) throws -> Note {
        try #require(notes.first { millis($0.createdAt) == millis(note.createdAt) })
    }

    // MARK: - Round trips

    @Test func markdownRoundTripKeepsTextDatesAndAttachments() throws {
        let png = Data((0..<2000).map { UInt8($0 % 251) })
        let pdf = Data("%PDF-1.4 fake".utf8) + Data([0, 255, 7])
        let text = "# Trip\n\nBody #tag/sub and Üñí 日本\n\n![](photo%202.jpg)<!-- {\"width\":\"320\"} -->\n\n"
            + "[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let plain = try add("# Plain\n\nNo files.\n", 1)
        let trip = try add(text, 2, files: [("photo 2.jpg", png), ("a.pdf", pdf)])

        let result = try export([plain.id, trip.id], .markdown)
        #expect(result.files.allSatisfy { $0.missingAttachments.isEmpty })
        #expect(result.files[0].attachmentsFolder == nil)
        #expect(!FileManager.default.fileExists(atPath: result.dir.appendingPathComponent("Plain").path))
        try reimport(result.dir)

        let imported = try b.notes()
        #expect(imported.count == 2)
        for original in [plain, trip] {
            let copy = try match(original, in: imported)
            #expect(Array(copy.text.utf8) == Array(original.text.utf8))
            #expect(millis(copy.createdAt) == millis(original.createdAt))
            #expect(millis(copy.modifiedAt) == millis(original.modifiedAt))
            #expect(b.attachments(copy) == a.attachments(original))
        }
        #expect(a.attachments(trip).count == 2)
    }

    @Test func textBundleRoundTripKeepsFlagsAndPins() throws {
        let pinned = try add("# Pinned\n#work #home\n", 1, pinned: true, tagPins: ["work"], readOnly: true)
        let archived = try add("# Archived\n#work\n", 2, location: .archive)
        let trashed = try add("# Trashed\n", 3, location: .trash)
        let withFile = try add("# File\n\n![](x.png)\n", 4, files: [("x.png", Data([1, 2, 3, 4]))])

        let result = try export([pinned.id, archived.id, trashed.id, withFile.id], .textBundle)
        try reimport(result.dir)

        let imported = try b.notes()
        #expect(imported.count == 4)
        for original in [pinned, archived, trashed, withFile] {
            let copy = try match(original, in: imported)
            #expect(Array(copy.text.utf8) == Array(original.text.utf8))
            #expect(copy.location == original.location)
            #expect(copy.isPinnedGlobal == original.isPinnedGlobal)
            #expect(copy.isReadOnly == original.isReadOnly)
            #expect(millis(copy.modifiedAt) == millis(original.modifiedAt))
            #expect(try b.pins(copy.id) == a.pins(original.id))
            #expect(b.attachments(copy) == a.attachments(original))
        }
        #expect(try a.pins(pinned.id) == ["work"])
        #expect(try match(pinned, in: imported).isPinnedGlobal)
        #expect(try match(pinned, in: imported).isReadOnly)
        #expect(try match(archived, in: imported).location == .archive)
        #expect(try match(trashed, in: imported).location == .trash)
    }

    @Test func awkwardAttachmentNamesAndTitlesRoundTrip() throws {
        let nfd = "U\u{308}ni\u{308}code.pdf"
        #expect(Array(nfd.utf8) != Array(nfd.precomposedStringWithCanonicalMapping.utf8))
        let link = { (name: String) in AttachmentLinkRewriter.encode(name) }
        func file(_ name: String, _ seed: UInt8) -> (String, Data) { (name, Data(repeating: seed, count: 64 + Int(seed))) }

        let same = try add("# Same\n\n![](photo.jpg)\n", 1, files: [file("photo.jpg", 1)])
        let lower = try add("# same\n\n![](Photo.jpg)\n", 2, files: [file("Photo.jpg", 2)])
        let awkward = try add(
            "![](\(link("photo 2.jpg")))\n\n![](\(link("100%.png")))\n\n"
                + "[a#b (1).pdf](\(link("a#b (1).pdf")))<!-- {\"embed\":\"true\"} -->\n\n"
                + "[x](\(link(nfd)))<!-- {\"embed\":\"true\"} -->\n",
            3, files: [file("photo 2.jpg", 3), file("100%.png", 4), file("a#b (1).pdf", 5), file(nfd, 6)])
        let untitled = try add("![](\(link("photo 2.jpg")))\n", 4, files: [file("photo 2.jpg", 7)])
        // Spelling forms the source used must come back as written: angle brackets with raw
        // spaces and a title, lower-case percent escapes.
        let spelling = try add(
            "# Spelling\n\n![x](<photo 3.jpg> \"cap\")\n\n![](caf%c3%a9.png)\n\n![](<p q.png>)<!-- {\"width\":\"9\"} -->\n",
            5, files: [file("photo 3.jpg", 8), file("caf\u{E9}.png", 9), file("p q.png", 10)])
        #expect(awkward.title == "" && untitled.title == "")

        for format in [FileExportFormat.markdown, .textBundle] {
            let name = "awkward-\(format.rawValue)"
            let result = try export([same.id, lower.id, awkward.id, untitled.id, spelling.id], format, folder: name)
            #expect(result.plan.items.map(\.stem) == ["Same", "same 2", "Untitled", "Untitled 2", "Spelling"])

            // Every attachment link resolves on disk, relative to the exported text.
            for (file, original) in zip(result.files, [same, lower, awkward, untitled, spelling]) {
                let primary = file.primary
                let textURL = format == .markdown ? primary : primary.appendingPathComponent("text.md")
                let text = try String(contentsOf: textURL, encoding: .utf8)
                let targets = NoteParser.attachmentLinkTargets(in: text)
                #expect(targets.count == NoteParser.attachmentLinks(in: original.text).count)
                let bytes = Array(text.utf8)
                for target in targets {
                    let written = String(decoding: bytes[target.bytes], as: UTF8.self)
                    let decoded = try #require(written.removingPercentEncoding)
                    let resolved = URL(fileURLWithPath: textURL.deletingLastPathComponent().path + "/" + decoded)
                    #expect(FileManager.default.fileExists(atPath: resolved.path), "\(written) does not resolve")
                }
            }

            let freshB = try Library()
            let importer = FileImporter(
                store: freshB.store, paths: freshB.tmp.paths,
                temporaryDirectory: scratch.url.appendingPathComponent("tmp-\(name)"))
            let report = try importer.importItems([result.dir])
            #expect(report.errors.isEmpty && report.warnings.isEmpty, "\(report.warnings) \(report.errors)")
            let imported = try freshB.notes()
            #expect(imported.count == 5)
            for original in [same, lower, awkward, untitled, spelling] {
                let copy = try match(original, in: imported)
                #expect(Array(copy.text.utf8) == Array(original.text.utf8), "\(format.rawValue): \(original.text)")
                #expect(freshB.attachments(copy) == a.attachments(original))
            }
        }
    }

    /// Found by `bear-oracle --roundtrip-check` on a real library copy (M8-R133): an attachment
    /// named like a note file (`.txt`, `.md`) was left as a dead `assets/…` link and dropped,
    /// because the importer reads such a link target as a link to another note.
    @Test func textFileAttachmentsSurviveTheTextBundleRoundTrip() throws {
        let text = "# Notes\n\n[log 1.txt](log%201.txt)<!-- {\"embed\":\"true\"} -->\n\n"
            + "[readme.md](readme.md)<!-- {\"embed\":\"true\"} -->\n\nmore\n"
        let note = try add(text, 1, files: [("log 1.txt", Data("line one\n".utf8)), ("readme.md", Data("# not a note\n".utf8))])

        try reimport(try export([note.id], .textBundle, folder: "bundle").dir)
        let copy = try #require(try b.notes().first)
        #expect(Array(copy.text.utf8) == Array(text.utf8))
        #expect(b.attachments(copy) == a.attachments(note))
        #expect(b.attachments(copy).count == 2)
    }

    @Test func aMarkdownLinkToATextFileStaysALinkToANote() throws {
        // A plain .md file linking a sibling note file must not copy that file as an attachment.
        let dir = try scratch.dir("vault")
        try Data("# One\n\nsee [two](two.md)\n".utf8).write(to: dir.appendingPathComponent("one.md"))
        try Data("# Two\n".utf8).write(to: dir.appendingPathComponent("two.md"))
        let importer = FileImporter(
            store: b.store, paths: b.tmp.paths, temporaryDirectory: scratch.url.appendingPathComponent("tmp-vault"))
        _ = try importer.importItems([dir.appendingPathComponent("one.md")])
        let one = try #require(try b.notes().first)
        #expect(one.text == "# One\n\nsee [two](two.md)\n")
        #expect(b.attachments(one).isEmpty)
    }

    @Test func frontMatterTagsSurviveTheTextBundleRoundTrip() throws {
        let text = "---\ntags: [x]\n---\n# FM\n\nBody\n"
        let note = try add(text, 1)

        try reimport(try export([note.id], .textBundle, folder: "bundle").dir)
        #expect(try b.notes().first.map { Array($0.text.utf8) } == Array(text.utf8))

        // A plain .md import still appends the front matter tags: a documented limit.
        let other = try Library()
        let md = try export([note.id], .markdown, folder: "md").dir
        let importer = FileImporter(
            store: other.store, paths: other.tmp.paths, temporaryDirectory: scratch.url.appendingPathComponent("tmp-md"))
        _ = try importer.importItems([md])
        #expect(try other.notes().first?.text == text + "\n#x")
    }

    @Test func keepTagsOffRemovesTagsInEveryFileFormat() throws {
        let note = try add("# T\nsee #a here\n\n#b #c/d#\n", 1)
        for format in FileExportFormat.allCases {
            let result = try export([note.id], format, keepTags: false, folder: "notags-\(format.rawValue)")
            let primary = result.files[0].primary
            let url = format == .textBundle ? primary.appendingPathComponent("text.md") : primary
            let text = try String(contentsOf: url, encoding: .utf8)
            switch format {
            case .markdown, .textBundle: #expect(text == "# T\nsee here\n\n")
            case .plainText: #expect(text == "T\nsee here\n\n")
            }
        }
        let kept = try export([note.id], .plainText, keepTags: true, folder: "tags")
        #expect(try String(contentsOf: kept.files[0].primary, encoding: .utf8) == "T\nsee #a here\n\n#b #c/d#\n")
        // The stored note is untouched.
        #expect(try a.store.note(id: note.id)?.text == "# T\nsee #a here\n\n#b #c/d#\n")
    }

    @Test func exportedFilesCarryTheNoteDates() throws {
        let note = try add("# Dated\n\n![](x.png)\n", 1, files: [("x.png", Data([9, 9]))])
        for format in FileExportFormat.allCases {
            let result = try export([note.id], format, folder: "dates-\(format.rawValue)")
            var urls = [result.files[0].primary]
            if let folder = result.files[0].attachmentsFolder {
                urls.append(folder)
                urls.append(folder.appendingPathComponent("x.png"))
            }
            if format == .textBundle {
                urls.append(result.files[0].primary.appendingPathComponent("text.md"))
                urls.append(result.files[0].primary.appendingPathComponent("info.json"))
            }
            #expect(urls.count >= (format == .plainText ? 1 : 3))
            for url in urls {
                let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                #expect(millis(try #require(values.creationDate)) == millis(note.createdAt), "\(url.lastPathComponent) created")
                #expect(millis(try #require(values.contentModificationDate)) == millis(note.modifiedAt), "\(url.lastPathComponent) modified")
            }
        }
    }

    // MARK: - Files and refusals

    @Test func writeRefusesALockedNote() throws {
        let locked = Note(
            id: "locked-1", text: "", title: "Secret", titleKey: "secret",
            createdAt: Date(timeIntervalSince1970: base), modifiedAt: Date(timeIntervalSince1970: base),
            isLocked: true, encryptedPayload: Data([1, 2, 3, 4]))
        try a.db.pool.write { try locked.insert($0) }
        let dir = try scratch.dir("locked")
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        for format in FileExportFormat.allCases {
            #expect(throws: ExportError.noteLocked(id: "locked-1")) {
                try exporter.write(
                    ExportItem(noteId: "locked-1", folder: ["sub", "deeper"], stem: "Secret"),
                    format: format, under: dir, options: ExportOptions())
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func writeThrowsNoteNotFoundForAGoneIdAndRefusesUnsafeNames() throws {
        let dir = try scratch.dir("gone")
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        #expect(throws: StoreError.noteNotFound(id: "nope")) {
            try exporter.write(ExportItem(noteId: "nope", folder: [], stem: "x"), format: .markdown, under: dir, options: ExportOptions())
        }
        let note = try add("# Real\n", 1)
        for bad in [ExportItem(noteId: note.id, folder: [], stem: "../x"), ExportItem(noteId: note.id, folder: [".."], stem: "x"),
                    ExportItem(noteId: note.id, folder: [], stem: "")] {
            #expect(throws: ExportError.self) {
                try exporter.write(bad, format: .markdown, under: dir, options: ExportOptions())
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func writeNeverOverwritesAndLeavesNoPartialFolder() throws {
        let note = try add("# Twice\n", 1)
        let dir = try scratch.dir("twice")
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        let item = ExportItem(noteId: note.id, folder: ["f"], stem: "Twice")
        _ = try exporter.write(item, format: .markdown, under: dir, options: ExportOptions())
        #expect(throws: ExportError.destinationExists("Twice.md")) {
            try exporter.write(item, format: .markdown, under: dir, options: ExportOptions())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("f").path) == ["Twice.md"])
    }

    @Test func anUnrelatedFolderOnlyBlocksMarkdownWhileAttachmentsAreIncluded() throws {
        let note = try add("# Same\n", 1)
        let dir = try scratch.dir("sibling")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Same"), withIntermediateDirectories: true)
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        let item = ExportItem(noteId: note.id, folder: [], stem: "Same")
        #expect(throws: ExportError.destinationExists("Same")) {
            try exporter.write(item, format: .markdown, under: dir, options: ExportOptions())
        }
        _ = try exporter.write(item, format: .markdown, under: dir, options: ExportOptions(includeAttachments: false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Same", "Same.md"])
    }

    @Test func aNoteWithoutAttachmentsGetsNoFolderAndMissingFilesAreReported() throws {
        let plain = try add("# Plain\n", 1)
        let broken = try add("# Broken\n\n![](gone.png)\n\n![](..%2Fsecret.txt)\n\n![](linked.png)\n", 2, files: [("linked.png", Data([5]))])
        try Data("secret".utf8).write(to: a.tmp.paths.attachments.appendingPathComponent("secret.txt"))
        try FileManager.default.removeItem(atPath: a.tmp.paths.attachments.path + "/\(broken.id)/linked.png")

        let result = try export([plain.id, broken.id], .textBundle)
        #expect(result.files[0].attachmentsFolder == nil)
        #expect(!FileManager.default.fileExists(atPath: result.files[0].primary.appendingPathComponent("assets").path))
        #expect(result.files[1].attachmentsFolder == nil)
        #expect(result.files[1].missingAttachments == ["\(broken.id)/gone.png", "\(broken.id)/../secret.txt", "\(broken.id)/linked.png"])
        let leaked = try FileManager.default.subpathsOfDirectory(atPath: result.dir.path).filter { $0.contains("secret") }
        #expect(leaked.isEmpty)
    }

    @Test func textBundleInfoJSONHasTheDocumentedShape() throws {
        let note = try add("# Info\n#work\n", 1, location: .archive, pinned: true, tagPins: ["work"], readOnly: true)
        let result = try export([note.id], .textBundle)
        let data = try Data(contentsOf: result.files[0].primary.appendingPathComponent("info.json"))
        let info = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(info["version"] as? Int == 2)
        #expect(info["type"] as? String == "net.daringfireball.markdown")
        #expect(info["creatorIdentifier"] as? String == "com.truebrewbirdie.baerchen")
        #expect(info["transient"] as? Bool == false)
        let own = try #require(info["com.truebrewbirdie.baerchen"] as? [String: Any])
        #expect(own["id"] as? String == note.id)
        #expect(own["pinned"] as? Bool == true && own["archived"] as? Bool == true)
        #expect(own["trashed"] as? Bool == false && own["readOnly"] as? Bool == true)
        #expect(own["tagPins"] as? [String] == ["work"])
        #expect(own["creationDate"] as? String == "2025-10-09T08:53:21.123Z")
        #expect(own["modificationDate"] as? String == "2025-10-09T09:01:41.456Z")
        #expect(NoteExporter.iso8601(Date(timeIntervalSince1970: 1.0)) == "1970-01-01T00:00:01.000Z")
        #expect(NoteExporter.iso8601(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500Z")
    }

    // MARK: - Symbolic links

    private func entries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test func writeRefusesToGoThroughASymlinkedFolderComponent() throws {
        let note = try add("# Note\n\n![](x.png)\n", 1, files: [("x.png", Data([1]))])
        let dest = try scratch.dir("sym-dest")
        let outside = try scratch.dir("sym-outside")
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("out"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dest.appendingPathComponent("real/link"), withDestinationURL: outside)
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        for format in FileExportFormat.allCases {
            for folder in [["out"], ["out", "deeper"], ["real", "link"]] {
                #expect(throws: ExportError.self) {
                    try exporter.write(
                        ExportItem(noteId: note.id, folder: folder, stem: "Note"),
                        format: format, under: dest, options: ExportOptions())
                }
            }
        }
        #expect(try entries(outside).isEmpty)
        #expect(try entries(dest) == ["out", "real"])
        #expect(try entries(dest.appendingPathComponent("real")) == ["link"])
    }

    @Test func writeRefusesASymlinkAtTheFinalName() throws {
        let note = try add("# Note\n\n![](x.png)\n", 1, files: [("x.png", Data([1]))])
        let outside = try scratch.dir("final-outside")
        let target = outside.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        let exporter = NoteExporter(store: a.store, paths: a.tmp.paths)
        let cases: [(FileExportFormat, [String])] = [
            (.markdown, ["Note.md"]), (.markdown, ["Note"]), (.textBundle, ["Note.textbundle"]), (.plainText, ["Note.txt"]),
        ]
        for (format, names) in cases {
            for dangling in [false, true] {
                let dest = try scratch.dir("final-\(format.rawValue)-\(names[0])-\(dangling)")
                let to = dangling ? outside.appendingPathComponent("missing") : target
                for name in names {
                    try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent(name), withDestinationURL: to)
                }
                #expect(throws: ExportError.destinationExists(names[0])) {
                    try exporter.write(
                        ExportItem(noteId: note.id, folder: [], stem: "Note"),
                        format: format, under: dest, options: ExportOptions())
                }
                #expect(try entries(dest) == names)
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(try entries(outside) == ["target.txt"])
    }
}
