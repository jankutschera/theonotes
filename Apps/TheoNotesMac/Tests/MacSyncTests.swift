// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Security
import Testing
@testable import TheoNotes

private struct EmptyMacSync: SyncTransport, SyncBlobTransport {
    func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult { throw CancellationError() }
    func pull(after cursor: Int64) async throws -> SyncPullResult {
        try JSONDecoder().decode(SyncPullResult.self, from: Data(#"{"changes":[],"cursor":\#(cursor),"hasMore":false}"#.utf8))
    }
    func acknowledge(_ cursor: Int64) async throws {}
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL { throw CancellationError() }
}

@MainActor @Suite struct MacSyncTests {
    /// Runs in the signed app host: unsigned package tests cannot validate its Keychain entitlements.
    /// A unique namespace keeps this test separate from every real library and account.
    @Test(.enabled(if: HostEntitlements.hasKeychainAccessGroup, HostEntitlements.keychainSkipReason))
    func signedAppCanPersistSyncIdentityInDataProtectionKeychain() async throws {
        let namespace = "signing-test." + UUID().uuidString
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.truebrewbirdie.theonotes.sync",
            kSecAttrAccount: namespace,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
        defer {
            let status = SecItemDelete(query as CFDictionary)
            #expect(status == errSecSuccess || status == errSecItemNotFound)
        }
        let store = KeychainSyncStore(namespace: namespace)
        let first = try await store.identity()
        // Exercise update as well as insertion, then load through a fresh store instance.
        try await store.clearAuthentication()
        let restored = try await KeychainSyncStore(namespace: namespace).identity()
        #expect(first.id == restored.id)
        #expect(first.signingKey.publicKey.rawRepresentation == restored.signingKey.publicKey.rawRepresentation)
        #expect(first.transferKey.publicKey.rawRepresentation == restored.transferKey.publicKey.rawRepresentation)
    }

    @Test func missingEntitlementDoesNotTellUserToUnlockDevice() {
        let message = SyncKeychainError.status(errSecMissingEntitlement).localizedDescription
        #expect(message.contains("correctly signed update"))
        #expect(!message.contains("Unlock this device and try again"))
        #expect(SyncKeychainError.status(errSecInteractionNotAllowed).localizedDescription.contains("Unlock this device"))
    }

    private func environment() throws -> AppEnvironment {
        try AppEnvironment(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacSyncTests-\(UUID())")))
    }

    @Test func commitFlushesAcknowledgedLocalTextAndRefreshesTheOpenSession() async throws {
        let environment = try environment()
        defer { try? FileManager.default.removeItem(at: environment.paths.root) }
        let note = try environment.store.create(text: "base")
        let session = try environment.session(for: note.id)
        let edit = ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " local")])
        #expect(session.apply(txId: "local", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
        let store = environment.store
        let result = try await MacSyncCommitCoordinator(environment: environment).commit {
            let flushed = try store.note(id: note.id)!
            guard flushed.text == "base local" else { throw CocoaError(.fileReadCorruptFile) }
            _ = try store.updateText(id: note.id, text: flushed.text + " remote", expectedRevision: flushed.revision)
            return .applied
        }
        #expect(result == .applied)
        #expect(session.text == "base local remote")
        #expect(try environment.store.note(id: note.id)?.text == session.text)
    }

    @Test func durableChangeIsReconciledEvenWhenFileInstallationThrows() throws {
        let environment = try environment()
        defer { try? FileManager.default.removeItem(at: environment.paths.root) }
        let note = try environment.store.create(text: "before")
        let session = try environment.session(for: note.id), store = environment.store
        #expect(throws: CocoaError.self) {
            try environment.commitSyncedChange {
                _ = try store.updateText(id: note.id, text: "durable", expectedRevision: note.revision)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(session.text == "durable")
    }

    @Test func firstSyncBackupContainsAcknowledgedEditsAndCanBeVerified() async throws {
        let environment = try environment()
        defer { try? FileManager.default.removeItem(at: environment.paths.root) }
        let note = try environment.store.create(text: "draft")
        let session = try environment.session(for: note.id)
        #expect(session.apply(txId: "backup", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " saved")]), origin: nil) == .acked(revision: 1))
        let archive = try await environment.makeBackup()
        let summary = try LibraryBackup(database: environment.database, paths: environment.paths).inspect(archive)
        #expect(summary.noteCount == 1)
        #expect(try environment.store.note(id: note.id)?.text == "draft saved")
        #expect(try !SyncQueue(database: environment.database).isEnabled())
    }

    @Test func stoppedEnvironmentRejectsLateRemoteCommits() throws {
        let environment = try environment()
        defer { try? FileManager.default.removeItem(at: environment.paths.root) }
        environment.stopSync()
        #expect(throws: CancellationError.self) { try environment.commitSyncedChange { .applied } }
    }
    @Test func nextCycleCanUseTheRemotePasswordAfterARecoveryVaultConversion() async throws {
        let environment = try environment()
        defer { try? FileManager.default.removeItem(at: environment.paths.root) }
        let privacy = NotePrivacy(store: environment.store)
        let access = try privacy.setPassword("before conversion"); access.revoke()
        try privacy.changePassword(from: "before conversion", to: "after conversion")
        try SyncQueue(database: environment.database).configure(accountID: "account")
        let fake = EmptyMacSync()
        let engine = SyncEngine(database: environment.database, paths: environment.paths, accountID: "account",
                                vaultKey: SymmetricKey(size: .bits256), transport: fake, blobs: fake)
        let result = try await environment.synchronize(using: engine, notePassword: "before conversion", remoteNotePassword: "after conversion")
        #expect(result.pendingDownloads == 0)
        await engine.shutdown()
    }

}
