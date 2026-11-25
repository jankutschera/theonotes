// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Synchronization
import Testing
@testable import TheoNotes

/// Import task 3 fix round 1: App Lock closes the import sheet, stops a run and keeps new
/// imports from starting (the menu is not the only gate: a sheet can outlive the menu check).
@MainActor
@Suite struct ImportAppLockTests {
    /// Each note waits for `step()`; the run reads `isCancelled` between notes.
    final class GatedFileService: ImportService, @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        let created = Mutex(0)
        let started = Mutex(false)

        func step(_ count: Int = 1) { (0..<count).forEach { _ in gate.signal() } }

        func bearPreview(executable: URL) throws -> BearLibraryPreview { BearLibraryPreview(total: 0, trashed: 0) }
        func pullFromBear(
            executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> BearImportReport { BearImportReport(total: 0) }
        func appleNotesPreview() throws -> AppleNotesPreview { AppleNotesPreview(total: 0, accounts: 0) }
        func importFromAppleNotes(
            progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> AppleNotesImportReport { AppleNotesImportReport(total: 0) }

        func importFiles(
            _ urls: [URL], options: FileImportOptions,
            progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> FileImportReport {
            started.withLock { $0 = true }
            var report = FileImportReport()
            progress(0, 5)
            for index in 0..<5 {
                gate.wait()
                if isCancelled() {
                    report.wasCancelled = true
                    break
                }
                created.withLock { $0 += 1 }
                report.created += 1
                progress(index + 1, 5)
            }
            return report
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 5 s")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The model

    @Test func lockingDuringARunStopsItBetweenNotesAndShowsNothing() async {
        let service = GatedFileService()
        var refreshed = 0
        let model = ImportModel(
            service: service, bearCLIPath: { "/x/bearcli" }, prepare: {}, didImport: { refreshed += 1 })
        model.showFileImport([URL(fileURLWithPath: "/tmp/anything")])
        model.startFileImport()
        await waitUntil("running") { model.isRunning && service.started.withLock { $0 } }
        service.step(2)
        await waitUntil("two notes") { service.created.withLock { $0 } == 2 }

        model.appLockEngaged()
        #expect(model.sheet == nil, "the sheet closes at once")
        service.step(3)
        await model.runTask?.value

        #expect(service.created.withLock { $0 } == 2, "the run stopped before the third note")
        #expect(model.phase == .idle, "no report of a locked run is kept")
        #expect(model.sheet == nil)
        #expect(refreshed == 1, "the library still refreshes for the notes that arrived")
    }

    @Test func lockingClosesAnOpenSheetAndForgetsItsReport() {
        let model = ImportModel(
            service: GatedFileService(), bearCLIPath: { "/x/bearcli" }, prepare: {}, didImport: {})
        model.showFileImport([URL(fileURLWithPath: "/tmp/anything")])
        #expect(model.sheet != nil)

        model.appLockEngaged()

        #expect(model.sheet == nil)
        #expect(model.phase == .idle)
    }

    @Test func aSheetThatSurvivedTheLockCannotStartAnImport() {
        let service = GatedFileService()
        let locked = Mutex(false)
        let model = ImportModel(service: service, bearCLIPath: { "/x/bearcli" }, prepare: {}, didImport: {})
        model.isBlocked = { locked.withLock { $0 } }
        model.showFileImport([URL(fileURLWithPath: "/tmp/anything")])
        locked.withLock { $0 = true }

        model.startFileImport()

        #expect(!model.isRunning)
        #expect(!service.started.withLock { $0 })
        model.dismissSheet()
        model.showFileImport([URL(fileURLWithPath: "/tmp/anything")])
        #expect(model.sheet == nil, "no new sheet while locked")
    }

    // MARK: - The window state wiring

    private func lockedEnvironment() async throws -> (AppEnvironment, URL, FakeAppAuthenticator) {
        let root = URL(fileURLWithPath: "/tmp/theo-importlock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let authenticator = FakeAppAuthenticator()
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: authenticator, appLockLifecycle: ManualLifecycleSource(), appIdleSeconds: { 0 })
        try await environment.vault.createPassword("correct horse")
        #expect(await environment.appLock.setEnabled(true) == .enabled)
        return (environment, root, authenticator)
    }

    @Test func theWindowsImporterIsBlockedAndClosedWhenTheAppLocks() async throws {
        let (environment, root, authenticator) = try await lockedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let drop = root.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        try "Plain text".write(to: drop.appendingPathComponent("Groceries.md"), atomically: true, encoding: .utf8)
        let state = MainWindowState(
            environment: environment, defaults: UserDefaults(suiteName: "ImportLock-\(UUID().uuidString)")!)
        #expect(!state.importer.isBlocked())
        state.importer.showFileImport([drop])
        #expect(state.importer.sheet != nil, "the panel returned, the options sheet is up")

        environment.appLock.lock()

        #expect(state.importer.isBlocked())
        #expect(state.importer.sheet == nil, "locking closes the sheet")
        state.importer.startFileImport()
        #expect(!state.importer.isRunning)
        #expect(state.importer.phase == .idle)
        #expect(try environment.store.allNotes().isEmpty, "nothing was imported")
        state.importer.showFileImport([drop])
        #expect(state.importer.sheet == nil)

        authenticator.script(.success)
        #expect(await environment.appLock.unlock())
        #expect(!state.importer.isBlocked())
        state.importer.showFileImport([drop])
        #expect(state.importer.sheet != nil, "after the unlock the import works again")
        state.close()
    }

    @Test func aClosedWindowNoLongerListensForTheLock() async throws {
        let (environment, root, _) = try await lockedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = MainWindowState(
            environment: environment, defaults: UserDefaults(suiteName: "ImportLock-\(UUID().uuidString)")!)
        state.importer.showFileImport([root])
        state.close()

        environment.appLock.lock()

        #expect(state.importer.sheet != nil, "the closed window's importer was left alone")
    }
}
