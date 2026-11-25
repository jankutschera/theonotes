// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct AccountKeyTests {
    @Test func mnemonicUses256BitEntropyAndChecksum() throws {
        let zero = try RecoveryKey(secret: Data(repeating: 0, count: 32))
        let expected = Array(repeating: "abandon", count: 23).joined(separator: " ") + " art"
        #expect(try zero.words() == expected)
        #expect(try RecoveryKey(words: " \n" + expected.uppercased() + "\n").words() == expected)
        #expect(throws: AccountKeyError.invalidRecoveryKey) { try RecoveryKey(words: Array(repeating: "abandon", count: 24).joined(separator: " ")) }
        #expect(throws: AccountKeyError.invalidRecoveryKey) { try RecoveryKey(words: "not a recovery key") }
        for _ in 0..<10 {
            let key = RecoveryKey()
            let restored = try RecoveryKey(words: key.words())
            #expect(try restored.signingKey(accountID: "account").rawRepresentation == key.signingKey(accountID: "account").rawRepresentation)
        }
    }

    @Test func recoveryAndDeviceEnvelopesPreserveVaultButCannotCrossAccountsOrDevices() throws {
        let original = try AccountKeys(accountID: "account-one")
        let recovery = RecoveryKey()
        let envelope = try original.envelope(recovery: recovery)
        let restored = try AccountKeys(recovery: RecoveryKey(words: recovery.words()), envelope: envelope)
        let body = Data("exact private content".utf8)
        let cipher = try NoteCipher.seal(body, vaultKey: original.vaultKey, context: "test")
        #expect(try NoteCipher.open(cipher, vaultKey: restored.vaultKey, context: "test") == body)
        #expect(throws: AccountKeyError.invalidRecoveryKey) { try AccountKeys(recovery: RecoveryKey(), envelope: envelope) }
        let deviceKey = SymmetricKey(size: .bits256)
        let wrapped = try original.deviceWrappedMasterKey(deviceID: "phone", wrappingKey: deviceKey)
        let device = try AccountKeys(deviceWrappedMasterKey: wrapped, deviceID: "phone", wrappingKey: deviceKey, envelope: envelope)
        #expect(try NoteCipher.open(cipher, vaultKey: device.vaultKey, context: "test") == body)
        #expect(throws: (any Error).self) {
            try AccountKeys(deviceWrappedMasterKey: wrapped, deviceID: "other", wrappingKey: deviceKey, envelope: envelope)
        }
        #expect(try recovery.signingKey(accountID: "account-one").rawRepresentation != recovery.signingKey(accountID: "account-two").rawRepresentation)
        let tampered = AccountKeyEnvelope(version: 1, algorithm: envelope.algorithm, accountId: "account-two",
            wrappedMasterKey: envelope.wrappedMasterKey, wrappedVaultKey: envelope.wrappedVaultKey, recoveryPublicKey: envelope.recoveryPublicKey)
        #expect(throws: (any Error).self) { try AccountKeys(recovery: recovery, envelope: tampered) }
    }

    @Test func transferUsesEphemeralAgreementWithMatchingWordsExpiryAndRecipientBinding() throws {
        let keys = try AccountKeys(accountID: "account"), recovery = RecoveryKey()
        let envelope = try keys.envelope(recovery: recovery)
        let receiver = Curve25519.KeyAgreement.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let offered = try keys.transfer(to: receiver.publicKey, transferID: "transfer", expiresAt: now.addingTimeInterval(600), now: now)
        let accepted = try AccountKeys.receive(offered.package, privateKey: receiver, envelope: envelope, now: now)
        #expect(accepted.verificationWords == offered.verificationWords)
        #expect(accepted.verificationWords.split(separator: " ").count == 6)
        let cipher = try NoteCipher.seal(Data("secret".utf8), vaultKey: keys.vaultKey, context: "test")
        #expect(try NoteCipher.open(cipher, vaultKey: accepted.keys.vaultKey, context: "test") == Data("secret".utf8))
        #expect(throws: AccountKeyError.expiredTransfer) {
            try AccountKeys.receive(offered.package, privateKey: receiver, envelope: envelope, now: now.addingTimeInterval(601))
        }
        #expect(throws: AccountKeyError.wrongRecipient) {
            try AccountKeys.receive(offered.package, privateKey: .init(), envelope: envelope, now: now)
        }
        let changed = AccountKeys.Transfer(version: 1, accountId: offered.package.accountId, transferId: "other",
            expiresAt: offered.package.expiresAt, senderPublicKey: offered.package.senderPublicKey,
            recipientPublicKey: offered.package.recipientPublicKey, wrappedMasterKey: offered.package.wrappedMasterKey)
        #expect(throws: (any Error).self) { try AccountKeys.receive(changed, privateKey: receiver, envelope: envelope, now: now) }
    }

    @Test func opensIndependentWebCryptoFixture() throws {
        struct Fixture: Decodable { let recoveryWords: String; let envelope: AccountKeyEnvelope; let signingSeedHex: String; let vaultKeyHex: String }
        let url = SchemaSnapshotTests.fixtureDir.deletingLastPathComponent().appendingPathComponent("sync/account-keys-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let recovery = try RecoveryKey(words: fixture.recoveryWords)
        #expect(try recovery.signingKey(accountID: fixture.envelope.accountId).rawRepresentation.map { String(format: "%02x", $0) }.joined() == fixture.signingSeedHex)
        let keys = try AccountKeys(recovery: recovery, envelope: fixture.envelope)
        #expect(keys.vaultKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() == fixture.vaultKeyHex)
    }
}
