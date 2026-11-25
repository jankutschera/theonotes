// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileShareInboxTests {
    @Test func drainCommitsCachedEditsAndDoesNotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Base")
        let session = try library.session(for: note.id)
        _ = session.apply(txId: "typed", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " typed")]), origin: nil)
        let inbox = CaptureInbox(directory: container.appendingPathComponent("CaptureInbox"))
        try inbox.enqueue(CaptureRequest(itemId: UUID().uuidString.lowercased(), mode: .append,
            targetNoteId: note.id, text: "Shared"), files: [])
        #expect(try await library.drainShareInbox() == [note.id])
        #expect(session.text == "Base typed\n\nShared")
        #expect(try await library.drainShareInbox() == [])
    }

    @Test func concurrentDrainsWaitForEditorAndSaveAttachmentOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        let bytes = Data([1, 3, 5, 7])
        try bytes.write(to: file)
        let id = UUID().uuidString.lowercased()
        try CaptureInbox(directory: container.appendingPathComponent("CaptureInbox")).enqueue(
            CaptureRequest(itemId: id, mode: .save, text: "Shared", files: [file.lastPathComponent]), files: [file])
        var resume: CheckedContinuation<Void, Never>?
        library.drainEditorForLibraryOperation = {
            await withCheckedContinuation { resume = $0 }
            return nil
        }
        let first = Task { try await library.drainShareInbox() }
        while resume == nil { await Task.yield() }
        #expect(try await library.drainShareInbox() == [])
        resume?.resume()
        #expect(try await first.value == [id])
        #expect(try library.store.captureSource(noteId: id) == .share)
        #expect(try library.store.allNotes().count == 1)
        #expect(try Data(contentsOf: #require(try library.attachmentURL(file.lastPathComponent, noteID: id))) == bytes)
    }

    @Test func enabledAppLockScrubsStalePickerBeforeSceneAndWhileAuthenticated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: root.appendingPathComponent("library"))
        let container = root.appendingPathComponent("group")
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let database = try AppDatabase(path: paths.database)
        try Settings(db: database).set(.mobileAppLock, to: true)
        try database.pool.close()
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        try Data("stale private title".utf8).write(to: picker)
        let library = try MobileLibrary(paths: paths, shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: picker.path))
        library.unlockAppForTesting()
        library.publishRecentNotes()
        #expect(!FileManager.default.fileExists(atPath: picker.path))
    }

    @Test func invalidContainerDoesNotFallBackToLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root), shareContainer: root.appendingPathComponent("missing/group"))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        #expect(!library.sharingEnabled)
        #expect(library.sharingError != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CaptureInbox").path))
    }

    @Test func lockingNoteSynchronouslyRemovesPickerEntryAndFailedLockRestoresAllowedEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let protected = try library.store.create(text: "Private title")
        let allowed = try library.store.create(text: "Still available")
        try await library.unlockNotes(password: "share-publication-test-password", createPassword: true)
        library.publishRecentNotes()
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        func entries() throws -> [RecentNotesFile.Entry] {
            try JSONDecoder().decode(RecentNotesFile.self, from: Data(contentsOf: picker)).notes
        }
        #expect(try entries().contains { $0.id == protected.id })
        try library.lockNote(protected.id)
        // No yield: the title must be gone before asynchronous observations can refresh the list.
        #expect(try !entries().contains { $0.id == protected.id })
        #expect(try entries().contains { $0.id == allowed.id })
        #expect(throws: (any Error).self) { try library.lockNote(UUID().uuidString.lowercased()) }
        #expect(try entries().map(\.id) == [allowed.id])
    }

    @Test func completedLibraryOperationRepublishesPicker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Available after import")
        library.publishRecentNotes()
        var operationPrepared = false
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        // An empty batch leaves no database change to trigger another observation after completion.
        library.prepareForLibraryOperation = {
            operationPrepared = true
        }
        _ = try await library.importNotes([])
        #expect(operationPrepared)
        #expect(!library.libraryOperationBusy)
        let entries = try JSONDecoder().decode(RecentNotesFile.self, from: Data(contentsOf: picker)).notes
        #expect(entries.map(\.id) == [note.id])
    }

    @Test func emptyInboxNeverFreezesAnEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        var drained = false
        library.drainEditorForLibraryOperation = { drained = true; throw MobileEditorDrainError.busy }
        #expect(try await library.drainShareInbox() == [])
        #expect(!drained)
    }

    @Test func activationDefersUnreadySessionWithoutAlertOrConsumingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Original")
        let editor = MobileEditor(library: library)
        defer { try? editor.closeForPrivacy() }
        try editor.open(note.id)
        editor.webView.stopLoading()
        #expect(!editor.ready && editor.session?.noteId == note.id)
        let inbox = CaptureInbox(directory: container.appendingPathComponent("CaptureInbox"))
        let request = CaptureRequest(itemId: UUID().uuidString.lowercased(), mode: .append,
            targetNoteId: note.id, text: "Shared")
        try inbox.enqueue(request, files: [])
        await library.drainShareInboxOnActivation()
        #expect(library.errorMessage == nil)
        #expect(try library.store.note(id: note.id)?.text == "Original")
        #expect(FileManager.default.fileExists(atPath: inbox.directory.appendingPathComponent(request.itemId + ".capture").path))
    }

    @Test func pickerScrubFailureDoesNotPreventOpeningLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: invalid)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: invalid)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        #expect(!library.sharingEnabled)
        #expect(library.sharingError != nil)
        #expect(try library.store.create(text: "Library still works").text == "Library still works")
    }

    @Test func enablingAppLockScrubsBeforePublishingEvenWhileAuthenticated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "Private title")
        library.publishRecentNotes()
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        #expect(FileManager.default.fileExists(atPath: picker.path))
        enum Denied: Error { case authentication }
        await #expect(throws: Denied.authentication) {
            try await library.setAppLock(true, authenticate: { throw Denied.authentication })
        }
        #expect(!library.appLockEnabled)
        #expect(FileManager.default.fileExists(atPath: picker.path))
        try await library.setAppLock(true, authenticate: {})
        #expect(library.appLockEnabled && !library.appLocked)
        #expect(!FileManager.default.fileExists(atPath: picker.path))
        library.publishRecentNotes()
        #expect(!FileManager.default.fileExists(atPath: picker.path))
    }

    @Test func syncedLockOfUncachedNoteSynchronouslyRemovesPickerTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Title no extension may retain")
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        let access = try #require(library.privateAccess)
        library.publishRecentNotes()
        _ = try library.commitSyncedChange { try access.lock(noteId: note.id); return .applied }
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        let entries = try JSONDecoder().decode(RecentNotesFile.self, from: Data(contentsOf: picker)).notes
        #expect(!entries.contains { $0.id == note.id })
    }

    @Test(arguments: [MobileEditorDrainError.busy, .composing, .timeout, .unavailable, .mismatch])
    func activationDefersEditorFailuresWithoutAlert(failure: MobileEditorDrainError) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let inbox = CaptureInbox(directory: container.appendingPathComponent("CaptureInbox"))
        let request = CaptureRequest(itemId: UUID().uuidString.lowercased(), mode: .save, text: "Shared")
        try inbox.enqueue(request, files: [])
        library.drainEditorForLibraryOperation = { throw failure }
        await library.drainShareInboxOnActivation()
        #expect(library.errorMessage == nil)
        // An unavailable callback with no registered editor is safe; all other failures retain the item.
        #expect((try library.store.note(id: request.itemId) != nil) == (failure == .unavailable))
    }

    @Test func disabledSharingCannotLetAppLockSucceedWithReadableStalePicker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        let stale = Data("readable private title".utf8)
        try stale.write(to: picker)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: container.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
            try? FileManager.default.removeItem(at: root)
        }
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
            try? library.close()
        }
        #expect(!library.sharingEnabled)
        #expect(library.sharingError != nil)
        #expect(try Data(contentsOf: picker) == stale)
        await #expect(throws: CocoaError.self) { try await library.setAppLock(true, authenticate: {}) }
        #expect(!library.appLockEnabled)
        #expect(try library.settings.value(.mobileAppLock) == false)
        #expect(try Data(contentsOf: picker) == stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
        try await library.setAppLock(true, authenticate: {})
        #expect(library.appLockEnabled)
        #expect(!FileManager.default.fileExists(atPath: picker.path))
    }

    @Test func activationRetriesOnceAfterAnUnreadyEditorStopsBlocking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Original")
        let editor = MobileEditor(library: library)
        defer { try? editor.closeForPrivacy() }
        try editor.open(note.id)
        editor.webView.stopLoading()
        #expect(!editor.ready)
        let request = CaptureRequest(itemId: UUID().uuidString.lowercased(), mode: .save, text: "Shared after startup")
        try CaptureInbox(directory: container.appendingPathComponent("CaptureInbox")).enqueue(request, files: [])
        var retried = 0
        library.drainEditorForLibraryOperation = { retried += 1; return nil }
        let activation = Task { await library.drainShareInboxOnActivation() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try library.store.note(id: request.itemId) == nil)
        try editor.closeForPrivacy()
        await activation.value
        #expect(retried == 1)
        #expect(try library.store.note(id: request.itemId)?.text == request.text)
        #expect(library.errorMessage == nil)
    }
    @Test func syncLockSurvivesScrubFailureAndNextPublicationClearsBeforeWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        let protected = try library.store.create(text: "Protected title")
        let allowed = try library.store.create(text: "Allowed title")
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        let access = try #require(library.privateAccess)
        library.publishRecentNotes()
        let picker = container.appendingPathComponent(RecentNotesFile.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: container.path)
        let outcome = try library.commitSyncedChange { try access.lock(noteId: protected.id); return .applied }
        #expect(outcome == .applied)
        #expect(try library.store.note(id: protected.id)?.isLocked == true)
        #expect(library.sharePublicationScrubPending)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
        try FileManager.default.removeItem(at: picker)
        // Atomic writing alone cannot replace this stale directory; the pending scrub must run first.
        try FileManager.default.createDirectory(at: picker, withIntermediateDirectories: false)
        try Data("stale title".utf8).write(to: picker.appendingPathComponent("stale"))
        library.publishRecentNotes()
        #expect(!library.sharePublicationScrubPending)
        #expect(library.sharingError == nil)
        let entries = try JSONDecoder().decode(RecentNotesFile.self, from: Data(contentsOf: picker)).notes
        #expect(entries.map(\.id) == [allowed.id])
    }

}
