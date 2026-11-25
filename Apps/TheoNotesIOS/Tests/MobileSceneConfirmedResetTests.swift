// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneConfirmedResetTests {
    @Test func onlyConfirmedInvalidatedSessionIsSkippedAndOtherSessionFlushes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let target = try library.store.create(text: "target"), other = try library.store.create(text: "other")
        let targetEditor = MobileEditor(library: library), otherEditor = MobileEditor(library: library)
        targetEditor.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        otherEditor.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        try targetEditor.open(target.id); try otherEditor.open(other.id)
        let targetSession = try #require(targetEditor.session), otherSession = try #require(otherEditor.session)
        let edit = ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!")])
        #expect(otherSession.apply(txId: "pending", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
        try targetSession.invalidate()
        let registry = MobileSceneRegistry()
        try registry.register(sceneID: UUID(), editor: targetEditor, activity: .active)
        try registry.register(sceneID: UUID(), editor: otherEditor, activity: .active)
        do {
            let invalid = try await registry.freezeAll(confirmedResetInvalidatedIDs: [other.id])
            invalid.release()
            Issue.record("An unrelated ID must not admit an invalidated session")
        } catch { }
        #expect(!targetEditor.isClosedForPrivacy && !otherEditor.isClosedForPrivacy)
        let lease = try await registry.freezeAll(confirmedResetInvalidatedIDs: [target.id])
        try lease.detachEditors(); lease.release()
        #expect(targetEditor.isClosedForPrivacy && otherEditor.isClosedForPrivacy)
        #expect(try library.store.note(id: other.id)?.text == "other!")
    }
}
