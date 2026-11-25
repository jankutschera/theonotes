// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CoreServices
import Synchronization
import GRDB
import Testing
@testable import TheoNotesCore

/// Editor attachments (M3 Task 9): unique names, the staging rule, rename, safe URLs, the Bear
/// Markdown they are written as, and the cleanup of files no committed text references.
@Suite struct AttachmentStoreTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let attachments: AttachmentStore

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        attachments = AttachmentStore(paths: tmp.paths, database: db)
    }

    private func names(_ noteId: String) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(noteId)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private var stagingEntries: [String] {
        let staging = tmp.paths.attachments.appendingPathComponent(".staging")
        return (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }

    private func batchRows() throws -> Int {
        try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM staging_batch") ?? 0 }
    }

    // MARK: - AttachmentStore

    @Test func testAddPicksUniqueNamesLikeBear() throws {
        let note = try store.create(text: "")
        #expect(try attachments.add(data: Data([1]), filename: "photo.jpg", to: note.id) == "photo.jpg")
        #expect(try attachments.add(data: Data([2]), filename: "photo.jpg", to: note.id) == "photo 2.jpg")
        #expect(try attachments.add(data: Data([3]), filename: "photo.jpg", to: note.id) == "photo 3.jpg")
        // The file system ignores case, so does the name check.
        #expect(try attachments.add(data: Data([4]), filename: "PHOTO.jpg", to: note.id) == "PHOTO 4.jpg")
        #expect(try attachments.add(data: Data([5]), filename: "README", to: note.id) == "README")
        #expect(try attachments.add(data: Data([6]), filename: "README", to: note.id) == "README 2")
        #expect(names(note.id) == ["PHOTO 4.jpg", "README", "README 2", "photo 2.jpg", "photo 3.jpg", "photo.jpg"])
        let url = try #require(attachments.url(for: "photo 2.jpg", noteId: note.id))
        #expect(try Data(contentsOf: url) == Data([2]))
        #expect(stagingEntries.isEmpty)
        #expect(try batchRows() == 0)
    }

    @Test func testAddCleansUpNamesItCannotUse() throws {
        let note = try store.create(text: "")
        #expect(try attachments.add(data: Data(), filename: "a/b:c.png", to: note.id) == "a-b-c.png")
        #expect(try attachments.add(data: Data(), filename: "", to: note.id) == "file")
        #expect(try attachments.add(data: Data(), filename: "..", to: note.id) == "file 2")
        #expect(try attachments.add(data: Data(), filename: ".hidden.txt", to: note.id) == "hidden.txt")
        let long = String(repeating: "é", count: 200) + ".pdf"
        let name = try attachments.add(data: Data(), filename: long, to: note.id)
        #expect(name.hasSuffix(".pdf"))
        #expect(name.utf8.count <= 200)
    }

    @Test func testAddCopiesAFile() throws {
        let note = try store.create(text: "")
        let source = tmp.paths.root.appendingPathComponent("Report final.pdf")
        try Data([9, 9]).write(to: source)
        #expect(try attachments.add(fileAt: source, to: note.id) == "Report final.pdf")
        #expect(try Data(contentsOf: #require(attachments.url(for: "Report final.pdf", noteId: note.id))) == Data([9, 9]))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func testRenameKeepsTheOldNameForUndo() throws {
        let note = try store.create(text: "")
        _ = try attachments.add(data: Data([1]), filename: "a.png", to: note.id)
        _ = try attachments.add(data: Data([2]), filename: "c.png", to: note.id)
        #expect(try attachments.rename("a.png", to: "b.png", in: note.id) == "b.png")
        #expect(try attachments.rename("a.png", to: "c.png", in: note.id) == "c 2.png")
        #expect(names(note.id) == ["a.png", "b.png", "c 2.png", "c.png"])
        #expect(try Data(contentsOf: #require(attachments.url(for: "c 2.png", noteId: note.id))) == Data([1]))
        #expect(throws: (any Error).self) { try attachments.rename("missing.png", to: "x.png", in: note.id) }
        try attachments.delete("b.png", from: note.id)
        #expect(names(note.id) == ["a.png", "c 2.png", "c.png"])
    }

    /// A link copied from note A and pasted into B: the file is copied into B (Bear behavior).
    @Test func testAPastedLinksFileIsCopiedIntoTheOtherNote() throws {
        let a = try store.create(text: "![](p.png)")
        let b = try store.create(text: "")
        _ = try attachments.add(data: Data([1]), filename: "p.png", to: a.id)
        _ = try attachments.add(data: Data([2]), filename: "p.png", to: b.id)
        let name = try attachments.copy("p.png", from: a.id, to: b.id)
        #expect(name == "p 2.png")
        #expect(try Data(contentsOf: #require(attachments.url(for: "p 2.png", noteId: b.id))) == Data([1]))
        #expect(throws: (any Error).self) { try attachments.copy("../x", from: a.id, to: b.id) }

        let text = "see ![](p.png) and ![](p.png)<!-- {\"width\":\"9\"} --> 👩‍👩‍👧 [p.png](p.png)"
        let items = [
            PastedAttachment(from: 4, to: 14, filename: "p.png"),
            PastedAttachment(from: 19, to: 51, filename: "p.png"),
            PastedAttachment(from: 0, to: 3, filename: "p.png"), // not a link: left alone
        ]
        #expect(AttachmentMarkdown.rewriting(text, items: items, renamed: ["p.png": "p 2.png"])
            == "see ![](p%202.png) and ![](p%202.png)<!-- {\"width\":\"9\"} --> 👩‍👩‍👧 [p.png](p.png)")
        #expect(AttachmentMarkdown.rewriting(text, items: items, renamed: ["p.png": "p.png"]) == text)
    }

    @Test func testURLIsOnlyForFilesInsideTheNotesDirectory() throws {
        let note = try store.create(text: "")
        let other = try store.create(text: "")
        _ = try attachments.add(data: Data([1]), filename: "a.png", to: note.id)
        _ = try attachments.add(data: Data([2]), filename: "secret.png", to: other.id)
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("out.png").path, withDestinationPath: "../\(other.id)/secret.png")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("abs.png").path, withDestinationPath: "/etc/hosts")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        #expect(attachments.url(for: "a.png", noteId: note.id) != nil)
        for name in ["", ".", "..", "../\(other.id)/secret.png", "a/b", "/etc/hosts", "out.png", "abs.png", "sub", "missing.png", "a\u{0}.png"] {
            #expect(attachments.url(for: name, noteId: note.id) == nil, "\(name)")
        }
        for noteId in ["", "..", "../x", "a/b", ".staging"] {
            #expect(attachments.url(for: "a.png", noteId: noteId) == nil, "\(noteId)")
        }
    }

    // MARK: - Quarantine (Gatekeeper still checks attached apps and scripts)

    private func quarantine(_ url: URL?) -> [String: Any]? {
        guard let url else { return nil }
        return try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    }

    private func agent(_ url: URL?) -> String? {
        quarantine(url)?[kLSQuarantineAgentNameKey as String] as? String
    }

    @Test func pastedBytesGetAFreshQuarantineRecord() throws {
        let note = try store.create(text: "")
        let name = try attachments.add(data: Data("#!/bin/sh\necho hi\n".utf8), filename: "run.command", to: note.id)
        let url = attachments.url(for: name, noteId: note.id)
        #expect(agent(url) == "Theo Notes")
        #expect(quarantine(url)?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeOtherDownload as String)
    }

    @Test func filesAddedFromAURLKeepTheirSourcesQuarantine() throws {
        let note = try store.create(text: "")
        var source = tmp.paths.root.appendingPathComponent("Downloaded.zip")
        try Data([1]).write(to: source)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Safari",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        try source.setResourceValues(values)
        let name = try attachments.add(fileAt: source, to: note.id)
        let url = attachments.url(for: name, noteId: note.id)
        #expect(agent(url) == "Safari")
        #expect(quarantine(url)?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)

        // A source without a record: a fresh one.
        let plain = tmp.paths.root.appendingPathComponent("plain.zip")
        try Data([2]).write(to: plain)
        #expect(agent(attachments.url(for: try attachments.add(fileAt: plain, to: note.id), noteId: note.id)) == "Theo Notes")
        // The renamed name is the same file (hard link): same record.
        #expect(agent(attachments.url(for: try attachments.rename(name, to: "Other.zip", in: note.id), noteId: note.id)) == "Safari")
    }

    @Test func importsConflictCopiesAndRecoveryKeepTheQuarantine() throws {
        let imported = try store.importNote(ImportedNoteDraft(
            text: "![](a.png)", createdAt: .now, modifiedAt: .now,
            attachments: [ImportedAttachment(filename: "a.png", data: Data([1]))]))
        #expect(agent(attachments.url(for: "a.png", noteId: imported.id)) == "Theo Notes")
        let copy = try store.createConflictCopy(of: imported.id, text: "![](a.png) theirs")
        #expect(agent(attachments.url(for: "a.png", noteId: copy.id)) == "Theo Notes")

        // A batch staged and committed, installed by recovery after a crash.
        let files = AttachmentFiles(paths: tmp.paths, database: db)
        let staged = try files.stage([ImportedAttachment(filename: "b.png", data: Data([2]))], noteId: imported.id)
        try db.pool.write { try AttachmentFiles.record(staged, in: $0) }
        staged.lock?.release()
        _ = try files.recover()
        #expect(agent(attachments.url(for: "b.png", noteId: imported.id)) == "Theo Notes")
    }

    // MARK: - Markdown

    @Test func testNewAttachmentsAreWrittenInBearFormat() {
        #expect(AttachmentMarkdown.link(for: "image.png") == "![](image.png)")
        #expect(AttachmentMarkdown.link(for: "photo 2.JPG") == "![](photo%202.JPG)")
        #expect(AttachmentMarkdown.link(for: "Report (final).pdf")
            == #"[Report (final).pdf](Report%20%28final%29.pdf)<!-- {"preview":"true","embed":"true"} -->"#)
        #expect(AttachmentMarkdown.link(for: "data.zip") == #"[data.zip](data.zip)<!-- {"embed":"true"} -->"#)
        #expect(AttachmentMarkdown.link(for: "[x].txt") == #"[\[x\].txt](%5Bx%5D.txt)<!-- {"embed":"true"} -->"#)
        // What the parser reads back.
        for name in ["image.png", "photo 2.JPG", "Report (final).pdf", "data.zip", "[x].txt", "日本 100%.pdf"] {
            #expect(NoteParser.metadata(for: AttachmentMarkdown.link(for: name)).attachments.map(\.filename) == [name])
        }
    }

    @Test func testRenamingRewritesTheDestinationAndAMatchingTitle() {
        #expect(AttachmentMarkdown.renaming("![](a.png)", to: "b c.png") == "![](b%20c.png)")
        #expect(AttachmentMarkdown.renaming(#"![](a.png)<!-- {"width":"320"} -->"#, to: "b.png") == #"![](b.png)<!-- {"width":"320"} -->"#)
        #expect(AttachmentMarkdown.renaming(#"[a.pdf](a.pdf)<!-- {"embed":"true"} -->"#, to: "b.pdf")
            == #"[b.pdf](b.pdf)<!-- {"embed":"true"} -->"#)
        #expect(AttachmentMarkdown.renaming(#"[My doc](a.pdf)<!-- {"embed":"true"} -->"#, to: "b.pdf")
            == #"[My doc](b.pdf)<!-- {"embed":"true"} -->"#)
        #expect(AttachmentMarkdown.renaming("not a link", to: "b.pdf") == nil)
        // CommonMark's angle-bracket destination (Bear reads it; attachments.ts too).
        #expect(AttachmentMarkdown.renaming("![](<with space.jpg>)", to: "b c.jpg") == "![](b%20c.jpg)")
        #expect(AttachmentMarkdown.renaming(#"[a b.pdf](<a b.pdf>)<!-- {"embed":"true"} -->"#, to: "c.pdf")
            == #"[c.pdf](c.pdf)<!-- {"embed":"true"} -->"#)
    }

    @Test func testMetadataIsMergedInPlace() {
        #expect(AttachmentMarkdown.settingMetadata(#"[a.pdf](a.pdf)<!-- {"preview":"true","embed":"true"} -->"#, "preview", "false")
            == #"[a.pdf](a.pdf)<!-- {"preview":"false","embed":"true"} -->"#)
        #expect(AttachmentMarkdown.settingMetadata("![](a.png)", "width", "320") == #"![](a.png)<!-- {"width":"320"} -->"#)
        #expect(AttachmentMarkdown.settingMetadata(#"[a.pdf](a.pdf) <!-- {"embed":"true"} -->"#, "preview", "true")
            == #"[a.pdf](a.pdf) <!-- {"embed":"true","preview":"true"} -->"#)
        #expect(AttachmentMarkdown.metadata(#"[a.pdf](a.pdf)<!-- {"preview":"true","embed":"true"} -->"#) == ["preview": "true", "embed": "true"])
    }

    // MARK: - Cleanup of unreferenced files

    /// Files older than the grace period (`NoteStore.attachmentGracePeriod`), unless `aged: false`.
    private func place(_ noteId: String, _ names: String..., aged: Bool = true) throws {
        for name in names {
            let placed = try AttachmentFiles(paths: tmp.paths, database: db).place(Data([1]), filename: name, noteId: noteId)
            if aged { try age(noteId, placed) }
        }
    }

    private func age(_ noteId: String, _ name: String) throws {
        let url = tmp.paths.attachments.appendingPathComponent(noteId).appendingPathComponent(name)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-NoteStore.attachmentGracePeriod - 60)], ofItemAtPath: url.path)
    }

    @Test func testFilesTheCommittedTextNoLongerLinksAreRemoved() throws {
        let note = try store.create(text: "![](a.png) ![](b%202.png) [c.pdf](c.pdf)<!-- {\"embed\":\"true\"} -->")
        try place(note.id, "a.png", "b 2.png", "c.pdf", "orphan.zip")
        _ = try store.updateText(id: note.id, text: "![](a.png) and [c.pdf](c.pdf)<!-- {\"embed\":\"true\"} -->", expectedRevision: note.revision)
        // Ruling R23: a commit never deletes files (the CLI and MCP write through the store too);
        // only the app's eviction and launch sweep run the cleanup.
        #expect(names(note.id) == ["a.png", "b 2.png", "c.pdf", "orphan.zip"])
        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["b 2.png", "orphan.zip"])
        #expect(names(note.id) == ["a.png", "c.pdf"])
    }

    @Test func testFreshFilesAreKeptForTheGracePeriod() throws {
        // Placed before its link is inserted (drop, paste, ⇧⌘V) or still being linked.
        let note = try store.create(text: "nothing yet")
        try place(note.id, "new.png", aged: false)
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        try age(note.id, "new.png")
        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["new.png"])
    }

    @Test func testNotesAPendingCopyReadsFromKeepTheirFiles() throws {
        let note = try store.create(text: "![](a.png) ![](b.png)")
        try place(note.id, "a.png", "b.png")
        let unreadable = tmp.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("b.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        _ = try store.createConflictCopy(of: note.id, text: "theirs")
        // The source edits the links away; the copy still waits for b.png from it.
        _ = try store.updateText(id: note.id, text: "mine", expectedRevision: note.revision)
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(names(note.id) == ["a.png", "b.png"])
    }

    @Test func testCleanupKeepsFilesOpenSessionsJournalsAndBatchesMayStillLink() throws {
        let note = try store.create(text: "![](a.png)")
        try place(note.id, "a.png")

        // Open in this process (an editor session; its undo history may bring the link back).
        store.retention.retain(note.id)
        let edited = try store.updateText(id: note.id, text: "gone", expectedRevision: note.revision)
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(names(note.id) == ["a.png"])
        store.retention.release(note.id)

        // Unsaved acked edits in a journal (another process's session).
        let journal = tmp.paths.journal.appendingPathComponent("\(note.id).jsonl")
        try Data("{}\n".utf8).write(to: journal)
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        try Data().write(to: journal)

        // A journal kept for manual recovery may link them too.
        let aside = tmp.paths.journal.appendingPathComponent("\(note.id).jsonl.unreplayed.2")
        try Data("{}\n".utf8).write(to: aside)
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        try FileManager.default.removeItem(at: aside)

        // A batch staged for the note (being written, or waiting for recovery).
        let staged = try AttachmentFiles(paths: tmp.paths, database: db).stage([ImportedAttachment(filename: "b.png", data: Data())], noteId: note.id)
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        AttachmentFiles(paths: tmp.paths, database: db).discard(staged)

        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["a.png"])
        #expect(names(note.id).isEmpty)
        #expect(edited.text == "gone")
    }

    /// Ruling R30: a cut or copied link holds its file while the pasteboard still has that copy
    /// (its change count), at most 24 h.
    @Test func testCopiedLinksHoldTheirFilesUntilThePasteboardChanges() throws {
        let note = try store.create(text: "cut away")
        try place(note.id, "a.png", "b.png")
        let token = Mutex(7)
        store.retention.setPasteboardToken { token.withLock { $0 } }
        store.retention.holdFiles(["A.png"], of: note.id)
        // Not settled yet: held anyway (the copy may still be on its way to the pasteboard).
        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["b.png"])
        store.retention.settleHeldFiles()
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(store.removeUnreferencedAttachments(noteId: note.id, now: Date().addingTimeInterval(AttachmentRetention.maxHold + 1))
            == ["a.png"])

        try place(note.id, "c.png")
        store.retention.holdFiles(["c.png"], of: note.id)
        store.retention.settleHeldFiles()
        token.withLock { $0 = 8 } // something else was copied
        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["c.png"])
    }

    @Test func testCleanupIsConservativeAboutMentions() throws {
        // Any mention of the name keeps the file, also outside an attachment link.
        let note = try store.create(text: "`a.png` and see b%20c.txt and [d](D.PDF)")
        try place(note.id, "a.png", "b c.txt", "d.pdf", "e.png")
        #expect(store.removeUnreferencedAttachments(noteId: note.id) == ["e.png"])
        #expect(names(note.id) == ["a.png", "b c.txt", "d.pdf"])
    }

    @Test func testLockedNotesKeepTheirFiles() throws {
        let note = try store.create(text: "")
        try place(note.id, "a.png")
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [note.id]) }
        #expect(store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(names(note.id) == ["a.png"])
    }

    @Test func testTheLaunchSweepCleansEveryNote() throws {
        let a = try store.create(text: "![](keep.png)")
        let b = try store.create(text: "nothing")
        try place(a.id, "keep.png", "drop.png")
        try place(b.id, "drop.png")
        // A directory of a note that does not exist is left to the delete path.
        try FileManager.default.createDirectory(at: tmp.paths.attachments.appendingPathComponent("unknown"), withIntermediateDirectories: true)
        #expect(store.removeUnreferencedAttachments() == 2)
        #expect(names(a.id) == ["keep.png"])
        #expect(names(b.id).isEmpty)
    }

    @Test func selectionCopyIsFreshPreservesFilesAndNeverMovesImportIdentity() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let now = created.addingTimeInterval(120)
        let selected = "# Selected e\u{301} 🐻\n  ![](one.bin)\n\ttrailing  "
        let source = try store.create(text: "before\n" + selected + "\nafter", now: created)
        _ = try attachments.add(data: Data([0, 1, 255]), filename: "one.bin", to: source.id)
        _ = try attachments.add(data: Data([2, 3]), filename: "unused.bin", to: source.id)
        try store.setPinned([source.id], pinned: true)
        try store.archive([source.id], now: created)
        try db.pool.write {
            try $0.execute(sql: "INSERT INTO external_ref(source,externalId,noteId,importedTextHash) VALUES('bear','selection',?,?)",
                           arguments: [source.id, NoteStore.textHash(selected)])
        }
        let before = try #require(try store.note(id: source.id))
        let copy = try store.createFromSelection(of: source.id, text: selected, now: now)
        #expect(copy.text == selected)
        #expect(copy.id != source.id && copy.location == .notes && !copy.isPinnedGlobal)
        #expect(copy.createdAt == now && copy.modifiedAt == now && copy.archivedAt == nil)
        #expect(try store.tagPins(noteId: copy.id).isEmpty)
        #expect(try store.note(id: source.id) == before)
        #expect(names(copy.id) == ["one.bin", "unused.bin"])
        #expect(try Data(contentsOf: #require(attachments.url(for: "one.bin", noteId: copy.id))) == Data([0, 1, 255]))
        #expect(try db.pool.read { try String.fetchOne($0, sql: "SELECT noteId FROM external_ref WHERE externalId='selection'") } == source.id)
        #expect(stagingEntries.isEmpty)
    }

    // MARK: - Conflict copies and duplicates (M2 ruling R20)

    @Test func testConflictCopyKeepsTheOriginalsPinLocationAndCreatedAt() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let note = try store.create(text: "# A\n#work", now: created)
        try store.setPinned([note.id], pinned: true)
        try store.setPinned([note.id], pinned: true, inTag: "work")
        try store.archive([note.id], now: created.addingTimeInterval(60))
        let original = try #require(try store.note(id: note.id))

        let copy = try store.createConflictCopy(of: note.id, text: "# A\n#work theirs")
        #expect(copy.createdAt == created)
        #expect(copy.isPinnedGlobal)
        #expect(copy.location == .archive)
        #expect(copy.archivedAt == original.archivedAt)
        #expect(try store.tagPins(noteId: copy.id) == ["work"])
        #expect(copy.modifiedAt > created)

        // Duplicate stays a fresh note.
        let duplicate = try store.duplicate(id: note.id)
        #expect(!duplicate.isPinnedGlobal && duplicate.location == .notes && duplicate.createdAt > created)
    }

    @Test func testAConflictCopyWhoseFileCopyFailedIsRepaired() throws {
        let note = try store.create(text: "![](a.png) ![](b.png)")
        try place(note.id, "a.png", "b.png")
        let unreadable = tmp.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("b.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        let copy = try store.createConflictCopy(of: note.id, text: "![](a.png) ![](b.png) theirs")
        #expect(names(copy.id) == ["a.png"])
        #expect(try batchRows() == 1)

        // Still unreadable at the next launch: the repair waits.
        #expect(try AttachmentFiles(paths: tmp.paths, database: db).recover()
            == AttachmentFiles.Recovery(installed: 1, discarded: 0, failedCopies: 1))
        #expect(try batchRows() == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        #expect(try AttachmentFiles(paths: tmp.paths, database: db).recover() == AttachmentFiles.Recovery(installed: 1, discarded: 0))
        #expect(names(copy.id) == ["a.png", "b.png"])
        #expect(try batchRows() == 0)
        #expect(stagingEntries.isEmpty)
    }

    @Test func testADuplicateCopiesItsFilesThroughStaging() throws {
        let note = try store.create(text: "![](a.png)")
        try place(note.id, "a.png")
        let copy = try store.duplicate(id: note.id)
        #expect(names(copy.id) == ["a.png"])
        #expect(try batchRows() == 0)
        #expect(stagingEntries.isEmpty)
    }

    // MARK: - Journals of missing notes

    @Test func testJournalsOfAMissingNoteAreMovedAside() throws {
        let fm = FileManager.default
        let note = try store.create(text: "Gone")
        let kept = try store.create(text: "Kept")
        try place(note.id, "a.png")
        try store.deletePermanently([note.id])
        try place(note.id, "late.png")
        for id in [note.id, kept.id] {
            for name in ["\(id).jsonl", "\(id).base"] {
                try Data("x".utf8).write(to: tmp.paths.journal.appendingPathComponent(name))
            }
        }
        #expect(try store.removeFilesIfDeleted(noteId: note.id))
        #expect(try !store.removeFilesIfDeleted(noteId: kept.id))
        #expect(try Set(fm.contentsOfDirectory(atPath: tmp.paths.journal.path)) == [
            "\(kept.id).base", "\(kept.id).jsonl", "\(note.id).base.unreplayed", "\(note.id).jsonl.unreplayed",
        ])
        #expect(try Data(contentsOf: tmp.paths.journal.appendingPathComponent("\(note.id).jsonl.unreplayed")) == Data("x".utf8))
        #expect(!fm.fileExists(atPath: tmp.paths.attachments.appendingPathComponent(note.id).path))
    }
}
