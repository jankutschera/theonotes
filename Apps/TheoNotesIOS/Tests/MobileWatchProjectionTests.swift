// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileWatchProjectionTests {
    @Test func excludesLockedRemovedAndCodeTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let visible = try library.store.create(text: "# Visible\n- [ ] Real\n```\n- [ ] Not a task\n```")
        let secret = try library.store.create(text: "# Private")
        let trashed = try library.store.create(text: "# Removed")
        try library.store.trash([trashed.id])
        try await library.unlockNotes(password: "fixture", createPassword: true)
        try #require(library.privateAccess).lock(noteId: secret.id)
        let notes = try MobileWatchProjection.notes(library: library)
        #expect(notes.map(\.id) == [visible.id])
        #expect(notes.first?.tasks.count == 1)
        #expect(notes.first?.tasks.first?.expectedMarker == "[ ]")
        try await library.setAppLock(true, authenticate: {})
        #expect(try MobileWatchProjection.notes(library: library).isEmpty)
    }
    @Test func limitsRecentNotesAndKeepsTaskOffsetsInUTF16() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        for i in 0..<20 { _ = try library.store.create(text: "# Entry \(i)\n😀\n- [ ] task", now: Date(timeIntervalSince1970: Double(i + 1))) }
        let notes = try MobileWatchProjection.notes(library: library)
        #expect(notes.count == 15)
        let note = try #require(notes.first)
        let task = try #require(note.tasks.first)
        let ns = note.text as NSString
        #expect(ns.substring(with: NSRange(location: task.utf16Offset, length: 3)) == task.expectedMarker)
    }
    @Test func lockingANoteInvalidatesWatchBeforeChangingPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Private fixture")
        try await library.unlockNotes(password: "fixture", createPassword: true)
        var invalidatedWhilePlain = false
        library.watchWillRestrictAccess = { invalidatedWhilePlain = (try? library.store.note(id: note.id)?.isLocked) == false }
        try library.lockNote(note.id)
        #expect(invalidatedWhilePlain)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
    }
    @Test func failedContextStillAttemptsInteractivePrivacyRedaction() {
        var interactiveAttempted = false
        let sent = MobileWatchConnectivity.submitRedaction(isPaired: true, isWatchAppInstalled: true, context: { throw CocoaError(.fileWriteUnknown) }, interactive: { interactiveAttempted = true })
        #expect(!sent && interactiveAttempted)
    }
    @Test(arguments: [(false, false), (false, true), (true, false)])
    func absentWatchDoesNotSendOrReportAnError(state: (Bool, Bool)) {
        var contextAttempted = false, interactiveAttempted = false
        let sent = MobileWatchConnectivity.submitRedaction(isPaired: state.0, isWatchAppInstalled: state.1,
            context: { contextAttempted = true; throw CocoaError(.fileWriteUnknown) },
            interactive: { interactiveAttempted = true })
        #expect(sent && !contextAttempted && !interactiveAttempted)
    }
}

@Suite @MainActor struct MobileWatchHelloTests {
    @Test func snapshotRestrictionImmediatelyRequestsRedaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let locked = try library.store.create(text: "# Locked"), removed = try library.store.create(text: "# Removed")
        try await library.unlockNotes(password: "fixture", createPassword: true)
        var redactions = 0
        let check = { (ids: Set<String>) in
            MobileWatchConnectivity.redactIfSnapshotRestricted(ids, lookup: { try library.store.note(id: $0) }, redact: { redactions += 1 })
        }
        check([locked.id, removed.id]); #expect(redactions == 0)
        try #require(library.privateAccess).lock(noteId: locked.id)
        check([locked.id]); #expect(redactions == 1)
        try library.store.trash([removed.id])
        check([removed.id]); #expect(redactions == 2)
        check([UUID().uuidString]); #expect(redactions == 3)
        MobileWatchConnectivity.redactIfSnapshotRestricted([locked.id], lookup: { _ in throw CocoaError(.fileReadUnknown) }, redact: { redactions += 1 })
        #expect(redactions == 4)
    }
    @Test(arguments: ["trashed", "deleted", "locked"])
    func snapshotObserverRedactsWhenAnUnlistedNoteBecomesRestricted(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Previously sent")
        if change == "locked" { try await library.unlockNotes(password: "fixture", createPassword: true) }
        var restricted = false
        let observation = MobileWatchConnectivity.observeSnapshotRestrictions([note.id], database: library.database) { restricted = true }
        defer { observation.cancel() }
        switch change {
        case "locked": try #require(library.privateAccess).lock(noteId: note.id)
        case "deleted":
            let noteID = note.id
            try await library.database.pool.write { db in
                try db.execute(sql: "UPDATE note SET deletedAt = ? WHERE id = ?", arguments: [Date(), noteID])
            }
        default: try library.store.trash([note.id])
        }
        for _ in 0..<100 where !restricted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restricted)
    }
    @Test func delayedNewHelloKeepsPreviouslyDisclosedNoteUnderObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let previous = try library.store.create(text: "# Previous hello")
        let newest = try library.store.create(text: "# Later hello")
        let now = Date.now
        let disclosure = MobileWatchConnectivity.retainedDisclosures(previous: [previous.id: now.addingTimeInterval(15)], next: [newest.id], expiresAt: now.addingTimeInterval(30), now: now)
        let disclosed = Set(disclosure.keys)
        #expect(MobileWatchConnectivity.retainedDisclosures(previous: [previous.id: now.addingTimeInterval(-1)], next: [newest.id], expiresAt: now.addingTimeInterval(30), now: now)[previous.id] == nil)
        var restricted = false
        let observation = MobileWatchConnectivity.observeSnapshotRestrictions(disclosed, database: library.database) { restricted = true }
        defer { observation.cancel() }
        // The second reply is delayed: the Watch may still display the first snapshot.
        try library.store.trash([previous.id])
        for _ in 0..<100 where !restricted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restricted)
    }
    @Test func helloReturnsSnapshotWithStableLibraryIdentityWithoutContextPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Watch hello")
        let now = Date.now
        let hello = WatchWireHello(id: UUID(), issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let snapshot = try MobileWatchConnectivity.makeHelloSnapshot(hello, library: library, generation: 1, now: now)
        let stableID = try library.store.watchLibraryID()
        #expect(snapshot.libraryID == stableID)
        #expect(snapshot.notes.map(\.id) == [note.id])
        #expect(snapshot.authorizationID == hello.id)
    }
    @Test func lockedHelloDoesNotReturnPlaintext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Hidden")
        try await library.setAppLock(true, authenticate: {})
        let now = Date.now
        let hello = WatchWireHello(id: UUID(), issuedAt: now, expiresAt: now.addingTimeInterval(30))
        #expect(throws: WatchWireError.self) { try MobileWatchConnectivity.makeHelloSnapshot(hello, library: library, generation: 1, now: now) }
    }
}
