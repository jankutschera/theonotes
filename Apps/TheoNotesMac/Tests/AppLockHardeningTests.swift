// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// M9M fix round 1 for task 6 (security review): nothing is built, started, replayed or published
/// across the lock boundary. Libraries are temporary, the identity check is a fake.
@MainActor
@Suite(.serialized) struct AppLockHardeningTests {
    typealias Env = AppSocketServerTests.Env

    // MARK: 1. launch gate

    /// A library whose App Lock is on, relaunched: the second environment starts locked.
    private func lockedRelaunch() async throws -> (environment: AppEnvironment, app: AppModel, noteId: String, authenticator: FakeAppAuthenticator, cleanup: () -> Void) {
        let root = URL(fileURLWithPath: "/tmp/theo-hard-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let first = try AppEnvironment(paths: AppPaths(root: root), appAuthenticator: FakeAppAuthenticator(), appLockLifecycle: nil, appIdleSeconds: { 0 })
        let note = try first.store.create(text: "# Quarterly numbers zqx\n\nbody")
        _ = try first.store.create(text: "# Second note")
        first.appLock.setDelay(60)
        TheoNotesCore.Settings(db: first.database).appLockEnabled = true
        try first.database.pool.close()
        let authenticator = FakeAppAuthenticator()
        let environment = try AppEnvironment(paths: AppPaths(root: root), appAuthenticator: authenticator, appLockLifecycle: nil, appIdleSeconds: { 0 })
        let defaults = UserDefaults(suiteName: "hard-\(UUID().uuidString)")!
        let app = AppModel(environment: environment, defaults: defaults)
        return (environment, app, note.id, authenticator, { try? FileManager.default.removeItem(at: root) })
    }

    @Test func aLockedLaunchBuildsNoWindowStateSessionOrEditor() async throws {
        let launch = try await lockedRelaunch()
        defer { launch.cleanup() }
        #expect(launch.environment.appLock.isLocked)
        #expect(launch.environment.openSessionCount == 0 && launch.environment.registeredEditorCount == 0)

        // What the windows' views do on appear, once per restored window.
        #expect(launch.app.makeMainWindowIfUnlocked() == nil)
        #expect(launch.app.makeNoteWindowIfUnlocked(noteId: launch.noteId) == nil)

        #expect(launch.app.mainWindows.isEmpty && launch.app.noteWindowRefs.isEmpty)
        #expect(launch.environment.openSessionCount == 0, "no note was opened")
        #expect(launch.environment.registeredEditorCount == 0, "no editor page was made")
    }

    @Test func theWindowsAreMadeOnlyAfterTheUnlock() async throws {
        let launch = try await lockedRelaunch()
        defer { launch.cleanup() }
        launch.authenticator.script(.success)
        #expect(await launch.environment.appLock.unlock())

        let main = try #require(launch.app.makeMainWindowIfUnlocked())
        defer { main.close() }
        let note = try #require(launch.app.makeNoteWindowIfUnlocked(noteId: launch.noteId))
        #expect(note.noteId == launch.noteId)
        #expect(launch.app.mainWindows.count == 1)
    }

    // MARK: 2. in-flight authentication

    @Test func aPromptThatSucceedsAfterTheMacLockedOpensNothing() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.holdPrompts()
        async let outcome = lock.unlock()
        for _ in 0..<200 where !lock.isAuthenticating { await Task.yield() }
        #expect(lock.isAuthenticating)

        fixture.lifecycle.send(.deviceLocked)
        #expect(fixture.authenticator.invalidations >= 1, "the prompt that is up is ended")
        fixture.authenticator.script(.success)
        fixture.authenticator.releasePrompts()

        #expect(await outcome == false)
        #expect(lock.isLocked, "a late success from before the Mac locked stays locked")
        #expect(fixture.authenticator.callCount == 1)
        // A fresh attempt after the Mac is unlocked again works.
        #expect(await lock.unlock())
    }

    @Test func aLateSuccessWhileTurningTheLockOffKeepsItOn() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        fixture.authenticator.script(.success)
        _ = await lock.unlock()
        fixture.authenticator.holdPrompts()
        async let outcome = lock.setEnabled(false)
        for _ in 0..<200 where !lock.isAuthenticating { await Task.yield() }
        fixture.lifecycle.send(.deviceLocked)
        fixture.authenticator.script(.success)
        fixture.authenticator.releasePrompts()
        #expect(await outcome == .cancelled)
        #expect(lock.isEnabled && lock.isLocked && fixture.settings.appLockEnabled)
    }

    @Test func theGenerationMovesOnlyWhenTheLockEngages() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock()
        _ = await lock.unlock()
        let before = lock.generation
        #expect(lock.isCurrent(before))
        fixture.lifecycle.send(.appResigned)
        #expect(lock.generation == before || lock.isLocked, "a resign alone does not stale anything unless it locks")
        lock.lock()
        #expect(lock.generation != before && !lock.isCurrent(before))
        _ = await lock.unlock()
        #expect(!lock.isCurrent(before), "stale stays stale after the unlock")
        #expect(lock.isCurrent(lock.generation))

        let off = try AppLockFixture(enabled: false)
        defer { off.destroy() }
        let idle = off.makeLock()
        let start = idle.generation
        off.lifecycle.send(.deviceLocked)
        #expect(idle.isCurrent(start), "with App Lock off the Mac locking does not stale anything")
    }

    // MARK: 3. deferred automation

    @Test func requestsWaitingForAWindowAreDroppedWhenTheLockEngages() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        var ran = false
        #expect(env.app.withMainWindow { _ in ran = true })
        env.app.pendingNoteOpens[note.id] = OpenNoteRequest(noteId: note.id, newWindow: true)
        #expect(!env.app.pendingMainActions.isEmpty && !env.app.pendingNoteOpens.isEmpty)

        await env.engageAppLock()
        #expect(env.app.pendingMainActions.isEmpty && env.app.pendingNoteOpens.isEmpty)
        await env.unlockApp()
        let main = env.app.makeMainWindow()
        defer { main.close() }
        #expect(!ran, "an open accepted before the lock does not run after the unlock")
    }

    @Test func aWaitingActionThatSlipsThroughIsStillRefusedAtExecution() async throws {
        let env = try Env()
        await env.engageAppLock()
        var ran = false
        env.app.pendingMainActions = [{ _ in ran = true }]
        let main = env.app.makeMainWindow()
        defer { main.close() }
        #expect(!ran)
        #expect(env.app.pendingMainActions.isEmpty)
    }

    @Test func queuedWindowRequestsForNotesAreDroppedButNewWindowsSurvive() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        #expect(env.app.requestWindow(.note(id: note.id)))
        #expect(env.app.requestWindow(.main))
        await env.engageAppLock()
        await env.unlockApp()
        env.app.openWindowRequest = { [unowned env] in env.requests.append($0) }
        #expect(env.requests == [.main], "the note window request did not survive: \(env.requests)")
    }

    @Test func aNoteWindowDispatchedBeforeTheLockIsStaleWhenItsHostAppearsAfterTheUnlock() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        env.app.openWindowRequest = { [unowned env] in env.requests.append($0) }
        // The request goes out at once (SwiftUI will make the scene a moment later).
        #expect(env.app.requestWindow(.note(id: note.id)))
        #expect(env.requests == [.note(id: note.id)])
        await env.engageAppLock()

        // The host appears while locked: it waits and opens nothing.
        guard case .wait = env.app.claimNoteWindow(noteId: note.id) else { Issue.record("expected wait"); return }
        #expect(env.app.noteWindowRefs.isEmpty)

        await env.unlockApp()
        guard case .stale = env.app.claimNoteWindow(noteId: note.id) else { Issue.record("expected stale"); return }
        #expect(env.app.noteWindowRefs.isEmpty && env.environment.openSessionCount == 0, "the note was not opened")
    }

    @Test func aFreshOrRestoredNoteWindowOpens() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        env.app.openWindowRequest = { [unowned env] in env.requests.append($0) }
        // Dispatched with no lock around: opens.
        env.app.requestWindow(.note(id: note.id))
        guard case .open(let first) = env.app.claimNoteWindow(noteId: note.id) else { Issue.record("expected open"); return }
        first.close()
        // Restored by the system (no request of ours): opens.
        guard case .open(let restored) = env.app.claimNoteWindow(noteId: note.id) else { Issue.record("expected open"); return }
        restored.close()
        // A stale request and a fresh one for the same note: the fresh one is honoured.
        env.app.requestWindow(.note(id: note.id))
        await env.engageAppLock()
        await env.unlockApp()
        env.app.requestWindow(.note(id: note.id))
        guard case .open(let fresh) = env.app.claimNoteWindow(noteId: note.id) else { Issue.record("expected open"); return }
        fresh.close()
    }

    // MARK: 4. sync barrier

    private func syncController() throws -> (MacSyncController, cleanup: () -> Void) {
        struct Refused: Error {}
        let suite = "hard-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let services = MacSyncServices(
            defaults: defaults, credentials: { _ in throw Refused() }, transport: { _, _ in throw Refused() },
            enrollment: { _, _ in throw Refused() }, engine: { _, _, _ in throw Refused() }, scheduler: { _, _ in nil })
        let root = URL(fileURLWithPath: "/tmp/theo-hard-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let environment = try AppEnvironment(paths: AppPaths(root: root), syncPolicy: .enabled, syncServices: services)
        return (environment.sync, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            _ = environment
        })
    }

    @Test func quiesceBlocksNewRunsAndWaitsForTheRunningOne() async throws {
        let (sync, cleanup) = try syncController()
        defer { cleanup() }
        let gate = AsyncGateForTests()
        let running = Task { await sync.perform { await gate.wait() } }
        for _ in 0..<200 where !sync.busy { await Task.yield() }
        #expect(sync.busy)

        async let quiet = sync.quiesce(timeout: .seconds(5))
        for _ in 0..<20 { await Task.yield() }
        #expect(sync.busy, "the barrier does not return while the run is going")
        #expect(await sync.refreshAutomatically() == .deferred, "no new run starts once the barrier is up")
        gate.open()
        #expect(await quiet)
        #expect(!sync.busy)
        await running.value

        #expect(await sync.refreshAutomatically() == .deferred)
        sync.endQuiesce()
        #expect(await sync.refreshAutomatically() != .deferred, "after the barrier is released runs may start again")
    }

    @Test func quiesceGivesUpAfterItsTimeoutButStaysBalanced() async throws {
        let (sync, cleanup) = try syncController()
        defer { cleanup() }
        let gate = AsyncGateForTests()
        let running = Task { await sync.perform { await gate.wait() } }
        for _ in 0..<200 where !sync.busy { await Task.yield() }
        #expect(await sync.quiesce(timeout: .milliseconds(50)) == false)
        sync.endQuiesce()
        gate.open()
        await running.value
        #expect(await sync.refreshAutomatically() != .deferred)
    }

    // MARK: 5. content jobs

    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("theo-hard-\(UUID().uuidString)"))
    }

    @Test func copyAsWritesNothingWhenTheLockEngagesBeforeTheWrite() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx\n\nbody")
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        let board = pasteboard()
        board.clearContents()
        let copier = CopyAs(
            environment: env.environment, renderer: env.environment.renderer, pasteboard: board,
            beep: {}, beforeWrite: { env.environment.appLock.lock() })

        let outcome = await copier.perform(.markdown, target: .notes([note.id]))
        #expect(!outcome.wrote)
        #expect(board.string(forType: .string) == nil, "the pasteboard stays empty")
    }

    @Test func copyAsStartedWhileLockedWritesNothing() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        await env.engageAppLock()
        let board = pasteboard()
        let outcome = await CopyAs(environment: env.environment, renderer: env.environment.renderer, pasteboard: board, beep: {})
            .perform(.markdown, target: .notes([note.id]))
        #expect(!outcome.wrote && board.string(forType: .string) == nil)
    }

    @Test func copyAsStillWorksWhenNothingLocked() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        let board = pasteboard()
        let outcome = await CopyAs(environment: env.environment, renderer: env.environment.renderer, pasteboard: board, beep: {})
            .perform(.markdown, target: .notes([note.id]))
        #expect(outcome.wrote && board.string(forType: .string)?.contains("Visible title") == true)
    }

    @Test func anExportThatIsLockedMidRunPlacesNothing() async throws {
        let env = try Env()
        let notes = try (0..<3).map { try env.store.create(text: "# Note \($0) zqx") }
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        let out = env.root.appendingPathComponent("out", isDirectory: true)
        let plan = ExportPlan.selection(try env.store.exportCandidates(ids: notes.map(\.id)))
        let job = ExportJob(environment: env.environment, renderer: env.environment.renderer)

        let report = await job.run(
            plan, settings: ExportSettings(format: .markdown, keepTags: true), destination: out,
            progress: { done, _ in if done == 1 { env.environment.appLock.lock() } }, isCancelled: { false })

        #expect(report.exported == 0, "all or nothing: a locked run places no file")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(left.isEmpty, "nothing, not even the stage: \(left)")
    }

    @Test func anExportWhoseRenderFinishesAfterTheLockWritesNothingToTheStage() async throws {
        let env = try Env()
        let notes = try (0..<2).map { try env.store.create(text: "# Note \($0) zqx") }
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        let out = env.root.appendingPathComponent("out", isDirectory: true)
        let plan = ExportPlan.selection(try env.store.exportCandidates(ids: notes.map(\.id)))

        // Control: without the lock the seam sees the writes.
        var control: [URL] = []
        var job = ExportJob(environment: env.environment, renderer: env.environment.renderer)
        job.beforeStageWrite = { control.append($0) }
        let ok = await job.run(
            plan, settings: ExportSettings(format: .rtf, keepTags: true), destination: out,
            progress: { _, _ in }, isCancelled: { false })
        #expect(ok.exported == 2 && !control.isEmpty, "report: \(ok) control: \(control.count)")
        try? FileManager.default.removeItem(at: out)

        // The lock engages while the first render is in flight; the render still completes.
        var written: [URL] = []
        job.beforeStageWrite = { written.append($0) }
        let lock = env.environment.appLock
        let locker = Task { @MainActor in lock.lock() }
        let report = await job.run(
            plan, settings: ExportSettings(format: .rtf, keepTags: true), destination: out,
            progress: { _, _ in }, isCancelled: { false })
        await locker.value
        #expect(lock.isLocked)
        #expect(written.isEmpty, "nothing was written to the stage after the lock: \(written)")
        #expect(report.exported == 0)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test func lockingCancelsTheRunningCopy() async throws {
        let env = try Env()
        let note = try env.store.create(text: "# Visible title zqx")
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        let board = pasteboard()
        let copier = CopyAs(environment: env.environment, renderer: env.environment.renderer, pasteboard: board, beep: {})
        let task = CopyAsRunner.start(copier, .markdown, target: .notes([note.id]))
        env.environment.appLock.lock()
        #expect(task.isCancelled, "the lock asks the running copy to stop")
        let outcome = await task.value
        #expect(!outcome.wrote && board.string(forType: .string) == nil)
    }

    // MARK: 6. window metadata

    private func window(_ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func scrubbingSetsNeutralTitlesAndDockImagesAndRestoreBringsThemBack() {
        let scrubber = AppLockWindowScrubber()
        let note = window("Quarterly numbers zqx")
        let other = window("Another secret zqx")
        let original = NSImage(size: NSSize(width: 4, height: 4))
        other.miniwindowImage = original
        other.miniwindowTitle = "Another secret zqx"

        scrubber.scrub([note, other])
        for w in [note, other] {
            #expect(w.title == AppLockWindowScrubber.neutralTitle)
            #expect(w.miniwindowTitle == AppLockWindowScrubber.neutralTitle)
            #expect(w.miniwindowImage != nil && w.miniwindowImage !== original)
        }

        scrubber.restore()
        #expect(note.title == "Quarterly numbers zqx" && other.title == "Another secret zqx")
        #expect(note.miniwindowImage == nil)
        #expect(other.miniwindowImage === original)
        #expect(other.miniwindowTitle == "Another secret zqx")
    }

    @Test func aTitleSwiftUIChangedMeanwhileIsNotOverwrittenByTheRestore() {
        let scrubber = AppLockWindowScrubber()
        let w = window("Old title")
        scrubber.scrub([w])
        w.title = "New title from the unlocked view"
        scrubber.restore()
        #expect(w.title == "New title from the unlocked view")
    }

    @Test func theLockScrubsWindowsBeforeItPublishesTheLockedState() async throws {
        let env = try Env()
        let a = window("Quarterly numbers zqx")
        env.app.lockableWindows = { [a] }
        env.authenticator.script(.success)
        _ = await env.environment.appLock.setEnabled(true)
        var titleAtPublish: String?
        var lockedAtPublish: Bool?
        // Registered after the app model's own handler: it runs after the scrub, before `isLocked` flips.
        env.environment.appLock.addWillLockHandler {
            titleAtPublish = a.title
            lockedAtPublish = env.environment.appLock.isLocked
        }
        env.environment.appLock.lock()
        #expect(lockedAtPublish == false)
        #expect(titleAtPublish == AppLockWindowScrubber.neutralTitle, "the title is already neutral when the state is published")
        #expect(a.miniwindowImage != nil)

        await env.unlockApp()
        #expect(a.title == "Quarterly numbers zqx")
        #expect(a.miniwindowImage == nil)
    }
}
