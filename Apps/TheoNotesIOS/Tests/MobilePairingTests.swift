// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Security
import Testing

struct MobilePairingTests {
    @Test func receivedKeysStayInactiveAcrossReopenUntilConfirmed() async throws {
        let namespace = "pairing-test." + UUID().uuidString
        defer { removeTestIdentity(namespace) }
        let store = KeychainSyncStore(namespace: namespace)
        let identity = try await store.identity()
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        try await store.save(SyncCredentials(accountId: "account", deviceId: identity.id,
            accessToken: SyncWire.base64(Data(repeating: 1, count: 32)), refreshToken: SyncWire.base64(Data(repeating: 2, count: 32)),
            accessExpiresAt: now + 600_000, refreshExpiresAt: now + 86_400_000))
        let account = try AccountKeys(accountID: "account"), envelope = try account.envelope(recovery: RecoveryKey())
        let transfer = try account.transfer(to: identity.transferKey.publicKey, transferID: "test-transfer", expiresAt: Date.now.addingTimeInterval(590))
        let received = try AccountKeys.receive(transfer.package, privateKey: identity.transferKey, envelope: envelope)
        try await store.saveTransferredAccount(received.keys, envelope: envelope, transferID: "test-transfer",
            verificationWords: received.verificationWords, expiresAt: transfer.package.expiresAt)
        #expect(try await store.account() == nil)
        let reopened = KeychainSyncStore(namespace: namespace)
        #expect(try await reopened.account() == nil)
        #expect(try await reopened.pendingTransfer()?.verificationWords == transfer.verificationWords)
        try await reopened.confirmTransferredAccount()
        #expect(try await reopened.pendingTransfer() == nil)
        let activated = try #require(try await reopened.account())
        #expect(activated.keys.vaultKey.withUnsafeBytes { Data($0) } == account.vaultKey.withUnsafeBytes { Data($0) })
        await #expect(throws: Error.self) {
            try await reopened.saveTransferredAccount(received.keys, envelope: envelope, transferID: "test-transfer",
                verificationWords: received.verificationWords, expiresAt: transfer.package.expiresAt)
        }
        try await reopened.discardUnconfirmedTransfer()
        #expect(try await reopened.account() != nil)
    }

    @Test func cancellationDiscardsOnlyUnconfirmedKeys() async throws {
        let namespace = "pairing-test." + UUID().uuidString
        defer { removeTestIdentity(namespace) }
        let store = KeychainSyncStore(namespace: namespace), identity = try await store.identity()
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        try await store.save(SyncCredentials(accountId: "account", deviceId: identity.id,
            accessToken: SyncWire.base64(Data(repeating: 1, count: 32)), refreshToken: SyncWire.base64(Data(repeating: 2, count: 32)),
            accessExpiresAt: now + 600_000, refreshExpiresAt: now + 86_400_000))
        let account = try AccountKeys(accountID: "account"), envelope = try account.envelope(recovery: RecoveryKey())
        let transfer = try account.transfer(to: identity.transferKey.publicKey, transferID: "cancelled", expiresAt: Date.now.addingTimeInterval(590))
        try await store.saveTransferredAccount(account, envelope: envelope, transferID: "cancelled",
            verificationWords: transfer.verificationWords, expiresAt: transfer.package.expiresAt)
        try await store.discardUnconfirmedTransfer()
        #expect(try await store.account() == nil)
        #expect(try await store.pendingTransfer() == nil)
        #expect(try await store.load()?.accountId == "account")
        #expect(try await store.identity().id == identity.id)
        await #expect(throws: Error.self) { try await store.confirmTransferredAccount() }
    }

    private func removeTestIdentity(_ namespace: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: AppIdentity.syncKeychainService,
                       kSecAttrAccount: namespace, kSecAttrSynchronizable: false] as CFDictionary)
    }
}
