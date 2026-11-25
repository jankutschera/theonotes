// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Security

public enum SyncKeychainError: Error, LocalizedError {
    case status(OSStatus), invalidState, accountMismatch
    public var errorDescription: String? {
        switch self {
        case .status(errSecMissingEntitlement):
            "This app build is missing the Keychain access entitlement required for sync. Install a correctly signed update; unlocking the device will not fix this error (-34018)."
        case .status(errSecInteractionNotAllowed):
            "Sync credentials are unavailable while Keychain access is locked or interaction is not allowed. Unlock this device and try again (-25308)."
        case .status(let status):
            "Sync credentials could not be accessed in Keychain (\(status)). Try again; if the error persists, contact support."
        case .invalidState: "The saved sync identity is invalid. Reconnect this device using your passkey and recovery key."
        case .accountMismatch: "The saved device belongs to a different sync account."
        }
    }
}

public struct SyncDeviceIdentity: Sendable {
    public let id: String
    public let signingKey: Curve25519.Signing.PrivateKey
    public let transferKey: Curve25519.KeyAgreement.PrivateKey
}

public struct StoredSyncAccount: Sendable {
    public let keys: AccountKeys
    public let envelope: AccountKeyEnvelope
    /// Present only until the first setup's explicit recovery-key confirmation completes.
    public let pendingRecoveryWords: String?
}

public struct PendingSyncTransfer: Codable, Equatable, Sendable {
    public let transferID: String
    public let verificationWords: String
    public let expiresAt: Int64
}

/// One atomic Keychain item, serialized by this actor. After-first-unlock allows encrypted
/// background sync; ThisDeviceOnly and synchronizable=false prevent cloud keychain migration.
/// The note-password vault remains a separate, explicitly authenticated privacy boundary.
public actor KeychainSyncStore: SyncCredentialStore {
    /// The keychain service of every sync item. Pinned by `AppIdentityTests`: the installed app's items live under it.
    public static let keychainService = AppIdentity.syncKeychainService

    private struct SavedAccount: Codable {
        let envelope: AccountKeyEnvelope
        let wrappedMasterKey: String
        var pendingRecoveryWords: String?
        var pendingTransfer: PendingSyncTransfer?
    }
    private struct State: Codable {
        var version = 1
        let deviceID: String
        let signingKey: Data
        let transferKey: Data
        let wrappingKey: Data
        var credentials: SyncCredentials?
        var account: SavedAccount?
        var rotation: PendingRecoveryRotation?
    }
    private let namespace: String

    /// Use a stable namespace per library/service, never the changing iOS container path.
    public init(namespace: String) { self.namespace = namespace }

    public func identity() throws -> SyncDeviceIdentity {
        let state: State
        if let existing = try read() { state = existing }
        else {
            let fresh = State(deviceID: UUIDv7.make(), signingKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                              transferKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                              wrappingKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            let status = try insert(fresh)
            if status == errSecDuplicateItem {
                guard let existing = try read() else { throw SyncKeychainError.invalidState }
                state = existing
            } else {
                guard status == errSecSuccess else { throw SyncKeychainError.status(status) }
                state = fresh
            }
        }
        return SyncDeviceIdentity(id: state.deviceID,
                                  signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: state.signingKey),
                                  transferKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.transferKey))
    }

    public func load() throws -> SyncCredentials? { try read()?.credentials }

    public func save(_ credentials: SyncCredentials) throws {
        guard var state = try read(), credentials.deviceId == state.deviceID else { throw SyncKeychainError.invalidState }
        try SyncWire.validateID(credentials.accountId)
        guard state.credentials == nil || state.credentials?.accountId == credentials.accountId,
              state.account == nil || state.account?.envelope.accountId == credentials.accountId else { throw SyncKeychainError.accountMismatch }
        guard try SyncWire.decode64(credentials.accessToken).count == 32,
              try SyncWire.decode64(credentials.refreshToken).count == 32,
              credentials.accessExpiresAt > 0, credentials.refreshExpiresAt > credentials.accessExpiresAt else { throw SyncKeychainError.invalidState }
        state.credentials = credentials
        try write(state)
    }

    public func saveAccount(_ keys: AccountKeys, envelope: AccountKeyEnvelope, pendingRecoveryWords: String? = nil) throws {
        try persistAccount(keys, envelope: envelope, pendingRecoveryWords: pendingRecoveryWords, pendingTransfer: nil)
    }

    /// Store received keys atomically, but keep them unavailable to account() until the
    /// user has compared the six words with the sending device.
    public func saveTransferredAccount(_ keys: AccountKeys, envelope: AccountKeyEnvelope,
                                       transferID: String, verificationWords: String, expiresAt: Int64) throws {
        try SyncWire.validateID(transferID)
        let words = verificationWords.split(separator: " ").map(String.init)
        let dictionary = Set(try RecoveryKey.wordList())
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        guard words.count == 6, words.allSatisfy(dictionary.contains), expiresAt > now, expiresAt <= now + 600_000 else { throw SyncKeychainError.invalidState }
        if let existing = try read()?.account {
            guard existing.pendingTransfer?.transferID == transferID else { throw SyncKeychainError.invalidState }
        }
        let pending = PendingSyncTransfer(transferID: transferID, verificationWords: verificationWords, expiresAt: expiresAt)
        try persistAccount(keys, envelope: envelope, pendingRecoveryWords: nil, pendingTransfer: pending)
    }

    private func persistAccount(_ keys: AccountKeys, envelope: AccountKeyEnvelope,
                                pendingRecoveryWords: String?, pendingTransfer: PendingSyncTransfer?) throws {
        guard var state = try read(), state.credentials?.accountId == keys.accountID,
              envelope.accountId == keys.accountID else { throw SyncKeychainError.accountMismatch }
        if let pendingRecoveryWords {
            // Refuse a mismatched recovery phrase before persisting an unrecoverable account.
            let recovered = try AccountKeys(recovery: RecoveryKey(words: pendingRecoveryWords), envelope: envelope)
            guard recovered.vaultKey.withUnsafeBytes({ Data($0) }) == keys.vaultKey.withUnsafeBytes({ Data($0) }) else { throw SyncKeychainError.invalidState }
        }
        let wrapped = try keys.deviceWrappedMasterKey(deviceID: state.deviceID, wrappingKey: SymmetricKey(data: state.wrappingKey))
        // Validate the supplied envelope against the actual master key even on QR transfer.
        _ = try AccountKeys(deviceWrappedMasterKey: wrapped, deviceID: state.deviceID,
                            wrappingKey: SymmetricKey(data: state.wrappingKey), envelope: envelope)
        state.account = SavedAccount(envelope: envelope, wrappedMasterKey: wrapped,
                                     pendingRecoveryWords: pendingRecoveryWords, pendingTransfer: pendingTransfer)
        try write(state)
    }

    public func account() throws -> StoredSyncAccount? {
        guard let state = try read(), let account = state.account, account.pendingTransfer == nil else { return nil }
        guard state.credentials?.accountId == account.envelope.accountId else { throw SyncKeychainError.accountMismatch }
        let keys = try AccountKeys(deviceWrappedMasterKey: account.wrappedMasterKey, deviceID: state.deviceID,
                                   wrappingKey: SymmetricKey(data: state.wrappingKey), envelope: account.envelope)
        return StoredSyncAccount(keys: keys, envelope: account.envelope, pendingRecoveryWords: account.pendingRecoveryWords)
    }

    public func pendingTransfer() throws -> PendingSyncTransfer? { try read()?.account?.pendingTransfer }

    public func confirmTransferredAccount() throws {
        guard var state = try read(), let pending = state.account?.pendingTransfer else { throw SyncKeychainError.invalidState }
        guard pending.expiresAt > Int64(Date.now.timeIntervalSince1970 * 1000) else { throw AccountKeyError.expiredTransfer }
        state.account?.pendingTransfer = nil
        try write(state)
    }

    public func discardUnconfirmedTransfer() throws {
        guard var state = try read(), state.account?.pendingTransfer != nil else { return }
        state.account = nil
        try write(state)
    }

    public func confirmRecoverySaved() throws {
        guard var state = try read(), state.account != nil else { throw SyncKeychainError.invalidState }
        state.account?.pendingRecoveryWords = nil
        try write(state)
    }

    public func pendingRecoveryRotation() throws -> PendingRecoveryRotation? { try read()?.rotation }

    public func stageRecoveryRotation(_ proposal: PendingRecoveryRotation) throws {
        guard var state = try read(), let saved = state.account, state.rotation == nil,
              saved.envelope == proposal.previousEnvelope, !proposal.confirmed,
              proposal.parentRevision > 0, let current = try account() else { throw SyncKeychainError.invalidState }
        _ = try current.keys.replacingRecoveryEnvelope(proposal.envelope)
        let recovered = try AccountKeys(recovery: RecoveryKey(words: proposal.words), envelope: proposal.envelope)
        guard recovered.vaultKey.withUnsafeBytes({ Data($0) }) == current.keys.vaultKey.withUnsafeBytes({ Data($0) }) else { throw SyncKeychainError.invalidState }
        state.rotation = proposal
        try write(state)
    }

    public func confirmRecoveryRotationSaved() throws -> PendingRecoveryRotation {
        guard var state = try read(), var proposal = state.rotation else { throw SyncKeychainError.invalidState }
        proposal.confirmed = true; state.rotation = proposal
        try write(state)
        return proposal
    }

    public func discardRecoveryRotation() throws {
        guard var state = try read() else { return }
        state.rotation = nil; try write(state)
    }

    /// A device already holding the master key can follow a recovery rewrap without asking
    /// for the new phrase. Authenticate the new vault wrapper with that same master first.
    public func adoptRecoveryEnvelope(_ envelope: AccountKeyEnvelope) throws {
        guard var state = try read(), let saved = state.account, let current = try account() else { throw SyncKeychainError.invalidState }
        let keys = try current.keys.replacingRecoveryEnvelope(envelope)
        let wrapped = try keys.deviceWrappedMasterKey(deviceID: state.deviceID, wrappingKey: SymmetricKey(data: state.wrappingKey))
        state.account = SavedAccount(envelope: envelope, wrappedMasterKey: wrapped,
                                    pendingRecoveryWords: saved.envelope == envelope ? saved.pendingRecoveryWords : nil,
                                    pendingTransfer: nil)
        if state.rotation?.envelope == envelope { state.rotation = nil }
        try write(state)
    }

    /// The caller first awaits transport/enrollment shutdown, preventing a late token save.
    /// Keep the device identity so reconnecting doesn't consume another device slot.
    public func clearAuthentication() throws {
        guard var state = try read() else { return }
        state.credentials = nil; state.account = nil; state.rotation = nil
        try write(state)
    }

    private func query() -> [CFString: Any] {
        var value: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService, kSecAttrAccount: namespace,
            kSecAttrSynchronizable: false]
        #if os(macOS)
        value[kSecUseDataProtectionKeychain] = true
        #endif
        return value
    }

    private func read() throws -> State? {
        var query = query()
        query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncKeychainError.status(status) }
        guard let data = result as? Data, data.count <= 65_536,
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
              state.signingKey.count == 32, state.transferKey.count == 32, state.wrappingKey.count == 32 else { throw SyncKeychainError.invalidState }
        try SyncWire.validateID(state.deviceID)
        return state
    }

    private func insert(_ state: State) throws -> OSStatus {
        var attributes = query()
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData] = try JSONEncoder().encode(state)
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func write(_ state: State) throws {
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(state),
                                         kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw SyncKeychainError.status(status) }
    }
}
