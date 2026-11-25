// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

struct SyncTransferChallengeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func publicChallengeDerivesSameWordsWithoutReleasingMasterKey() throws {
        let account = try AccountKeys(accountID: "account")
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let transfer = try account.transfer(to: recipient.publicKey, transferID: "transfer",
            expiresAt: now.addingTimeInterval(590), now: now)
        let words = try AccountKeys.verificationWords(for: transfer.package.challenge, privateKey: recipient, now: now)
        #expect(words == transfer.verificationWords)
        let envelope = try account.envelope(recovery: RecoveryKey())
        #expect(try AccountKeys.receive(transfer.package, privateKey: recipient, envelope: envelope, now: now).verificationWords == words)
        let encoded = try JSONEncoder().encode(transfer.package.challenge)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(fields.keys) == Set(["version", "accountId", "transferId", "expiresAt", "senderPublicKey", "recipientPublicKey"]))
        #expect(fields["wrappedMasterKey"] == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(transfer.package.wrappedMasterKey))
        #expect(try JSONDecoder().decode(AccountKeys.TransferChallenge.self, from: encoded) == transfer.package.challenge)
    }

    @Test func substitutedSenderChangesWordsAndWrongRecipientOrMalformedChallengeFails() throws {
        let account = try AccountKeys(accountID: "account"), recipient = Curve25519.KeyAgreement.PrivateKey()
        let original = try account.transfer(to: recipient.publicKey, transferID: "transfer", expiresAt: now.addingTimeInterval(590), now: now)
        let substituted = try account.transfer(to: recipient.publicKey, transferID: "transfer", expiresAt: now.addingTimeInterval(590), now: now)
        #expect(try AccountKeys.verificationWords(for: substituted.package.challenge, privateKey: recipient, now: now) != original.verificationWords)
        #expect(throws: AccountKeyError.wrongRecipient) {
            try AccountKeys.verificationWords(for: original.package.challenge, privateKey: Curve25519.KeyAgreement.PrivateKey(), now: now)
        }
        #expect(throws: AccountKeyError.expiredTransfer) {
            try AccountKeys.verificationWords(for: original.package.challenge, privateKey: recipient, now: now.addingTimeInterval(600))
        }
        let challenge = original.package.challenge
        for invalid in [
            AccountKeys.TransferChallenge(version: 2, accountId: "account", transferId: "transfer", expiresAt: challenge.expiresAt,
                senderPublicKey: challenge.senderPublicKey, recipientPublicKey: challenge.recipientPublicKey),
            AccountKeys.TransferChallenge(version: 1, accountId: "", transferId: "transfer", expiresAt: challenge.expiresAt,
                senderPublicKey: challenge.senderPublicKey, recipientPublicKey: challenge.recipientPublicKey),
            AccountKeys.TransferChallenge(version: 1, accountId: "account", transferId: "transfer", expiresAt: challenge.expiresAt,
                senderPublicKey: "AA", recipientPublicKey: challenge.recipientPublicKey)
        ] {
            #expect(throws: Error.self) { try AccountKeys.verificationWords(for: invalid, privateKey: recipient, now: now) }
        }
    }
}
