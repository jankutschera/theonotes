// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// REL-R70 … REL-R79: the notes a brand-new library starts with.
@Suite struct GettingStartedNotesTests {
    struct Library {
        let paths: AppPaths, db: AppDatabase, store: NoteStore
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("getting-started-\(UUID())"))
            try paths.createDirectories()
            db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        var backup: LibraryBackup { LibraryBackup(database: db, paths: paths) }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        func seeded() throws -> Bool { try Settings(db: db).value(.gettingStartedSeeded) }
        func gettingStarted() throws -> [Note] {
            let wanted = Set(GettingStartedNotes.ids)
            return try store.allNotes(location: .notes).filter { wanted.contains($0.id) }
        }
        func everyNote() throws -> [Note] {
            try NoteLocation.allCasesForTests.flatMap { try store.allNotes(location: $0) }
        }
    }

    static let expectedTitles = [
        "Welcome to Theo Notes", "Write and format", "Tags and links", "Find anything", "Capture & Next Up",
        "Keep notes private", "Import, export and back up", "Use Theo Notes with Claude", "Ideas, Logs and References",
        "Example idea: a Friday look back", "Example log: planning call, 2026-11-03", "Example reference: restart the home router",
    ]

    static let expectedTypeTags = [
        "Ideas, Logs and References": "ref", "Example idea: a Friday look back": "idea",
        "Example log: planning call, 2026-11-03": "log", "Example reference: restart the home router": "ref",
    ]

    // MARK: Created exactly once

    @Test func aBrandNewEmptyLibraryGetsAllNotesExactlyOnce() throws {
        let library = try Library(); defer { library.cleanup() }
        let made = try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        #expect(made == GettingStartedNotes.ids)
        let notes = try library.everyNote()
        #expect(notes.count == 12)
        #expect(Set(notes.map(\.id)) == Set(GettingStartedNotes.ids))
        #expect(try library.seeded())
        // Reading order: the default list (newest first) shows the notes in the order they are meant to be read.
        let listed = try library.store.allNotes(location: .notes).map(\.title)
        #expect(listed == Self.expectedTitles)

        // A second launch's call, and any further one, changes nothing.
        let again = try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        #expect(again.isEmpty)
        #expect(try library.everyNote().count == 12)
    }

    // MARK: Not created

    @Test func aLibraryThatIsNotNewIsLeftAlone() throws {
        let library = try Library(); defer { library.cleanup() }
        let made = try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: false)
        #expect(made.isEmpty)
        #expect(try library.everyNote().isEmpty)
        #expect(try !library.seeded())
    }

    @Test func aLibraryWithNotesIsLeftAlone() throws {
        let library = try Library(); defer { library.cleanup() }
        _ = try library.store.create(text: "# Mine\nstays alone")
        #expect(try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true).isEmpty)
        #expect(try library.everyNote().count == 1)
        #expect(try !library.seeded())
        // Also when the only note sits in the Trash or the Archive.
        let other = try Library(); defer { other.cleanup() }
        let note = try other.store.create(text: "gone")
        try other.store.trash([note.id])
        #expect(try GettingStartedNotes.seedNewLibrary(in: other.store, isNewLibrary: true).isEmpty)
    }

    @Test func aLibraryThatWasImportedIntoIsLeftAloneEvenWhenEmptiedAgain() throws {
        let library = try Library(); defer { library.cleanup() }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = ImportedNoteDraft(text: "# From elsewhere\nbody", createdAt: stamp, modifiedAt: stamp)
        let note = try library.store.importNote(
            draft,
            externalRef: ExternalRefWrite(
                source: "test", externalId: "x1", lastSeenModified: stamp, lastSeenHash: "h", lastSeenTextHash: "t",
                lastSeenMeta: SourceMetadata(location: .notes, isPinnedGlobal: false, tagPins: [], isReadOnly: false)))
        try library.store.deletePermanently([note.id])
        #expect(try library.everyNote().isEmpty)
        // The import record (a tombstone) remains: this library has been imported into.
        #expect(try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true).isEmpty)
        #expect(try library.everyNote().isEmpty)
    }

    @Test func aRestoredLibraryIsLeftAlone() throws {
        let source = try Library(), target = try Library()
        defer { source.cleanup(); target.cleanup() }
        _ = try source.store.create(text: "# Restored note\nfrom a backup")
        let archive = source.paths.root.appendingPathComponent("backup.baerchen-backup")
        try source.backup.create(at: archive)
        _ = try target.backup.restore(archive, mode: .replaceAll)
        #expect(try target.everyNote().count == 1)
        #expect(try GettingStartedNotes.seedNewLibrary(in: target.store, isNewLibrary: true).isEmpty)
        #expect(try target.gettingStarted().isEmpty)
        // A backup of a seeded library, restored into a library that was seeded before: no second set.
        let seededSource = try Library(); defer { seededSource.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: seededSource.store, isNewLibrary: true)
        let seededArchive = seededSource.paths.root.appendingPathComponent("seeded.baerchen-backup")
        try seededSource.backup.create(at: seededArchive)
        let empty = try Library(); defer { empty.cleanup() }
        _ = try empty.backup.restore(seededArchive, mode: .replaceAll)
        #expect(try GettingStartedNotes.seedNewLibrary(in: empty.store, isNewLibrary: true).isEmpty)
        #expect(try empty.everyNote().count == 12)
    }

    // MARK: Not recreated

    @Test func deletedNotesAreNotRecreatedByALaterLaunch() throws {
        let library = try Library(); defer { library.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        try library.store.deletePermanently(GettingStartedNotes.ids)
        #expect(try library.everyNote().isEmpty)
        // Even if a later launch wrongly said "new": the library is empty again, but it was seeded.
        #expect(try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true).isEmpty)
        #expect(try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: false).isEmpty)
        #expect(try library.everyNote().isEmpty)
    }

    @Test func trashedNotesAreNotRecreatedEither() throws {
        let library = try Library(); defer { library.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        try library.store.trash(GettingStartedNotes.ids)
        #expect(try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true).isEmpty)
        #expect(try library.store.allNotes(location: .trash).count == 12)
        #expect(try library.store.allNotes(location: .notes).isEmpty)
    }

    // MARK: Help ▸ Restore Getting Started Notes

    @Test func restoreAddsOnlyTheMissingOnes() throws {
        let library = try Library(); defer { library.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        let ids = GettingStartedNotes.ids

        let welcome = try #require(try library.store.note(id: ids[0]))
        let edited = try library.store.updateText(
            id: welcome.id, text: "# Welcome to Theo Notes\n\nmy own words", expectedRevision: welcome.revision)
        try library.store.deletePermanently([ids[1]])
        try library.store.trash([ids[3]])
        try library.store.archive([ids[2]])

        let result = try GettingStartedNotes.restoreMissing(in: library.store)
        #expect(result.added == [ids[1]])
        #expect(result.movedBackFromTrash == [ids[3]])
        #expect(Set(result.alreadyPresent) == Set([ids[0], ids[2], ids[4], ids[5], ids[6], ids[7], ids[8], ids[9], ids[10], ids[11]]))

        // The edited note keeps the edit; the archived one stays archived; the deleted one is back as it was written.
        #expect(try library.store.note(id: ids[0])?.text == edited.text)
        #expect(try library.store.note(id: ids[2])?.location == .archive)
        #expect(try library.store.note(id: ids[3])?.location == .notes)
        let brought = try #require(try library.store.note(id: ids[1]))
        #expect(brought.location == .notes)
        #expect(brought.title == "Write and format")
        #expect(brought.text == (try GettingStartedNotes.notes())[1].text)
        #expect(try library.everyNote().count == 12)

        // Running it again changes nothing.
        let second = try GettingStartedNotes.restoreMissing(in: library.store)
        #expect(!second.changedAnything)
        #expect(try library.everyNote().count == 12)
        #expect(try library.store.note(id: ids[0])?.text == edited.text)
    }

    @Test func restoreWorksInAnyLibraryAndMatchesTheFirstSet() throws {
        let fresh = try Library(), later = try Library()
        defer { fresh.cleanup(); later.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: fresh.store, isNewLibrary: true)
        _ = try later.store.create(text: "# Existing library\nwith a note")
        let result = try GettingStartedNotes.restoreMissing(in: later.store)
        #expect(result.added == GettingStartedNotes.ids)
        #expect(try later.store.allNotes().count == 13)
        // Same ids, texts and stamps as the first launch of a new library would have made.
        for id in GettingStartedNotes.ids {
            let a = try #require(try fresh.store.note(id: id)), b = try #require(try later.store.note(id: id))
            #expect(a.text == b.text && a.createdAt == b.createdAt && a.modifiedAt == b.modifiedAt)
        }
        // The launch rule still applies afterwards: a later launch does not add anything.
        #expect(try GettingStartedNotes.seedNewLibrary(in: later.store, isNewLibrary: true).isEmpty)
    }

    // MARK: Stable ids

    @Test func idsAreFixedLiterals() throws {
        #expect(GettingStartedNotes.ids == [
            "5e9a6e60-abf2-540e-82ef-aaab1a2a77b7", "f9fd6747-5aac-517f-811e-616b1ed0cb6f",
            "aad307cb-32a2-5639-8be0-39cbb28af780", "51b6deb6-bbce-5825-9ec4-519bb427506b",
            "4870293e-d190-5e99-a8d1-81d22e77ab35", "4813ad1d-fabd-567a-990d-e99f795342f3",
            "7b4f0da1-8a33-530f-a081-9d06aeca58de", "151e810a-987f-5ae7-a3ec-afd97ea5fa9b",
            "cbe42bd2-be8f-589a-a3e6-5a7b77d41f51", "bfb7c70d-fc6f-5046-b081-b5107afdc3bb",
            "221557c5-c711-5a1d-b0ba-6347e62da1f4", "f47987a3-ac35-5b16-8fe7-b5650224bdae",
        ])
        #expect(Set(GettingStartedNotes.ids).count == 12)
        for id in GettingStartedNotes.ids { try SyncWire.validateID(id) }
        // And they are the documented derivation: SHA-256 of the name, first 16 bytes, version 5.
        for (entry, id) in zip(GettingStartedNotes.entries, GettingStartedNotes.ids) {
            #expect(Self.derivedID(slug: entry.slug) == id)
        }
    }

    @Test func twoDevicesMakeIdenticalNotesAndASyncMergeKeepsOne() throws {
        let a = try Library(), b = try Library()
        defer { a.cleanup(); b.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: a.store, isNewLibrary: true)
        Thread.sleep(forTimeInterval: 0.01)
        try GettingStartedNotes.seedNewLibrary(in: b.store, isNewLibrary: true)
        for id in GettingStartedNotes.ids {
            let left = try #require(try a.store.note(id: id)), right = try #require(try b.store.note(id: id))
            #expect(left.text == right.text)
            #expect(left.createdAt == right.createdAt && left.modifiedAt == right.modifiedAt)
            // What each device would upload for the same id: equal payloads, so the merge keeps one note.
            let tags = NoteParser.metadata(for: left.text).tags
            let local = SyncNotePayload(note: left, directTags: tags, pinnedTags: [], attachmentIds: [])
            let remote = SyncNotePayload(note: right, directTags: tags, pinnedTags: [], attachmentIds: [])
            let merged = try SyncNoteMerge.reconcile(
                base: nil, local: local, remote: remote, entityID: id, rejectedMutationID: "mutation-1", remoteRevision: 1)
            #expect(merged == .merged(local))
        }
        // If one device edited its copy first, there is no base: the merge keeps the edit at the id and
        // makes the other version a conflict copy. It never silently drops text.
        let welcome = try #require(try a.store.note(id: GettingStartedNotes.ids[0]))
        let edited = try a.store.updateText(id: welcome.id, text: welcome.text + "\nmine", expectedRevision: welcome.revision)
        let other = try #require(try b.store.note(id: welcome.id))
        let tags = NoteParser.metadata(for: edited.text).tags
        let result = try SyncNoteMerge.reconcile(
            base: nil, local: SyncNotePayload(note: edited, directTags: tags, pinnedTags: [], attachmentIds: []),
            remote: SyncNotePayload(note: other, directTags: tags, pinnedTags: [], attachmentIds: []),
            entityID: welcome.id, rejectedMutationID: "mutation-2", remoteRevision: 2)
        guard case .conflict(let local, let copy) = result else { Issue.record("expected a conflict copy"); return }
        #expect(local?.id == welcome.id)
        #expect(copy?.id != welcome.id)
    }

    // MARK: Ordinary notes

    @Test func theyAreNormalEditableNotes() throws {
        let library = try Library(); defer { library.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        for note in try library.everyNote() {
            #expect(note.location == .notes)
            #expect(!note.isReadOnly && !note.isLocked && !note.isPinnedGlobal)
            #expect(note.encryptedPayload == nil && note.revision == 1)
        }
        let first = try #require(try library.store.note(id: GettingStartedNotes.ids[4]))
        let edited = try library.store.updateText(id: first.id, text: "# Mine now\n\nchanged", expectedRevision: first.revision)
        #expect(edited.title == "Mine now" && edited.revision == 2)
        try library.store.trash([first.id])
        try library.store.restore([first.id])
        try library.store.addTag("extra", to: [first.id], position: .bottom)
        #expect(try library.store.note(id: first.id)?.text.contains("#extra") == true)
    }

    // MARK: The texts

    @Test func textsHaveTheExpectedTitlesAndTheOneTag() throws {
        let notes = try GettingStartedNotes.notes()
        #expect(notes.map(\.title) == Self.expectedTitles)
        for note in notes {
            let metadata = NoteParser.metadata(for: note.text)
            // The guide note is itself a Reference; the three examples carry their own type tag as the last tag.
            let typeTag = Self.expectedTypeTags[note.title]
            let expectedTags = typeTag.map { [GettingStartedNotes.tag, $0] } ?? [GettingStartedNotes.tag]
            #expect(metadata.tags == expectedTags, "\(note.title) tags: \(metadata.tags)")
            #expect(NoteType.of(directTags: metadata.tags) == typeTag.flatMap { NoteType.of(directTags: [$0]) }, "\(note.title) type")
            if let typeTag { #expect(note.text.hasSuffix("\n#\(typeTag)\n"), "\(note.title) ends with its type tag") }
            if note.title.hasPrefix("Example ") {
                #expect(note.text.contains("[[Ideas, Logs and References]]"), "\(note.title) links to the guide")
                #expect(note.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 15, "\(note.title) is short")
            }
            #expect(!metadata.subtitle.isEmpty, "\(note.title) has a preview")
            #expect(note.text.hasPrefix("# \(note.title)\n\n#getting started#\n"), "\(note.title) title then tag")
            #expect(!note.text.contains("\r"))
        }
    }

    @Test func theExampleNotesIndexToTheirType() throws {
        let library = try Library(); defer { library.cleanup() }
        try GettingStartedNotes.seedNewLibrary(in: library.store, isNewLibrary: true)
        let wanted: [(String, NoteType)] = [("example-idea", .idea), ("example-log", .log), ("example-reference", .reference)]
        for (slug, type) in wanted {
            let note = try #require(try library.store.note(id: Self.derivedID(slug: slug)))
            #expect(NoteType.of(directTags: NoteParser.metadata(for: note.text).tags) == type, "\(slug)")
            let stored = try library.db.pool.read { try String.fetchOne($0, sql: "SELECT noteType FROM note WHERE id = ?", arguments: [note.id]) }
            #expect(stored == type.rawValue, "\(slug) indexed type")
        }
    }

    @Test func linksBetweenTheNotesResolve() throws {
        let notes = try GettingStartedNotes.notes()
        let headings = Dictionary(uniqueKeysWithValues: notes.map { note in
            (note.title, Set(NoteParser.metadata(for: note.text).headings.map(\.text)))
        })
        var live = 0
        for note in notes {
            for link in NoteParser.metadata(for: note.text).wikiLinks {
                let target = link.target.isEmpty ? note.title : link.target
                let known = try #require(headings[target], "\(note.title) links to \(target), which is not a getting started note")
                if let heading = link.heading { #expect(known.contains(heading), "\(target) has no heading \(heading)") }
                live += 1
            }
        }
        #expect(live >= 10)
        // The welcome note is the entry: every guide (notes 2 to 9) is one of its links (STARTER-R16). The first shipped
        // welcome text is frozen apart (STARTER-R1), so linking the ninth note moves no merge base.
        let welcomeTargets = Set(NoteParser.metadata(for: notes[0].text).wikiLinks.map(\.target))
        #expect(welcomeTargets == Set(Self.expectedTitles[1..<9]))
    }

    @Test func textsPassTheCopyRules() throws {
        let notes = try GettingStartedNotes.notes()
        let condition = try Regex(#"(?i)\b(adhd|adhs)\b"#)
        for note in notes {
            #expect(note.text.firstMatch(of: condition) == nil, "\(note.title) names a condition")
            // The only place that may name the other app is the import compatibility line.
            for line in note.text.split(separator: "\n", omittingEmptySubsequences: false) where line.localizedCaseInsensitiveContains("bear") {
                #expect(note.title == "Import, export and back up" && line.contains("Import From ▸ Bear…"), "\(note.title): \(line)")
            }
            // Sync is explained in one place, and the Claude note says that its writes reach iPhone and iPad (STARTER-R16).
            if !["Import, export and back up", "Use Theo Notes with Claude"].contains(note.title) {
                #expect(!note.text.localizedCaseInsensitiveContains("sync"), "\(note.title) mentions sync")
                #expect(!note.text.localizedCaseInsensitiveContains("icloud"), "\(note.title) mentions iCloud")
            }
        }
        // The focus features carry their product name.
        let capture = try #require(notes.first { $0.title == "Capture & Next Up" })
        #expect(capture.text.contains("Capture & Next Up") && capture.text.contains("Next Up"))
        let bearLines = notes.flatMap { $0.text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("bear") } }
        #expect(bearLines.count == 1)
    }

    @Test func theResourcesAreExactlyTheCatalog() throws {
        let urls = Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        let shipped = Set(urls.map { $0.deletingPathExtension().lastPathComponent }.filter { $0.hasPrefix("getting-started-") })
        #expect(shipped == Set(GettingStartedNotes.entries.map(\.resource)))
        #expect(Bundle.module.url(forResource: "getting-started-source", withExtension: "txt") != nil)
    }

    static let copyDocumentURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // …/Packages/TheoNotesCore/Tests/TheoNotesCoreTests -> repo root
        return url.appendingPathComponent("docs/release/getting-started-copy.md")
    }()

    /// The approval document is the bundled files word for word (REL-R79): it cannot drift from what ships.
    /// It lives with the private release papers (PUB-R1), so a public checkout skips this check.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: copyDocumentURL.path), "needs the private release papers"))
    func theCopyDocumentHoldsEveryTextVerbatim() throws {
        let document = try String(contentsOf: Self.copyDocumentURL, encoding: .utf8)
        for note in try GettingStartedNotes.notes() {
            #expect(document.contains("`````markdown\n" + note.text + "`````"), "\(note.title) is not verbatim in the document")
            #expect(document.contains(note.id), "\(note.title) id is listed")
        }
    }

    private static func derivedID(slug: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("theonotes-getting-started:1:\(slug)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 0x50
        bytes[8] = (bytes[8] & 63) | 0x80
        let h = bytes.map { String(format: "%02x", $0) }
        return [h[0..<4].joined(), h[4..<6].joined(), h[6..<8].joined(), h[8..<10].joined(), h[10..<16].joined()]
            .joined(separator: "-")
    }
}

extension NoteLocation {
    static let allCasesForTests: [NoteLocation] = [.notes, .archive, .trash]
}
