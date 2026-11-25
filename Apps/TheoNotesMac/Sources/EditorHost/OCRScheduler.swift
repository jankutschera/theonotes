// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import os

private let ocrSchedulerLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "ocr")

/// What the scheduler asks of the OCR queue; every call returns at once.
protocol OCRWorking: Sendable {
    func enqueue(_ jobs: [OCRJob]) async
    func startBacklog() async
    func pauseBacklog() async
    func cancel() async
}

extension OCRQueue: OCRWorking {}

/// Decides when the OCR queue works (app process only, started by `AppEnvironment`; the CLI never
/// creates one).
///
/// - A just-inserted attachment runs right away (`attachmentsInserted`). Its `attachment` row
///   appears when the note's text is committed, so the scheduler keeps watching the note's next
///   commits (at most `commitsWatched`) until they have shown all the inserted files.
/// - The backlog starts every time the app resigns active, after `idleDelay` without editor
///   changes, and when a session reports a change from outside the editor (CLI, MCP, sync) while
///   the app is not active. The queue's `startBacklog` is idempotent, so starting is never
///   skipped on the scheduler's own guess whether the backlog is still running. It pauses when the
///   app becomes active and when the editor changes again.
///
/// Instructions reach the queue in the order they were given. Logs carry counts and note ids only.
@MainActor
final class OCRScheduler {
    static let idleDelay: Duration = .seconds(30)
    /// How many commits of a note are watched for an inserted attachment's link.
    static let commitsWatched = 3

    private let worker: any OCRWorking
    private let store: AttachmentTextStore
    private let center: NotificationCenter
    private let scheduler: any DebounceScheduler
    private let isAppActive: @MainActor () -> Bool
    private var observers: [any NSObjectProtocol] = []
    private var idleTimer: ScheduledAction?
    /// Whether the backlog was started and not paused since; only decides whether an edit sends a
    /// pause (the queue may have finished on its own).
    private var backlogStarted = false

    private struct Awaiting {
        /// Inserted files whose rows the store has not shown yet (file system keys).
        var keys: Set<String>
        var commitsLeft: Int
    }

    private var awaitingCommit: [String: Awaiting] = [:]
    /// The last instruction on its way to the queue (tests await it).
    private(set) var pendingWork: Task<Void, Never>?

    init(
        worker: any OCRWorking, store: AttachmentTextStore, center: NotificationCenter = .default,
        scheduler: any DebounceScheduler = TaskDebounceScheduler(),
        isAppActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }
    ) {
        self.worker = worker
        self.store = store
        self.center = center
        self.scheduler = scheduler
        self.isAppActive = isAppActive
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appResigned() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
        ]
        armIdleTimer()
    }

    /// Quit: no more triggers, and the queue drops what waits and ends after the job in progress.
    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
        idleTimer?.cancel()
        idleTimer = nil
        awaitingCommit = [:]
        send { await $0.cancel() }
    }

    // MARK: Events

    /// Attachments `filenames` were stored for `noteId` and their link inserted into the editor.
    func attachmentsInserted(noteId: String, filenames: [String]) {
        var entry = awaitingCommit[noteId] ?? Awaiting(keys: [], commitsLeft: Self.commitsWatched)
        entry.keys.formUnion(filenames.map(Self.key))
        entry.commitsLeft = Self.commitsWatched
        entry.keys.subtract(enqueueRows(of: noteId))
        awaitingCommit[noteId] = entry.keys.isEmpty ? nil : entry
    }

    /// Activity of a note's session (`AppEnvironment` forwards it).
    func sessionActivity(_ noteId: String, _ activity: NoteSession.Activity) {
        switch activity {
        case .edited:
            if backlogStarted { pause() }
            armIdleTimer()
        case .committed:
            guard var entry = awaitingCommit[noteId] else { return }
            entry.keys.subtract(enqueueRows(of: noteId))
            entry.commitsLeft -= 1
            awaitingCommit[noteId] = entry.keys.isEmpty || entry.commitsLeft <= 0 ? nil : entry
        case .externalChange:
            if !isAppActive() { startBacklog() }
        }
    }

    private func appResigned() {
        idleTimer?.cancel()
        idleTimer = nil
        startBacklog()
    }

    private func appBecameActive() {
        pause()
        armIdleTimer()
    }

    // MARK: Instructions

    /// Queues the note's rows that wait for recognition; returns their file system keys.
    @discardableResult
    private func enqueueRows(of noteId: String) -> Set<String> {
        let jobs = (try? store.pendingJobs(noteId: noteId)) ?? []
        guard !jobs.isEmpty else { return [] }
        ocrSchedulerLogger.notice("ocr: note \(noteId, privacy: .public): \(jobs.count) inserted attachment(s) queued")
        send { await $0.enqueue(jobs) }
        return Set(jobs.map { Self.key($0.filename) })
    }

    /// How the file system compares names (NFC, case-insensitive).
    private static func key(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        idleTimer = scheduler.schedule(after: Self.idleDelay) { [weak self] in
            self?.idleTimer = nil
            self?.startBacklog()
        }
    }

    private func startBacklog() {
        backlogStarted = true
        send { await $0.startBacklog() }
    }

    private func pause() {
        guard backlogStarted else { return }
        backlogStarted = false
        send { await $0.pauseBacklog() }
    }

    private func send(_ instruction: @escaping @Sendable (any OCRWorking) async -> Void) {
        let previous = pendingWork
        let worker = worker
        pendingWork = Task {
            await previous?.value
            await instruction(worker)
        }
    }
}
