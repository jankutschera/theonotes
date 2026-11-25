// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import OSLog
import Testing
@testable import TheoNotes

/// Focus layer C17: the app side of the Mac share extension (FOC-R12, FOC-R330 ... FOC-R338). A
/// temporary folder stands in for the App Group container, so no entitlement is needed.
@MainActor
@Suite struct ShareInboxDrainTests {
    @MainActor
    final class Env {
        let root: URL
        let container: URL
        let authenticator = FakeAppAuthenticator()
        let environment: AppEnvironment

        /// `root` and `container` let a test open the same library and container again.
        init(root: URL? = nil, container: URL? = nil, appLockEnabled: Bool = false, makeContainer: Bool = true) throws {
            let tag = UUID().uuidString.prefix(8)
            let root = root ?? URL(fileURLWithPath: "/tmp/theo-share-\(tag)", isDirectory: true)
            let container = container ?? URL(fileURLWithPath: "/tmp/theo-share-group-\(tag)", isDirectory: true)
            if makeContainer {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            }
            let paths = AppPaths(root: root)
            if appLockEnabled {
                // The setting a previous run stored: written before the environment opens the library.
                try paths.createDirectories()
                let database = try AppDatabase(path: paths.database)
                TheoNotesCore.Settings(db: database).appLockEnabled = true
                try database.pool.close()
            }
            self.root = root
            self.container = container
            environment = try AppEnvironment(
                paths: paths, vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
                appAuthenticator: authenticator, appLockLifecycle: nil, appIdleSeconds: { 0 },
                shareContainer: container)
        }

        isolated deinit {
            try? environment.database.pool.close()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: container)
        }

        var store: NoteStore { environment.store }
        var inbox: CaptureInbox { CaptureInbox(directory: container.appendingPathComponent("CaptureInbox", isDirectory: true)) }
        var recentFile: URL { container.appendingPathComponent(RecentNotesFile.fileName) }

        func recentIds() throws -> [String] {
            try JSONDecoder().decode(RecentNotesFile.self, from: Data(contentsOf: recentFile)).notes.map(\.id)
        }

        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    private func itemId() -> String { UUID().uuidString.lowercased() }

    // MARK: - Drain

    @Test func activationDrainsAndShowsTheNewNoteInTheList() async throws {
        let env = try Env()
        let library = LibraryModel(environment: env.environment)
        let id = itemId()
        try env.inbox.enqueue(CaptureRequest(itemId: id, mode: .save, text: "From the share sheet\n\nbody"), files: [])
        #expect(try env.store.note(id: id) == nil, "nothing drains before the app is told")

        env.environment.applicationDidBecomeActive()

        let note = try #require(try env.store.note(id: id))
        #expect(note.text == "From the share sheet\n\nbody")
        #expect(try env.store.captureSource(noteId: id) == .share)
        await env.waitUntil { library.items.contains { $0.id == id } }
        #expect(library.items.contains { $0.id == id })
        let left = try FileManager.default.contentsOfDirectory(atPath: env.inbox.directory.path)
        #expect(left.isEmpty)
    }

    @Test func launchDrainLeavesNothingBehindAndDoesNotRepeat() throws {
        let env = try Env()
        let id = itemId()
        try env.inbox.enqueue(CaptureRequest(itemId: id, mode: .save, text: "once"), files: [])
        #expect(env.environment.drainShareInbox() == [id])
        #expect(env.environment.drainShareInbox() == [])
        #expect(try env.store.allNotes().map(\.id) == [id])
    }

    @Test func appendItemForAnOpenNoteGoesThroughTheSession() throws {
        let env = try Env()
        let note = try env.store.create(text: "Base")
        let session = try env.environment.session(for: note.id)
        // Typed in the editor and acknowledged, but not yet written to the database.
        let typed = session.apply(
            txId: "tx-1", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " typed")]), origin: nil)
        guard case .acked = typed else { Issue.record("edit not acked: \(typed)"); return }
        #expect(session.text == "Base typed")
        #expect(try env.store.note(id: note.id)?.text == "Base")

        let id = itemId()
        try env.inbox.enqueue(
            CaptureRequest(itemId: id, mode: .append, targetNoteId: note.id, text: "shared"), files: [])
        #expect(env.environment.drainShareInbox() == [note.id])

        // The typed text was committed first; the appended text reached the session at once.
        #expect(try env.store.note(id: note.id)?.text == "Base typed\n\nshared")
        #expect(session.text == "Base typed\n\nshared")
        #expect(session.committedText == session.text)
        #expect(try env.store.allNotes().map(\.id) == [note.id], "no conflict copy")
    }

    @Test func aSessionThatCannotBeSavedHoldsBackAppendsToItsNoteOnly() throws {
        let env = try Env()
        let open = try env.store.create(text: "Open")
        let other = try env.store.create(text: "Other")
        let session = try env.environment.session(for: open.id)
        let typed = session.apply(
            txId: "tx-1", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " typed")]), origin: nil)
        guard case .acked = typed else { Issue.record("edit not acked: \(typed)"); return }
        env.environment.sessionFlushFault = { $0 == open.id ? CocoaError(.fileWriteUnknown) : nil }

        let toOpen = itemId()
        let toOther = itemId()
        try env.inbox.enqueue(CaptureRequest(itemId: toOpen, mode: .append, targetNoteId: open.id, text: "later"), files: [])
        try env.inbox.enqueue(CaptureRequest(itemId: toOther, mode: .append, targetNoteId: other.id, text: "now"), files: [])

        #expect(env.environment.drainShareInbox() == [other.id], "only the clean note took its item")
        #expect(try env.store.note(id: open.id)?.text == "Open")
        #expect(try env.store.note(id: other.id)?.text == "Other\n\nnow")
        #expect(try env.store.allNotes().count == 2, "no fallback note for the held item")
        #expect(session.text == "Open typed")

        env.environment.sessionFlushFault = nil
        #expect(env.environment.drainShareInbox() == [open.id])
        #expect(try env.store.note(id: open.id)?.text == "Open typed\n\nlater")
        #expect(session.text == "Open typed\n\nlater")
    }

    // MARK: - recent-notes.json

    @Test func lockingANoteTakesItOutOfTheRecentNotesFileBeforeLockNotesReturns() async throws {
        let env = try Env()
        let keep = try env.store.create(text: "Keep")
        let secret = try env.store.create(text: "Secret title")
        try await env.environment.vault.createPassword("correct horse")
        env.environment.databaseDidChange()
        #expect(Set(try env.recentIds()) == [keep.id, secret.id])

        let outcome = try await env.environment.lockNotes(ids: [secret.id])
        #expect(outcome.locked == [secret.id])
        #expect(try env.recentIds() == [keep.id], "gone synchronously, no waiting for the change notification")
        let text = try String(contentsOf: env.recentFile, encoding: .utf8)
        #expect(!text.contains("Secret"))

        try await env.environment.removeLock(noteId: secret.id)
        #expect(Set(try env.recentIds()) == [keep.id, secret.id], "an unlocked note is offered again")
    }

    @Test func aLockThatArrivesThroughSyncTakesTheTitleOutOfTheFile() async throws {
        let env = try Env()
        let secret = try env.store.create(text: "Secret title")
        try await env.environment.vault.createPassword("correct horse")
        env.environment.databaseDidChange()
        #expect(try env.recentIds() == [secret.id])

        let access = try env.environment.vault.requireAccess()
        _ = try env.environment.commitSyncedChange {
            try access.lock(noteId: secret.id)
            return .applied
        }
        #expect(try env.recentIds().isEmpty)
    }

    @Test func lockingAnOpenNoteTakesItOutOfTheFileToo() async throws {
        let env = try Env()
        let secret = try env.store.create(text: "Secret title")
        try await env.environment.vault.createPassword("correct horse")
        _ = try env.environment.session(for: secret.id)
        env.environment.databaseDidChange()
        #expect(try env.recentIds() == [secret.id])

        let outcome = try await env.environment.lockNotes(ids: [secret.id])
        #expect(outcome.locked == [secret.id])
        #expect(try env.recentIds().isEmpty)
    }

    @Test func recentNotesFileIsWrittenAndRemovedWhenAppLockIsEnabled() async throws {
        let env = try Env()
        let first = try env.store.create(text: "First note")
        env.environment.databaseDidChange()
        #expect(try env.recentIds() == [first.id])

        let second = try env.store.create(text: "Second note")
        env.environment.databaseDidChange()
        #expect(Set(try env.recentIds()) == [first.id, second.id])

        env.authenticator.script(.success)
        #expect(await env.environment.appLock.setEnabled(true) == .enabled)
        #expect(!FileManager.default.fileExists(atPath: env.recentFile.path))

        _ = try env.store.create(text: "Third note")
        env.environment.databaseDidChange()
        #expect(!FileManager.default.fileExists(atPath: env.recentFile.path), "never written while App Lock is enabled")

        env.authenticator.script(.success)
        #expect(await env.environment.appLock.setEnabled(false) == .disabled)
        #expect(try env.recentIds().count == 3, "turning App Lock off publishes again")
    }

    @Test func initWithAppLockEnabledRemovesAStaleRecentNotesFile() throws {
        let tag = UUID().uuidString.prefix(8)
        let root = URL(fileURLWithPath: "/tmp/theo-share-\(tag)", isDirectory: true)
        let container = URL(fileURLWithPath: "/tmp/theo-share-group-\(tag)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let stale = container.appendingPathComponent(RecentNotesFile.fileName)
        try Data(#"{"notes":[{"id":"x","title":"Secret"}]}"#.utf8).write(to: stale)

        let env = try Env(root: root, container: container, appLockEnabled: true)

        #expect(!FileManager.default.fileExists(atPath: stale.path), "gone when init returns, before any window")
        #expect(env.environment.appLock.isEnabled)
    }

    @Test func setEnabledTrueDeletesTheRecentNotesFileAtOnce() async throws {
        let env = try Env()
        _ = try env.store.create(text: "A note")
        env.environment.databaseDidChange()
        #expect(FileManager.default.fileExists(atPath: env.recentFile.path))

        env.authenticator.script(.success)
        let result = await env.environment.appLock.setEnabled(true)

        #expect(result == .enabled)
        #expect(!FileManager.default.fileExists(atPath: env.recentFile.path), "no waiting for an engage or a database change")
        #expect(!env.environment.appLock.isLocked, "enabling does not engage the lock")
    }

    @Test func recentNotesAreNotPublishedForLockedNotes() async throws {
        let env = try Env()
        let open = try env.store.create(text: "Open note")
        let secret = try env.store.create(text: "Secret note")
        try await env.environment.vault.createPassword("correct horse")
        try env.environment.vault.requireAccess().lock(noteId: secret.id)
        env.environment.databaseDidChange()
        #expect(try env.recentIds() == [open.id])
    }

    // MARK: - Invalid container

    @Test func invalidContainerDisablesSharingWithoutCrashing() throws {
        // A plain file where the folder should be: the URL looks fine, the probe cannot be written.
        let tag = UUID().uuidString.prefix(8)
        let container = URL(fileURLWithPath: "/tmp/theo-share-group-\(tag)")
        try Data("not a folder".utf8).write(to: container)
        defer { try? FileManager.default.removeItem(at: container) }
        let env = try Env(container: container, makeContainer: false)

        #expect(!env.environment.sharingEnabled)
        _ = try env.store.create(text: "A note")
        env.environment.databaseDidChange()
        #expect(env.environment.drainShareInbox() == [])
        env.environment.applicationDidBecomeActive()
        #expect(try env.store.allNotes().count == 1)
    }

    @Test func missingContainerAlsoDisablesSharing() throws {
        let env = try Env(makeContainer: false)
        #expect(!env.environment.sharingEnabled)
    }

    @Test func noContainerMeansNoSharing() throws {
        let root = URL(fileURLWithPath: "/tmp/theo-share-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appLockLifecycle: nil, appIdleSeconds: { 0 })
        defer {
            try? environment.database.pool.close()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(!environment.sharingEnabled)
        #expect(environment.drainShareInbox() == [])
    }

    @Test func invalidContainerIsLoggedWithoutNoteData() throws {
        let container = URL(fileURLWithPath: "/tmp/theo-share-group-\(UUID().uuidString.prefix(8))")
        try Data("not a folder".utf8).write(to: container)
        defer { try? FileManager.default.removeItem(at: container) }
        let started = Date.now.addingTimeInterval(-1)
        let env = try Env(container: container, makeContainer: false)
        #expect(!env.environment.sharingEnabled)

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.truebrewbirdie.baerchen" && $0.category == "app" }
            .map(\.composedMessage)
        #expect(entries.contains { $0.contains("sharing is off") }, "logged: \(entries.suffix(5))")
    }

    // MARK: - Which launches use the container (FOC-R337)

    @Test func onlyTheDefaultLibraryUsesTheSharedContainerUnlessAskedTo() {
        let container = URL(fileURLWithPath: "/tmp/group")
        let resolve: @Sendable () -> URL? = { container }
        let key = AppEnvironment.shareContainerEnvironmentKey
        #expect(AppEnvironment.shareContainer(syncPolicy: .enabled, environment: [:], resolve: resolve) == container)
        #expect(AppEnvironment.shareContainer(syncPolicy: .localOnly, environment: [:], resolve: resolve) == nil)
        #expect(AppEnvironment.shareContainer(syncPolicy: .localOnly, environment: [key: "1"], resolve: resolve) == container)
        #expect(AppEnvironment.shareContainer(syncPolicy: .localOnly, environment: [key: "0"], resolve: resolve) == nil)
    }

    @Test func theGroupIdentifierIsTheOneInTheEntitlements() {
        #expect(AppEnvironment.shareGroupIdentifier == AppIdentity.current.appGroupIdentifier)
    }
}
