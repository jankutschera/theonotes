// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

/// The one additive member under `Sync/`: `AccountKeys(masterKey:envelope)` and `masterKeyData`.
/// Golden vectors prove the new path equals the existing recovery path and that nothing else changed.
/// Secrets are compared as booleans only, so a failure message never prints key bytes.
@Suite struct AccountKeysMasterKeyTests {
    struct Fixture: Decodable { let recoveryWords: String; let envelope: AccountKeyEnvelope; let signingSeedHex: String; let vaultKeyHex: String }

    static func fixture() throws -> Fixture {
        let url = SchemaSnapshotTests.fixtureDir.deletingLastPathComponent().appendingPathComponent("sync/account-keys-v1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func masterKeyPathEqualsTheRecoveryPathForTheGoldenFixture() throws {
        let fixture = try Self.fixture()
        let viaRecovery = try AccountKeys(recovery: RecoveryKey(words: fixture.recoveryWords), envelope: fixture.envelope)
        let master = viaRecovery.masterKeyData
        #expect(master.count == 32)
        let viaMaster = try AccountKeys(masterKey: SymmetricKey(data: master), envelope: fixture.envelope)
        let vaultMatchesFixture = Self.hex(Self.bytes(viaMaster.vaultKey)) == fixture.vaultKeyHex
        let vaultMatchesRecovery = Self.bytes(viaMaster.vaultKey) == Self.bytes(viaRecovery.vaultKey)
        let masterRoundTrips = viaMaster.masterKeyData == master
        #expect(vaultMatchesFixture, "the master-key path must open the golden envelope to the golden vault key")
        #expect(vaultMatchesRecovery)
        #expect(masterRoundTrips)
        #expect(viaMaster.accountID == fixture.envelope.accountId)
    }

    @Test func existingBehaviourIsUnchangedForTheGoldenFixture() throws {
        // The pre-existing recovery path still yields the golden signing seed and vault key (same assertions as
        // AccountKeyTests.opensIndependentWebCryptoFixture), and a device wrapper made from master-key-built keys
        // opens with the existing device initializer.
        let fixture = try Self.fixture()
        let recovery = try RecoveryKey(words: fixture.recoveryWords)
        let seedMatches = Self.hex(try recovery.signingKey(accountID: fixture.envelope.accountId).rawRepresentation) == fixture.signingSeedHex
        #expect(seedMatches)
        let keys = try AccountKeys(recovery: recovery, envelope: fixture.envelope)
        let rebuilt = try AccountKeys(masterKey: SymmetricKey(data: keys.masterKeyData), envelope: fixture.envelope)
        let wrappingKey = SymmetricKey(size: .bits256)
        let wrapped = try rebuilt.deviceWrappedMasterKey(deviceID: "device-1", wrappingKey: wrappingKey)
        let device = try AccountKeys(deviceWrappedMasterKey: wrapped, deviceID: "device-1", wrappingKey: wrappingKey, envelope: fixture.envelope)
        let sameVault = Self.bytes(device.vaultKey) == Self.bytes(keys.vaultKey)
        #expect(sameVault)
        // Re-wrapping from master-key-built keys produces an envelope the existing recovery path opens to the same vault.
        let fresh = RecoveryKey()
        let envelope = try rebuilt.envelope(recovery: fresh)
        let reopened = try AccountKeys(recovery: fresh, envelope: envelope)
        let sameAfterRewrap = Self.bytes(reopened.vaultKey) == Self.bytes(keys.vaultKey)
        #expect(sameAfterRewrap)
        _ = try keys.replacingRecoveryEnvelope(envelope)
    }

    @Test func aWrongMasterKeyNeverOpensTheEnvelope() throws {
        let fixture = try Self.fixture()
        #expect(throws: (any Error).self) { try AccountKeys(masterKey: SymmetricKey(size: .bits256), envelope: fixture.envelope) }
        #expect(throws: AccountKeyError.invalidEnvelope) { try AccountKeys(masterKey: SymmetricKey(size: .bits128), envelope: fixture.envelope) }
        let keys = try AccountKeys(recovery: RecoveryKey(words: fixture.recoveryWords), envelope: fixture.envelope)
        let moved = AccountKeyEnvelope(version: 1, algorithm: fixture.envelope.algorithm, accountId: "another-account",
                                       wrappedMasterKey: fixture.envelope.wrappedMasterKey, wrappedVaultKey: fixture.envelope.wrappedVaultKey,
                                       recoveryPublicKey: fixture.envelope.recoveryPublicKey)
        #expect(throws: (any Error).self) { try AccountKeys(masterKey: SymmetricKey(data: keys.masterKeyData), envelope: moved) }
        let unsupported = AccountKeyEnvelope(version: 2, algorithm: fixture.envelope.algorithm, accountId: fixture.envelope.accountId,
                                             wrappedMasterKey: fixture.envelope.wrappedMasterKey, wrappedVaultKey: fixture.envelope.wrappedVaultKey,
                                             recoveryPublicKey: fixture.envelope.recoveryPublicKey)
        #expect(throws: AccountKeyError.invalidEnvelope) { try AccountKeys(masterKey: SymmetricKey(data: keys.masterKeyData), envelope: unsupported) }
    }

    @Test func freshKeysRoundTripThroughTheMasterKey() throws {
        let keys = try AccountKeys(accountID: "ck-0190f5a0-0000-7000-8000-000000000001")
        let envelope = try keys.envelope(recovery: RecoveryKey())
        let rebuilt = try AccountKeys(masterKey: SymmetricKey(data: keys.masterKeyData), envelope: envelope)
        let sameVault = Self.bytes(rebuilt.vaultKey) == Self.bytes(keys.vaultKey)
        let sameMaster = rebuilt.masterKeyData == keys.masterKeyData
        #expect(sameVault)
        #expect(sameMaster)
        let other = try AccountKeys(accountID: "ck-0190f5a0-0000-7000-8000-000000000001")
        let distinct = other.masterKeyData != keys.masterKeyData
        #expect(distinct)
    }
}
