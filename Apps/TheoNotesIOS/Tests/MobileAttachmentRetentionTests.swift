// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Dispatch
import GRDB
import Testing
import TheoNotesCore
@testable import BaerchenIOS

private final class AttachmentSweepGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var waiting = false
    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting
    }
    func holdSweep(_ sql: String) {
        guard sql.contains("FROM privacy_transition WHERE noteId") else { return }
        lock.lock()
        let hold = !entered
        if hold { entered = true; waiting = true }
        lock.unlock()
        if hold {
            _ = release.wait(timeout: .now() + 5)
            lock.lock(); waiting = false; lock.unlock()
        }
    }
    func resume() { release.signal() }
}

@Suite @MainActor struct MobileAttachmentRetentionTests {
    @Test func openSessionRetainsUndoFilesAndClosedSessionAllowsGraceCleanup() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "No attachment link after Undo")
        let name = try library.addAttachment(data: Data([1, 2]), filename: "undo.png", noteID: note.id)
        let file = paths.attachments.appendingPathComponent(note.id).appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        _ = try library.session(for: note.id)
        #expect(library.store.retention.contains(note.id))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try library.discardSession(note.id)
        #expect(!library.store.retention.contains(note.id))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id) == [name])
    }

    @Test func failedSessionCreationAndBulkCloseReleaseRetention() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let missing = UUID().uuidString.lowercased()
        #expect(throws: (any Error).self) { try library.session(for: missing) }
        #expect(!library.store.retention.contains(missing))
        let first = try library.store.create(text: "First"), second = try library.store.create(text: "Second")
        _ = try library.session(for: first.id); _ = try library.session(for: second.id)
        _ = try await library.importNotes([])
        #expect(!library.store.retention.contains(first.id) && !library.store.retention.contains(second.id))
        _ = try library.session(for: first.id)
        try library.close()
        #expect(!library.store.retention.contains(first.id))
    }
    @Test func editorOutlivingCacheRetainsUndoFilesUntilItCloses() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Undo may still restore an image link")
        let name = try library.addAttachment(data: Data([7]), filename: "undo.png", noteID: note.id)
        let file = paths.attachments.appendingPathComponent(note.id).appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        let editor = MobileEditor(library: library)
        defer { try? editor.closeForPrivacy() }
        try editor.open(note.id)
        try library.discardSession(note.id)
        #expect(!library.hasCachedSession(for: note.id))
        #expect(editor.session?.noteId == note.id)
        #expect(library.store.retention.contains(note.id))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try editor.closeForPrivacy()
        #expect(!library.store.retention.contains(note.id))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id) == [name])
    }

    @Test func editorDeinitReleasesLeaseAfterCacheEviction() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        var editor: MobileEditor? = MobileEditor(library: library)
        try editor?.open(note.id)
        try library.discardSession(note.id)
        #expect(library.store.retention.contains(note.id))
        editor = nil
        #expect(!library.store.retention.contains(note.id))
    }

    @Test func closingOneOfTwoEditorsKeepsTheOtherEditorsUndoFiles() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        let name = try library.addAttachment(data: Data([7]), filename: "undo.png", noteID: note.id)
        let file = paths.attachments.appendingPathComponent(note.id).appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        defer { try? first.closeForPrivacy(); try? second.closeForPrivacy() }
        try first.open(note.id); try second.open(note.id)
        try library.discardSession(note.id)
        try first.closeForPrivacy()
        #expect(second.session?.noteId == note.id)
        #expect(library.store.retention.contains(note.id))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try second.closeForPrivacy()
        #expect(!library.store.retention.contains(note.id))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id) == [name])
    }

    @Test func startupSweepUsesTheSameRetentionAndRunsOncePerLibrary() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        let name = try library.addAttachment(data: Data([7]), filename: "undo.png", noteID: note.id)
        let file = paths.attachments.appendingPathComponent(note.id).appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        _ = try library.session(for: note.id)
        async let first = library.sweepAttachments()
        async let second = library.sweepAttachments()
        let results = await (first, second)
        #expect(results.0 == 0 && results.1 == 0)
        try library.discardSession(note.id)
        #expect(await library.sweepAttachments() == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(library.store.removeUnreferencedAttachments(noteId: note.id) == [name])
    }

    @Test func asyncCloseWaitsForTheTrackedSweep() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Original")
        let name = try library.addAttachment(data: Data([1]), filename: "unreferenced.png", noteID: note.id)
        let file = paths.attachments.appendingPathComponent(note.id).appendingPathComponent(name)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        let gate = AttachmentSweepGate()
        defer { gate.resume() }
        try await library.database.pool.write { db in
            db.trace { event in gate.holdSweep(event.description) }
        }
        let sweep = Task { await library.sweepAttachments() }
        for _ in 0..<300 where !gate.isHeld { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.isHeld, "The actual detached sweep must own the writer before testing close")
        sweep.cancel()
        #expect(throws: BackupError.pendingFiles) { try library.close() }
        var closeFinished = false
        let close = Task {
            defer { closeFinished = true }
            try await library.closeAfterStopping()
        }
        for _ in 0..<300 where !library.isClosing { try await Task.sleep(for: .milliseconds(10)) }
        try #require(library.isClosing)
        #expect(!closeFinished && !library.isClosed)
        try #require(gate.isHeld, "The sweep must still be inside the held writer, not already finished")
        gate.resume()
        try await close.value
        #expect(await sweep.value == 1)
        #expect(library.isClosed)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

}
