// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesWatch

@Suite @MainActor struct WatchCaptureSessionTests {
    @Test func uncertainCommitKeepsComposerTextAndEveryRetryUsesOriginalID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), library = String(repeating: "a", count: 64)
        try WatchCommandOutbox(url: url).bind(libraryID: library, epoch: UUID())
        let actions = TheoNotesWatchTransport(outboxURL: url), editor = WatchCaptureSession(draftID: UUID())
        actions.outbox?.beforeDirectorySyncForTesting = { throw WatchWireError.storage }
        editor.text = "Keep until confirmed"
        #expect(!editor.submit(actions: actions))
        let id = try #require(editor.pendingID)
        #expect(editor.cancelDisposition == .pendingRequest)
        #expect(editor.cancelDisposition.message.contains("may still be sent or applied"))
        #expect(editor.text == "Keep until confirmed" && actions.outbox?.pending.count == 1)
        #expect(actions.presentation.operations.first?.state == .waitingForStorage)
        #expect(!editor.submit(actions: actions))
        #expect(actions.outbox?.pending.map(\.id) == [id] && editor.text == "Keep until confirmed")
        actions.outbox?.beforeDirectorySyncForTesting = nil
        #expect(editor.submit(actions: actions))
        #expect(editor.text.isEmpty && actions.outbox?.pending.map(\.id) == [id])
    }
    @Test func cancelCopyDescribesSavedDraftWithoutClaimingDeletion() {
        let fresh = WatchCaptureSession(draftID: UUID())
        #expect(fresh.cancelDisposition == .unsavedText)
        let existing = WatchCaptureSession(draftID: UUID(), recoveryID: UUID())
        #expect(existing.cancelDisposition == .savedDraft)
        #expect(existing.cancelDisposition.message.contains("saved draft remains"))
        #expect(!existing.cancelDisposition.message.contains("Discard this dictated text"))
    }
    @Test(arguments: [false, true])
    func backgroundOrPrivacyPreservesUnqueuedDictationWithoutSending(privacy: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outbox.json"), id = UUID()
        let actions = TheoNotesWatchTransport(outboxURL: url), editor = WatchCaptureSession(draftID: id)
        editor.text = "Unqueued dictated text"
        if privacy { actions.receive(.redact) } else { actions.setForeground(false) }
        #expect(editor.protect(actions: actions))
        #expect(editor.text.isEmpty && editor.isProtected)
        let saved = try WatchCommandOutbox(url: url)
        #expect(saved.pending.isEmpty && saved.drafts.first?.id == id && saved.drafts.first?.text == "Unqueued dictated text")
        let restarted = TheoNotesWatchTransport(outboxURL: url)
        #expect(throws: WatchWireError.self) { try restarted.draftText(id: id) }
        #expect(!String(reflecting: restarted.presentation.drafts).contains("Unqueued dictated text"))
    }
    @Test func failedDraftSaveKeepsHiddenMemoryTextAndOriginalDraftIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = TheoNotesWatchTransport(outboxURL: root.appendingPathComponent("outbox.json"))
        let id = UUID(), editor = WatchCaptureSession(draftID: id)
        editor.text = "Not saved yet"
        actions.outbox?.beforeRenameForTesting = { throw WatchWireError.storage }
        #expect(!editor.protect(actions: actions))
        #expect(editor.text == "Not saved yet" && editor.isProtected && editor.notice == .draftSaveFailed)
        #expect(actions.outbox?.drafts.isEmpty == true && actions.outbox?.pending.isEmpty == true)
        actions.outbox?.beforeRenameForTesting = nil
        #expect(editor.protect(actions: actions))
        #expect(actions.outbox?.drafts.first?.id == id && actions.outbox?.drafts.first?.text == "Not saved yet")
    }
    @Test func newlyCreatedDirectoryParentMustSyncBeforeDraftSaveIsConfirmed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Application Support/WatchCommands/outbox.json"), outbox = try WatchCommandOutbox(url: url)
        var attemptedParent: URL?
        outbox.beforeParentDirectorySyncForTesting = { parent in attemptedParent = parent; throw WatchWireError.storage }
        #expect(throws: WatchWireError.storage) { try outbox.saveDraft(id: UUID(), text: "Protect new directory") }
        #expect(attemptedParent == url.deletingLastPathComponent().deletingLastPathComponent())
        #expect(outbox.requiresDurabilityRetry && outbox.drafts.first?.text == "Protect new directory")
        outbox.beforeParentDirectorySyncForTesting = nil
        try outbox.retryDurability()
        let restored = try WatchCommandOutbox(url: url)
        #expect(!outbox.requiresDurabilityRetry && restored.drafts.first?.text == "Protect new directory")
    }
}
