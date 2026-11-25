// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesWatch

@Suite @MainActor struct WatchWireTests {
    let library = String(repeating: "a", count: 64)
    @Test func legacyDraftCapacityCanBeUsedUpToThePersistedLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), epoch = UUID()
        let original = try WatchCommandOutbox(url: url)
        try original.bind(libraryID: library, epoch: epoch)
        var tree = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        tree["drafts"] = (0..<510).map { _ in ["id": UUID().uuidString, "text": "Preserve"] }
        try JSONSerialization.data(withJSONObject: tree).write(to: url)
        let outbox = try WatchCommandOutbox(url: url)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Pending"))
        try outbox.enqueue(command)
        try outbox.saveDraft(id: UUID(), text: "Final draft")
        #expect(throws: WatchWireError.capacity) { try outbox.saveDraft(id: UUID(), text: "Too many") }
        #expect(try outbox.acknowledge(.init(commandID: command.id, libraryID: library, epoch: epoch, result: .refused(.privacy))))
        let restored = try WatchCommandOutbox(url: url)
        #expect(restored.pending.isEmpty && restored.drafts.count == 512)
        #expect(restored.drafts.contains { $0.id == command.id && $0.text == "Pending" })
    }
    @Test func smallHelloClockSkewIsAllowedButFarFutureIsRejected() throws {
        let now = Date(), id = UUID()
        try WatchWireHello(id: id, issuedAt: now.addingTimeInterval(3), expiresAt: now.addingTimeInterval(33)).validate(now: now)
        #expect(throws: WatchWireError.self) {
            try WatchWireHello(id: id, issuedAt: now.addingTimeInterval(6), expiresAt: now.addingTimeInterval(36)).validate(now: now)
        }
    }
    @Test func malformedTaskIsDroppedWithoutHidingValidNote() throws {
        let now = Date(), id = UUID(), epoch = UUID()
        let bad = WatchWireTask(title: "bad", isChecked: false, sourceSHA256: "bad", utf16Offset: 0, expectedMarker: "[ ]")
        let good = WatchWireTask(title: "good", isChecked: false, sourceSHA256: library, utf16Offset: 0, expectedMarker: "[ ]")
        let note = WatchWireNote(id: UUID().uuidString, revision: 1, title: "Note", text: "- [ ] task", tasks: [bad, good])
        let snapshot = WatchWireSnapshot(libraryID: library, epoch: epoch, generation: 1, authorizationID: id, issuedAt: now, expiresAt: now.addingTimeInterval(30), redacted: false, notes: [note])
        let filtered = snapshot.sanitizingTasks()
        try filtered.validate(now: now)
        #expect(filtered.notes.count == 1 && filtered.notes[0].tasks == [good])
    }
    @Test func legacyFullDraftsCanStillPreservePendingRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .append(noteID: UUID().uuidString, revision: 1, text: "Keep this"))
        try outbox.enqueue(command)
        var tree = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        tree["drafts"] = (0..<256).map { _ in ["id": UUID().uuidString, "text": "Prior draft"] }
        try JSONSerialization.data(withJSONObject: tree).write(to: url)
        let restored = try WatchCommandOutbox(url: url)
        #expect(try restored.acknowledge(.init(commandID: command.id, libraryID: library, epoch: epoch, result: .refused(.privacy))))
        #expect(restored.pending.isEmpty && restored.drafts.count == 257)
        #expect(restored.drafts.contains { $0.id == command.id && $0.text == "Keep this" })
    }
    @Test func writerFailureBeforeRenamePreservesOldBytesAndAfterRenameBlocksSendsUntilSync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), outbox = try WatchCommandOutbox(url: url), epoch = UUID()
        try outbox.bind(libraryID: library, epoch: epoch)
        let saved = try Data(contentsOf: url)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Never discard"))
        outbox.beforeRenameForTesting = { throw WatchWireError.storage }
        #expect(throws: WatchWireError.storage) { try outbox.enqueue(command) }
        let retained = try Data(contentsOf: url)
        #expect(outbox.pending.isEmpty && retained == saved)
        outbox.beforeRenameForTesting = nil
        outbox.beforeDirectorySyncForTesting = { throw WatchWireError.storage }
        #expect(throws: WatchWireError.storage) { try outbox.enqueue(command) }
        #expect(outbox.pending == [command] && outbox.requiresDurabilityRetry)
        #expect(!outbox.mayDeliver(command, now: .now))
        #expect(try WatchCommandOutbox(url: url).pending == [command])
        outbox.beforeDirectorySyncForTesting = nil
        try outbox.retryDurability()
        #expect(!outbox.requiresDurabilityRetry && outbox.mayDeliver(command, now: .now))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func deliveryExpiryAndClockRollbackKeepTextUntilExplicitOriginalIDRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), epoch = UUID(), now = Date()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, createdAt: now, action: .create(text: "Keep expired dictation"))
        try outbox.enqueue(command, now: now)
        #expect(outbox.mayDeliver(command, now: now))
        try outbox.updateDeliveryClock(now: now.addingTimeInterval(WatchCommandOutbox.deliveryLifetime))
        #expect(!outbox.mayDeliver(command, now: now.addingTimeInterval(WatchCommandOutbox.deliveryLifetime)))
        let restarted = try WatchCommandOutbox(url: url)
        #expect(restarted.pending == [command])
        #expect(!restarted.mayDeliver(command, now: now.addingTimeInterval(5)))
        #expect(throws: WatchWireError.clock) { try restarted.renewDelivery(id: command.id, now: now.addingTimeInterval(5)) }
        let later = now.addingTimeInterval(WatchCommandOutbox.deliveryLifetime + 1)
        try restarted.renewDelivery(id: command.id, now: later)
        #expect(restarted.pending == [command] && restarted.mayDeliver(command, now: later))
        try restarted.updateDeliveryClock(now: later.addingTimeInterval(10))
        try restarted.updateDeliveryClock(now: later.addingTimeInterval(2))
        #expect(!restarted.mayDeliver(command, now: later.addingTimeInterval(11)))
    }
    @Test func wrongLibraryWaitsButOriginalEpochIsNeverRewritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try WatchCommandOutbox(url: root.appendingPathComponent("outbox.json")), epoch = UUID(), now = Date()
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, createdAt: now, action: .create(text: "Wrong library"))
        try outbox.enqueue(command, now: now)
        try outbox.bind(libraryID: String(repeating: "b", count: 64), epoch: UUID())
        #expect(!outbox.mayDeliver(command, now: now))
        try outbox.bind(libraryID: library, epoch: UUID())
        #expect(outbox.mayDeliver(command, now: now) && outbox.pending == [command])
    }
    @Test func retryCannotChangeCreationTimeOrExtendSevenDayLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try WatchCommandOutbox(url: root.appendingPathComponent("outbox.json")), now = Date(), epoch = UUID()
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, createdAt: now, action: .create(text: "Original capture"))
        try outbox.enqueue(command, now: now)
        let forged = WatchWireCommand(id: command.id, libraryID: library, epoch: epoch,
            createdAt: now.addingTimeInterval(86_400), action: command.action)
        #expect(throws: WatchWireError.invalid) { try outbox.enqueue(forged) }
        #expect(!outbox.mayDeliver(forged, now: now))
        try outbox.renewDelivery(id: command.id, now: now.addingTimeInterval(6.5 * 86_400))
        #expect(outbox.pending == [command] && outbox.delivery(for: command.id)?.createdAt == now)
        #expect(outbox.delivery(for: command.id)?.expiresAt == now.addingTimeInterval(WatchWireCommand.maximumAge))
        try outbox.renewDelivery(id: command.id, now: now.addingTimeInterval(8 * 86_400))
        #expect(!outbox.mayDeliver(command, now: now.addingTimeInterval(8 * 86_400)))
        #expect(outbox.pending.first?.createdAt == now)
        let ack = WatchWireAck(commandID: command.id, libraryID: library, epoch: epoch, result: .refused(.expired))
        #expect(try outbox.acknowledge(ack))
        #expect(outbox.drafts.first?.text == "Original capture")
        guard case .command(let decoded) = try WatchWirePacket.decode(WatchWirePacket.command(command).encoded()) else {
            Issue.record("Command did not round trip"); return
        }
        #expect(decoded == command && decoded.createdAt == now)
    }
    @Test func ackBindsExactCommandLibraryEpochAndTaskRevision() throws {
        let id = UUID().uuidString.lowercased(), epoch = UUID()
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch,
            action: .append(noteID: id, revision: 3, text: "Exact"))
        let ack = WatchWireAck(commandID: command.id, libraryID: library, epoch: epoch, result: .applied(noteID: id, revision: 4))
        #expect(ack.matches(command))
        #expect(!WatchWireAck(commandID: command.id, libraryID: library, epoch: UUID(), result: ack.result).matches(command))
        #expect(!WatchWireAck(commandID: command.id, libraryID: library, epoch: epoch, result: .applied(noteID: id, revision: 3)).matches(command))
        let task = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch,
            action: .setTask(noteID: id, revision: 3, sourceSHA256: library, utf16Offset: 2, expectedMarker: "[X]", checked: true))
        #expect(WatchWireAck(commandID: task.id, libraryID: library, epoch: epoch, result: .applied(noteID: id, revision: 3)).matches(task))
        #expect(!WatchWireAck(commandID: task.id, libraryID: library, epoch: epoch, result: .applied(noteID: id, revision: 4)).matches(task))
    }
    @Test func pendingSurvivesRestartAndOnlyMatchingAckClearsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("outbox.json"), epoch = UUID()
        let outbox = try WatchCommandOutbox(url: file)
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch, action: .create(text: "Unsent dictation"))
        try outbox.enqueue(command)
        let restarted = try WatchCommandOutbox(url: file)
        #expect(restarted.pending == [command])
        #expect(!((try restarted.acknowledge(WatchWireAck(commandID: UUID(), libraryID: library, epoch: epoch, result: .refused(.privacy))))))
        #expect(try WatchCommandOutbox(url: file).pending == [command])
        let ack = WatchWireAck(commandID: command.id, libraryID: library, epoch: epoch,
                               result: .applied(noteID: UUID().uuidString, revision: 0))
        #expect(try restarted.acknowledge(ack))
        let completed = try WatchCommandOutbox(url: file)
        #expect(completed.pending.isEmpty && completed.completed.first?.ack == ack)
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Unsent dictation"))
    }
    @Test func snapshotsRequireFreshHandshakeAndExpiryNeverReappears() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), epoch = UUID()
        let hello = WatchWireHello(id: UUID(), issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let note = WatchWireNote(id: UUID().uuidString, revision: 0, title: "Note", text: "Private", tasks: [])
        let snapshot = WatchWireSnapshot(libraryID: library, epoch: epoch, generation: 1, authorizationID: hello.id,
            issuedAt: now, expiresAt: hello.expiresAt, redacted: false, notes: [note])
        var gate = WatchSnapshotAuthorization()
        #expect(throws: WatchWireError.self) { try gate.accept(snapshot, now: now) }
        try gate.authorize(hello, now: now)
        try gate.accept(snapshot, now: now)
        #expect(gate.visibleNotes(now: now).count == 1)
        #expect(gate.visibleNotes(now: hello.expiresAt).isEmpty)
        #expect(gate.visibleNotes(now: now.addingTimeInterval(5)).isEmpty)
        #expect(throws: WatchWireError.self) { try gate.accept(snapshot, now: now.addingTimeInterval(5)) }
    }
    @Test(arguments: [false, true])
    func refusedTextIsRecoveredWithoutAutomaticRetryOrOldEpoch(append: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), oldEpoch = UUID(), newEpoch = UUID()
        let outbox = try WatchCommandOutbox(url: url)
        try outbox.bind(libraryID: library, epoch: oldEpoch)
        let action: WatchWireAction = append
            ? .append(noteID: UUID().uuidString, revision: 1, text: "Recover my dictation")
            : .create(text: "Recover my dictation")
        let original = WatchWireCommand(id: UUID(), libraryID: library, epoch: oldEpoch, action: action)
        try outbox.enqueue(original)
        #expect(try outbox.acknowledge(WatchWireAck(commandID: original.id, libraryID: library, epoch: oldEpoch, result: .refused(.epochMismatch))))
        let restarted = try WatchCommandOutbox(url: url)
        #expect(restarted.pending.isEmpty && restarted.drafts.first?.text == "Recover my dictation")
        try restarted.updateDraft(id: original.id, text: "Edited recovery")
        #expect(try WatchCommandOutbox(url: url).drafts.first?.text == "Edited recovery")
        try restarted.bind(libraryID: library, epoch: newEpoch)
        #expect(throws: WatchWireError.self) {
            try restarted.recoverDraft(id: original.id, command: WatchWireCommand(id: UUID(), libraryID: library,
                epoch: oldEpoch, action: .create(text: "Wrong epoch")))
        }
        #expect(restarted.drafts.first?.text == "Edited recovery" && restarted.pending.isEmpty)
        let replacement = WatchWireCommand(id: UUID(), libraryID: library, epoch: newEpoch, action: .create(text: "Edited recovery"))
        try restarted.recoverDraft(id: original.id, command: replacement)
        let recovered = try WatchCommandOutbox(url: url)
        #expect(recovered.drafts.isEmpty && recovered.pending == [replacement])
        #expect(replacement.id != original.id && replacement.epoch == newEpoch)
    }
    @Test func taskRefusalDoesNotPersistSnapshotSourceAsRecoveryText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try WatchCommandOutbox(url: root.appendingPathComponent("outbox.json")), epoch = UUID()
        try outbox.bind(libraryID: library, epoch: epoch)
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: epoch,
            action: .setTask(noteID: UUID().uuidString, revision: 1, sourceSHA256: library, utf16Offset: 2, expectedMarker: "[ ]", checked: true))
        try outbox.enqueue(command)
        #expect(try outbox.acknowledge(WatchWireAck(commandID: command.id, libraryID: library, epoch: epoch, result: .refused(.privacy))))
        #expect(outbox.pending.isEmpty && outbox.drafts.isEmpty)
    }
    @Test func malformedOversizedAndRedactedPayloadsFailClosed() throws {
        let command = WatchWireCommand(id: UUID(), libraryID: library, epoch: UUID(), action: .create(text: "\0"))
        #expect(throws: WatchWireError.self) { try command.validate() }
        #expect(throws: WatchWireError.self) { try WatchWirePacket.decode(Data(repeating: 0, count: WatchWirePacket.maximumBytes + 1)) }
        let now = Date(), note = WatchWireNote(id: UUID().uuidString, revision: 0, title: "", text: "Private", tasks: [])
        let snapshot = WatchWireSnapshot(libraryID: library, epoch: UUID(), generation: 0, authorizationID: UUID(),
            issuedAt: now, expiresAt: now.addingTimeInterval(30), redacted: true, notes: [note])
        #expect(throws: WatchWireError.self) { try snapshot.validate(now: now) }
    }
}
