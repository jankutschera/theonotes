// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import TheoNotes

/// Importer double: `total` notes, one `created` per step. With `gated`, each note waits for
/// `step()`, so tests can cancel mid-run.
final class FakeImportService: ImportService, @unchecked Sendable {
    let total: Int
    let gated: Bool
    var failure: (any Error)?
    var previewResult: Result<BearLibraryPreview, BearCLIError> = .success(BearLibraryPreview(total: 233, trashed: 90))
    var errors: [String] = []
    var warnings: [String] = []
    let calls = Mutex<[String]>([])
    let executables = Mutex<[String]>([])
    private let gate = DispatchSemaphore(value: 0)

    init(total: Int = 3, gated: Bool = false) {
        self.total = total
        self.gated = gated
    }

    func step(_ count: Int = 1) { (0..<count).forEach { _ in gate.signal() } }

    /// Called with the requested bearcli path instead of `previewResult` when set.
    var previewHandler: (@Sendable (String) throws -> BearLibraryPreview)?

    func bearPreview(executable: URL) throws -> BearLibraryPreview {
        calls.withLock { $0.append("preview") }
        if let previewHandler { return try previewHandler(executable.path) }
        return try previewResult.get()
    }

    func pullFromBear(
        executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> BearImportReport {
        calls.withLock { $0.append("pull") }
        executables.withLock { $0.append(executable.path) }
        #expect(!Thread.isMainThread)
        if let failure { throw failure }
        var report = BearImportReport(total: total)
        progress(0, total)
        for index in 0..<total {
            if gated { gate.wait() }
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            report.created += 1
            progress(index + 1, total)
        }
        report.errors = errors
        report.warnings = warnings
        return report
    }

    func importFiles(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport {
        calls.withLock {
            $0.append("files \(urls.count) keepDates=\(options.keepDates) title=\(options.titleFromFilename)"
                + " firstLine=\(options.titleFromFirstLine) hashes=\(options.keepHashNumbersAsText)")
        }
        progress(0, urls.count)
        progress(urls.count, urls.count)
        return FileImportReport(created: urls.count, skipped: 1, attachmentsCopied: 2, warnings: warnings, errors: errors)
    }

    var appleNotesPreviewResult: Result<AppleNotesPreview, AppleNotesError> =
        .success(AppleNotesPreview(total: 13, accounts: 1, folders: [.init(path: "Notes", count: 13)]))

    func appleNotesPreview() throws -> AppleNotesPreview {
        calls.withLock { $0.append("notes preview") }
        return try appleNotesPreviewResult.get()
    }

    func importFromAppleNotes(
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AppleNotesImportReport {
        calls.withLock { $0.append("notes import") }
        #expect(!Thread.isMainThread)
        if let failure { throw failure }
        var report = AppleNotesImportReport(total: total)
        progress(0, total)
        for index in 0..<total {
            if gated { gate.wait() }
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            report.created += 1
            progress(index + 1, total)
        }
        report.errors = errors
        report.warnings = warnings
        return report
    }
}

@MainActor
@Suite struct ImportModelTests {
    final class Recorder {
        var events: [String] = []
    }

    private func makeModel(_ service: FakeImportService, path: String = "/x/bearcli", recorder: Recorder = Recorder()) -> ImportModel {
        ImportModel(
            service: service, bearCLIPath: { path },
            prepare: { recorder.events.append("flush") }, didImport: { recorder.events.append("refresh") })
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 3 s")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func summary(_ model: ImportModel) -> ImportSummary? {
        if case .finished(let summary) = model.phase { return summary }
        return nil
    }

    @Test func testPullFlushesRunsOffMainAndRefreshes() async {
        let service = FakeImportService(total: 3)
        let recorder = Recorder()
        let model = makeModel(service, path: "/Custom/bearcli", recorder: recorder)

        model.pullFromBear()
        #expect(model.isRunning)
        #expect(model.showsPullProgress)
        #expect(recorder.events == ["flush"])
        await waitUntil("finished") { summary(model) != nil }

        #expect(summary(model)?.rows.first == ImportSummary.Row(label: "Created", count: 3))
        #expect(recorder.events == ["flush", "refresh"])
        #expect(service.executables.withLock { $0 } == ["/Custom/bearcli"])
        #expect(model.pullAlert?.headline == "3 created.")
        #expect(!model.showsPullProgress)
    }

    @Test func testProgressIsDeterminate() async {
        let service = FakeImportService(total: 3, gated: true)
        let model = makeModel(service)
        model.sheet = .bear
        model.startBearImport()

        await waitUntil("total known") { model.phase == .running(done: 0, total: 3, cancelling: false) }
        service.step()
        await waitUntil("one done") { model.phase == .running(done: 1, total: 3, cancelling: false) }
        service.step(2)
        await waitUntil("finished") { summary(model) != nil }
        #expect(summary(model)?.title == "Import from Bear finished")
        #expect(model.pullAlert == nil, "the sheet shows the report, no alert")
    }

    @Test func testCancelStopsBetweenNotes() async {
        let service = FakeImportService(total: 5, gated: true)
        let model = makeModel(service)
        model.startBearImport()
        service.step()
        await waitUntil("one done") { model.phase == .running(done: 1, total: 5, cancelling: false) }

        model.cancel()
        #expect(model.phase == .running(done: 1, total: 5, cancelling: true))
        service.step()
        await waitUntil("finished") { summary(model) != nil }

        let result = summary(model)
        #expect(result?.wasCancelled == true)
        #expect(result?.title == "Import from Bear cancelled")
        #expect(result?.rows.first?.count == 1)
    }

    @Test func testSecondRunWhileRunningIsIgnored() async {
        let service = FakeImportService(total: 1, gated: true)
        let model = makeModel(service)
        model.pullFromBear()
        model.pullFromBear()
        model.startBearImport()
        model.showFileImport([URL(fileURLWithPath: "/tmp/a.md")])
        #expect(model.sheet == nil)
        service.step()
        await waitUntil("finished") { summary(model) != nil }
        #expect(service.calls.withLock { $0 } == ["pull"])
    }

    @Test func testFailureToStartIsReported() async {
        let service = FakeImportService()
        service.failure = BearCLIError.notInstalled
        let recorder = Recorder()
        let model = makeModel(service, recorder: recorder)

        model.pullFromBear()
        await waitUntil("failed") { model.phase == .failed("bearcli is not installed or not executable") }
        #expect(model.pullAlert?.title == "Pull from Bear failed")
        #expect(model.pullAlert?.headline == "bearcli is not installed or not executable")
        #expect(recorder.events == ["flush", "refresh"])
    }

    @Test func testBearSheetLoadsPreview() async {
        let service = FakeImportService()
        let model = makeModel(service)
        model.showBearImport()
        #expect(model.sheet == .bear)
        #expect(model.bearCLIDisplayPath == "/x/bearcli")
        await waitUntil("preview") { model.preview != .loading }
        #expect(model.preview == .loaded(BearLibraryPreview(total: 233, trashed: 90)))
        #expect(BearLibraryPreview(total: 233, trashed: 90).text == "233 notes incl. 90 in trash")
        #expect(BearLibraryPreview(total: 1, trashed: 0).text == "1 note")

        service.previewResult = .failure(.notInstalled)
        model.loadPreview()
        await waitUntil("preview failed") { model.preview != .loading }
        #expect(model.preview == .failed("bearcli is not installed or not executable"))
    }

    @Test func testDismissResetsButNotWhileRunning() async {
        let service = FakeImportService(total: 1, gated: true)
        let model = makeModel(service)
        model.showBearImport()
        model.startBearImport()
        model.dismissSheet()
        #expect(model.sheet == .bear)
        service.step()
        await waitUntil("finished") { summary(model) != nil }
        model.dismissSheet()
        #expect(model.sheet == nil)
        #expect(model.phase == .idle)
    }

    @Test func testQuietPullAlertsOnlyWithNews() async {
        let unchanged = FakeImportService(total: 0)
        let quiet = makeModel(unchanged)
        quiet.pullFromBear(quiet: true)
        await waitUntil("finished") { summary(quiet) != nil }
        #expect(quiet.pullAlert == nil)

        let changed = FakeImportService(total: 2)
        let loud = makeModel(changed)
        loud.pullFromBear(quiet: true)
        await waitUntil("finished") { summary(loud) != nil }
        #expect(loud.pullAlert?.headline == "2 created.")
    }

    @Test func testPullDetailsOpenTheReport() async {
        let service = FakeImportService(total: 1)
        service.errors = ["B1: bearcli exited with code 1"]
        let model = makeModel(service)
        model.pullFromBear()
        await waitUntil("finished") { summary(model) != nil }
        model.showPullDetails()
        #expect(model.pullAlert == nil)
        #expect(model.sheet == .bear)
        #expect(summary(model)?.errors == ["B1: bearcli exited with code 1"])
    }

    @Test func testFileImportUsesOptions() async {
        let service = FakeImportService()
        let model = makeModel(service)
        let urls = [URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.textbundle")]
        model.showFileImport(urls)
        #expect(model.sheet == .files(urls))
        model.fileOptions.titleFromFilename = true
        model.fileOptions.keepHashNumbersAsText = true
        model.startFileImport()
        await waitUntil("finished") { summary(model) != nil }
        #expect(service.calls.withLock { $0 } == ["files 2 keepDates=true title=true firstLine=false hashes=true"])
        #expect(summary(model)?.rows.map(\.count) == [2, 1, 2])
        #expect(summary(model)?.headline == "2 created, 1 skipped.")
    }

    @Test func testStalePreviewDoesNotOverwriteANewerOne() async {
        // Each request is told apart by its bearcli path (detached tasks may start in any order)
        // and gated, not timed: a slow machine can only make this pass falsely, never fail falsely.
        let service = FakeImportService()
        let older = DispatchSemaphore(value: 0), newer = DispatchSemaphore(value: 0)
        let olderReturned = Mutex(false)
        service.previewHandler = { path in
            if path == "/old/bearcli" {
                older.wait()
                olderReturned.withLock { $0 = true }
                return BearLibraryPreview(total: 1, trashed: 0)
            }
            newer.wait()
            return BearLibraryPreview(total: 2, trashed: 0)
        }
        final class Path { var value = "/old/bearcli" }
        let path = Path()
        let model = ImportModel(service: service, bearCLIPath: { path.value }, prepare: {}, didImport: {})
        model.showBearImport()
        path.value = "/new/bearcli"
        model.loadPreview()
        older.signal()
        await waitUntil("older preview returned") { olderReturned.withLock { $0 } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.preview == .loading, "the older (stale) preview must not land")
        newer.signal()
        await waitUntil("newer preview") { model.preview != .loading }
        #expect(model.preview == .loaded(BearLibraryPreview(total: 2, trashed: 0)))
    }

    @Test func testOpenPanelAcceptsTextBundlePackages() throws {
        let types = ImportPanel.allowedTypes
        let bundle = try #require(UTType("org.textbundle.package"))
        #expect(bundle.conforms(to: .package))
        #expect(types.contains { bundle.conforms(to: $0) })
        for ext in [
            "md", "markdown", "txt", "textpack", "bear2bk", "zip", "textbundle", "html", "htm", "rtf", "rtfd",
            "bear", "bearnote", "panda",
        ] {
            let packages: Set = ["textbundle", "rtfd"]
            let type = try #require(UTType(filenameExtension: ext, conformingTo: packages.contains(ext) ? .package : .data))
            #expect(types.contains { type.conforms(to: $0) }, "\(ext)")
        }
        #expect(types.contains(.folder))
    }

    // MARK: - Apple Notes

    @Test func testAppleNotesSheetLoadsPreviewAndImports() async {
        let service = FakeImportService(total: 3, gated: true)
        let recorder = Recorder()
        let model = makeModel(service, recorder: recorder)
        model.showAppleNotesImport()
        #expect(model.sheet == .appleNotes)
        await waitUntil("preview") { model.appleNotesPreview != .loading }
        #expect(model.appleNotesPreview == .loaded(AppleNotesPreview(total: 13, accounts: 1, folders: [.init(path: "Notes", count: 13)])))

        model.startAppleNotesImport()
        #expect(recorder.events == ["flush"])
        await waitUntil("total known") { model.phase == .running(done: 0, total: 3, cancelling: false) }
        service.step(3)
        await waitUntil("finished") { summary(model) != nil }
        #expect(summary(model)?.title == "Import from Apple Notes finished")
        #expect(summary(model)?.headline == "3 created.")
        #expect(recorder.events == ["flush", "refresh"])
        #expect(model.pullAlert == nil)
        #expect(service.calls.withLock { $0 } == ["notes preview", "notes import"])
        model.dismissSheet()
        #expect(model.appleNotesPreview == .idle)
    }

    @Test func testAppleNotesPermissionDeniedIsShown() async {
        let service = FakeImportService()
        service.appleNotesPreviewResult = .failure(.notAuthorized)
        let model = makeModel(service)
        model.showAppleNotesImport()
        await waitUntil("preview failed") { model.appleNotesPreview != .loading }
        #expect(model.appleNotesPreview == .failed(AppleNotesError.notAuthorized.description))
    }

    @Test func testAppleNotesCancel() async {
        let service = FakeImportService(total: 4, gated: true)
        let model = makeModel(service)
        model.showAppleNotesImport()
        model.startAppleNotesImport()
        service.step()
        await waitUntil("one done") { model.phase == .running(done: 1, total: 4, cancelling: false) }
        model.cancel()
        service.step()
        await waitUntil("finished") { summary(model) != nil }
        #expect(summary(model)?.title == "Import from Apple Notes cancelled")
        #expect(summary(model)?.rows.first?.count == 1)
    }

    @Test func testAppleNotesSummaryRowsAndHeadline() {
        let report = AppleNotesImportReport(
            total: 20, created: 2, updated: 1, unchanged: 12, conflicts: 1, passwordProtected: 2, recentlyDeleted: 2,
            imagesCopied: 6, missingInNotes: 1, deletedInTheoNotes: 1, errors: ["“A”: x"], warnings: ["“B”: y"])
        let summary = ImportSummary(appleNotes: report)
        #expect(summary.rows.map(\.count) == [2, 1, 12, 1, 2, 2, 1, 1, 6])
        #expect(summary.headline
            == "2 created, 1 updated, 12 unchanged, 1 conflict copy, 2 locked notes skipped, 1 error, 1 warning.")
        #expect(ImportSummary(appleNotes: AppleNotesImportReport()).headline == "Apple Notes has no notes.")
    }

    @Test func testAppleNotesPreviewCountsFolders() {
        let listing = AppleNotesListing(
            accounts: [AppleNotesAccount(id: "a", name: "iCloud", defaultFolderID: "n"),
                       AppleNotesAccount(id: "b", name: "Gmail", defaultFolderID: "m")],
            folders: [AppleNotesFolder(id: "n", name: "Notes", accountID: "a"),
                      AppleNotesFolder(id: "w", name: "Work", accountID: "a"),
                      AppleNotesFolder(id: "s", name: "Sub", accountID: "a", parentID: "w"),
                      AppleNotesFolder(id: "d", name: "Recently Deleted", accountID: "a"),
                      AppleNotesFolder(id: "m", name: "Notes", accountID: "b")],
            notes: [
                AppleNotesRecord(id: "1", name: "", created: .now, modified: .now, accountID: "a", folderID: "n"),
                AppleNotesRecord(id: "2", name: "", created: .now, modified: .now, accountID: "a", folderID: "s"),
                AppleNotesRecord(id: "3", name: "", created: .now, modified: .now, accountID: "a", folderID: "s",
                                 isPasswordProtected: true),
                AppleNotesRecord(id: "4", name: "", created: .now, modified: .now, accountID: "a", folderID: "d"),
            ])
        let preview = AppleNotesPreview(listing: listing)
        #expect(preview.total == 3)
        #expect(preview.accounts == 1)
        #expect(preview.recentlyDeleted == 1)
        #expect(preview.folders == [.init(path: "Notes", count: 1), .init(path: "Work / Sub", count: 2)])
        #expect(preview.text == "3 notes in 2 folders, 1 locked (skipped)")
    }

    // MARK: - Report formatting

    @Test func testHasNewsCountsChangesErrorsAndCancel() {
        #expect(!ImportSummary(bear: BearImportReport(total: 5, unchanged: 5, warnings: ["B1: pin"]), kind: .bearPull).hasNews)
        #expect(ImportSummary(bear: BearImportReport(total: 5, unchanged: 4, conflicts: 1), kind: .bearPull).hasNews)
        #expect(ImportSummary(bear: BearImportReport(total: 5, updated: 1, unchanged: 4), kind: .bearPull).hasNews)
        #expect(ImportSummary(bear: BearImportReport(total: 5, unchanged: 5, errors: ["B2: x"]), kind: .bearPull).hasNews)
        #expect(ImportSummary(bear: BearImportReport(total: 5, wasCancelled: true), kind: .bearPull).hasNews)
        #expect(!ImportSummary(bear: BearImportReport(total: 5, lockedStubs: 0, missingInBear: 3, deletedInTheoNotes: 2),
                               kind: .bearPull).hasNews)
    }

    @Test func testBearSummaryRowsAndHeadline() {
        let report = BearImportReport(
            total: 233, created: 3, updated: 1, unchanged: 227, conflicts: 2, lockedStubs: 1, attachmentsCopied: 9,
            missingInBear: 4, deletedInTheoNotes: 5, errors: ["B9: invalid attachment filename 'x'"], warnings: ["B2: pin", "B3: pin"])
        let summary = ImportSummary(bear: report, kind: .bearPull)
        #expect(summary.title == "Pull from Bear finished")
        #expect(summary.rows.map(\.label) == [
            "Created", "Updated", "Unchanged", "Conflicts", "Locked stubs", "Deleted in Theo Notes", "Missing in Bear",
            "Attachments copied",
        ])
        #expect(summary.rows.map(\.count) == [3, 1, 227, 2, 1, 5, 4, 9])
        #expect(summary.headline
            == "3 created, 1 updated, 227 unchanged, 2 conflict copies, 1 locked stub, 1 error, 2 warnings.")
        #expect(summary.errors == ["B9: invalid attachment filename 'x'"])
        #expect(summary.hasNews)
    }

    @Test func testUnchangedPullHeadline() {
        let summary = ImportSummary(bear: BearImportReport(total: 233, unchanged: 233), kind: .bearPull)
        #expect(summary.headline == "233 unchanged.")
        #expect(!summary.hasNews)
        #expect(ImportSummary(bear: BearImportReport(), kind: .bearImport).headline == "Bear has no notes.")
        #expect(ImportSummary(files: FileImportReport()).headline == "Nothing was imported.")
    }
}
