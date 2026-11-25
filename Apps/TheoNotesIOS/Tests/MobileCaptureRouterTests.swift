// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileCaptureRouterTests {
    @Test func pendingDeliveriesAreNeverEvictedUnderQueuePressure() {
        let router = MobileCaptureRouter()
        let first = UUID()
        #expect(router.enqueue(.search, deliveryID: first))
        for _ in 0..<1025 { #expect(router.enqueue(.search)) }
        #expect(!router.enqueue(.search, deliveryID: first))
        #expect(router.pendingCount == 1026)
    }

    @Test func completedDeliveryWindowEvictsOldestAndKeepsRecentDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        router.connect(library, ready: true)
        let deliveries = (0..<1025).map { _ in UUID() }
        for delivery in deliveries {
            #expect(router.enqueue(.search, deliveryID: delivery))
            try await router.drain()
            let presentation = try #require(router.presentation)
            #expect(presentation.id == delivery)
            #expect(router.finishPresentation(deliveryID: delivery))
        }
        #expect(!router.enqueue(.search, deliveryID: deliveries[1]))
        #expect(!router.enqueue(.search, deliveryID: deliveries[1024]))
        #expect(router.enqueue(.search, deliveryID: deliveries[0]))
        #expect(router.pendingCount == 1)
        #expect(try library.store.allNotes().isEmpty)
    }

    @Test func exposedCaptureActionsExcludeUnavailableVoice() {
        #expect(MobileCaptureAction(rawValue: "voice") == nil)
        #expect(Set(MobileCaptureAction.allCases.map(\.rawValue)) ==
                Set(["newNote", "newTodo", "scan", "search", "thought"]))
    }

    @Test func coldRequestWaitsForReadinessAndRepeatedDeliveryCreatesOneNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        let delivery = UUID()
        #expect(router.enqueue(.newNote, deliveryID: delivery))
        #expect(!router.enqueue(.newNote, deliveryID: delivery))
        try await router.drain()
        router.connect(library, ready: false)
        try await router.drain()
        #expect(try library.store.allNotes().isEmpty)
        router.connect(library, ready: true)
        try await router.drain()
        #expect(try library.store.allNotes().count == 1)
        #expect(router.pendingCount == 0)
        #expect(!router.enqueue(.newNote, deliveryID: delivery))
        try await router.drain()
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func lockedLibraryKeepsRequestUntilAuthenticated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        try await library.setAppLock(true, authenticate: {})
        library.lockApplication()
        let router = MobileCaptureRouter()
        router.connect(library, ready: true)
        router.enqueue(.newTodo)
        try await router.drain()
        #expect(router.pendingCount == 1)
        #expect(try library.store.allNotes().isEmpty)
        try await library.setAppLock(true, authenticate: {})
        try await router.drain()
        let id = try #require(library.selectedID)
        let note = try #require(try library.store.note(id: id))
        #expect(note.text == "- [ ] ")
        #expect(library.pendingCaret[note.id] == note.text.utf16.count)
    }

    @Test func warmThoughtUsesExistingCapturedNoteLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        router.connect(library, ready: true)
        router.enqueue(.thought)
        try await router.drain()
        let id = try #require(library.selectedID)
        #expect(library.isActiveCapture(id))
        #expect(try library.store.captureSource(noteId: id) == .command)
    }

    @Test func scanPresentsOnceAndCancellationRejectsLateResultsWithoutAttachments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { true })
        router.connect(library, ready: true)
        let delivery = UUID()
        router.enqueue(.scan, deliveryID: delivery)
        try await router.drain()
        let scan = try #require(router.presentation)
        #expect(scan.action == .scan && scan.id == delivery)
        #expect(router.canAcceptScan(scan))
        #expect(!router.enqueue(.scan, deliveryID: delivery))
        try await router.drain()
        #expect(try library.store.allNotes().count == 1)
        router.finishPresentation(deliveryID: delivery)
        #expect(!router.canAcceptScan(scan))
        let noteID = try #require(scan.noteID)
        #expect(try library.store.note(id: noteID)?.text == "")
        #expect(!FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent(noteID).path))
    }

    @Test func scanResultCannotFollowSelectionOrLibrarySwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("first")))
        let second = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("second")))
        defer { try? first.close(); try? second.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { true })
        router.connect(first, ready: true)
        router.enqueue(.scan)
        try await router.drain()
        let scan = try #require(router.presentation)
        _ = try first.createNote()
        #expect(!router.canAcceptScan(scan))
        router.connect(second, ready: true)
        #expect(router.presentation == nil)
        #expect(!router.canAcceptScan(scan))
        #expect(try second.store.allNotes().isEmpty)
    }

    @Test func queuedRequestDoesNotMoveIntoAnotherLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("first")))
        let second = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("second")))
        defer { try? first.close(); try? second.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        router.enqueue(.newNote)
        router.connect(first, ready: false)
        router.connect(second, ready: true)
        await #expect(throws: MobileCaptureRouter.Failure.libraryChanged) { try await router.drain() }
        #expect(try first.store.allNotes().isEmpty && second.store.allNotes().isEmpty)
    }

    @Test func searchWaitsForUIAndDoesNotCreateANote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        router.connect(library, ready: false)
        router.enqueue(.search)
        try await router.drain()
        #expect(router.presentation == nil)
        router.connect(library, ready: true)
        try await router.drain()
        #expect(router.presentation?.action == .search)
        #expect(try library.store.allNotes().isEmpty)
    }

    @Test
    func unavailableScanNeverCreatesAFakeNote() async throws {
        let action = MobileCaptureRouter.Action.scan
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { false })
        router.connect(library, ready: true)
        router.enqueue(action)
        await #expect(throws: MobileCaptureRouter.Failure.scanUnavailable) {
            try await router.drain()
        }
        #expect(try library.store.allNotes().isEmpty)
        #expect(router.presentation == nil)
    }

    @Test func scanResultsFailClosedAfterAppLockOrReadOnlyChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { true })
        router.connect(library, ready: true)
        router.enqueue(.scan)
        try await router.drain()
        let scan = try #require(router.presentation)
        try await library.setAppLock(true, authenticate: {})
        library.lockApplication()
        #expect(!router.canAcceptScan(scan))
        try await library.setAppLock(true, authenticate: {})
        #expect(router.canAcceptScan(scan))
        try library.store.setReadOnly(#require(scan.noteID), readOnly: true)
        #expect(!router.canAcceptScan(scan))
    }

    @Test func cancelledDrainKeepsUnattemptedRequestForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        router.connect(library, ready: true)
        router.enqueue(.newNote)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await router.drain()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(router.pendingCount == 1)
        #expect(try library.store.allNotes().isEmpty)
        try await router.drain()
        #expect(try library.store.allNotes().count == 1)
    }


    @Test(arguments: [MobileCaptureRouter.Action.newNote, .newTodo, .thought, .scan])
    func cancellationAfterCommittedCreateResumesWithoutCreatingTwice(action: MobileCaptureRouter.Action) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        var release: CheckedContinuation<Void, Never>?
        var createdID: String?
        var creationCount = 0
        let router = MobileCaptureRouter(canScan: { true }, afterCreate: { _, id in
            createdID = id
            creationCount += 1
            try Task.checkCancellation()
            await withCheckedContinuation { release = $0 }
        })
        router.connect(library, ready: true)
        let delivery = UUID()
        router.enqueue(action, deliveryID: delivery)
        let running = Task { try await router.drain() }
        defer { running.cancel(); release?.resume() }
        for _ in 0..<200 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        let resume = try #require(release)
        #expect(!router.enqueue(action, deliveryID: delivery))
        #expect(router.pendingCount == 1)
        release = nil
        running.cancel()
        resume.resume()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(router.pendingCount == 1 && router.presentation == nil)
        #expect(try library.store.allNotes().count == 1)
        #expect(!router.enqueue(action, deliveryID: delivery))
        try await router.drain()
        #expect(creationCount == 1 && router.pendingCount == 0)
        #expect(library.selectedID == createdID)
        #expect(try library.store.allNotes().count == 1)
        #expect((router.presentation?.action == .scan) == (action == .scan))
    }

    @Test func failureAfterTodoCreateRetriesNavigationWithoutDuplicatingNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(afterCreate: { _, _ in throw CocoaError(.fileReadUnknown) })
        router.connect(library, ready: true)
        router.enqueue(.newTodo)
        await #expect(throws: CocoaError.self) { try await router.drain() }
        #expect(router.pendingCount == 1)
        #expect(try library.store.allNotes().count == 1)
        let created = try #require(try library.store.allNotes().first)
        try await router.drain()
        #expect(router.pendingCount == 0 && library.selectedID == created.id)
        #expect(try library.store.allNotes().count == 1)
    }


    @Test func onlyClaimingWindowCanAcceptOrFinishScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { true })
        router.connect(library, ready: true)
        router.enqueue(.scan)
        try await router.drain()
        let scan = try #require(router.presentation)
        let firstWindow = UUID(), otherWindow = UUID()
        #expect(router.claimPresentation(scan, owner: firstWindow))
        #expect(router.claimPresentation(scan, owner: firstWindow))
        #expect(!router.claimPresentation(scan, owner: otherWindow))
        #expect(router.canAcceptScan(scan, owner: firstWindow))
        #expect(!router.canAcceptScan(scan, owner: otherWindow))
        #expect(!router.canAcceptScan(scan))
        #expect(!router.finishPresentation(deliveryID: scan.id))
        #expect(!router.finishPresentation(deliveryID: scan.id, owner: otherWindow))
        #expect(router.presentation == scan && router.presentationOwner == firstWindow)
        #expect(!router.releasePresentation(deliveryID: scan.id, owner: otherWindow))
        #expect(router.releasePresentation(deliveryID: scan.id, owner: firstWindow))
        #expect(router.presentation == scan && router.presentationOwner == nil)
        #expect(router.claimPresentation(scan, owner: otherWindow))
        #expect(router.finishPresentation(deliveryID: scan.id, owner: otherWindow))
        #expect(router.presentation == nil && router.presentationOwner == nil)
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func librarySwitchInvalidatesClaimAndOldWindowCannotFinishNextPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("first")))
        let second = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("second")))
        defer { try? first.close(); try? second.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        let owner = UUID()
        router.connect(first, ready: true)
        router.enqueue(.search)
        try await router.drain()
        let old = try #require(router.presentation)
        #expect(router.claimPresentation(old, owner: owner))
        router.connect(second, ready: true)
        #expect(router.presentation == nil && router.presentationOwner == nil)
        router.enqueue(.search)
        try await router.drain()
        let next = try #require(router.presentation)
        #expect(!router.claimPresentation(old, owner: owner))
        #expect(!router.finishPresentation(deliveryID: old.id, owner: owner))
        #expect(router.claimPresentation(next, owner: owner))
        #expect(router.finishPresentation(deliveryID: next.id, owner: owner))
    }


    @Test func unclaimedScanAfterSelectionChangeIsDiscardedAndSearchProceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { true })
        router.connect(library, ready: true)
        router.enqueue(.scan)
        try await router.drain()
        let stale = try #require(router.presentation)
        _ = try library.createNote()
        router.enqueue(.search)
        #expect(router.discardUnclaimedStaleScan())
        #expect(!router.discardUnclaimedStaleScan())
        try await router.drain()
        #expect(router.presentation?.action == .search)
        #expect(router.pendingCount == 0)
        #expect(!router.finishPresentation(deliveryID: stale.id))
        #expect(try library.store.allNotes().count == 2)
    }

    @Test func staleScanDiscardDoesNotStealClaimOrRunWhileAppLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(canScan: { true })
        router.connect(library, ready: true)
        router.enqueue(.scan)
        try await router.drain()
        let scan = try #require(router.presentation)
        let owner = UUID()
        #expect(router.claimPresentation(scan, owner: owner))
        library.selectedID = nil
        #expect(!router.discardUnclaimedStaleScan())
        #expect(router.presentation == scan && router.presentationOwner == owner)
        #expect(router.releasePresentation(deliveryID: scan.id, owner: owner))
        try await library.setAppLock(true, authenticate: {})
        library.lockApplication()
        #expect(!router.discardUnclaimedStaleScan())
        #expect(router.presentation == scan && router.presentationOwner == nil)
        try await library.setAppLock(true, authenticate: {})
        #expect(router.discardUnclaimedStaleScan())
        #expect(router.presentation == nil)
    }

    @Test func voicePresentsWithoutCreatingAndBlocksQueueUntilOwningWindowDismisses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter()
        router.connect(library, ready: true)
        let delivery = UUID(), owner = UUID(), other = UUID()
        #expect(router.enqueue(.voice, deliveryID: delivery))
        #expect(!router.enqueue(.voice, deliveryID: delivery))
        router.enqueue(.newNote)
        try await router.drain()
        let request = try #require(router.presentation)
        #expect(request.action == .voice && request.noteID == nil)
        #expect(try library.store.allNotes().isEmpty)
        #expect(router.claimPresentation(request, owner: owner))
        #expect(!router.claimPresentation(request, owner: other))
        #expect(router.canAcceptVoice(request, owner: owner))
        #expect(!router.canAcceptVoice(request, owner: other))
        try await router.drain()
        #expect(router.pendingCount == 1)
        #expect(try library.store.allNotes().isEmpty)
        #expect(!router.finishPresentation(deliveryID: request.id, owner: other))
        #expect(router.finishPresentation(deliveryID: request.id, owner: owner))
        try await router.drain()
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func voiceWaitsForReadinessAndLockAndRejectsBackgroundOrOldLibraryClaims() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("first")))
        let second = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("second")))
        defer { try? first.close(); try? second.close(); try? FileManager.default.removeItem(at: root) }
        let router = MobileCaptureRouter(), owner = UUID()
        router.connect(first, ready: false)
        router.enqueue(.voice)
        try await router.drain()
        #expect(router.presentation == nil)
        try await first.setAppLock(true, authenticate: {})
        first.lockApplication()
        router.connect(first, ready: true)
        try await router.drain()
        #expect(router.presentation == nil && router.pendingCount == 1)
        try await first.setAppLock(true, authenticate: {})
        try await router.drain()
        let request = try #require(router.presentation)
        #expect(router.claimPresentation(request, owner: owner))
        router.connect(first, ready: false)
        #expect(!router.canAcceptVoice(request, owner: owner))
        router.connect(first, ready: true)
        first.lockApplication()
        #expect(!router.canAcceptVoice(request, owner: owner))
        #expect(try first.store.allNotes().isEmpty)
        router.connect(second, ready: true)
        #expect(!router.claimPresentation(request, owner: owner))
        #expect(!router.finishPresentation(deliveryID: request.id, owner: owner))
        #expect(try second.store.allNotes().isEmpty)
    }

    @Test func externalSheetLeasesStayBlockingUntilActualDismissAndIgnoreStaleCallbacks() {
        let gate = MobileCaptureModalGate()
        let attachment = UUID(), preview = UUID(), nextPreview = UUID()
        gate.presented(attachment)
        gate.presented(preview)
        #expect(gate.isPresented)
        gate.dismissed(preview)
        #expect(gate.isPresented) // Nested Quick Look closed, attachment actions still open.
        gate.dismissed(attachment)
        #expect(!gate.isPresented)
        gate.presented(nextPreview)
        gate.dismissed(preview) // A late callback from the prior controller cannot release this one.
        #expect(gate.isPresented)
        gate.dismissed(nextPreview)
        #expect(!gate.isPresented)
    }

}
