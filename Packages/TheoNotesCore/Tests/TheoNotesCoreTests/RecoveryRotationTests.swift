// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

private actor RotationServer: SyncRecoveryTransport {
    var envelope: AccountKeyEnvelope
    var revision: Int64 = 1
    var writes = 0
    var loseResponse = false
    init(_ envelope: AccountKeyEnvelope) { self.envelope = envelope }
    func keyBundle() -> SyncKeyBundle { SyncKeyBundle(envelope: envelope, revision: revision) }
    func dropNextResponse() { loseResponse = true }
    func writeKeyEnvelope(_ next: AccountKeyEnvelope, parentRevision: Int64) throws -> Int64 {
        guard parentRevision == revision else { throw RecoveryRotationError.superseded }
        envelope = next; revision += 1; writes += 1
        if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        return revision
    }
}

@Suite struct RecoveryRotationTests {
    private let account = "019a0000-0000-7000-8000-000000000001"

    @Test func twoDevicesKeepDecryptingWhileOldRecoveryWordsStopWorking() async throws {
        let original = try AccountKeys(accountID: account), oldRecovery = RecoveryKey()
        let oldEnvelope = try original.envelope(recovery: oldRecovery)
        let secondDevice = try AccountKeys(recovery: oldRecovery, envelope: oldEnvelope)
        let server = RotationServer(oldEnvelope)
        var proposal = try PendingRecoveryRotation(keys: original, previous: await server.keyBundle())
        let ciphertext = try NoteCipher.seal(Data("private note".utf8), vaultKey: original.vaultKey, context: "rotation-test")
        proposal.confirmed = true
        try await SyncRecoveryRotation.publish(proposal, using: server)
        let updated = try secondDevice.replacingRecoveryEnvelope(await server.keyBundle().envelope)
        #expect(try NoteCipher.open(ciphertext, vaultKey: updated.vaultKey, context: "rotation-test") == Data("private note".utf8))
        #expect(throws: AccountKeyError.self) { try AccountKeys(recovery: oldRecovery, envelope: proposal.envelope) }
        let recovered = try AccountKeys(recovery: RecoveryKey(words: proposal.words), envelope: proposal.envelope)
        #expect(try NoteCipher.open(ciphertext, vaultKey: recovered.vaultKey, context: "rotation-test") == Data("private note".utf8))
    }

    @Test func lostResponseAndRestartReuseDurableProposalWithoutSecondWrite() async throws {
        let keys = try AccountKeys(accountID: account), server = RotationServer(try keys.envelope(recovery: RecoveryKey()))
        var proposal = try PendingRecoveryRotation(keys: keys, previous: await server.keyBundle())
        proposal.confirmed = true
        let durable = try JSONEncoder().encode(proposal)
        await server.dropNextResponse()
        do { try await SyncRecoveryRotation.publish(proposal, using: server); Issue.record("expected lost response") }
        catch is URLError {}
        let restarted = try JSONDecoder().decode(PendingRecoveryRotation.self, from: durable)
        try await SyncRecoveryRotation.publish(restarted, using: server)
        #expect(await server.writes == 1)
        #expect(await server.keyBundle().envelope == proposal.envelope)
    }

    @Test func concurrentDeviceProposalNeverOverwritesTheWinningRecoveryKey() async throws {
        let keys = try AccountKeys(accountID: account), server = RotationServer(try keys.envelope(recovery: RecoveryKey()))
        let previous = await server.keyBundle()
        var a = try PendingRecoveryRotation(keys: keys, previous: previous), b = try PendingRecoveryRotation(keys: keys, previous: previous)
        a.confirmed = true; b.confirmed = true
        try await SyncRecoveryRotation.publish(a, using: server)
        do { try await SyncRecoveryRotation.publish(b, using: server); Issue.record("stale rotation accepted") }
        catch RecoveryRotationError.superseded {}
        #expect(await server.writes == 1)
        #expect(await server.keyBundle().envelope == a.envelope)
    }

    @Test func unconfirmedOrDifferentVaultProposalCannotPublish() async throws {
        let keys = try AccountKeys(accountID: account), server = RotationServer(try keys.envelope(recovery: RecoveryKey()))
        let proposal = try PendingRecoveryRotation(keys: keys, previous: await server.keyBundle())
        do { try await SyncRecoveryRotation.publish(proposal, using: server); Issue.record("unconfirmed rotation accepted") }
        catch RecoveryRotationError.confirmationRequired {}
        let unrelated = try AccountKeys(accountID: account)
        #expect(throws: AccountKeyError.self) { try unrelated.replacingRecoveryEnvelope(proposal.envelope) }
        #expect(await server.writes == 0)
    }
    @Test func corruptedDurableWordsCannotReplaceTheServerRecoveryKey() async throws {
        let keys = try AccountKeys(accountID: account), server = RotationServer(try keys.envelope(recovery: RecoveryKey()))
        var proposal = try PendingRecoveryRotation(keys: keys, previous: await server.keyBundle())
        proposal.confirmed = true
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as! [String: Any]
        object["words"] = try RecoveryKey().words()
        let corrupted = try JSONDecoder().decode(PendingRecoveryRotation.self, from: JSONSerialization.data(withJSONObject: object))
        do { try await SyncRecoveryRotation.publish(corrupted, using: server); Issue.record("corrupted recovery published") }
        catch is AccountKeyError {}
        #expect(await server.writes == 0)
    }

}
