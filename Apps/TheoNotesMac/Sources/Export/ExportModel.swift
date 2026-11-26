// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Observation

/// Plans and runs one export (M8 Task 13). A seam like `ImportService`: the live one plans from
/// the store and runs `ExportJob`, tests use a double. Main-actor, because `ExportJob` is.
@MainActor
protocol ExportService {
    func plan(ids: [String]) throws -> ExportPlan.Result
    func plan(tagTree: String) throws -> ExportPlan.Result
    func run(
        _ plan: ExportPlan.Result, settings: ExportSettings, destination: URL,
        progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) async -> ExportJobReport
}

@MainActor
struct LiveExportService: ExportService {
    let environment: AppEnvironment

    func plan(ids: [String]) throws -> ExportPlan.Result {
        ExportPlan.selection(try environment.store.exportCandidates(ids: ids))
    }

    func plan(tagTree: String) throws -> ExportPlan.Result {
        ExportPlan.tagTree(root: tagTree, notes: try environment.store.exportCandidates(tagTree: tagTree))
    }

    func run(
        _ plan: ExportPlan.Result, settings: ExportSettings, destination: URL,
        progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) async -> ExportJobReport {
        await ExportJob(environment: environment, renderer: environment.renderer)
            .run(plan, settings: settings, destination: destination, progress: progress, isCancelled: isCancelled)
    }
}

/// What ⇧⌘S exports: the tag tree when neither the note list nor the editor is focused
/// and the scope is a tag; otherwise the selected notes (in list order).
enum ExportTarget: Equatable {
    case tagTree(String)
    case selection([String])

    static func resolve(scope: SidebarScope, noteListFocused: Bool, editorFocused: Bool, selection: [String]) -> ExportTarget? {
        if case .tag(let path) = scope, !noteListFocused, !editorFocused { return .tagTree(path) }
        return selection.isEmpty ? nil : .selection(selection)
    }
}

/// When File ▸ Export Notes… is enabled: not while an import, an export or a restore runs, and
/// only with something to export.
enum ExportCommandAvailability {
    static func isEnabled(importRunning: Bool, exportBusy: Bool, restoreRunning: Bool, hasTarget: Bool) -> Bool {
        hasTarget && !importRunning && !exportBusy && !restoreRunning
    }
}

/// The finished report as the sheet shows it: counts, the locked line, missing attachments and
/// per-note errors. Never carries note text.
struct ExportReportSummary: Equatable {
    var headline: String
    /// "N locked notes were not exported", nil when none were skipped.
    var lockedLine: String?
    /// `"<noteId>/<filename>"`.
    var missingAttachments: [String]
    var errors: [String]
    var wasCancelled: Bool
    var destination: URL

    init(_ report: ExportJobReport, wasCancelled: Bool) {
        self.wasCancelled = wasCancelled
        if wasCancelled {
            headline = "Export cancelled. Nothing was exported."
        } else if report.exported == 0 {
            headline = "Nothing was exported."
        } else {
            headline = "\(report.exported) \(report.exported == 1 ? "note" : "notes") exported."
        }
        lockedLine = report.skippedLocked == 0
            ? nil
            : report.skippedLocked == 1
                ? "1 locked note was not exported" : "\(report.skippedLocked) locked notes were not exported"
        missingAttachments = report.missingAttachments
        errors = report.errors
        destination = report.destination
    }
}

/// File ▸ Export Notes…, the note list's Export… and a tag's Export Notes…. One run at a time per
/// window. Each start shows the folder panel first; the run then goes through `ExportJob`, which
/// copies attachments on the main actor, so a progress sheet with Cancel stays up.
@MainActor
@Observable
final class ExportModel {
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(ExportJobReport)
        /// The run could not start (the plan failed); nothing was exported.
        case failed(String)
    }

    /// Shows the folder panel for `title` with the last-used `settings`. Exactly one of `completion`
    /// (folder and chosen settings) or `cancelled` is called.
    typealias PanelPresenter = @MainActor (
        _ title: String, _ settings: ExportSettings,
        _ completion: @escaping @MainActor (URL, ExportSettings) -> Void, _ cancelled: @escaping @MainActor () -> Void
    ) -> Void

    static let defaultsKey = "Export.settings"

    private(set) var phase: Phase = .idle
    /// The folder panel is up.
    private(set) var isChoosing = false
    private(set) var isCancelling = false
    private(set) var wasCancelled = false

    @ObservationIgnored private let service: any ExportService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keepTags: @MainActor () -> Bool
    @ObservationIgnored private let panel: PanelPresenter
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?

    /// - Parameters:
    ///   - keepTags: Settings ▸ General "Keep tags when exporting", read when a run starts.
    ///   - panel: `ExportPanel.choose` in the app.
    init(
        service: any ExportService, defaults: UserDefaults = .standard, keepTags: @escaping @MainActor () -> Bool,
        panel: @escaping PanelPresenter
    ) {
        self.service = service
        self.defaults = defaults
        self.keepTags = keepTags
        self.panel = panel
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The progress or report sheet is up.
    var showsSheet: Bool { phase != .idle }

    // MARK: - Settings

    /// The settings the panel starts with: the last-used format and HTML/PDF options; `keepTags`
    /// always the Settings value.
    var lastSettings: ExportSettings {
        let stored = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        return ExportSettings(
            format: stored.flatMap { ExportFormat(rawValue: $0.format) } ?? .markdown, keepTags: keepTags(),
            htmlLinksBetweenNotes: stored?.htmlLinksBetweenNotes ?? false,
            htmlEmbedImages: stored?.htmlEmbedImages ?? false, includeAttachments: stored?.includeAttachments ?? true,
            markdownEmbedImages: stored?.markdownEmbedImages ?? false, pdfThemeId: stored?.pdfThemeId)
    }

    /// `keepTags` is deliberately not stored.
    private struct Stored: Codable {
        var format: String
        var htmlLinksBetweenNotes: Bool
        var htmlEmbedImages: Bool
        // Optional: settings stored before 1.1 have neither key.
        var includeAttachments: Bool?
        var markdownEmbedImages: Bool?
        var pdfThemeId: String?
    }

    private func remember(_ settings: ExportSettings) {
        let stored = Stored(
            format: settings.format.rawValue, htmlLinksBetweenNotes: settings.htmlLinksBetweenNotes,
            htmlEmbedImages: settings.htmlEmbedImages, includeAttachments: settings.includeAttachments,
            markdownEmbedImages: settings.markdownEmbedImages, pdfThemeId: settings.pdfThemeId)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: - Starting

    /// Export the notes `ids` (in list order) flat into the chosen folder.
    func exportSelection(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        begin(title: ids.count == 1 ? "Export Note" : "Export \(ids.count) Notes") { try $0.plan(ids: ids) }
    }

    /// Export the tag `path` with its sub-tags as nested folders.
    func exportTagTree(_ path: String) {
        begin(title: "Export #\(path)") { try $0.plan(tagTree: path) }
    }

    private func begin(title: String, plan: @escaping (any ExportService) throws -> ExportPlan.Result) {
        guard !isClosed, !isRunning, !isChoosing, phase == .idle else { return }
        isChoosing = true
        panel(
            title, lastSettings,
            { [weak self] destination, chosen in
                guard let self else { return }
                self.isChoosing = false
                guard !self.isClosed else { return }
                self.start(plan: plan, destination: destination, chosen: chosen)
            },
            { [weak self] in self?.isChoosing = false })
    }

    private func start(
        plan: (any ExportService) throws -> ExportPlan.Result, destination: URL, chosen: ExportSettings
    ) {
        remember(chosen)
        var settings = chosen
        settings.keepTags = keepTags()
        let service = service
        let planned: ExportPlan.Result
        do {
            planned = try plan(service)
        } catch {
            phase = .failed(Self.describe(error))
            return
        }
        cancelRequested = false
        isCancelling = false
        wasCancelled = false
        phase = .running(done: 0, total: planned.items.count)
        runTask = Task { [weak self] in
            let report = await service.run(
                planned, settings: settings, destination: destination,
                progress: { done, total in
                    guard let self, !self.isClosed else { return }
                    self.phase = .running(done: done, total: total)
                },
                isCancelled: { self?.cancelRequested ?? true })
            self?.finish(report)
        }
    }

    private func finish(_ report: ExportJobReport) {
        wasCancelled = cancelRequested
        isCancelling = false
        // A closed window has no sheet to show the report in.
        phase = isClosed ? .idle : .finished(report)
    }

    // MARK: - Running

    /// Stops the run before the next note; a run cancelled before placement places nothing.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        isCancelling = true
        runTask?.cancel()
    }

    /// The window closed: a running export is cancelled (the job rolls back what it placed, so
    /// nothing of the run remains) and the model goes idle once the job returns; a panel still up
    /// starts nothing; no later start is accepted. Called by `MainWindowState.close()`.
    func close() {
        isClosed = true
        isChoosing = false
        if isRunning {
            cancelRequested = true
            isCancelling = true
            runTask?.cancel()
        } else {
            phase = .idle
        }
    }

    /// Closes the sheet (not while running) and forgets the last result.
    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
        isCancelling = false
        wasCancelled = false
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let error as StoreError: String(describing: error)
        case let error as CustomStringConvertible: error.description
        default: String(describing: type(of: error))
        }
    }
}
