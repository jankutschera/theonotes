// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import BaerchenIOS

@Suite @MainActor
struct MobileImportTests {
    @Test func importBatchExcludesRestoreBackupAndCloseUntilItsWriterFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-import-" + UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let archive = try await library.makeBackup()
        let prepared = try SyncRecoveryLibrary.prepare(source: library.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        let sync = MobileSyncController(library: library)
        let input = root.appendingPathComponent("import.md")
        try Data("# Imported 🐻\nBody".utf8).write(to: input)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in
            try await library.importNotes([input]) { done, _ in
                if done == 0 { continuation.yield(()); release.wait() }
            }
        }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        // The actual importer is paused before its first note, not mocked or timing dependent.
        #expect(library.libraryOperationBusy)
        #expect(throws: BackupError.pendingFiles) { try library.close() }
        await #expect(throws: BackupError.pendingFiles) { try await library.makeBackup() }
        await #expect(throws: BackupError.pendingFiles) {
            try await library.restoreBackup(input, mode: .replaceAll, backupPassword: nil, currentPassword: nil)
        }
        await #expect(throws: BackupError.pendingFiles) { try await library.closeAfterStopping() }
        await sync.openRecoveryCopy()
        #expect(sync.errorMessage == BackupError.pendingFiles.localizedDescription)
        #expect(try SyncRecoveryLibrary.activePaths(base: library.paths).root == library.paths.root)
        // Exercise return's mutation guard with a real persistent recovery selection too.
        try SyncRecoveryLibrary.select(prepared)
        await sync.returnToOriginalLibrary()
        #expect(try SyncRecoveryLibrary.activePaths(base: library.paths).root == prepared.paths.root)
        try SyncRecoveryLibrary.selectOriginal(for: library.paths)
        #expect(!library.isClosed)
        release.signal()
        let report = try await task.value
        #expect(report.created == 1 && report.errors.isEmpty)
        #expect(!library.libraryOperationBusy)
        #expect(try library.store.allNotes().first?.text == "# Imported 🐻\nBody")
        let backup = try await library.makeBackup()
        #expect(FileManager.default.fileExists(atPath: backup.path))
        try library.close()
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try reopened.store.allNotes().count == 1)
    }

    @Test func failedImportReportReleasesOperationAndPreservesExistingNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-import-failure-" + UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Keep me")
        let report = try await library.importNotes([root.appendingPathComponent("missing.zip")])
        #expect(report.created == 0 && report.errors.count == 1)
        #expect(!library.libraryOperationBusy)
        #expect(try library.store.note(id: note.id)?.text == "Keep me")
        _ = try library.store.updateText(id: note.id, text: "Still editable", expectedRevision: note.revision)
        #expect(try library.store.note(id: note.id)?.text == "Still editable")
    }
    @Test func retainedAutomationCannotWriteWhileShutdownAwaitsDailyBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-closing-" + UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "Keep unchanged")
        let service = MobileShortcutService(library: library)
        let capture = MobileShortcutCapture(library: library)
        let database = library.database
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try database.pool.write { _ in signal.yield(()); release.wait() }
        }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        library.setActive(true) // The real daily-backup task must wait for the held writer.
        let close = Task { @MainActor in try await library.closeAfterStopping() }
        while !library.isClosing { await Task.yield() }
        #expect(!library.isClosed)
        release.signal()
        // No actor suspension here: shutdown stays in progress through each retained call.
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try service.create(text: "Late", title: nil) }
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try service.append(text: "Late", to: note.id) }
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try capture.capture(inputs: [.text("Late")]) }
        try await writer.value
        try await close.value
        #expect(library.isClosed && !library.isClosing)
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try reopened.store.allNotes().map(\.text) == ["Keep unchanged"])
    }

}
