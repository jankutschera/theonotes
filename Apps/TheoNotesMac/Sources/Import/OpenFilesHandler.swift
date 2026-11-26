// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation

/// Files the Finder hands to the app (Open With, a drop on the Dock icon, `open -a`): each becomes a
/// new note through the same importer as File ▸ Import Notes (default options), and the last note made
/// is shown in the frontmost main window.
///
/// Files that arrive before the library is open (a cold launch through Open With) or while App Lock is
/// engaged wait here, in order, and run once there is a `target` and the app is unlocked.
@MainActor
final class OpenFilesHandler {
    /// Most files kept while the app cannot import yet; more are dropped and logged.
    static let maxPending = 200

    /// What the handler needs from the running app; tests pass their own.
    struct Target {
        var service: any ImportService
        var isLocked: @MainActor () -> Bool
        /// A backup, restore or other library-wide operation runs.
        var isBusy: @MainActor () -> Bool
        /// Marks the library busy for the length of a run, so a backup or restore cannot start in the
        /// middle of an import (`LibraryOperationGate.begin` / `end`).
        var beginOperation: @MainActor () -> Void
        var endOperation: @MainActor () -> Void
        var prepare: @MainActor () -> Void
        var didImport: @MainActor () -> Void
        /// Shows a note in the frontmost main window; false when it could not be shown.
        var show: @MainActor (String) -> Bool
        /// Tells the user about errors or skipped files.
        var report: @MainActor (ImportSummary) -> Void
    }

    /// Setting it starts whatever waited.
    var target: Target? {
        didSet { drain() }
    }

    private(set) var pending: [URL] = []
    private(set) var isRunning = false
    private(set) var runTask: Task<Void, Never>?
    /// How long to wait before looking again while a backup or restore runs.
    var busyRetryInterval: Duration = .seconds(1)
    private var runLockFlag = CancelFlag()
    /// When each URL was last received, so the same event arriving by two doors (the Apple event and
    /// `application(_:open:)`) imports a file once.
    private var recent: [URL: ContinuousClock.Instant] = [:]
    /// Two deliveries of one URL closer together than this are one event.
    static let duplicateWindow: Duration = .seconds(1)
    private var retryTask: Task<Void, Never>?

    /// The `application(_:open:)` entry point. Anything but a file URL is ignored.
    func receive(_ urls: [URL]) {
        let now = ContinuousClock.now
        recent = recent.filter { now - $0.value < Self.duplicateWindow }
        for url in urls where url.isFileURL {
            let key = url.standardizedFileURL
            // The same file twice in one batch, or the same event again from a second door.
            guard recent[key] == nil else { continue }
            recent[key] = now
            guard pending.count < Self.maxPending else {
                appLogger.error("open files: dropped a file, too many waiting")
                break
            }
            pending.append(url)
        }
        drain()
    }

    /// App Lock is about to engage: a run in progress stops before its next file; the rest waits.
    func lockEngaged() {
        runLockFlag.set()
    }

    /// Imports what waits, unless there is nothing, no app yet, the app is locked or a run is going.
    func drain() {
        guard !isRunning, !pending.isEmpty, let target, !target.isLocked() else { return }
        guard !target.isBusy() else {
            appLogger.notice("open files: \(self.pending.count) waiting for a backup or restore to end")
            return scheduleRetry()
        }
        isRunning = true
        target.beginOperation()
        let end = target.endOperation
        let urls = pending
        pending = []
        let flag = CancelFlag()
        runLockFlag = flag
        target.prepare()
        let service = target.service
        runTask = Task { [weak self] in
            let outcome = await Task.detached { Self.run(urls, service: service, stop: flag) }.value
            self?.finish(outcome, end: end)
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let interval = busyRetryInterval
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.drain()
        }
    }

    private struct Outcome: Sendable {
        var report = FileImportReport()
        /// Files not tried because App Lock engaged.
        var remaining: [URL] = []
    }

    /// One file at a time, so a lock between two files keeps the rest back.
    private nonisolated static func run(_ urls: [URL], service: any ImportService, stop: CancelFlag) -> Outcome {
        var outcome = Outcome()
        for (index, url) in urls.enumerated() {
            if stop.isSet {
                outcome.remaining = Array(urls[index...])
                break
            }
            do {
                let one = try service.importFiles([url], options: FileImportOptions(), progress: { _, _ in }, isCancelled: { stop.isSet })
                outcome.report.created += one.created
                outcome.report.skipped += one.skipped
                outcome.report.attachmentsCopied += one.attachmentsCopied
                outcome.report.warnings += one.warnings
                outcome.report.errors += one.errors
                outcome.report.createdNoteIds += one.createdNoteIds
                if one.wasCancelled {
                    outcome.remaining = Array(urls[index...])
                    break
                }
            } catch {
                outcome.report.errors.append("\(url.lastPathComponent): \(ImportModel.describe(error))")
            }
        }
        return outcome
    }

    private func finish(_ outcome: Outcome, end: @MainActor () -> Void) {
        end()
        isRunning = false
        runTask = nil
        pending.insert(contentsOf: outcome.remaining.prefix(Self.maxPending), at: 0)
        guard let target else { return }
        target.didImport()
        let report = outcome.report
        if target.isLocked() {
            // What a locked app shows is nothing.
            appLogger.notice("open files: \(report.created) imported, result not shown while locked")
        } else {
            if let id = report.createdNoteIds.last, !target.show(id) {
                appLogger.error("open files: the imported note could not be shown")
            }
            if !report.errors.isEmpty || report.skipped > 0 {
                target.report(ImportSummary(files: report))
            }
        }
        drain()
    }
}

extension OpenFilesHandler {
    /// Connects the handler to the running app: its store, window routing and App Lock.
    func attach(to app: AppModel) {
        let lock = app.environment.appLock
        lock.addWillLockHandler { [weak self] in self?.lockEngaged() }
        lock.addDidUnlockHandler { [weak self] in self?.drain() }
        let environment = app.environment
        target = Target(
            service: LiveImportService(store: environment.store, paths: environment.paths),
            isLocked: { [weak app] in app?.isLocked ?? true },
            isBusy: { environment.operations.isBusy },
            beginOperation: { environment.operations.begin() },
            endOperation: { environment.operations.end() },
            prepare: { environment.flushAll() },
            didImport: { [weak app] in app?.frontmostMainWindow?.model.refresh() },
            show: { [weak app] id in
                guard let app else { return false }
                let queued = app.openNote(OpenNoteRequest(noteId: id))
                Self.ensureMainWindow(of: app)
                return queued
            },
            report: { OpenFilesAlert.show($0) })
    }
}

extension OpenFilesHandler {
    /// SwiftUI shows no launch window when the app was started by an opened file that it left to the
    /// delegate, and no window means nothing has installed `openWindow` yet. If, shortly after
    /// the note was queued, there still is no main window and no window host, ask for one the way a Dock
    /// click does (the reopen event); the queued note opens in it. Nothing happens when a window came by
    /// itself, so there is never a second one.
    static func ensureMainWindow(of app: AppModel, after delay: Duration = .milliseconds(500)) {
        guard app.mainWindows.isEmpty else { return }
        Task { @MainActor [weak app] in
            try? await Task.sleep(for: delay)
            guard let app, !app.isLocked, app.mainWindows.isEmpty, app.openWindowRequest == nil else { return }
            _ = try? await NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// The alert for files that could not be imported: the importer's own headline and error lines
/// (paths and reasons, never note text).
@MainActor
enum OpenFilesAlert {
    static func show(_ summary: ImportSummary) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = summary.title
        alert.informativeText = text(summary)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func text(_ summary: ImportSummary) -> String {
        let lines = Array((summary.errors + summary.warnings).prefix(6))
        let more = summary.errors.count + summary.warnings.count - lines.count
        return ([summary.headline] + lines + (more > 0 ? ["… and \(more) more."] : [])).joined(separator: "\n")
    }
}
