// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite @MainActor struct NoteSessionInvalidationTests {
    @Test func fenceRejectsChangedHoldersAndRevisionsBeforeInvalidatingAnySession() throws {
        let lib = try PrivacyTestLibrary(), other = try PrivacyTestLibrary()
        defer { lib.cleanup(); other.cleanup() }
        let note = try lib.store.create(text: "base")
        let first = try NoteSession(noteId: note.id, store: lib.store, journalDirectory: lib.paths.journal)
        let fence = NoteSession.captureSessionFence(journalDirectory: lib.paths.journal, noteIDs: [note.id])
        let second = try NoteSession(noteId: note.id, store: lib.store, journalDirectory: lib.paths.journal)
        #expect(throws: NoteSessionFenceError.stale) { try NoteSession.invalidateSessions(journalDirectory: lib.paths.journal, noteIDs: [note.id], matching: fence) }
        #expect(!first.isInvalidated && !second.isInvalidated)
        let changedRevision = NoteSession.captureSessionFence(journalDirectory: lib.paths.journal, noteIDs: [note.id])
        let edit = ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])
        #expect(first.apply(txId: "edit", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
        #expect(throws: NoteSessionFenceError.stale) { try NoteSession.invalidateSessions(journalDirectory: lib.paths.journal, noteIDs: [note.id], matching: changedRevision) }
        #expect(!first.isInvalidated && !second.isInvalidated)
        let current = NoteSession.captureSessionFence(journalDirectory: lib.paths.journal, noteIDs: [note.id])
        #expect(throws: NoteSessionFenceError.stale) { try NoteSession.invalidateSessions(journalDirectory: other.paths.journal, noteIDs: [note.id], matching: current) }
        #expect(throws: NoteSessionFenceError.stale) { try NoteSession.invalidateSessions(journalDirectory: lib.paths.journal, noteIDs: [], matching: current) }
        try NoteSession.invalidateSessions(journalDirectory: lib.paths.journal, noteIDs: [note.id], matching: current)
        #expect(first.isInvalidated && second.isInvalidated)
    }

    @Test func fenceRejectsReleasedOrSeparatelyInvalidatedHolder() throws {
        let lib = try PrivacyTestLibrary(); defer { lib.cleanup() }
        let note = try lib.store.create(text: "base")
        let first = try NoteSession(noteId: note.id, store: lib.store, journalDirectory: lib.paths.journal)
        var second: NoteSession? = try NoteSession(noteId: note.id, store: lib.store, journalDirectory: lib.paths.journal)
        let beforeRelease = NoteSession.captureSessionFence(journalDirectory: lib.paths.journal, noteIDs: [note.id])
        weak var weakSecond = second
        second = nil
        #expect(weakSecond == nil)
        #expect(throws: NoteSessionFenceError.stale) { try NoteSession.invalidateSessions(journalDirectory: lib.paths.journal, noteIDs: [note.id], matching: beforeRelease) }
        let beforeInvalidation = NoteSession.captureSessionFence(journalDirectory: lib.paths.journal, noteIDs: [note.id])
        try first.invalidate()
        #expect(throws: NoteSessionFenceError.stale) { try NoteSession.invalidateSessions(journalDirectory: lib.paths.journal, noteIDs: [note.id], matching: beforeInvalidation) }
    }
    @Test func invalidationClosesExternalHoldersAndNeverAcknowledgesDuplicates() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let first = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        let second = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        let external = first
        let change = ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])
        #expect(first.apply(txId: "one", baseRevision: 0, changeSet: change, origin: nil) == .acked(revision: 1))
        let url = library.paths.journal.appendingPathComponent(note.id + ".jsonl")
        let before = try Data(contentsOf: url)
        try NoteSession.invalidateSessions(journalDirectory: library.paths.journal, noteIDs: [note.id])
        #expect(!external.isJournalUsable && !second.isJournalUsable)
        #expect(external.apply(txId: "one", baseRevision: 0, changeSet: change, origin: nil) == .needsFullText(currentRevision: 1))
        #expect(external.applyJournaled(txId: "one", baseRevision: 0, changeSet: change, origin: nil).result == .needsFullText(currentRevision: 1))
        #expect(throws: NoteSessionError.sessionClosed) { try external.flush() }
        #expect(throws: NoteSessionError.sessionClosed) { try external.handleExternalChange() }
        #expect(try Data(contentsOf: url) == before)
        let moved = url.appendingPathExtension("kept")
        try FileManager.default.moveItem(at: url, to: moved)
        #expect(external.apply(txId: "two", baseRevision: 1, changeSet: change, origin: nil) == .needsFullText(currentRevision: 1))
        #expect(try Data(contentsOf: moved) == before && !FileManager.default.fileExists(atPath: url.path))
    }

    @Test func registryTargetsLibraryAndNoteOnly() throws {
        let first = try PrivacyTestLibrary(), second = try PrivacyTestLibrary()
        defer { first.cleanup(); second.cleanup() }
        let a = try first.store.create(text: "first"), b = try first.store.create(text: "other")
        let c = try second.db.pool.write { try NoteStore.insert(id: a.id, text: "separate", now: .now, in: $0) }
        let aSession = try NoteSession(noteId: a.id, store: first.store, journalDirectory: first.paths.journal)
        let bSession = try NoteSession(noteId: b.id, store: first.store, journalDirectory: first.paths.journal)
        let cSession = try NoteSession(noteId: c.id, store: second.store, journalDirectory: second.paths.journal)
        try NoteSession.invalidateSessions(journalDirectory: first.paths.journal, noteIDs: [a.id, c.id])
        #expect(!aSession.isJournalUsable && bSession.isJournalUsable && cSession.isJournalUsable)
    }

    @Test func liveSessionIDsIncludeRetainedHoldersAndExcludeClosedOrReleasedSessions() throws {
        let first = try PrivacyTestLibrary(), second = try PrivacyTestLibrary()
        defer { first.cleanup(); second.cleanup() }
        let a = try first.store.create(text: "first"), b = try first.store.create(text: "other")
        let c = try second.store.create(text: "separate")
        let retained = try NoteSession(noteId: a.id, store: first.store, journalDirectory: first.paths.journal)
        let duplicate = try NoteSession(noteId: a.id, store: first.store, journalDirectory: first.paths.journal)
        var released: NoteSession? = try NoteSession(noteId: b.id, store: first.store, journalDirectory: first.paths.journal)
        weak var releasedReference = released
        let otherLibrary = try NoteSession(noteId: c.id, store: second.store, journalDirectory: second.paths.journal)
        #expect(NoteSession.liveSessionIDs(journalDirectory: first.paths.journal) == [a.id, b.id])
        #expect(NoteSession.liveSessionIDs(journalDirectory: second.paths.journal) == [c.id])
        try duplicate.invalidate()
        #expect(NoteSession.liveSessionIDs(journalDirectory: first.paths.journal).contains(a.id))
        released = nil
        #expect(releasedReference == nil)
        #expect(NoteSession.liveSessionIDs(journalDirectory: first.paths.journal) == [a.id])
        try retained.invalidate()
        #expect(NoteSession.liveSessionIDs(journalDirectory: first.paths.journal).isEmpty)
        #expect(NoteSession.liveSessionIDs(journalDirectory: second.paths.journal) == [c.id])
        withExtendedLifetime(otherLibrary) {}
    }
}
