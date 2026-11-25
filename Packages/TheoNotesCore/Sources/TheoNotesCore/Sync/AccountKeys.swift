// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public enum AccountKeyError: Error, Equatable {
    case invalidRecoveryKey, invalidEnvelope, expiredTransfer, wrongRecipient
}

/// A printable encoding of 256 random bits plus the BIP39 checksum. This is not a wallet:
/// Theo Notes uses the decoded entropy directly in domain-separated HKDF, not BIP39's seed KDF.
public struct RecoveryKey: Sendable {
    private let secret: Data
    public init() { secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    init(secret: Data) throws {
        guard secret.count == 32 else { throw AccountKeyError.invalidRecoveryKey }
        self.secret = secret
    }
    public init(words: String) throws {
        let list = try Self.wordList()
        let words = words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 24 else { throw AccountKeyError.invalidRecoveryKey }
        let lookup = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.element, $0.offset) })
        var bits: [UInt8] = []
        for word in words {
            guard let index = lookup[word] else { throw AccountKeyError.invalidRecoveryKey }
            bits += (0..<11).reversed().map { UInt8((index >> $0) & 1) }
        }
        var bytes = Data()
        for start in stride(from: 0, to: 264, by: 8) {
            bytes.append(bits[start..<start + 8].reduce(0) { ($0 << 1) | $1 })
        }
        let entropy = Data(bytes.prefix(32))
        guard Data(SHA256.hash(data: entropy)).first == bytes.last else { throw AccountKeyError.invalidRecoveryKey }
        secret = entropy
    }
    public func words() throws -> String {
        let list = try Self.wordList()
        let bytes = secret + Data(SHA256.hash(data: secret).prefix(1))
        let bits = bytes.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        return stride(from: 0, to: 264, by: 11).map { start in
            list[bits[start..<start + 11].reduce(0) { ($0 << 1) | Int($1) }]
        }.joined(separator: " ")
    }
    public func signingKey(accountID: String) throws -> Curve25519.Signing.PrivateKey {
        let key = try derive(accountID: accountID, purpose: "recovery-signing")
        return try Curve25519.Signing.PrivateKey(rawRepresentation: key.withUnsafeBytes { Data($0) })
    }
    func wrappingKey(accountID: String) throws -> SymmetricKey { try derive(accountID: accountID, purpose: "recovery-wrapping") }
    private func derive(accountID: String, purpose: String) throws -> SymmetricKey {
        try SyncWire.validateID(accountID)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(accountID.utf8),
                                     info: Data("\(ProtocolLabels.account):\(purpose)".utf8), outputByteCount: 32)
    }
    static func wordList() throws -> [String] {
        guard let url = Bundle.module.url(forResource: "recovery-english", withExtension: "txt") else { throw AccountKeyError.invalidRecoveryKey }
        let data = try Data(contentsOf: url)
        guard SyncWire.hash(data) == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda" else { throw AccountKeyError.invalidRecoveryKey }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

public struct AccountKeyEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let algorithm: String
    public let accountId: String
    public let wrappedMasterKey: String
    public let wrappedVaultKey: String
    public let recoveryPublicKey: String
}

/// Never persisted as Codable. The app stores only `deviceWrappedMasterKey` and the public
/// envelope; its device wrapping key is a non-synchronizable Keychain item.
public struct AccountKeys: Sendable {
    public let accountID: String
    public let vaultKey: SymmetricKey
    private let masterKey: SymmetricKey

    public init(accountID: String) throws {
        try SyncWire.validateID(accountID)
        self.accountID = accountID
        masterKey = SymmetricKey(size: .bits256)
        vaultKey = SymmetricKey(size: .bits256)
    }
    private init(master: SymmetricKey, envelope: AccountKeyEnvelope) throws {
        try Self.validate(envelope)
        accountID = envelope.accountId; masterKey = master
        vaultKey = try Self.open(envelope.wrappedVaultKey, key: master, context: Self.context(accountID, "vault"))
    }
    /// Rebuilds the keys from the account master key (the synchronizable Keychain seed, CK-R6) and the public envelope.
    public init(masterKey: SymmetricKey, envelope: AccountKeyEnvelope) throws {
        try self.init(master: masterKey, envelope: envelope)
    }
    /// The account master key bytes, only for the synchronizable Keychain seed (CK-R6). Never log or upload them.
    public var masterKeyData: Data { masterKey.withUnsafeBytes { Data($0) } }
    public init(recovery: RecoveryKey, envelope: AccountKeyEnvelope) throws {
        try Self.validate(envelope)
        let signing = try recovery.signingKey(accountID: envelope.accountId)
        guard SyncWire.base64(signing.publicKey.rawRepresentation) == envelope.recoveryPublicKey else { throw AccountKeyError.invalidRecoveryKey }
        let master = try Self.open(envelope.wrappedMasterKey, key: recovery.wrappingKey(accountID: envelope.accountId),
                                   context: Self.context(envelope.accountId, "recovery-master"))
        try self.init(master: master, envelope: envelope)
    }
    /// Recovery rotation changes only the master-key wrapper, never the content vault.
    public func replacingRecoveryEnvelope(_ envelope: AccountKeyEnvelope) throws -> AccountKeys {
        guard envelope.accountId == accountID else { throw AccountKeyError.invalidEnvelope }
        let updated: AccountKeys
        do { updated = try AccountKeys(master: masterKey, envelope: envelope) }
        catch { throw AccountKeyError.invalidEnvelope }
        guard updated.vaultKey.withUnsafeBytes({ Data($0) }) == vaultKey.withUnsafeBytes({ Data($0) }) else {
            throw AccountKeyError.invalidEnvelope
        }
        return updated
    }
    public func envelope(recovery: RecoveryKey) throws -> AccountKeyEnvelope {
        AccountKeyEnvelope(version: 1, algorithm: "HKDF-SHA256+AES-256-GCM+Ed25519", accountId: accountID,
            wrappedMasterKey: try Self.seal(masterKey, key: recovery.wrappingKey(accountID: accountID), context: Self.context(accountID, "recovery-master")),
            wrappedVaultKey: try Self.seal(vaultKey, key: masterKey, context: Self.context(accountID, "vault")),
            recoveryPublicKey: try SyncWire.base64(recovery.signingKey(accountID: accountID).publicKey.rawRepresentation))
    }
    public func deviceWrappedMasterKey(deviceID: String, wrappingKey: SymmetricKey) throws -> String {
        try SyncWire.validateID(deviceID)
        return try Self.seal(masterKey, key: wrappingKey, context: Self.context(accountID, "device:\(deviceID)"))
    }
    public init(deviceWrappedMasterKey: String, deviceID: String, wrappingKey: SymmetricKey, envelope: AccountKeyEnvelope) throws {
        try Self.validate(envelope); try SyncWire.validateID(deviceID)
        let master = try Self.open(deviceWrappedMasterKey, key: wrappingKey, context: Self.context(envelope.accountId, "device:\(deviceID)"))
        try self.init(master: master, envelope: envelope)
    }
    private static func validate(_ envelope: AccountKeyEnvelope) throws {
        try SyncWire.validateID(envelope.accountId)
        guard envelope.version == 1, envelope.algorithm == "HKDF-SHA256+AES-256-GCM+Ed25519",
              try SyncWire.decode64(envelope.recoveryPublicKey).count == 32 else { throw AccountKeyError.invalidEnvelope }
    }
    static func context(_ account: String, _ purpose: String) -> String { "\(ProtocolLabels.account):\(account):\(purpose)" }
    private static func seal(_ value: SymmetricKey, key: SymmetricKey, context: String) throws -> String {
        let data = value.withUnsafeBytes { Data($0) }
        guard data.count == 32, key.bitCount == 256,
              let box = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined
        else { throw AccountKeyError.invalidEnvelope }
        return SyncWire.base64(box)
    }
    private static func open(_ value: String, key: SymmetricKey, context: String) throws -> SymmetricKey {
        let data = try SyncWire.decode64(value)
        guard data.count == 60, key.bitCount == 256 else { throw AccountKeyError.invalidEnvelope }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
        guard plaintext.count == 32 else { throw AccountKeyError.invalidEnvelope }
        return SymmetricKey(data: plaintext)
    }

    /// Public handshake material only. It never contains an encrypted account key.
    public struct TransferChallenge: Codable, Equatable, Sendable {
        public let version: Int
        public let accountId: String
        public let transferId: String
        public let expiresAt: Int64
        public let senderPublicKey: String
        public let recipientPublicKey: String

        public init(version: Int, accountId: String, transferId: String, expiresAt: Int64,
                    senderPublicKey: String, recipientPublicKey: String) {
            self.version = version; self.accountId = accountId; self.transferId = transferId
            self.expiresAt = expiresAt; self.senderPublicKey = senderPublicKey
            self.recipientPublicKey = recipientPublicKey
        }

        func validate(now: Date = .now) throws {
            try SyncWire.validateID(accountId); try SyncWire.validateID(transferId)
            guard version == 1, try SyncWire.decode64(senderPublicKey).count == 32,
                  try SyncWire.decode64(recipientPublicKey).count == 32 else { throw AccountKeyError.invalidEnvelope }
            let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
            guard expiresAt > milliseconds, expiresAt <= milliseconds + 600_000 else { throw AccountKeyError.expiredTransfer }
        }
    }

    /// Derives the comparison words without receiving or opening any account key.
    public static func verificationWords(for challenge: TransferChallenge,
                                         privateKey: Curve25519.KeyAgreement.PrivateKey,
                                         now: Date = .now) throws -> String {
        try challenge.validate(now: now)
        guard SyncWire.base64(privateKey.publicKey.rawRepresentation) == challenge.recipientPublicKey else {
            throw AccountKeyError.wrongRecipient
        }
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: SyncWire.decode64(challenge.senderPublicKey))
        let context = transferContext(challenge.accountId, challenge.transferId, challenge.expiresAt,
                                      sender.rawRepresentation, privateKey.publicKey.rawRepresentation)
        return try verificationWords(transferKey(privateKey, sender, context))
    }

    public struct Transfer: Codable, Sendable {
        public let version: Int
        public let accountId: String
        public let transferId: String
        public let expiresAt: Int64
        public let senderPublicKey: String
        public let recipientPublicKey: String
        public let wrappedMasterKey: String
        public var challenge: TransferChallenge {
            TransferChallenge(version: version, accountId: accountId, transferId: transferId, expiresAt: expiresAt,
                              senderPublicKey: senderPublicKey, recipientPublicKey: recipientPublicKey)
        }
    }
    public func transfer(to recipient: Curve25519.KeyAgreement.PublicKey, transferID: String, expiresAt: Date, now: Date = .now) throws -> (package: Transfer, verificationWords: String) {
        try SyncWire.validateID(transferID)
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let expiry = Int64(expiresAt.timeIntervalSince1970 * 1000)
        guard expiresAt > now, expiresAt <= now.addingTimeInterval(600) else { throw AccountKeyError.expiredTransfer }
        let context = Self.transferContext(accountID, transferID, expiry, sender.publicKey.rawRepresentation, recipient.rawRepresentation)
        let key = try Self.transferKey(sender, recipient, context)
        return (Transfer(version: 1, accountId: accountID, transferId: transferID, expiresAt: expiry,
            senderPublicKey: SyncWire.base64(sender.publicKey.rawRepresentation), recipientPublicKey: SyncWire.base64(recipient.rawRepresentation),
            wrappedMasterKey: try Self.seal(masterKey, key: key, context: context)), try Self.verificationWords(key))
    }
    public static func receive(_ transfer: Transfer, privateKey: Curve25519.KeyAgreement.PrivateKey,
                               envelope: AccountKeyEnvelope, now: Date = .now) throws -> (keys: AccountKeys, verificationWords: String) {
        try validate(envelope); try SyncWire.validateID(transfer.transferId)
        guard transfer.version == 1, transfer.accountId == envelope.accountId else { throw AccountKeyError.invalidEnvelope }
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        guard transfer.expiresAt > milliseconds, transfer.expiresAt <= milliseconds + 600_000 else { throw AccountKeyError.expiredTransfer }
        guard SyncWire.base64(privateKey.publicKey.rawRepresentation) == transfer.recipientPublicKey else { throw AccountKeyError.wrongRecipient }
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: SyncWire.decode64(transfer.senderPublicKey))
        let context = transferContext(transfer.accountId, transfer.transferId, transfer.expiresAt, sender.rawRepresentation, privateKey.publicKey.rawRepresentation)
        let key = try transferKey(privateKey, sender, context)
        let master = try open(transfer.wrappedMasterKey, key: key, context: context)
        return (try AccountKeys(master: master, envelope: envelope), try verificationWords(key))
    }
    private static func transferContext(_ account: String, _ transfer: String, _ expiry: Int64, _ sender: Data, _ recipient: Data) -> String {
        "\(ProtocolLabels.transfer):\(account):\(transfer):\(expiry):\(SyncWire.base64(sender)):\(SyncWire.base64(recipient))"
    }
    private static func transferKey(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Curve25519.KeyAgreement.PublicKey, _ context: String) throws -> SymmetricKey {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey).hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data(context.utf8), sharedInfo: Data(ProtocolLabels.transferKey.utf8), outputByteCount: 32)
    }
    private static func verificationWords(_ key: SymmetricKey) throws -> String {
        let bytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(), info: Data(ProtocolLabels.transferWords.utf8), outputByteCount: 32)
        let digest = bytes.withUnsafeBytes { Data($0) }
        let list = try RecoveryKey.wordList()
        let bits = digest.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        return (0..<6).map { word in list[bits[(word * 11)..<(word * 11 + 11)].reduce(0) { ($0 << 1) | Int($1) }] }.joined(separator: " ")
    }
}
