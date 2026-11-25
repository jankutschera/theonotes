// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct AppEnvironmentTests {
    /// The window that shows the notes of these tests.
    private let windowId = ObjectIdentifier(NSObject())
    @Test func launchReplaysJournalsWithoutOpeningNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesLaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)

        // A crash after acked edits: journaled, never committed.
        let noteId: String
        let untouchedId: String
        do {
            try paths.createDirectories()
            let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
            noteId = try store.create(text: "list").id
            untouchedId = try store.create(text: "other").id
            let session = try NoteSession(
                noteId: noteId, store: store, journalDirectory: paths.journal, commitDelay: .seconds(3600)
            )
            let edit = ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " preview 漢字")])
            #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
            #expect(try store.note(id: noteId)?.text == "list")
        }
        // A journal moved aside earlier is left for manual recovery.
        let aside = paths.journal.appendingPathComponent("\(untouchedId).jsonl.unreplayed")
        try Data("kept".utf8).write(to: aside)

        let relaunched = try AppEnvironment(paths: paths)
        #expect(try relaunched.store.note(id: noteId)?.text == "list preview 漢字")
        #expect(relaunched.existingSession(for: noteId) == nil)
        let journal = paths.journal.appendingPathComponent("\(noteId).jsonl")
        #expect(try Data(contentsOf: journal).isEmpty)
        #expect(try relaunched.store.note(id: untouchedId)?.text == "other")
        #expect(try Data(contentsOf: aside) == Data("kept".utf8))
    }

    /// REN-R12: the folder a launch resolved vanishes before it is opened (another launch moved it).
    /// Nothing is created and the launch is refused; a fresh install still creates its library.
    @Test func aLibraryThatVanishesBetweenResolveAndOpenIsNeverRecreated() throws {
        let parent = URL(fileURLWithPath: "/tmp/theo-env-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = parent.appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let production = AppPaths.production(applicationSupport: support)
        try FileManager.default.createDirectory(at: production.root, withIntermediateDirectories: true)

        #expect(throws: AppPaths.DataDirectoryError.libraryVanished(production.root.path)) {
            try AppEnvironment.launching(
                arguments: ["Theo Notes"], environment: [:], production: production,
                afterResolve: { try? FileManager.default.removeItem(at: production.root) })
        }
        #expect(!FileManager.default.fileExists(atPath: production.root.path), "no empty library was created")

        // Nothing there at the first check: a fresh install creates its library.
        let fresh = try AppEnvironment.launching(arguments: ["Theo Notes"], environment: [:], production: production)
        #expect(fresh.paths.root == production.root)
        #expect(FileManager.default.fileExists(atPath: production.database.path))
    }

    @Test func launchInstallsCommittedAttachmentBatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesLaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)

        // A crash after the transaction committed, before the staged file was moved into place;
        // plus a batch whose transaction never committed.
        let noteId: String
        do {
            try paths.createDirectories()
            let database = try AppDatabase(path: paths.database)
            let store = NoteStore(db: database, notifier: nil, paths: paths)
            noteId = try store.create(text: "![](photo 2.jpg)").id
            let files = AttachmentFiles(paths: paths, database: database)
            let committed = try files.stage([ImportedAttachment(filename: "photo 2.jpg", data: Data([1, 2, 3]))], noteId: noteId)
            try database.pool.write { try AttachmentFiles.record(committed, in: $0) }
            _ = try files.stage([ImportedAttachment(filename: "orphan.png", data: Data([9]))], noteId: noteId)
        }

        _ = try AppEnvironment(paths: paths)
        let installed = paths.attachments.appendingPathComponent(noteId).appendingPathComponent("photo 2.jpg")
        #expect(try Data(contentsOf: installed) == Data([1, 2, 3]))
        let staging = paths.attachments.appendingPathComponent(".staging")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.attachments.appendingPathComponent(noteId).appendingPathComponent("orphan.png").path))
    }

    private func tempPaths() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesLaunch-\(UUID().uuidString)"))
    }

    private func files(_ paths: AppPaths, _ noteId: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.attachments.appendingPathComponent(noteId).path)) ?? []).sorted()
    }

    private func age(_ paths: AppPaths, _ noteId: String, _ name: String) throws {
        let url = paths.attachments.appendingPathComponent(noteId).appendingPathComponent(name)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-NoteStore.attachmentGracePeriod - 60)], ofItemAtPath: url.path)
    }

    /// Ruling R23: a write from another process (CLI, MCP: a second NoteStore) never deletes
    /// files; the app's eviction does, once the grace period is over.
    @Test func otherWritersNeverDeleteFilesTheAppsEvictionDoes() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let environment = try AppEnvironment(paths: paths)
        let note = try environment.store.create(text: "![](a.png)")
        _ = try AttachmentStore(paths: paths, database: environment.database).add(data: Data([1]), filename: "a.png", to: note.id)
        try age(paths, note.id, "a.png")
        environment.setOpenNoteIds([note.id], for: windowId)
        _ = try environment.session(for: note.id)

        let cli = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        _ = try cli.updateText(id: note.id, text: "no link", expectedRevision: try #require(try cli.note(id: note.id)).revision)
        environment.databaseDidChange()
        #expect(files(paths, note.id) == ["a.png"])

        environment.setOpenNoteIds([], for: windowId)
        #expect(environment.existingSession(for: note.id) == nil)
        #expect(files(paths, note.id).isEmpty)
    }

    /// Attachment cleanup (M3 Task 9): a note open in a session keeps its files (unsaved text or
    /// the editor's undo history may link them again); once its session is evicted, the files
    /// the committed text no longer references go.
    @Test func openNotesKeepTheirAttachmentFilesUntilTheirSessionCloses() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let environment = try AppEnvironment(paths: paths)
        let note = try environment.store.create(text: "![](a.png) ![](b.png)")
        let store = AttachmentStore(paths: paths, database: environment.database)
        _ = try store.add(data: Data([1]), filename: "a.png", to: note.id)
        _ = try store.add(data: Data([2]), filename: "b.png", to: note.id)
        try age(paths, note.id, "b.png")
        environment.setOpenNoteIds([note.id], for: windowId)
        let session = try environment.session(for: note.id)

        // The editor deletes one link and the session commits it.
        let edit = ChangeSet(sections: [.retain(11), .replace(deleteLength: 10, insert: "")])
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
        try session.flush()
        #expect(try environment.store.note(id: note.id)?.text == "![](a.png) ")
        #expect(files(paths, note.id) == ["a.png", "b.png"])

        // The note leaves the editor: its session is evicted, the cleanup runs.
        environment.setOpenNoteIds([], for: windowId)
        #expect(environment.existingSession(for: note.id) == nil)
        #expect(files(paths, note.id) == ["a.png"])
    }

    @Test func launchRemovesAttachmentFilesNoTextReferences() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let noteId: String
        do {
            try paths.createDirectories()
            let database = try AppDatabase(path: paths.database)
            noteId = try NoteStore(db: database, notifier: nil, paths: paths).create(text: "![](keep.png)").id
            let store = AttachmentStore(paths: paths, database: database)
            _ = try store.add(data: Data([1]), filename: "keep.png", to: noteId)
            _ = try store.add(data: Data([2]), filename: "stale.png", to: noteId)
            _ = try store.add(data: Data([3]), filename: "fresh.png", to: noteId)
            try age(paths, noteId, "stale.png")
        }
        let environment = try AppEnvironment(paths: paths)
        // Not during init: the sweep runs off the main thread once the UI is up.
        #expect(files(paths, noteId) == ["fresh.png", "keep.png", "stale.png"])
        #expect(await environment.sweepAttachments().value == 1)
        #expect(files(paths, noteId) == ["fresh.png", "keep.png"])
    }

    /// Empty Trash: a note whose revision cannot be read after the delete keeps its session (M2
    /// ruling R20); only a successful read without the note drops it.
    @Test func aReadErrorAfterADeleteKeepsTheSession() {
        struct ReadFailed: Error {}
        #expect(AppEnvironment.noteIsGone { nil })
        #expect(!AppEnvironment.noteIsGone { 3 })
        #expect(!AppEnvironment.noteIsGone { throw ReadFailed() })
    }
}
