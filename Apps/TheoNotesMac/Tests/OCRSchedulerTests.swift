// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Synchronization
import Testing
@testable import TheoNotes

/// Records what the scheduler asks of the queue.
final class FakeOCRWorker: OCRWorking {
    enum Call: Equatable {
        case enqueue([OCRJob])
        case startBacklog
        case pauseBacklog
        case cancel
    }

    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    func enqueue(_ jobs: [OCRJob]) async { recorded.withLock { $0.append(.enqueue(jobs)) } }
    func startBacklog() async { recorded.withLock { $0.append(.startBacklog) } }
    func pauseBacklog() async { recorded.withLock { $0.append(.pauseBacklog) } }
    func cancel() async { recorded.withLock { $0.append(.cancel) } }
}

@MainActor
final class AppActiveFlag {
    var value = true
}

@MainActor
@Suite struct OCRSchedulerTests {
    typealias Env = LibraryModelTests.Env

    let env: Env
    let worker = FakeOCRWorker()
    let center = NotificationCenter()
    let clock = ManualScheduler()
    let active = AppActiveFlag()
    let scheduler: OCRScheduler

    init() throws {
        env = try Env()
        let flag = active
        scheduler = OCRScheduler(
            worker: worker, store: AttachmentTextStore(database: env.environment.database), center: center, scheduler: clock,
            isAppActive: { flag.value })
        scheduler.start()
    }

    private func settle() async {
        await scheduler.pendingWork?.value
    }

    @Test func resignActiveStartsTheBacklog() async {
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        await settle()
        #expect(worker.calls == [.startBacklog])
    }

    @Test func becomeActivePausesIt() async {
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(worker.calls == [.startBacklog, .pauseBacklog])
    }

    @Test func anInsertedImageIsEnqueuedImmediately() async throws {
        let note = try env.store.create(text: "# T\n![](a.png)")
        scheduler.attachmentsInserted(noteId: note.id, filenames: ["a.png"])
        await settle()
        #expect(worker.calls == [.enqueue([OCRJob(noteId: note.id, filename: "a.png")])])
    }

    @Test func anImageWhoseLinkIsNotCommittedYetWaitsForTheCommit() async throws {
        let note = try env.store.create(text: "# T")
        scheduler.attachmentsInserted(noteId: note.id, filenames: ["a.png"])
        await settle()
        #expect(worker.calls.isEmpty)
        // Other notes' commits do not count.
        scheduler.sessionActivity("other", .committed(text: "", modifiedAt: Date()))
        await settle()
        #expect(worker.calls.isEmpty)
        _ = try env.store.updateText(id: note.id, text: "# T\n![](a.png)", expectedRevision: note.revision)
        scheduler.sessionActivity(note.id, .committed(text: "# T\n![](a.png)", modifiedAt: Date()))
        await settle()
        #expect(worker.calls == [.enqueue([OCRJob(noteId: note.id, filename: "a.png")])])
        // Only once.
        scheduler.sessionActivity(note.id, .committed(text: "", modifiedAt: Date()))
        await settle()
        #expect(worker.calls.count == 1)
    }

    @Test func aLockedNoteIsNeverEnqueued() async throws {
        let note = try env.store.create(text: "# T\n![](a.png)")
        try await env.environment.database.pool.write { db in
            try db.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [note.id])
        }
        scheduler.attachmentsInserted(noteId: note.id, filenames: ["a.png"])
        await settle()
        #expect(worker.calls.isEmpty)
    }

    @Test func theBacklogStartsAfterThirtySecondsWithoutEditorChanges() async {
        clock.advance(by: .seconds(29))
        await settle()
        #expect(worker.calls.isEmpty)
        clock.advance(by: .seconds(1))
        await settle()
        #expect(worker.calls == [.startBacklog])
    }

    @Test func editingRestartsTheIdleTimerAndPausesARunningBacklog() async {
        clock.advance(by: .seconds(20))
        scheduler.sessionActivity("n", .edited)
        clock.advance(by: .seconds(29))
        await settle()
        #expect(worker.calls.isEmpty, "the 30 s count from the last change")
        clock.advance(by: .seconds(1))
        await settle()
        #expect(worker.calls == [.startBacklog])
        scheduler.sessionActivity("n", .edited)
        await settle()
        #expect(worker.calls == [.startBacklog, .pauseBacklog])
        clock.advance(by: .seconds(30))
        await settle()
        #expect(worker.calls == [.startBacklog, .pauseBacklog, .startBacklog])
    }

    @Test func resigningCancelsThePendingIdleTimer() async {
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        clock.advance(by: .seconds(60))
        await settle()
        #expect(worker.calls == [.startBacklog])
    }

    @Test func resigningStartsTheBacklogAgainAfterItFinishedOnItsOwn() async {
        // The idle timer starts it; the queue runs dry without telling the scheduler.
        clock.advance(by: .seconds(30))
        await settle()
        #expect(worker.calls == [.startBacklog])
        // New work arrived meanwhile (CLI, MCP); leaving the app must start the queue again.
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        await settle()
        #expect(worker.calls == [.startBacklog, .startBacklog])
    }

    @Test func aChangeFromOutsideStartsTheBacklogOnlyWhileTheAppIsInactive() async {
        active.value = true
        scheduler.sessionActivity("n", .externalChange(previous: "", text: "x", modifiedAt: Date()))
        await settle()
        #expect(worker.calls.isEmpty)
        active.value = false
        scheduler.sessionActivity("n", .externalChange(previous: "", text: "x", modifiedAt: Date()))
        await settle()
        #expect(worker.calls == [.startBacklog])
    }

    @Test func anInsertedImageIsWatchedForSeveralCommitsUntilItsRowAppears() async throws {
        let note = try env.store.create(text: "# T")
        scheduler.attachmentsInserted(noteId: note.id, filenames: ["a.png"])
        // A commit of text typed before the drop does not use the watch up.
        scheduler.sessionActivity(note.id, .committed(text: "# T", modifiedAt: Date()))
        scheduler.sessionActivity(note.id, .committed(text: "# T!", modifiedAt: Date()))
        await settle()
        #expect(worker.calls.isEmpty)
        _ = try env.store.updateText(id: note.id, text: "# T\n![](a.png)", expectedRevision: note.revision)
        scheduler.sessionActivity(note.id, .committed(text: "# T\n![](a.png)", modifiedAt: Date()))
        await settle()
        #expect(worker.calls == [.enqueue([OCRJob(noteId: note.id, filename: "a.png")])])
    }

    @Test func theWatchEndsAfterThreeCommits() async throws {
        let note = try env.store.create(text: "# T")
        scheduler.attachmentsInserted(noteId: note.id, filenames: ["a.png"])
        for _ in 0..<3 { scheduler.sessionActivity(note.id, .committed(text: "# T", modifiedAt: Date())) }
        _ = try env.store.updateText(id: note.id, text: "# T\n![](a.png)", expectedRevision: note.revision)
        scheduler.sessionActivity(note.id, .committed(text: "# T\n![](a.png)", modifiedAt: Date()))
        await settle()
        #expect(worker.calls.isEmpty, "left to the backlog")
    }

    @Test func theWatchContinuesWhileSomeInsertedFilesAreStillUnknown() async throws {
        let note = try env.store.create(text: "# T\n![](a.png)")
        scheduler.attachmentsInserted(noteId: note.id, filenames: ["a.png", "b.png"])
        await settle()
        #expect(worker.calls == [.enqueue([OCRJob(noteId: note.id, filename: "a.png")])])
        _ = try env.store.updateText(id: note.id, text: "# T\n![](a.png)\n![](b.png)", expectedRevision: note.revision)
        scheduler.sessionActivity(note.id, .committed(text: "", modifiedAt: Date()))
        await settle()
        #expect(worker.calls.last == .enqueue([OCRJob(noteId: note.id, filename: "a.png"), OCRJob(noteId: note.id, filename: "b.png")]))
    }

    @Test func stoppingCancelsTheQueueAndTheTriggers() async {
        scheduler.stop()
        await settle()
        #expect(worker.calls == [.cancel])
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        clock.advance(by: .seconds(60))
        await settle()
        #expect(worker.calls == [.cancel])
    }
}
