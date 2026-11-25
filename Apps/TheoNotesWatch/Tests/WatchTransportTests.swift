// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesWatch

@Suite @MainActor struct WatchTransportTests {
    @Test(arguments: [false, true]) func savedLocationSurvivesAckAndRestart(archived: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "a", count: 64), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Saved"))
        try outbox.enqueue(command)
        let transport = TheoNotesWatchTransport(outboxURL: url)
        let result: WatchWireResult = archived ? .appliedArchived(noteID: UUID().uuidString, revision: 0) : .appliedTrashed(noteID: UUID().uuidString, revision: 0)
        transport.receive(.ack(.init(commandID: command.id, libraryID: library, epoch: epoch, result: result)))
        let expected: WatchOperationState = archived ? .appliedArchived : .appliedTrashed
        #expect(transport.presentation.operations.first(where: { $0.id == command.id })?.state == expected)
        let restarted = TheoNotesWatchTransport(outboxURL: url)
        #expect(restarted.presentation.operations.first(where: { $0.id == command.id })?.state == expected)
    }
    @Test func restoredEpochRefusalPreservesAppendAndAsksToCheckTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "a", count: 64), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let append = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch,
            action: .append(noteID: UUID().uuidString, revision: 1, text: "Keep appended words"))
        let task = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch,
            action: .setTask(noteID: UUID().uuidString, revision: 1, sourceSHA256: library, utf16Offset: 2, expectedMarker: "[ ]", checked: true))
        try outbox.enqueue(append); try outbox.enqueue(task)
        let transport = TheoNotesWatchTransport(outboxURL: url)
        for command in [append, task] {
            transport.receive(.ack(.init(commandID: command.id, libraryID: library, epoch: epoch, result: .refused(.epochMismatch))))
        }
        let saved = try WatchCommandOutbox(url: url)
        #expect(saved.pending.isEmpty && saved.drafts.count == 1)
        #expect(saved.drafts.first?.id == append.id && saved.drafts.first?.text == "Keep appended words")
        let appendResult = try #require(transport.presentation.operations.first(where: { $0.id == append.id }))
        let taskResult = try #require(transport.presentation.operations.first(where: { $0.id == task.id }))
        #expect(appendResult.state == .refused(.epochMismatch) && appendResult.kind == .append)
        #expect(taskResult.state == .refused(.epochMismatch) && taskResult.kind == .task)
        #expect(WatchRefusalReason.epochMismatch.message(for: appendResult.kind).contains("may already have been applied before the restore"))
        #expect(WatchRefusalReason.epochMismatch.message(for: taskResult.kind).contains("Check the task"))
    }
    @Test func waitingDictationMovesToDraftAndLateAckCannotDiscardIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "a", count: 64), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Recover me"))
        try outbox.enqueue(command)
        try outbox.bind(libraryID: String(repeating: "b", count: 64), epoch: UUID())
        let transport = TheoNotesWatchTransport(outboxURL: url)
        try transport.keepDictation(id: command.id)
        let restored = try WatchCommandOutbox(url: url)
        #expect(restored.pending.isEmpty && restored.drafts.first?.text == "Recover me")
        transport.receive(.ack(.init(commandID: command.id, libraryID: library, epoch: epoch, result: .applied(noteID: UUID().uuidString, revision: 1))))
        #expect(try WatchCommandOutbox(url: url).drafts.first?.text == "Recover me")
    }
    @Test func expiredAppendKeepsTextAndFailedMoveLeavesOriginalPending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "a", count: 64), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url), now = Date()
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, createdAt: now, action: .append(noteID: UUID().uuidString, revision: 1, text: "Keep my append"))
        try outbox.enqueue(command, now: now)
        try outbox.updateDeliveryClock(now: now.addingTimeInterval(WatchCommandOutbox.deliveryLifetime + 1))
        outbox.beforeRenameForTesting = { throw WatchWireError.storage }
        #expect(throws: WatchWireError.storage) { try outbox.keepPendingDictation(id: command.id) }
        #expect(outbox.pending == [command] && outbox.drafts.isEmpty)
        outbox.beforeRenameForTesting = nil
        let transport = TheoNotesWatchTransport(outboxURL: url)
        try transport.keepDictation(id: command.id)
        let saved = try WatchCommandOutbox(url: url)
        #expect(saved.pending.isEmpty && saved.drafts.first?.text == "Keep my append")
    }
    @Test func emptyContextDoesNotClaimPrivacyLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = TheoNotesWatchTransport(outboxURL: root.appendingPathComponent("outbox.json"))
        transport.presentation.notice = nil
        transport.receiveEmptyContext()
        #expect(transport.presentation.notice != .privacy)
    }
    @Test func wrongLibraryIsVisibleAndExpiredCommandsStayProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "d", count: 64), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Waiting capture"))
        try outbox.enqueue(command)
        try outbox.bind(libraryID: String(repeating: "e", count: 64), epoch: UUID())
        let waiting = TheoNotesWatchTransport(outboxURL: url)
        #expect(waiting.presentation.operations.first?.state == .waitingForLibrary)
        #expect(waiting.presentation.operations.first?.expiresAt != nil)
        #expect(throws: WatchWireError.binding) { try waiting.retryRequest(id: command.id) }
        let resumed = try WatchCommandOutbox(url: url)
        try resumed.bind(libraryID: library, epoch: UUID())
        try resumed.updateDeliveryClock(now: Date().addingTimeInterval(WatchCommandOutbox.deliveryLifetime + 1))
        #expect(resumed.pending == [command])
        let expired = TheoNotesWatchTransport(outboxURL: url)
        #expect(expired.presentation.operations.first?.state == .expired)
        #expect(try WatchCommandOutbox(url: url).pending == [command])
    }
    @Test func offlineQueueKeepsUUIDUntilDurableAckAndRestartRestoresStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "b", count: 64), epoch = UUID()
        try WatchCommandOutbox(url: url).bind(libraryID: library, epoch: epoch)
        let transport = TheoNotesWatchTransport(outboxURL: url)
        let id = try transport.create(text: "Exact dictation")
        let command = try #require(WatchCommandOutbox(url: url).pending.first)
        #expect(command.id == id && command.action == .create(text: "Exact dictation"))
        #expect(transport.presentation.operations.first?.state == .queued)
        let restarted = TheoNotesWatchTransport(outboxURL: url)
        #expect(restarted.presentation.operations.first?.id == id)
        restarted.receive(.ack(WatchWireAck(commandID: id, libraryID: library, epoch: UUID(), result: .refused(.privacy))))
        #expect(try WatchCommandOutbox(url: url).pending == [command])
        restarted.receive(.ack(WatchWireAck(commandID: id, libraryID: library, epoch: epoch,
                                          result: .applied(noteID: UUID().uuidString, revision: 0))))
        #expect(try WatchCommandOutbox(url: url).pending.isEmpty)
        #expect(restarted.presentation.operations.first?.state == .applied)
        #expect(TheoNotesWatchTransport(outboxURL: url).presentation.operations.first?.state == .applied)
    }
    @Test func redactionIsUnconditionalAndBackgroundClearsPrivateProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = TheoNotesWatchTransport(outboxURL: root.appendingPathComponent("outbox.json"))
        transport.presentation.notes = [.init(id: UUID(), revision: 0, title: "Private", text: "Never persisted", tasks: [])]
        transport.presentation.isAuthorized = true
        transport.presentation.isReachable = true
        transport.presentation.authorizationDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        transport.receive(.redact)
        #expect(transport.presentation.visibleNotes.isEmpty && transport.presentation.notes.isEmpty)
        #expect(transport.presentation.notice == .privacy)
        transport.presentation.notes = [.init(id: UUID(), revision: 0, title: "Private", text: "Never persisted", tasks: [])]
        transport.setForeground(false)
        #expect(transport.presentation.notes.isEmpty && !transport.presentation.isAuthorized)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outbox.json").path))
    }
    @Test func refusedDraftCannotBeReadOrRequeuedAfterColdStartOrBackground() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "c", count: 64), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Saved dictation"))
        try outbox.enqueue(command)
        try outbox.acknowledge(WatchWireAck(commandID: command.id, libraryID: library, epoch: epoch, result: .refused(.privacy)))
        let transport = TheoNotesWatchTransport(outboxURL: url)
        #expect(transport.presentation.drafts.map(\.id) == [command.id])
        #expect(throws: WatchWireError.self) { try transport.draftText(id: command.id) }
        #expect(throws: WatchWireError.self) { try transport.recoverDraft(id: command.id, text: "Changed") }
        transport.setForeground(false)
        #expect(throws: WatchWireError.self) { try transport.draftText(id: command.id) }
        let restarted = try WatchCommandOutbox(url: url)
        #expect(restarted.pending.isEmpty && restarted.drafts.first?.text == "Saved dictation")
        #expect(!String(reflecting: transport.presentation.drafts).contains("Saved dictation"))
    }
    // WatchConnectivity calls both handlers on a background queue; 1.0.0 (1) trapped there on a real Watch.
    // The handlers must stay Sendable and nonisolated: this only compiles while they are.
    @Test func helloHandlersRunOffTheMainThread() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = TheoNotesWatchTransport(outboxURL: root.appendingPathComponent("outbox.json"))
        let handlers = transport.helloHandlers(id: UUID())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                handlers.reply(["wire": Data()]); handlers.error(CocoaError(.featureUnsupported)); done.resume()
            }
        }
    }
}
