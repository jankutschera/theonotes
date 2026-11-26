// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Observation
import Synchronization

/// How many notes Bear has, read without reading any note (`bearcli list --count`).
struct BearLibraryPreview: Equatable, Sendable {
    var total: Int
    var trashed: Int

    var text: String {
        let notes = total == 1 ? "1 note" : "\(total) notes"
        return trashed == 0 ? notes : "\(notes) incl. \(trashed) in trash"
    }
}

/// What Apple Notes holds, read from the listing (no bodies): notes per folder.
struct AppleNotesPreview: Equatable, Sendable {
    struct Folder: Equatable, Sendable, Identifiable {
        /// `Account / Folder / Sub` (account only when several accounts have notes).
        var path: String
        var count: Int
        var id: String { path }
    }

    var total: Int
    var accounts: Int
    var passwordProtected: Int
    var recentlyDeleted: Int
    var folders: [Folder]

    init(total: Int, accounts: Int, passwordProtected: Int = 0, recentlyDeleted: Int = 0, folders: [Folder] = []) {
        self.total = total
        self.accounts = accounts
        self.passwordProtected = passwordProtected
        self.recentlyDeleted = recentlyDeleted
        self.folders = folders
    }

    /// Counts per folder; Recently Deleted is counted apart, the folder list skips it.
    init(listing: AppleNotesListing) {
        let live = listing.notes.filter { !listing.isRecentlyDeleted($0) }
        let accountIDs = Set(live.map(\.accountID))
        let names = Dictionary(listing.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for note in live {
            var components = listing.folderPath(note.folderID).map(\.name)
            if accountIDs.count > 1 { components.insert(names[note.accountID] ?? "?", at: 0) }
            counts[components.isEmpty ? "–" : components.joined(separator: " / "), default: 0] += 1
        }
        self.init(
            total: live.count, accounts: accountIDs.count,
            passwordProtected: live.filter(\.isPasswordProtected).count,
            recentlyDeleted: listing.notes.count - live.count,
            folders: counts.map { Folder(path: $0.key, count: $0.value) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    var text: String {
        var parts = [total == 1 ? "1 note" : "\(total) notes"]
        if folders.count > 1 { parts.append("in \(folders.count) folders") }
        if accounts > 1 { parts.append("from \(accounts) accounts") }
        var text = parts.joined(separator: " ")
        if passwordProtected > 0 { text += ", \(passwordProtected) locked (skipped)" }
        return text
    }
}

/// Runs the importers. Called off the main actor; `progress` and `isCancelled` may be called from
/// any thread.
protocol ImportService: Sendable {
    func bearPreview(executable: URL) throws -> BearLibraryPreview
    func pullFromBear(
        executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> BearImportReport
    func importFiles(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport
    /// File ▸ Import From ▸ Apple Notes Export…: the Markdown files Notes wrote, with attachments.
    func importAppleNotesExport(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport
    func appleNotesPreview() throws -> AppleNotesPreview
    func importFromAppleNotes(
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AppleNotesImportReport
}

extension ImportService {
    /// Services that only read files (tests) do not read Apple Notes exports.
    func importAppleNotesExport(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport {
        throw ImportFailure(message: "Apple Notes exports are not supported here")
    }
}

/// The app's importers on the environment's store (read-only `bearcli`, `FileImporter`).
struct LiveImportService: ImportService {
    let store: NoteStore
    let paths: AppPaths
    /// Notes' scripting interface (Apple Events; the first use asks for Automation permission).
    var appleNotes: any AppleNotesClient = ScriptingAppleNotesClient()

    func bearPreview(executable: URL) throws -> BearLibraryPreview {
        let cli = ProcessBearCLI(executable: executable)
        return BearLibraryPreview(total: try cli.noteCount(location: "all"), trashed: try cli.noteCount(location: "trash"))
    }

    func pullFromBear(
        executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> BearImportReport {
        try BearImporter(store: store, paths: paths, cli: ProcessBearCLI(executable: executable))
            .pull(progress: progress, isCancelled: isCancelled)
    }

    func importFiles(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport {
        try FileImporter(store: store, paths: paths).importItems(urls, options: options, progress: progress, isCancelled: isCancelled)
    }

    func importAppleNotesExport(
        _ urls: [URL], options: FileImportOptions,
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> FileImportReport {
        try AppleNotesExportImporter(store: store, paths: paths)
            .importItems(urls, options: options, progress: progress, isCancelled: isCancelled)
    }

    func appleNotesPreview() throws -> AppleNotesPreview {
        AppleNotesPreview(listing: try appleNotes.listing())
    }

    func importFromAppleNotes(
        progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AppleNotesImportReport {
        try AppleNotesImporter(store: store, paths: paths, client: appleNotes).pull(progress: progress, isCancelled: isCancelled)
    }
}

enum ImportKind: Equatable, Sendable {
    /// File ▸ Import From ▸ Bear… (sheet).
    case bearImport
    /// File ▸ Pull from Bear (progress HUD, then an alert).
    case bearPull
    /// File ▸ Import Notes… (sheet).
    case files
    /// File ▸ Import From ▸ Apple Notes… (sheet).
    case appleNotes
}

/// The result of a run as shown in the report and the alert. Counts and `"<id or path>: message"`
/// lines only, never note text.
struct ImportSummary: Equatable {
    struct Row: Equatable, Identifiable {
        var label: String
        var count: Int
        var id: String { label }
    }

    var title: String
    var rows: [Row]
    var warnings: [String]
    var errors: [String]
    var wasCancelled: Bool
    /// One line for the alert, e.g. "3 created, 230 unchanged, 1 error."
    var headline: String

    init(bear report: BearImportReport, kind: ImportKind) {
        let name = kind == .bearPull ? "Pull from Bear" : "Import from Bear"
        title = report.wasCancelled ? "\(name) cancelled" : "\(name) finished"
        rows = [
            Row(label: "Created", count: report.created),
            Row(label: "Updated", count: report.updated),
            Row(label: "Unchanged", count: report.unchanged),
            Row(label: "Conflicts", count: report.conflicts),
            Row(label: "Locked stubs", count: report.lockedStubs),
            Row(label: "Deleted in Theo Notes", count: report.deletedInTheoNotes),
            Row(label: "Missing in Bear", count: report.missingInBear),
            Row(label: "Attachments copied", count: report.attachmentsCopied),
        ]
        warnings = report.warnings
        errors = report.errors
        wasCancelled = report.wasCancelled
        changedCount = report.created + report.updated + report.conflicts
        headline = Self.headline(
            [("created", report.created), ("updated", report.updated), ("unchanged", report.unchanged),
             ("conflict copy", report.conflicts), ("locked stub", report.lockedStubs)],
            errors: report.errors.count, warnings: report.warnings.count, total: report.total)
    }

    init(appleNotes report: AppleNotesImportReport) {
        title = report.wasCancelled ? "Import from Apple Notes cancelled" : "Import from Apple Notes finished"
        rows = [
            Row(label: "Created", count: report.created),
            Row(label: "Updated", count: report.updated),
            Row(label: "Unchanged", count: report.unchanged),
            Row(label: "Conflicts", count: report.conflicts),
            Row(label: "Locked (skipped)", count: report.passwordProtected),
            Row(label: "Recently Deleted (skipped)", count: report.recentlyDeleted),
            Row(label: "Deleted in Theo Notes", count: report.deletedInTheoNotes),
            Row(label: "Missing in Notes", count: report.missingInNotes),
            Row(label: "Images copied", count: report.imagesCopied),
        ]
        warnings = report.warnings
        errors = report.errors
        wasCancelled = report.wasCancelled
        changedCount = report.created + report.updated + report.conflicts
        headline = Self.headline(
            [("created", report.created), ("updated", report.updated), ("unchanged", report.unchanged),
             ("conflict copy", report.conflicts), ("locked note skipped", report.passwordProtected)],
            errors: report.errors.count, warnings: report.warnings.count, total: report.total,
            emptyMessage: "Apple Notes has no notes.")
    }

    init(files report: FileImportReport) {
        title = report.wasCancelled ? "Import cancelled" : "Import finished"
        rows = [
            Row(label: "Created", count: report.created),
            Row(label: "Skipped", count: report.skipped),
            Row(label: "Attachments copied", count: report.attachmentsCopied),
        ]
        warnings = report.warnings
        errors = report.errors
        wasCancelled = report.wasCancelled
        changedCount = report.created
        headline = Self.headline([("created", report.created), ("skipped", report.skipped)],
                                 errors: report.errors.count, warnings: report.warnings.count, total: nil)
    }

    /// Whether a quiet run (Pull at launch) has something worth an alert: notes created,
    /// updated or conflicted, errors, or a cancel.
    var hasNews: Bool { changedCount > 0 || !errors.isEmpty || wasCancelled }

    /// Notes created, updated or turned into conflict copies.
    private(set) var changedCount = 0

    private static func headline(
        _ parts: [(String, Int)], errors: Int, warnings: Int, total: Int?, emptyMessage: String = "Bear has no notes."
    ) -> String {
        var items = parts.filter { $0.1 > 0 }.map { "\($0.1) \(plural($0.0, $0.1))" }
        if errors > 0 { items.append("\(errors) \(plural("error", errors))") }
        if warnings > 0 { items.append("\(warnings) \(plural("warning", warnings))") }
        guard !items.isEmpty else { return total == 0 ? emptyMessage : "Nothing was imported." }
        return items.joined(separator: ", ") + "."
    }

    private static func plural(_ word: String, _ count: Int) -> String {
        guard count != 1 else { return word }
        switch word {
        case "created", "updated", "unchanged", "skipped": return word
        case "conflict copy": return "conflict copies"
        case "locked note skipped": return "locked notes skipped"
        default: return word + "s"
        }
    }
}

enum ImportPhase: Equatable {
    case idle
    /// `total` is 0 until the importer knows how many notes there are.
    case running(done: Int, total: Int, cancelling: Bool)
    case finished(ImportSummary)
    /// The run could not start (e.g. bearcli missing); nothing was imported.
    case failed(String)
}

enum BearPreviewState: Equatable {
    case idle, loading
    case loaded(BearLibraryPreview)
    case failed(String)
}

enum AppleNotesPreviewState: Equatable {
    case idle, loading
    case loaded(AppleNotesPreview)
    case failed(String)
}

/// Which importer reads the items of a file import sheet.
enum FileImportMode: Equatable, Sendable {
    /// File ▸ Import Notes…: `FileImporter`.
    case files
    /// File ▸ Import From ▸ Apple Notes Export…: `AppleNotesExportImporter`.
    case appleNotesExport
}

enum ImportSheet: Identifiable, Equatable {
    case bear
    case files([URL])
    case appleNotes

    var id: String {
        switch self {
        case .bear: "bear"
        case .files: "files"
        case .appleNotes: "applenotes"
        }
    }
}

/// Import from Bear, Pull from Bear and Import Notes. One run at a time; it runs off the main
/// actor and reports progress here. Open editor sessions are flushed first; the library
/// refreshes as notes arrive (store notifications) and once more at the end.
@MainActor
@Observable
final class ImportModel {
    private(set) var kind: ImportKind?
    private(set) var phase: ImportPhase = .idle
    private(set) var preview: BearPreviewState = .idle
    private(set) var appleNotesPreview: AppleNotesPreviewState = .idle
    var sheet: ImportSheet?
    var fileOptions = FileImportOptions()
    /// Which importer the open file sheet runs; reset by every `showFileImport`.
    private(set) var fileImportMode: FileImportMode = .files
    /// The finished Pull from Bear summary, shown as an alert.
    var pullAlert: ImportSummary?

    @ObservationIgnored private let service: any ImportService
    @ObservationIgnored private let bearCLIPath: @MainActor () -> String
    @ObservationIgnored private let prepare: @MainActor () -> Void
    @ObservationIgnored private let didImport: @MainActor () -> Void
    /// A backup or restore runs in some window, or the app is locked (set by `MainWindowState`):
    /// nothing starts meanwhile.
    @ObservationIgnored var isBlocked: @MainActor () -> Bool = { false }
    @ObservationIgnored private var cancelFlag: CancelFlag?
    @ObservationIgnored private var quietPull = false
    /// The app lock engaged during the run: its result is not shown (it may name notes).
    @ObservationIgnored private var lockedDuringRun = false
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?
    @ObservationIgnored private(set) var previewTask: Task<Void, Never>?

    /// - Parameters:
    ///   - bearCLIPath: the bearcli path (Settings → Advanced), read when a run starts.
    ///   - prepare: runs before every import (flushes open sessions).
    ///   - didImport: runs after every import (refreshes the library).
    init(
        service: any ImportService, bearCLIPath: @escaping @MainActor () -> String,
        prepare: @escaping @MainActor () -> Void, didImport: @escaping @MainActor () -> Void
    ) {
        self.service = service
        self.bearCLIPath = bearCLIPath
        self.prepare = prepare
        self.didImport = didImport
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The pull HUD is up.
    var showsPullProgress: Bool { kind == .bearPull && isRunning }

    var bearCLIDisplayPath: String { bearCLIPath() }

    // MARK: - Bear

    /// File ▸ Import from Bear…: opens the sheet and counts Bear's notes.
    func showBearImport() {
        guard !isBlocked() else { return }
        guard !isRunning else {
            if kind != .bearPull { sheet = .bear }
            return
        }
        phase = .idle
        kind = nil
        sheet = .bear
        loadPreview()
    }

    func loadPreview() {
        previewTask?.cancel()
        preview = .loading
        let service = service, executable = URL(fileURLWithPath: bearCLIPath())
        previewTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<BearLibraryPreview, ImportFailure> in
                do { return .success(try service.bearPreview(executable: executable)) }
                catch { return .failure(ImportFailure(message: Self.describe(error))) }
            }.value
            guard let self, !Task.isCancelled, self.preview == .loading else { return }
            switch result {
            case .success(let preview): self.preview = .loaded(preview)
            case .failure(let failure): self.preview = .failed(failure.message)
            }
        }
    }

    func startBearImport() {
        startBear(.bearImport)
    }

    /// File ▸ Pull from Bear (⌥⇧⌘B). `quiet` (Pull at launch) skips the alert when nothing changed.
    func pullFromBear(quiet: Bool = false) {
        guard !isRunning else { return }
        quietPull = quiet
        startBear(.bearPull)
    }

    private func startBear(_ kind: ImportKind) {
        let service = service, executable = URL(fileURLWithPath: bearCLIPath())
        start(kind) { progress, isCancelled in
            ImportSummary(bear: try service.pullFromBear(executable: executable, progress: progress, isCancelled: isCancelled),
                          kind: kind)
        }
    }

    /// The pull alert's "Show Details": the report in the Bear sheet.
    func showPullDetails() {
        pullAlert = nil
        guard case .finished = phase else { return }
        sheet = .bear
    }

    // MARK: - Apple Notes

    /// File ▸ Import From ▸ Apple Notes…: opens the sheet and lists Notes (counts per folder).
    /// Listing is the first Apple Event, so this is where macOS asks for Automation permission.
    func showAppleNotesImport() {
        guard !isBlocked() else { return }
        guard !isRunning else {
            if kind == .appleNotes { sheet = .appleNotes }
            return
        }
        phase = .idle
        kind = nil
        sheet = .appleNotes
        loadAppleNotesPreview()
    }

    func loadAppleNotesPreview() {
        previewTask?.cancel()
        appleNotesPreview = .loading
        let service = service
        previewTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<AppleNotesPreview, ImportFailure> in
                do { return .success(try service.appleNotesPreview()) }
                catch { return .failure(ImportFailure(message: Self.describe(error))) }
            }.value
            guard let self, !Task.isCancelled, self.appleNotesPreview == .loading else { return }
            switch result {
            case .success(let preview): self.appleNotesPreview = .loaded(preview)
            case .failure(let failure): self.appleNotesPreview = .failed(failure.message)
            }
        }
    }

    func startAppleNotesImport() {
        let service = service
        start(.appleNotes) { progress, isCancelled in
            ImportSummary(appleNotes: try service.importFromAppleNotes(progress: progress, isCancelled: isCancelled))
        }
    }

    // MARK: - Files

    /// File ▸ Import Notes… after the open panel: the options sheet.
    func showFileImport(_ urls: [URL], mode: FileImportMode = .files) {
        guard !isRunning, !isBlocked(), !urls.isEmpty else { return }
        phase = .idle
        kind = nil
        fileImportMode = mode
        sheet = .files(urls)
    }

    func startFileImport() {
        guard case .files(let urls) = sheet else { return }
        let service = service, options = fileOptions, mode = fileImportMode
        start(.files) { progress, isCancelled in
            switch mode {
            case .files:
                return ImportSummary(
                    files: try service.importFiles(urls, options: options, progress: progress, isCancelled: isCancelled))
            case .appleNotesExport:
                var summary = ImportSummary(
                    files: try service.importAppleNotesExport(urls, options: options, progress: progress, isCancelled: isCancelled))
                summary.title = summary.wasCancelled
                    ? "Import from Apple Notes export cancelled" : "Import from Apple Notes export finished"
                return summary
            }
        }
    }

    // MARK: - Running

    /// Stops the run between two notes; already imported notes stay.
    func cancel() {
        guard case .running(let done, let total, _) = phase else { return }
        cancelFlag?.set()
        phase = .running(done: done, total: total, cancelling: true)
    }

    /// Closes the sheet (not while running) and forgets the last result.
    func dismissSheet() {
        guard !isRunning else { return }
        sheet = nil
        phase = .idle
        kind = nil
        preview = .idle
        appleNotesPreview = .idle
    }

    /// App Lock engaged: any sheet or alert closes and its result is forgotten. A run
    /// that is still going stops between two notes (already imported notes stay) and ends quietly.
    func appLockEngaged() {
        previewTask?.cancel()
        pullAlert = nil
        sheet = nil
        if case .running = phase {
            lockedDuringRun = true
            cancel()
        } else {
            phase = .idle
            kind = nil
            preview = .idle
            appleNotesPreview = .idle
        }
    }

    private enum Event: Sendable {
        case progress(Int, Int)
        case finished(Result<ImportSummary, ImportFailure>)
    }

    private func start(
        _ kind: ImportKind,
        _ work: @escaping @Sendable (@escaping @Sendable (Int, Int) -> Void, @escaping @Sendable () -> Bool) throws -> ImportSummary
    ) {
        guard !isRunning, !isBlocked() else { return }
        prepare()
        let flag = CancelFlag()
        cancelFlag = flag
        self.kind = kind
        phase = .running(done: 0, total: 0, cancelling: false)
        let (events, continuation) = AsyncStream<Event>.makeStream()
        Task.detached {
            let result: Result<ImportSummary, ImportFailure>
            do {
                result = .success(try work({ continuation.yield(.progress($0, $1)) }, { flag.isSet }))
            } catch {
                result = .failure(ImportFailure(message: Self.describe(error)))
            }
            continuation.yield(.finished(result))
            continuation.finish()
        }
        runTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .progress(let done, let total):
            guard case .running(_, _, let cancelling) = phase else { return }
            phase = .running(done: done, total: total, cancelling: cancelling)
        case .finished(let result):
            cancelFlag = nil
            switch result {
            case .success(let summary):
                phase = .finished(summary)
                if kind == .bearPull, !quietPull || summary.hasNews { pullAlert = summary }
            case .failure(let failure):
                phase = .failed(failure.message)
                if kind == .bearPull {
                    pullAlert = ImportSummary(failure: failure.message)
                }
            }
            quietPull = false
            if lockedDuringRun {
                lockedDuringRun = false
                phase = .idle
                kind = nil
                pullAlert = nil
                sheet = nil
            }
            didImport()
        }
    }

    /// Error text for the UI: kinds, codes and Bear's messages, never note text.
    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let error as BearCLIError: error.description
        case let error as AppleNotesError: error.description
        case let error as CustomStringConvertible: error.description
        default: String(describing: type(of: error))
        }
    }
}

extension ImportSummary {
    /// A pull that could not start (shown in the alert).
    init(failure message: String) {
        title = "Pull from Bear failed"
        rows = []
        warnings = []
        errors = [message]
        wasCancelled = false
        headline = message
    }
}

/// A run or preview that could not start; `message` from `ImportModel.describe`.
struct ImportFailure: Error, Equatable {
    let message: String
}

/// Set by Cancel on the main actor, read by the importer between notes.
final class CancelFlag: Sendable {
    private let value = Mutex(false)

    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
