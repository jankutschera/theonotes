// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TheoNotes

/// Backup Notes… and Restore Backup… on the one backup format (`LibraryBackup`): the app
/// flow around it. The archive itself (hostile files, round trip, vault-aware restore) is tested
/// in TheoNotesCore.
@MainActor
@Suite(.serialized) struct BackupRestoreFlowTests {
    /// A temporary library with a live environment, an editor with a fake page and a backup model
    /// whose panels answer from `savePath` / `openPath`.
    @MainActor final class Env {
        let root: URL
        let paths: AppPaths
        let environment: AppEnvironment
        var savePath: URL?
        var openPath: URL?
        private(set) var savePanelNames: [String] = []
        private(set) var openPanelCalls = 0
        private(set) var refreshes = 0
        private(set) var model: BackupModel!

        init(name: String = "library", restoreRunner: @escaping BackupModel.RestoreRunner = BackupModel.liveRestoreRunner) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesBackupFlow-\(UUID().uuidString)", isDirectory: true)
            paths = AppPaths(root: root.appendingPathComponent(name, isDirectory: true))
            environment = try AppEnvironment(paths: paths)
            model = BackupModel(
                environment: environment, now: { Date(timeIntervalSince1970: 1_792_000_000) },
                savePanel: { [unowned self] name in
                    savePanelNames.append(name)
                    return savePath
                },
                openPanel: { [unowned self] in
                    openPanelCalls += 1
                    return openPath
                },
                didChange: { [unowned self] in refreshes += 1 },
                restoreRunner: restoreRunner)
        }

        deinit {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.backups.path)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        func editor(showing noteId: String) throws -> (EditorBridgeController, FakeEditorPage) {
            let page = FakeEditorPage()
            let controller = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            _ = controller.handle(.ready(version: EditorBridge.version))
            try controller.open(noteId: noteId)
            return (controller, page)
        }

        /// Types `text` at the end of the note in `controller`: acked and journaled, not committed.
        func type(_ text: String, into noteId: String, with controller: EditorBridgeController, base: Int, length: Int) {
            let change = ChangeSet(sections: [.retain(length), .replace(deleteLength: 0, insert: text)])
            let ack = controller.handle(
                .changes(noteId: noteId, txId: "t-\(UUID().uuidString.prefix(6))", baseRevision: base, revision: base + 1, changeSet: change))
            #expect(ack == .acked(revision: base + 1))
        }

        /// A full backup file of this library, made by the core writer.
        @discardableResult
        func makeBackupFile(named name: String = "made.baerchen-backup") throws -> URL {
            let url = root.appendingPathComponent(name)
            try LibraryBackup(database: environment.database, paths: paths).create(at: url)
            return url
        }

        /// The note texts of a library by id.
        func texts() throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try store.allNotes().map { ($0.id, $0.text) })
        }

        /// Journals that still hold edits (`Journal/*.jsonl` with bytes in them).
        func nonEmptyJournals() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: paths.journal.path)
                .filter { $0.hasSuffix(".jsonl") }
                .filter { (try? Data(contentsOf: paths.journal.appendingPathComponent($0)).isEmpty) == false }
        }
    }

    /// `unzip -p`: one file of a zip, to check the stored bytes without our own reader.
    private func unzipped(_ archive: URL, _ member: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Backup Notes…

    @Test func backupFlushesDirtyEditorsFirst() async throws {
        let env = try Env()
        let noteId = try env.store.create(text: "hello").id
        let (controller, _) = try env.editor(showing: noteId)
        env.type(" world", into: noteId, with: controller, base: 0, length: 5)
        #expect(try env.store.note(id: noteId)?.text == "hello", "typed but not committed yet")

        let destination = env.root.appendingPathComponent("typed.baerchen-backup")
        env.savePath = destination
        env.model.backUp()
        await env.model.runTask?.value

        #expect(env.model.phase == .backedUp(destination))
        #expect(env.savePanelNames == [BackupModel.defaultFileName(Date(timeIntervalSince1970: 1_792_000_000))])
        #expect(try unzipped(destination, "\(noteId).textbundle/text.md") == "hello world")
        #expect(try env.nonEmptyJournals().isEmpty)
        #expect(env.environment.operations.isBusy, "the sheet is still up")
        env.model.dismiss()
        #expect(env.model.phase == .idle)
        #expect(!env.environment.operations.isBusy)
        // No temporary file is left beside the backup.
        let names = try FileManager.default.contentsOfDirectory(atPath: env.root.path)
        #expect(!names.contains { $0.hasSuffix(".partial") })
    }

    @Test func backupOverAnExistingFileReplacesItAndCancelWritesNothing() async throws {
        let env = try Env()
        _ = try env.store.create(text: "one")
        let destination = env.root.appendingPathComponent("again.baerchen-backup")
        try Data("old".utf8).write(to: destination)
        env.savePath = destination
        env.model.backUp()
        await env.model.runTask?.value
        #expect(env.model.phase == .backedUp(destination))
        #expect(try LibraryBackup(database: env.environment.database, paths: env.paths).inspect(destination).noteCount == 1)
        env.model.dismiss()

        env.savePath = nil
        let before = try Data(contentsOf: destination)
        env.model.backUp()
        await env.model.runTask?.value
        #expect(env.model.phase == .idle)
        #expect(try Data(contentsOf: destination) == before)
        #expect(!env.environment.operations.isBusy)
    }

    @Test func theDefaultNameCarriesTheProductNameDateAndExtension() {
        let name = BackupModel.defaultFileName(Date(timeIntervalSince1970: 1_792_000_000))
        #expect(name.hasPrefix("Theo Notes Backup 20"))
        #expect(name.hasSuffix(".theonotes-backup"))
        #expect(!name.contains("Bear") && !name.contains("Theo Notes"))
    }

    // MARK: - Restore: Replace All

    @Test func replaceAllFlushesDirtyEditorsAndLeavesNoReplayableJournal() async throws {
        let env = try Env()
        let noteId = try env.store.create(text: "older text").id
        let backup = try env.makeBackupFile()

        // After the backup: a dirty edit of the same note, and a note the backup does not have.
        let (controller, page) = try env.editor(showing: noteId)
        env.type(" and a dirty edit", into: noteId, with: controller, base: 0, length: 10)
        let extraId = try env.store.create(text: "made after the backup").id
        #expect(try env.store.note(id: noteId)?.text == "older text", "the dirty edit is not committed yet")

        env.openPath = backup
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        guard case .review(let opened) = env.model.phase else { Issue.record("expected review, got \(env.model.phase)"); return }
        #expect(opened.summary.noteCount == 1)

        env.model.mode = .replaceAll
        env.model.requestRestore()
        // Asked first, nothing happened yet.
        let confirmation = try #require(env.model.confirmation)
        #expect(confirmation.title == "Replace all notes?")
        #expect(confirmation.message == "All 2 notes in this library, including the Trash, will be deleted and replaced with the 1 note in the backup. A safety backup of your current notes is saved to the Backups folder first.")
        #expect(try env.store.note(id: extraId) != nil)
        #expect(env.model.phase == .review(opened))

        env.model.confirmReplace()
        await env.model.runTask?.value
        guard case .restored(let report) = env.model.phase else { Issue.record("expected restored, got \(env.model.phase)"); return }
        #expect(report.mode == .replaceAll && report.restored == 1)
        #expect(env.refreshes == 1)

        // The library is the backup's.
        #expect(try env.texts() == [noteId: "older text"])
        // The safety backup holds what was typed and the note made later.
        let safety = try #require(report.safetyBackup)
        #expect(try unzipped(safety, "\(noteId).textbundle/text.md") == "older text and a dirty edit")
        #expect(try unzipped(safety, "\(extraId).textbundle/text.md") == "made after the backup")
        // No journal can replay the dirty edit onto the restored note.
        #expect(try env.nonEmptyJournals().isEmpty)
        // The editor that showed the note was told (the page applied an external change).
        guard case .applyExternalChange(let id, _, let changeSet)? = page.delivered.last else {
            Issue.record("no applyExternalChange, got \(String(describing: page.delivered.last))")
            return
        }
        #expect(id == noteId)
        #expect(try changeSet.apply(to: "older text and a dirty edit") == "older text")
        withExtendedLifetime(controller) {}

        // A relaunch on the same files shows the backup's text, not the dirty one.
        let relaunched = try AppEnvironment(paths: env.paths)
        #expect(try relaunched.store.note(id: noteId)?.text == "older text")
        #expect(try relaunched.store.note(id: extraId) == nil)
    }

    @Test func aNoteMissingFromTheBackupLosesItsOpenEditorWhenReplaced() async throws {
        let env = try Env()
        let keptId = try env.store.create(text: "kept").id
        let backup = try env.makeBackupFile()
        let goneId = try env.store.create(text: "will be replaced").id
        let (controller, _) = try env.editor(showing: goneId)
        env.type(" dirty", into: goneId, with: controller, base: 0, length: 16)

        env.openPath = backup
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.mode = .replaceAll
        env.model.requestRestore()
        env.model.confirmReplace()
        await env.model.runTask?.value

        #expect(try env.texts() == [keptId: "kept"])
        #expect(env.environment.existingSession(for: goneId) == nil, "the session of a note that is gone is closed")
        #expect(try env.nonEmptyJournals().isEmpty)
        withExtendedLifetime(controller) {}
    }

    @Test func replaceAllStopsWhenTheSafetyBackupFails() async throws {
        let env = try Env()
        let noteId = try env.store.create(text: "original").id
        let backup = try env.makeBackupFile()
        let laterId = try env.store.create(text: "later").id
        let before = try env.texts()

        env.openPath = backup
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.mode = .replaceAll
        env.model.requestRestore()

        // The Backups folder cannot take the safety backup.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.paths.backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.paths.backups.path) }
        env.model.confirmReplace()
        await env.model.runTask?.value

        guard case .failed(let message) = env.model.phase else { Issue.record("expected the alert, got \(env.model.phase)"); return }
        #expect(!message.isEmpty)
        #expect(try env.texts() == before, "the library is unchanged")
        #expect(try env.store.note(id: noteId) != nil && env.store.note(id: laterId) != nil)
        #expect(env.refreshes == 1, "the window refreshes to be safe, nothing else happened")
    }

    // MARK: - Restore: Merge

    @Test func mergeRunsWithoutConfirmationAndReports() async throws {
        let source = try Env(name: "source")
        let a = try source.store.create(text: "from the backup A").id
        let c = try source.store.create(text: "from the backup C").id
        let backup = try source.makeBackupFile()

        let env = try Env(name: "target")
        let d = try env.store.create(text: "already here").id
        env.openPath = backup
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        guard case .review(let opened) = env.model.phase else { Issue.record("expected review, got \(env.model.phase)"); return }
        #expect(env.model.mode == .merge, "Merge is the default")
        #expect(opened.summaryLine.hasPrefix("2 notes, 0 attachments, made "))

        env.model.requestRestore()
        #expect(env.model.confirmation == nil, "Merge asks nothing")
        guard case .restoring(.merge) = env.model.phase else { Issue.record("expected restoring, got \(env.model.phase)"); return }
        await env.model.runTask?.value
        guard case .restored(let report) = env.model.phase else { Issue.record("expected restored, got \(env.model.phase)"); return }
        #expect(report.headline == "Added 2 notes. 0 already here and stayed as they were.")
        #expect(report.safetyBackup == nil)
        #expect(try env.texts() == [a: "from the backup A", c: "from the backup C", d: "already here"])

        // The same backup again adds nothing and keeps everything.
        env.model.dismiss()
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.requestRestore()
        await env.model.runTask?.value
        guard case .restored(let again) = env.model.phase else { Issue.record("expected restored, got \(env.model.phase)"); return }
        #expect(again.headline == "Added 0 notes. 2 already here and stayed as they were.")
    }

    @Test func theRestoreSheetSummaryShowsArchivedAndTrashedCounts() async throws {
        let source = try Env(name: "source")
        _ = try source.store.create(text: "live one")
        let archived = try source.store.create(text: "to archive").id
        let trashedA = try source.store.create(text: "trash A").id
        let trashedB = try source.store.create(text: "trash B").id
        try source.store.archive([archived])
        try source.store.trash([trashedA, trashedB])
        let backup = try source.makeBackupFile()

        let env = try Env(name: "target")
        env.openPath = backup
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        guard case .review(let opened) = env.model.phase else { Issue.record("expected review, got \(env.model.phase)"); return }
        #expect(opened.summaryLine.hasPrefix("4 notes (1 archived, 2 in Trash), 0 attachments, made "))
    }

    @Test func aFileThatIsNotABackupIsRefusedBeforeAnyChange() async throws {
        let env = try Env()
        let noteId = try env.store.create(text: "safe").id
        let bogus = env.root.appendingPathComponent("bogus.baerchen-backup")
        try Data("not a zip".utf8).write(to: bogus)
        env.openPath = bogus
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        guard case .failed(let message) = env.model.phase else { Issue.record("expected failed, got \(env.model.phase)"); return }
        #expect(!message.isEmpty)
        #expect(try env.texts() == [noteId: "safe"])
        env.model.dismiss()
        #expect(env.model.phase == .idle)
    }

    // MARK: - Disabled while something else runs

    @Test func restoreIsDisabledWhileAnImportRuns() async throws {
        let env = try Env()
        let service = FakeImportService(total: 1, gated: true)
        let importer = ImportModel(
            service: service, bearCLIPath: { "/x/bearcli" }, prepare: {}, didImport: {})
        importer.isBlocked = { env.environment.operations.isBusy }
        let model = BackupModel(
            environment: env.environment, savePanel: { _ in nil },
            openPanel: { env.openPath }, isBlockedElsewhere: { importer.isRunning })

        importer.pullFromBear()
        #expect(importer.isRunning)
        model.chooseBackupToRestore()
        model.backUp()
        #expect(model.phase == .idle, "neither command starts while an import runs")
        #expect(BackupCommandAvailability.isBlocked(importRunning: importer.isRunning, exportBusy: false, backupBusy: false))

        service.step()
        while importer.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!BackupCommandAvailability.isBlocked(importRunning: importer.isRunning, exportBusy: false, backupBusy: false))
        model.chooseBackupToRestore()
        await model.runTask?.value
        #expect(model.phase == .idle, "the open panel was cancelled")

        // And the other way round: a restore sheet keeps imports out.
        let backup = try env.makeBackupFile()
        env.openPath = backup
        model.chooseBackupToRestore()
        await model.runTask?.value
        guard case .review = model.phase else { Issue.record("expected review, got \(model.phase)"); return }
        #expect(env.environment.operations.isBusy)
        importer.showFileImport([backup])
        #expect(importer.sheet == nil)
        importer.pullFromBear()
        #expect(!importer.isRunning)
        model.dismiss()
        #expect(!env.environment.operations.isBusy)
    }

    @Test func exportIsBlockedWhileABackupRuns() async throws {
        let env = try Env()
        let state = MainWindowState(
            environment: env.environment, defaults: UserDefaults(suiteName: "BackupExport-\(UUID().uuidString)")!)
        #expect(!state.isExportBlocked)
        let panel = PanelGate()
        let model = BackupModel(environment: env.environment, savePanel: { _ in await panel.wait() })
        model.backUp()
        while !panel.isWaiting { await Task.yield() }
        #expect(env.environment.operations.isBusy)
        #expect(state.isExportBlocked, "another window's backup blocks this window's export")
        #expect(ExportCommandAvailability.isEnabled(
            importRunning: false, exportBusy: false, restoreRunning: state.isBackupBusy, hasTarget: true) == false)
        panel.answer(nil)
        await model.runTask?.value
        #expect(!env.environment.operations.isBusy)
        #expect(!state.isExportBlocked)
        state.close()
    }

    // MARK: - Fix round 1: all windows, Cancel, Import menu

    /// Waits for a background thread and lets the test wait for it without blocking the main actor.
    final class Latch: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reached = false
        func signal() { lock.withLock { reached = true }; semaphore.signal() }
        func wait() { semaphore.wait() }
        var isReached: Bool { lock.withLock { reached } }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("\(what): not within 5 s"); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func anEditInAnotherWindowDuringReplaceAllNeverReachesTheRestoredLibrary() async throws {
        let started = Latch(), release = Latch()
        let env = try Env(restoreRunner: { backup, url, mode, bp, cp, after in
            started.signal()
            release.wait()
            return try BackupModel.liveRestoreRunner(backup, url, mode, bp, cp, after)
        })
        let noteId = try env.store.create(text: "older text").id
        let backupFile = try env.makeBackupFile()
        // Window A and window B show the same note; A has an uncommitted edit.
        let (a, _) = try env.editor(showing: noteId)
        let (b, pageB) = try env.editor(showing: noteId)
        env.type(" and a dirty edit", into: noteId, with: a, base: 0, length: 10)

        env.openPath = backupFile
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.mode = .replaceAll
        env.model.requestRestore()
        env.model.confirmReplace()
        await waitUntil("the restore started") { started.isReached }
        #expect(env.environment.editsFrozen)

        // The restore is running (blocked before it writes). Window B types now.
        let session = try env.environment.session(for: noteId)
        let textDuringRestore = session.text
        let change = ChangeSet(sections: [.retain(textDuringRestore.utf16.count), .replace(deleteLength: 0, insert: " LATE EDIT FROM B")])
        let reply = b.handle(.changes(
            noteId: noteId, txId: "late-b", baseRevision: session.revision, revision: session.revision + 1, changeSet: change))
        #expect(reply == .needsFullText(currentRevision: session.revision), "the edit is refused")
        #expect(session.text == textDuringRestore, "and reaches no session")
        #expect(try env.nonEmptyJournals().isEmpty, "and no journal")

        release.signal()
        await env.model.runTask?.value
        guard case .restored = env.model.phase else { Issue.record("expected restored, got \(env.model.phase)"); return }
        #expect(!env.environment.editsFrozen)
        #expect(try env.texts() == [noteId: "older text"])
        #expect(try env.nonEmptyJournals().isEmpty)
        // Window B reloads the restored note instead of keeping its refused edit.
        guard case .loadNote(let loadedId, let loadedText, _, _, _, _, _)? = pageB.loadNotes.last else {
            Issue.record("window B did not reload: \(pageB.loadNotes.count) loads"); return
        }
        #expect(loadedId == noteId && loadedText == "older text")
        let relaunched = try AppEnvironment(paths: env.paths)
        #expect(try relaunched.store.note(id: noteId)?.text == "older text")
        withExtendedLifetime((a, b)) {}
    }

    @Test func editsAreAcceptedAgainAfterTheRestore() async throws {
        let env = try Env()
        let noteId = try env.store.create(text: "abc").id
        let backupFile = try env.makeBackupFile()
        let (controller, _) = try env.editor(showing: noteId)
        env.openPath = backupFile
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.requestRestore()
        await env.model.runTask?.value
        #expect(!env.environment.editsFrozen)
        let session = try env.environment.session(for: noteId)
        env.type("d", into: noteId, with: controller, base: session.revision, length: 3)
        #expect(session.text == "abcd")
    }

    @Test func cancelBeforeTheCommitLeavesTheLibraryUnchanged() async throws {
        let env = try Env()
        let keptId = try env.store.create(text: "original").id
        let backupFile = try env.makeBackupFile()
        let laterId = try env.store.create(text: "later").id
        let before = try env.texts()
        env.openPath = backupFile
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.mode = .replaceAll
        env.model.requestRestore()
        env.model.confirmReplace()
        #expect(env.model.canCancelRestore)
        env.model.cancelRestore()
        await env.model.runTask?.value
        #expect(env.model.phase == .cancelled)
        #expect(try env.texts() == before)
        #expect(try env.store.note(id: keptId) != nil && env.store.note(id: laterId) != nil)
        #expect(!env.model.canCancelRestore)
        #expect(!env.environment.editsFrozen)
        env.model.dismiss()
        #expect(!env.environment.operations.isBusy)
    }

    @Test func cancelAfterTheCommitIsDisabledAndTheRestoreFinishes() async throws {
        let committed = Latch(), release = Latch()
        let env = try Env(restoreRunner: { backup, url, mode, bp, cp, after in
            try BackupModel.liveRestoreRunner(backup, url, mode, bp, cp, {
                after()
                committed.signal()
                release.wait() // the restore sits right after its commit
            })
        })
        let noteId = try env.store.create(text: "original").id
        let backupFile = try env.makeBackupFile()
        let laterId = try env.store.create(text: "later").id
        env.openPath = backupFile
        env.model.chooseBackupToRestore()
        await env.model.runTask?.value
        env.model.mode = .replaceAll
        env.model.requestRestore()
        env.model.confirmReplace()
        #expect(env.model.canCancelRestore)
        await waitUntil("committed") { committed.isReached }
        // The callback ran on the restore's thread: Cancel is off at once, without waiting for
        // the main actor to catch up.
        #expect(!env.model.canCancelRestore)
        env.model.cancelRestore() // no effect
        #expect(env.model.phase == .restoring(.replaceAll))
        release.signal()
        await env.model.runTask?.value
        guard case .restored = env.model.phase else { Issue.record("expected restored, got \(env.model.phase)"); return }
        #expect(try env.texts() == [noteId: "original"])
        #expect(try env.store.note(id: laterId) == nil)
    }

    @Test func theImportMenuIsOffWhileABackupOrRestoreRuns() async throws {
        #expect(!ImportCommandAvailability.isUnavailable(hasWindow: true, importRunning: false, libraryOperationBusy: false))
        #expect(ImportCommandAvailability.isUnavailable(hasWindow: false, importRunning: false, libraryOperationBusy: false))
        #expect(ImportCommandAvailability.isUnavailable(hasWindow: true, importRunning: true, libraryOperationBusy: false))
        #expect(ImportCommandAvailability.isUnavailable(hasWindow: true, importRunning: false, libraryOperationBusy: true))

        let env = try Env()
        let gate = PanelGate()
        let model = BackupModel(environment: env.environment, savePanel: { _ in await gate.wait() })
        func menuOff() -> Bool {
            ImportCommandAvailability.isUnavailable(
                hasWindow: true, importRunning: false, libraryOperationBusy: env.environment.operations.isBusy)
        }
        #expect(!menuOff())
        model.backUp()
        await waitUntil("panel up") { gate.isWaiting }
        #expect(menuOff(), "the backup's save panel is up")
        gate.answer(nil)
        await model.runTask?.value
        #expect(!menuOff())
    }

    // MARK: - Daily snapshots

    @Test func rollingBackupRunsAtLaunchWhenDue() async throws {
        let env = try Env()
        _ = try env.store.create(text: "one")
        #expect(env.environment.lastDailyBackupDate() == nil)

        let first = await env.environment.runDailyBackupIfDue()
        let url = try #require(first)
        #expect(url.pathExtension == "sqlite")
        #expect(url.deletingLastPathComponent() == env.paths.backups)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(env.environment.lastDailyBackupDate() != nil)
        #expect(env.environment.dailyBackupFailure == nil)

        // Not due again within 24 hours.
        #expect(await env.environment.runDailyBackupIfDue() == nil)
        let copies = try FileManager.default.contentsOfDirectory(atPath: env.paths.backups.path).filter { $0.hasSuffix(".sqlite") }
        #expect(copies.count == 1)

        // The launch loop does the same on a fresh library.
        let fresh = try Env(name: "fresh")
        fresh.environment.startDailyBackups(interval: .seconds(3600))
        let deadline = ContinuousClock.now + .seconds(10)
        while fresh.environment.lastDailyBackupDate() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        fresh.environment.stopDailyBackups()
        #expect(fresh.environment.lastDailyBackupDate() != nil)
    }

    // MARK: - File type

    @Test func backupTypeIsDeclared() throws {
        let type = try #require(UTType("com.truebrewbirdie.theonotes.backup"))
        #expect(type.preferredFilenameExtension == "theonotes-backup")
        #expect(!type.isDynamic)
        #expect(type.conforms(to: .zip) && type.conforms(to: .data))

        // The declaration is in the app's Info.plist as an exported type.
        let declarations = Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        let entry = declarations?.first { $0["UTTypeIdentifier"] as? String == BackupFileType.identifier }
        let conforms = entry?["UTTypeConformsTo"] as? [String]
        #expect(conforms == ["public.zip-archive", "public.data"])
        #expect(BackupFileType.allowedTypes.first?.identifier == BackupFileType.identifier)
    }

    /// Files of the first release keep opening: their type is declared as imported, and the panels accept it.
    @Test func theOldBackupTypeIsStillDeclaredAsImported() throws {
        let imported = Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]]
        let entry = try #require(imported?.first { $0["UTTypeIdentifier"] as? String == BackupFileType.legacyIdentifier })
        #expect(entry["UTTypeConformsTo"] as? [String] == ["public.zip-archive", "public.data"])
        let tags = entry["UTTypeTagSpecification"] as? [String: Any]
        #expect(tags?["public.filename-extension"] as? [String] == [BackupFileType.legacyFileExtension])
        let exported = Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        #expect(exported?.contains { $0["UTTypeIdentifier"] as? String == BackupFileType.legacyIdentifier } == false)
        let allowed = BackupFileType.allowedTypes.map(\.identifier)
        #expect(allowed.contains(BackupFileType.legacyIdentifier))
        #expect(BackupFileType.fileExtension == "theonotes-backup")
    }

    @Test func theConfirmationQuestionUsesTheExactWording() {
        let confirmation = BackupModel.ReplaceConfirmation(currentCount: 12, backupCount: 5)
        #expect(confirmation.title == "Replace all notes?")
        #expect(confirmation.message == "All 12 notes in this library, including the Trash, will be deleted and replaced with the 5 notes in the backup. A safety backup of your current notes is saved to the Backups folder first.")
    }
}

/// A panel that stays up until the test answers.
@MainActor
final class PanelGate {
    private var continuation: CheckedContinuation<URL?, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async -> URL? {
        await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ url: URL?) {
        continuation?.resume(returning: url)
        continuation = nil
    }
}
