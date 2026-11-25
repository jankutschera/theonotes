// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@MainActor private final class DelayedSpotlightIndex: MobileSpotlightIndex {
    var removals: [@MainActor (Error?) -> Void] = []
    var writes: [([MobileSpotlight.Entry], @MainActor (Error?) -> Void)] = []
    var visible: [MobileSpotlight.Entry] = []
    func removeAll(completion: @escaping @MainActor (Error?) -> Void) { removals.append(completion) }
    func index(_ entries: [MobileSpotlight.Entry], completion: @escaping @MainActor (Error?) -> Void) {
        writes.append((entries, completion))
    }
    func finishRemovals() {
        while !removals.isEmpty { visible = []; removals.removeFirst()(nil) }
    }
    func failWrite() {
        let (_, completion) = writes.removeFirst()
        completion(CocoaError(.fileWriteUnknown))
    }
    func finishWrite() {
        let (entries, completion) = writes.removeFirst()
        visible = entries
        completion(nil)
    }
}

private func spotlightWorkerIsOffMainThread() -> Bool { !Thread.isMainThread }

private actor HeldSpotlightPreparation {
    private(set) var entered = false
    private(set) var offMain = false
    private var reply: CheckedContinuation<Void, Never>?
    func pause(offMain: Bool) async {
        self.offMain = offMain
        entered = true
        await withCheckedContinuation { reply = $0 }
    }
    func release() { reply?.resume(); reply = nil }
}

private actor ControlledSpotlightDebounce {
    private(set) var requests = 0
    private var replies: [Int: CheckedContinuation<Void, Never>] = [:]
    func wait() async {
        requests += 1
        let id = requests
        await withCheckedContinuation { replies[id] = $0 }
    }
    func release(_ id: Int) { replies.removeValue(forKey: id)?.resume() }
}

@Suite @MainActor struct MobileSpotlightTests {
    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Spotlight publication did not reach the expected state")
        throw CocoaError(.fileReadUnknown)
    }
    private func clean(_ library: MobileLibrary) {
        try? library.close(); try? FileManager.default.removeItem(at: library.paths.root)
    }

    @Test func cancelledOldDebounceCompletionCannotClearTheReplacement() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Debounce replacement")
        let held = ControlledSpotlightDebounce(), backend = DelayedSpotlightIndex()
        let spotlight = MobileSpotlight(index: backend, debounceWait: { _ in await held.wait() })
        spotlight.connect(library); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations(); backend.finishWrite()
        _ = try library.store.updateText(id: note.id, text: "# First pending update", expectedRevision: note.revision)
        for _ in 0..<400 {
            if await held.requests == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let first = try #require(spotlight.pendingContentUpdateCompletion)
        let current = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: "# Replacement update", expectedRevision: current.revision)
        for _ in 0..<400 {
            if await held.requests == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await held.requests == 2)
        let replacement = try #require(spotlight.pendingContentUpdateCompletion)
        // A sleeper that has already completed need not throw if cancellation arrives just
        // before its caller resumes. Release the old continuation despite its cancellation.
        await held.release(1)
        await first.value
        #expect(spotlight.hasPendingContentUpdate)
        #expect(!spotlight.hasBackgroundPreparations && backend.writes.isEmpty)
        spotlight.connect(nil); backend.finishRemovals()
        await held.release(2)
        await replacement.value
        await spotlight.waitForBackgroundPreparations()
        #expect(!spotlight.hasPendingContentUpdate && backend.writes.isEmpty)
    }

    @Test(arguments: [false, true])
    func ordinaryEditDoesNotOrphanPendingPurgeAcknowledgement(purgeFails: Bool) async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Before delayed purge")
        let backend = DelayedSpotlightIndex()
        let spotlight = MobileSpotlight(index: backend, retryDelay: .seconds(3600), debounce: .milliseconds(100))
        spotlight.connect(library)
        let acknowledgement = try #require(backend.removals.first)
        backend.removals.removeFirst()
        _ = try library.store.updateText(id: note.id, text: "# Newest content", expectedRevision: note.revision)
        try await wait { spotlight.hasPendingContentUpdate }
        #expect(spotlight.scrubPending && backend.writes.isEmpty)
        acknowledgement(purgeFails ? CocoaError(.fileWriteNoPermission) : nil)
        if purgeFails {
            #expect(spotlight.scrubPending && spotlight.lastErrorMessage != nil)
            spotlight.retryPendingPurge()
            #expect(backend.removals.count == 1)
            backend.finishRemovals()
        }
        #expect(!spotlight.scrubPending)
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        #expect(backend.writes.first?.0.first?.title == "Newest content")
        backend.finishWrite()
        #expect(spotlight.lastErrorMessage == nil)
        spotlight.connect(nil); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
    }

    @Test func oldLibraryPurgeAcknowledgementCannotReleaseNewPrivacyBoundary() async throws {
        let first = try makeLibrary(), second = try makeLibrary()
        defer { clean(first); clean(second) }
        _ = try first.store.create(text: "# Old library")
        let note = try second.store.create(text: "# Replacement library")
        let backend = DelayedSpotlightIndex(), spotlight = MobileSpotlight(index: backend)
        spotlight.connect(first)
        let oldAcknowledgement = try #require(backend.removals.first)
        backend.removals.removeFirst()
        spotlight.connect(second)
        oldAcknowledgement(nil)
        #expect(spotlight.scrubPending && backend.writes.isEmpty)
        backend.finishRemovals()
        #expect(!spotlight.scrubPending)
        await spotlight.waitForBackgroundPreparations()
        #expect(backend.writes.first?.0.map(\.id) == [MobileSpotlight.identifier(noteID: note.id, paths: second.paths)])
        backend.finishWrite()
        spotlight.connect(nil); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
    }

    @Test func ordinaryEditsDebounceUpsertsWithoutDeletingTheIndex() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Original fixture")
        let backend = DelayedSpotlightIndex()
        let spotlight = MobileSpotlight(index: backend, debounce: .milliseconds(150))
        spotlight.connect(library); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations(); backend.finishWrite()
        var stored = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: "# First edit", expectedRevision: stored.revision)
        try await wait { spotlight.hasPendingContentUpdate }
        stored = try #require(try library.store.note(id: note.id))
        _ = try library.store.updateText(id: note.id, text: "# Latest edit", expectedRevision: stored.revision)
        try await Task.sleep(for: .milliseconds(40))
        #expect(backend.removals.isEmpty && backend.writes.isEmpty)
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1 && backend.removals.isEmpty)
        #expect(backend.writes.first?.0.first?.title == "Latest edit")
        backend.finishWrite()
        spotlight.connect(nil); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
    }

    @Test func appLockPurgesImmediatelyDuringContentDebounce() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Before lock")
        let backend = DelayedSpotlightIndex()
        let spotlight = MobileSpotlight(index: backend, debounce: .seconds(3600))
        spotlight.connect(library); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations(); backend.finishWrite()
        _ = try library.store.updateText(id: note.id, text: "# Pending private words", expectedRevision: note.revision)
        try await wait { spotlight.hasPendingContentUpdate }
        try await library.setAppLock(true, authenticate: {})
        #expect(!backend.removals.isEmpty && !spotlight.hasPendingContentUpdate)
        backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
        #expect(backend.visible.isEmpty && backend.writes.isEmpty)
        spotlight.connect(nil); backend.finishRemovals()
    }

    @Test func heldOffMainPreparationCannotPublishAfterAppLockAndCloseWaitsForIt() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Held private fixture")
        let entries = MobileSpotlight.entries(notes: [note], paths: library.paths)
        let held = HeldSpotlightPreparation()
        let backend = DelayedSpotlightIndex()
        let spotlight = MobileSpotlight(index: backend, prepareEntries: { _, _ in
            await held.pause(offMain: spotlightWorkerIsOffMainThread())
            return entries // Deliberately ignore cancellation, like a synchronous read finishing late.
        })
        spotlight.connect(library); backend.finishRemovals()
        for _ in 0..<400 {
            if await held.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await held.entered)
        #expect(await held.offMain)
        #expect(spotlight.hasBackgroundPreparations)
        try await library.setAppLock(true, authenticate: {})
        #expect(!backend.removals.isEmpty)
        #expect(throws: BackupError.pendingFiles) { try library.close() }
        backend.finishRemovals()
        await held.release()
        await spotlight.waitForBackgroundPreparations()
        #expect(!spotlight.hasBackgroundPreparations && backend.writes.isEmpty)
        spotlight.connect(nil); backend.finishRemovals()
    }

    @Test(arguments: ["local-lock", "local-trash", "sync-lock", "sync-delete"])
    func privacyHostHooksFenceOutstandingWritesBeforeObservation(action: String) async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Pre-transition private fixture")
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        let access = try #require(library.privateAccess)
        let store = library.store
        let backend = DelayedSpotlightIndex(), spotlight = MobileSpotlight(index: backend, debounce: .seconds(3600))
        spotlight.connect(library); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
        #expect(backend.writes.count == 1) // Keep an old plaintext write pending across the boundary.
        switch action {
        case "local-lock": try library.lockNote(note.id)
        case "local-trash": try library.move(note.id, to: .trash)
        default:
            _ = try library.commitSyncedChange {
                MainActor.assumeIsolated {
                    #expect(!backend.removals.isEmpty) // Pre-mutation; no async GRDB callback ran.
                }
                if action == "sync-lock" { try access.lock(noteId: note.id) }
                else { try store.deletePermanently([note.id]) }
                return .applied
            }
        }
        #expect(!backend.removals.isEmpty && spotlight.scrubPending)
        backend.finishRemovals()
        backend.finishWrite() // OS service applies its old write after the first purge.
        #expect(!backend.removals.isEmpty) // The synchronous host epoch forces another purge.
        backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
        #expect(backend.visible.isEmpty && backend.writes.isEmpty)
        spotlight.connect(nil); backend.finishRemovals()
    }

    @Test func eligibleFieldsExcludeProtectedTrashedAndDeletedNotes() throws {
        let library = try makeLibrary(); defer { clean(library) }
        let publicNote = try library.store.create(text: "# Public\n**Searchable body**")
        var archived = publicNote; archived.id = UUID().uuidString; archived.location = .archive
        var locked = publicNote; locked.id = UUID().uuidString; locked.isLocked = true
        var trashed = publicNote; trashed.id = UUID().uuidString; trashed.location = .trash
        var deleted = publicNote; deleted.id = UUID().uuidString; deleted.deletedAt = .now
        let entries = MobileSpotlight.entries(notes: [publicNote, archived, locked, trashed, deleted], paths: library.paths)
        #expect(entries.count == 2)
        #expect(entries[0].title == "Public")
        #expect(entries[0].text.contains("Searchable body") && !entries[0].text.contains("**"))
        #expect(entries[0].id == MobileSpotlight.identifier(noteID: publicNote.id, paths: library.paths))
    }

    @Test func authenticatedAppLockClearsAndLateIndexWriteIsPurgedAgain() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        _ = try library.store.create(text: "# Public fixture")
        let backend = DelayedSpotlightIndex()
        // No system index is touched.
        let spotlight = MobileSpotlight(index: backend)
        spotlight.connect(library)
        backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        try await library.setAppLock(true, authenticate: {})
        #expect(library.appLockEnabled && !library.appLocked)
        backend.finishRemovals() // Purge finishes before the old index callback.
        backend.finishWrite()
        #expect(!backend.removals.isEmpty)
        #expect(spotlight.scrubPending)
        backend.finishRemovals()
        #expect(backend.visible.isEmpty && backend.writes.isEmpty)
        spotlight.connect(nil)
    }

    @Test func librarySwitchNeverReusesOldWriteAndStartupAlwaysScrubs() async throws {
        let first = try makeLibrary(), second = try makeLibrary()
        defer { clean(first); clean(second) }
        let old = try first.store.create(text: "# Old library")
        let current = try second.store.create(text: "# Current library")
        let backend = DelayedSpotlightIndex()
        let tested = MobileSpotlight(index: backend)
        tested.connect(nil)
        #expect(backend.removals.count == 1)
        backend.finishRemovals()
        tested.connect(first); backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.first?.0.first?.id == MobileSpotlight.identifier(noteID: old.id, paths: first.paths))
        tested.connect(second); backend.finishRemovals()
        backend.finishWrite(); backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        #expect(backend.writes[0].0.first?.id == MobileSpotlight.identifier(noteID: current.id, paths: second.paths))
        backend.finishWrite()
        #expect(backend.visible.allSatisfy { $0.libraryID == MobileSpotlight.libraryID(for: second.paths) })
        tested.connect(nil); backend.finishRemovals()
    }

    @Test func persistedAppLockStartupAndFailedRemovalNeverIndex() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        _ = try library.store.create(text: "# Startup fixture")
        try await library.setAppLock(true, authenticate: {})
        try library.close()
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(reopened.appLockEnabled && reopened.appLocked)
        let backend = DelayedSpotlightIndex()
        let tested = MobileSpotlight(index: backend)
        tested.connect(reopened); backend.finishRemovals()
        #expect(backend.writes.isEmpty)
        try await reopened.setAppLock(false, authenticate: {})
        let callbacks = backend.removals; backend.removals = []
        for callback in callbacks { callback(CocoaError(.fileWriteNoPermission)) }
        #expect(tested.lastError != nil && backend.writes.isEmpty)
        tested.connect(nil)
    }

    @Test func failedPrivacyPurgeKeepsWarningAndRetriesUntilOldContentIsRemoved() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        _ = try library.store.create(text: "# Previously indexed fixture")
        let backend = DelayedSpotlightIndex()
        let spotlight = MobileSpotlight(index: backend, retryDelay: .milliseconds(1))
        spotlight.connect(library); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
        backend.finishWrite()
        #expect(backend.visible.count == 1)
        try await library.setAppLock(true, authenticate: {})
        let failed = backend.removals; backend.removals = []
        for callback in failed { callback(CocoaError(.fileWriteNoPermission)) }
        #expect(spotlight.scrubPending && spotlight.lastErrorMessage != nil)
        #expect(backend.visible.count == 1 && backend.writes.isEmpty)
        for _ in 0..<200 where backend.removals.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!backend.removals.isEmpty)
        // A persistent failure must keep both the warning and the pending cleanup state.
        let failedAgain = backend.removals; backend.removals = []
        for callback in failedAgain { callback(CocoaError(.fileWriteNoPermission)) }
        #expect(spotlight.scrubPending && spotlight.lastErrorMessage != nil)
        spotlight.retryPendingPurge()
        backend.finishRemovals()
        #expect(!spotlight.scrubPending && spotlight.lastErrorMessage == nil)
        #expect(backend.visible.isEmpty && backend.writes.isEmpty)
        spotlight.connect(nil); backend.finishRemovals()
    }

    @Test func lockingOneNotePurgesItEvenWhileAuthenticated() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let protected = try library.store.create(text: "# Protected later")
        let remaining = try library.store.create(text: "# Public stays")
        let backend = DelayedSpotlightIndex(), spotlight = MobileSpotlight(index: backend)
        spotlight.connect(library); backend.finishRemovals()
        await spotlight.waitForBackgroundPreparations()
        backend.finishWrite()
        try await library.unlockNotes(password: "test-fixture-password", createPassword: true)
        try library.lockNote(protected.id)
        #expect(!backend.removals.isEmpty)
        backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        #expect(backend.writes[0].0.map(\.id) == [MobileSpotlight.identifier(noteID: remaining.id, paths: library.paths)])
        backend.finishWrite()
        spotlight.connect(nil)
    }

    @Test func databaseChangesRemoveTrashedAndPermanentlyDeletedEntries() async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let first = try library.store.create(text: "# Trash fixture")
        let second = try library.store.create(text: "# Delete fixture")
        let backend = DelayedSpotlightIndex()
        let tested = MobileSpotlight(index: backend)
        tested.connect(library); backend.finishRemovals()
        await tested.waitForBackgroundPreparations()
        backend.finishWrite()
        #expect(backend.visible.count == 2)
        try library.store.trash([first.id])
        try library.store.deletePermanently([second.id])
        for _ in 0..<200 where backend.removals.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!backend.removals.isEmpty)
        backend.finishRemovals()
        await tested.waitForBackgroundPreparations()
        #expect(backend.visible.isEmpty && backend.writes.isEmpty)
        tested.connect(nil)
    }

    @Test(arguments: ["foreground", "timer"])
    func failedIndexWriteRetriesAfterSuccessfulCleanup(trigger: String) async throws {
        let library = try makeLibrary(); defer { clean(library) }
        let note = try library.store.create(text: "# Retry eligible fixture")
        let backend = DelayedSpotlightIndex()
        let tested = MobileSpotlight(index: backend, retryDelay: trigger == "timer" ? .milliseconds(1) : .seconds(3600))
        defer { tested.connect(nil); backend.finishRemovals() }
        tested.connect(library); backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        backend.failWrite()
        #expect(tested.scrubPending)
        backend.finishRemovals()
        #expect(!tested.scrubPending && tested.lastErrorMessage != nil)
        #expect(backend.writes.isEmpty) // Do not spin immediately on a failing index service.
        if trigger == "foreground" { tested.retryPendingPurge() }
        else {
            for _ in 0..<400 where backend.writes.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await wait { !backend.writes.isEmpty }
        let retry = try #require(backend.writes.first)
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        #expect(retry.0.map(\.id) == [MobileSpotlight.identifier(noteID: note.id, paths: library.paths)])
        backend.finishWrite()
        #expect(backend.visible.count == 1 && tested.lastErrorMessage == nil)
    }

    @Test func lateOldIndexErrorDoesNotDiscardReplacementLibraryRebuild() async throws {
        let first = try makeLibrary(), second = try makeLibrary()
        defer { clean(first); clean(second) }
        _ = try first.store.create(text: "# Old fixture")
        let current = try second.store.create(text: "# Current fixture")
        let backend = DelayedSpotlightIndex()
        let tested = MobileSpotlight(index: backend, retryDelay: .seconds(3600))
        defer { tested.connect(nil); backend.finishRemovals() }
        tested.connect(first); backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        tested.connect(second); backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1) // The old write still owns the outstanding callback.
        backend.failWrite()
        #expect(!backend.removals.isEmpty) // Even a failed old write may have partially applied.
        backend.finishRemovals()
        try await wait { !backend.writes.isEmpty }
        let replacement = try #require(backend.writes.first)
        try await wait { !backend.writes.isEmpty }
        #expect(backend.writes.count == 1)
        #expect(replacement.0.map(\.id) == [MobileSpotlight.identifier(noteID: current.id, paths: second.paths)])
        backend.finishWrite()
        #expect(backend.visible.allSatisfy { $0.libraryID == MobileSpotlight.libraryID(for: second.paths) })
        #expect(!tested.scrubPending && tested.lastErrorMessage == nil)
    }

    @Test func resultWaitsForReadinessAndRejectsWrongLibraryMissingAndNewlyProtectedNotes() async throws {
        let library = try makeLibrary(), other = try makeLibrary()
        defer { clean(library); clean(other) }
        let note = try library.store.create(text: "# Result")
        library.selectedID = nil
        let navigation = MobileSpotlightNavigation()
        navigation.receive(MobileSpotlight.identifier(noteID: note.id, paths: library.paths))
        try navigation.drain(ready: true) // Cold delivery before a library exists.
        navigation.connect(library)
        try navigation.drain(ready: false)
        #expect(library.selectedID == nil)
        try navigation.drain(ready: true)
        #expect(library.selectedID == note.id)
        library.selectedID = nil
        navigation.receive(MobileSpotlight.identifier(noteID: note.id, paths: other.paths))
        try navigation.drain(ready: true)
        #expect(library.selectedID == nil)
        navigation.receive(MobileSpotlight.identifier(noteID: UUID().uuidString, paths: library.paths))
        try navigation.drain(ready: true)
        #expect(library.selectedID == nil)
        try await library.unlockNotes(password: "test-fixture-password", createPassword: true)
        navigation.receive(MobileSpotlight.identifier(noteID: note.id, paths: library.paths))
        try library.lockNote(note.id)
        try navigation.drain(ready: true)
        #expect(library.selectedID == nil)
        try library.removeNoteLock(note.id)
        try await library.setAppLock(true, authenticate: {})
        navigation.receive(MobileSpotlight.identifier(noteID: note.id, paths: library.paths))
        try navigation.drain(ready: true)
        #expect(library.selectedID == nil) // Enabled, even while authenticated.
    }
}
