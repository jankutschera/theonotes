// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import TheoNotes

/// FIX-R1 … FIX-R6: files the Finder opens (Open With, Dock drop, `open -a`) become new notes.
@MainActor
@Suite struct OpenFilesHandlerTests {
    /// A library in a temp folder, a folder of files to open, and what the handler showed and reported.
    @MainActor
    final class Rig {
        let root: URL
        let files: URL
        let environment: AppEnvironment
        var shown: [String] = []
        var reports: [ImportSummary] = []
        var imported = 0
        var locked = { false }
        var busy = { false }

        init(environment: AppEnvironment? = nil, root: URL? = nil) throws {
            self.root = root ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("theo-openfiles-\(UUID().uuidString)", isDirectory: true)
            files = self.root.appendingPathComponent("incoming", isDirectory: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            self.environment = try environment ?? AppEnvironment(paths: AppPaths(root: self.root.appendingPathComponent("library")))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ name: String, _ text: String) throws -> URL {
            let url = files.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func target(service: (any ImportService)? = nil) -> OpenFilesHandler.Target {
            OpenFilesHandler.Target(
                service: service ?? LiveImportService(store: environment.store, paths: environment.paths),
                isLocked: { [unowned self] in self.locked() },
                isBusy: { [unowned self] in self.busy() || self.environment.operations.isBusy },
                beginOperation: { [unowned self] in self.environment.operations.begin() },
                endOperation: { [unowned self] in self.environment.operations.end() },
                prepare: {},
                didImport: { [unowned self] in self.imported += 1 },
                show: { [unowned self] in
                    self.shown.append($0)
                    return true
                },
                report: { [unowned self] in self.reports.append($0) })
        }

        var notes: [Note] { get throws { try environment.store.allNotes() } }
    }

    private func settle(_ handler: OpenFilesHandler) async {
        while let task = handler.runTask { await task.value }
    }

    // MARK: - Opening

    @Test func oneMarkdownFileBecomesOneNewNoteWithItsText() async throws {
        let rig = try Rig()
        let url = try rig.file("Groceries.md", "# Groceries\n\nmilk and #shopping eggs\n")
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive([url])
        await settle(handler)

        let notes = try rig.notes
        #expect(notes.count == 1)
        let id = try #require(notes.first?.id)
        let text = try rig.environment.store.note(id: id)?.text
        #expect(text?.contains("milk and #shopping eggs") == true)
        #expect(rig.shown == [id], "the imported note is shown")
        #expect(rig.reports.isEmpty, "a clean import says nothing")
        #expect(rig.imported == 1)
        #expect(FileManager.default.fileExists(atPath: url.path), "the file itself is left alone")
    }

    @Test func severalFilesAreAllImportedAndTheLastOneIsShown() async throws {
        let rig = try Rig()
        let urls = try ["One.md", "Two.txt", "Three.markdown"].map { try rig.file($0, "# \($0)\n\nbody of \($0)") }
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive(urls)
        await settle(handler)

        #expect(try rig.notes.count == 3)
        let shown = try #require(rig.shown.last)
        #expect(rig.shown.count == 1)
        #expect(try rig.environment.store.note(id: shown)?.text.contains("body of Three.markdown") == true)
    }

    @Test func aFileThatArrivesFirstWaitsForTheLibraryAndIsImportedAfterwards() async throws {
        let rig = try Rig()
        let url = try rig.file("Cold.md", "cold launch text")
        let handler = OpenFilesHandler()

        handler.receive([url])
        #expect(handler.pending == [url])
        #expect(try rig.notes.isEmpty, "nothing can be imported before the library is open")

        handler.target = rig.target()
        await settle(handler)

        #expect(try rig.notes.count == 1)
        #expect(handler.pending.isEmpty)
        #expect(rig.shown.count == 1)
    }

    @Test func filesThatArriveWhileARunIsGoingAreImportedAfterIt() async throws {
        let rig = try Rig()
        let first = try rig.file("First.md", "first")
        let second = try rig.file("Second.md", "second")
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive([first])
        handler.receive([second])
        await settle(handler)

        #expect(try rig.notes.count == 2)
        #expect(handler.pending.isEmpty)
    }

    @Test func anythingButAFileURLIsIgnored() async throws {
        let rig = try Rig()
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive([URL(string: "https://example.com/a.md")!])

        #expect(handler.pending.isEmpty)
        #expect(!handler.isRunning)
    }

    // MARK: - Errors

    @Test func anUnsupportedFileMakesNoNoteAndIsReported() async throws {
        let rig = try Rig()
        let url = rig.files.appendingPathComponent("picture.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive([url])
        await settle(handler)

        #expect(try rig.notes.isEmpty)
        #expect(rig.shown.isEmpty)
        let summary = try #require(rig.reports.first)
        #expect(summary.warnings.contains { $0.contains("unsupported file type") })
        #expect(summary.headline == "1 skipped, 1 warning.")
    }

    @Test func aFileThatCannotBeReadIsReportedAndTheRestStillImports() async throws {
        let rig = try Rig()
        let missing = rig.files.appendingPathComponent("gone.md")
        let good = try rig.file("Good.md", "still here")
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive([missing, good])
        await settle(handler)

        #expect(try rig.notes.count == 1, "one broken file never stops the others")
        let summary = try #require(rig.reports.first)
        #expect(!summary.errors.isEmpty || summary.headline != "Nothing was imported.")
        #expect(rig.shown.count == 1)
    }

    @Test func aServiceThatThrowsIsReportedNotCrashed() async throws {
        struct DiskFull: Error, CustomStringConvertible { var description: String { "disk is full" } }
        struct Broken: ImportService {
            func bearPreview(executable: URL) throws -> BearLibraryPreview { BearLibraryPreview(total: 0, trashed: 0) }
            func pullFromBear(
                executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
            ) throws -> BearImportReport { BearImportReport(total: 0) }
            func importFiles(
                _ urls: [URL], options: FileImportOptions,
                progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
            ) throws -> FileImportReport { throw DiskFull() }
            func appleNotesPreview() throws -> AppleNotesPreview { AppleNotesPreview(total: 0, accounts: 0) }
            func importFromAppleNotes(
                progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
            ) throws -> AppleNotesImportReport { AppleNotesImportReport(total: 0) }
        }
        let rig = try Rig()
        let handler = OpenFilesHandler()
        handler.target = rig.target(service: Broken())

        handler.receive([try rig.file("A.md", "a")])
        await settle(handler)

        let summary = try #require(rig.reports.first)
        #expect(summary.errors.first?.contains("disk is full") == true)
        #expect(rig.shown.isEmpty)
    }

    // MARK: - App Lock

    @Test func nothingIsImportedWhileLockedAndTheFilesWaitForTheUnlock() async throws {
        let root = URL(fileURLWithPath: "/tmp/theo-openlock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let authenticator = FakeAppAuthenticator()
        let environment = try AppEnvironment(
            paths: AppPaths(root: root.appendingPathComponent("library")), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: authenticator, appLockLifecycle: ManualLifecycleSource(), appIdleSeconds: { 0 })
        try await environment.vault.createPassword("correct horse")
        #expect(await environment.appLock.setEnabled(true) == .enabled)
        let rig = try Rig(environment: environment, root: root)
        let app = AppModel(environment: environment, defaults: UserDefaults(suiteName: "OpenLock-\(UUID().uuidString)")!)
        let handler = OpenFilesHandler()
        handler.attach(to: app)
        handler.target?.show = { [unowned rig] in
            rig.shown.append($0)
            return true
        }
        let url = try rig.file("Secret.md", "behind the lock")

        environment.appLock.lock()
        handler.receive([url])
        await settle(handler)

        #expect(try rig.notes.isEmpty, "never imported while locked")
        #expect(handler.pending == [url])
        #expect(rig.shown.isEmpty)

        authenticator.script(.success)
        #expect(await environment.appLock.unlock())
        await settle(handler)

        #expect(try rig.notes.count == 1, "the unlock runs what waited")
        #expect(handler.pending.isEmpty)
        #expect(rig.shown.count == 1)
    }

    @Test func aLockDuringARunKeepsTheFilesNotYetTriedForTheUnlock() async throws {
        let rig = try Rig()
        let service = GatedService()
        let handler = OpenFilesHandler()
        handler.target = rig.target(service: service)
        let urls = try ["A.md", "B.md", "C.md"].map { try rig.file($0, $0) }

        handler.receive(urls)
        while !service.entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        rig.locked = { true }
        handler.lockEngaged()
        service.gate.signal()
        await handler.runTask?.value

        #expect(service.seen.withLock { $0 } == ["A.md"], "no file starts after the lock")
        #expect(handler.pending.map(\.lastPathComponent) == ["B.md", "C.md"])
        #expect(rig.shown.isEmpty, "a locked app shows nothing")
    }

    @Test func theSameFileTwiceInOneBatchIsImportedOnce() async throws {
        let rig = try Rig()
        let url = try rig.file("Twice.md", "twice")
        let handler = OpenFilesHandler()
        handler.target = rig.target()

        handler.receive([url, url, rig.files.appendingPathComponent("./Twice.md")])
        await settle(handler)

        #expect(try rig.notes.count == 1)
    }

    @Test func theLibraryIsBusyForTheLengthOfARunSoNoBackupCanStartInTheMiddle() async throws {
        let rig = try Rig()
        let service = GatedService()
        let handler = OpenFilesHandler()
        handler.target = rig.target(service: service)
        #expect(!rig.environment.operations.isBusy)

        handler.receive([try rig.file("A.md", "a")])
        while !service.entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.environment.operations.isBusy, "a backup or restore must wait for the import")

        service.gate.signal()
        await settle(handler)
        #expect(!rig.environment.operations.isBusy, "released when the run ends")
    }

    @Test func theAppDelegateForwardsOpenedFilesToTheHandler() throws {
        let delegate = AppDelegate()
        let url = URL(fileURLWithPath: "/tmp/theo-forward-probe.md")

        delegate.application(NSApplication.shared, open: [url])

        #expect(delegate.openFiles.pending == [url], "no library in a test run, so the file waits")
    }

    // MARK: - A backup or restore is running

    @Test func aRunningBackupHoldsTheFilesUntilItEnds() async throws {
        let rig = try Rig()
        let busy = Mutex(true)
        rig.busy = { busy.withLock { $0 } }
        let handler = OpenFilesHandler()
        handler.busyRetryInterval = .milliseconds(10)
        handler.target = rig.target()

        handler.receive([try rig.file("Wait.md", "wait")])
        try await Task.sleep(for: .milliseconds(60))
        #expect(try rig.notes.isEmpty)

        busy.withLock { $0 = false }
        while handler.pending.count > 0 || handler.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        await settle(handler)
        #expect(try rig.notes.count == 1)
    }

    // MARK: - What the app declares

    @Test func theAppDeclaresMarkdownAndPlainTextAsAlternateViewerTypes() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let declared = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        #expect(declared == ["net.daringfireball.markdown", "public.plain-text"])
        for type in types {
            #expect(type["LSHandlerRank"] as? String == "Alternate", "never the user's default app")
            #expect(type["CFBundleTypeRole"] as? String == "Viewer")
        }
    }

    @Test func theDeclaredTypesCoverTheExtensionsTheFinderOffers() {
        for ext in ["md", "markdown", "txt"] {
            let type = UTType(filenameExtension: ext)
            let covered = ["net.daringfireball.markdown", "public.plain-text"].contains { type?.conforms(to: UTType($0)!) == true }
            #expect(covered, ".\(ext) is covered by a declared type")
        }
    }
}

/// Waits in `importFiles` until `gate` is signalled.
private final class GatedService: ImportService, @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    let entered = Mutex(false)
    let seen = Mutex<[String]>([])
    func bearPreview(executable: URL) throws -> BearLibraryPreview { BearLibraryPreview(total: 0, trashed: 0) }
    func pullFromBear(
        executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> BearImportReport { BearImportReport(total: 0) }
    func importFiles(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport {
        seen.withLock { $0 += urls.map(\.lastPathComponent) }
        entered.withLock { $0 = true }
        gate.wait()
        return FileImportReport(created: 1, createdNoteIds: ["id-\(urls[0].lastPathComponent)"])
    }
    func appleNotesPreview() throws -> AppleNotesPreview { AppleNotesPreview(total: 0, accounts: 0) }
    func importFromAppleNotes(
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AppleNotesImportReport { AppleNotesImportReport(total: 0) }
}
