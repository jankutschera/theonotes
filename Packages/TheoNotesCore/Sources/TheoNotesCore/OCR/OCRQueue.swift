// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import os

private let ocrLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "ocr")

/// The throttled OCR worker (app process only; the CLI never creates one). One job at a time,
/// a pause between jobs, extraction on a `.utility` detached task, never on the main thread.
///
/// Two sources of work. Insert jobs (`enqueue`) are attachments the user just added; they run
/// first and are not stopped by `pauseBacklog`. The backlog (`startBacklog`, `runBacklog`) is
/// whatever `AttachmentTextStore.pendingJobs` offers, fetched in small batches, until it is empty
/// or `pauseBacklog` is called; `failed` rows whose file changed since are offered too.
///
/// Before a job runs the job must be runnable (`AttachmentTextStore.runnableToken`: live
/// attachment, note neither locked, trashed nor deleted, no staged batch). Its result is stored
/// only if, inside the write transaction, that still holds and the row has not changed since
/// (`record(expectingUpdatedAt:)`), and only for the file as it was read: a file that changed
/// while it was being read drops the result, the next pass reads the new bytes. A file whose hash
/// was recognized before reuses that text. A job already running or waiting is not queued again.
/// Logs carry counts and note ids only.
public actor OCRQueue {
    private let store: AttachmentTextStore
    private let files: AttachmentStore
    private let extractor: any TextExtracting
    private let pause: Duration
    private let batchSize: Int

    private var insertJobs: [OCRJob] = []
    private var inFlight: OCRJob?
    private var backlogActive = false
    private var backlogBuffer: [OCRJob] = []
    /// Backlog jobs already tried in this run, so a job whose result cannot be stored is not
    /// fetched again and again.
    private var attempted: Set<OCRJob> = []
    private var drainTask: Task<Void, Never>?
    /// Jobs started so far (tests and diagnostics).
    public private(set) var processedCount = 0

    public init(
        store: AttachmentTextStore, files: AttachmentStore, extractor: any TextExtracting,
        pause: Duration = .milliseconds(250), batchSize: Int = 20
    ) {
        self.store = store
        self.files = files
        self.extractor = extractor
        self.pause = pause
        self.batchSize = max(1, batchSize)
    }

    /// Insert jobs, run before any backlog job; a job already waiting or running is not queued
    /// twice.
    public func enqueue(_ jobs: [OCRJob]) {
        for job in jobs where job != inFlight && !insertJobs.contains(job) { insertJobs.append(job) }
        guard !insertJobs.isEmpty else { return }
        startDraining()
    }

    /// Starts working through the backlog and returns at once. Idempotent.
    public func startBacklog() {
        if !backlogActive {
            backlogActive = true
            attempted = []
            backlogBuffer = []
        }
        startDraining()
    }

    /// Works through the backlog; returns when it is empty or paused (and no insert job waits).
    public func runBacklog() async {
        startBacklog()
        await waitUntilIdle()
    }

    /// Stops taking backlog jobs; the job in progress and insert jobs finish.
    public func pauseBacklog() {
        backlogActive = false
        backlogBuffer = []
    }

    /// Drops everything waiting and ends the worker after the job in progress (quit, library
    /// change). A job being read finishes its extraction but stores nothing the app still needs.
    public func cancel() {
        backlogActive = false
        backlogBuffer = []
        insertJobs = []
        drainTask?.cancel()
    }

    /// Returns once nothing is running and nothing is runnable.
    public func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    // MARK: Draining

    @discardableResult
    private func startDraining() -> Task<Void, Never> {
        if let drainTask { return drainTask }
        // Utility, not the caller's priority: a task inherits it, and awaiting a detached
        // task from a higher-priority task would raise that one too.
        let task = Task(priority: .utility) { await self.drain() }
        drainTask = task
        return task
    }

    private func drain() async {
        var ran = 0
        while !Task.isCancelled {
            // The pause comes first, so pausing the backlog during it still takes effect.
            if ran > 0, pause > .zero, hasWork() { try? await Task.sleep(for: pause) }
            guard !Task.isCancelled, let job = nextJob() else { break }
            inFlight = job
            await process(job)
            inFlight = nil
            ran += 1
        }
        if ran > 0 { ocrLogger.notice("ocr: \(ran) job(s) done") }
        drainTask = nil
    }

    private func hasWork() -> Bool {
        if !insertJobs.isEmpty { return true }
        fillBacklogBuffer()
        return !backlogBuffer.isEmpty
    }

    private func fillBacklogBuffer() {
        guard backlogActive, backlogBuffer.isEmpty else { return }
        let fetched = (try? store.pendingJobs(limit: batchSize + attempted.count)) ?? []
        backlogBuffer = fetched.filter { !attempted.contains($0) }
        if backlogBuffer.isEmpty { backlogBuffer = changedFailedJobs() }
        if backlogBuffer.isEmpty { backlogActive = false }
    }

    /// Failed rows still in their backoff whose file is not the one they failed on.
    private func changedFailedJobs() -> [OCRJob] {
        let failed = (try? store.failedJobsWithFacts(limit: batchSize + attempted.count)) ?? []
        return failed.compactMap { job, facts in
            guard !attempted.contains(job), let url = files.url(for: job.filename, noteId: job.noteId),
                  let now = OCRFileFacts(url: url), !now.matches(facts) else { return nil }
            return job
        }
    }

    private func nextJob() -> OCRJob? {
        if !insertJobs.isEmpty { return insertJobs.removeFirst() }
        fillBacklogBuffer()
        guard backlogActive, !backlogBuffer.isEmpty else { return nil }
        let job = backlogBuffer.removeFirst()
        attempted.insert(job)
        return job
    }

    // MARK: One job

    private func process(_ job: OCRJob) async {
        processedCount += 1
        guard let token = try? store.runnableToken(job) else { return }
        guard let url = files.url(for: job.filename, noteId: job.noteId), let before = OCRFileFacts(url: url) else {
            try? store.record(job, result: .missing, expectingUpdatedAt: token)
            return
        }
        let store = store
        let extractor = extractor
        let result = await Task.detached(priority: .utility) { () -> OCRResult in
            // Only files the extractor reads are worth hashing (a video or archive can be huge and
            // can never have recognized text to reuse).
            var sha256: String?
            if AttachmentTextExtractor.canExtract(url), before.size <= AttachmentTextExtractor.defaultMaxFileBytes {
                sha256 = AttachmentTextExtractor.sha256(of: url)
                if let sha256, let text = try? store.reusableText(sha256: sha256) {
                    return .text(text, sha256: sha256, byteSize: before.size, modifiedAt: before.modifiedAt)
                }
            }
            return await extractor.extract(from: url, knownSHA256: sha256)
        }.value

        // The bytes changed under the extractor (replaced, still syncing): its result is stale.
        guard OCRFileFacts(url: url) == before else { return }
        do {
            try store.record(job, result: result, facts: before, expectingUpdatedAt: token)
        } catch {
            ocrLogger.error("ocr: note \(job.noteId, privacy: .public): result not stored: \(error)")
        }
    }
}
