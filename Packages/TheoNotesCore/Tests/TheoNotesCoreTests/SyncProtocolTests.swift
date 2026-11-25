// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct SyncProtocolTests {
    @Test func sharedWireFixtureAndExplicitNulls() throws {
        struct Fixture: Decodable { let accountId: String; let mutation: SyncMutation; let canonicalMutation: String; let cipherContext: String }
        let url = SchemaSnapshotTests.fixtureDir.deletingLastPathComponent().appendingPathComponent("sync/protocol-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(try String(data: fixture.mutation.canonicalData(), encoding: .utf8) == fixture.canonicalMutation)
        #expect(try SyncWire.cipherContext(accountID: fixture.accountId, type: fixture.mutation.entityType,
                                         entityID: fixture.mutation.entityId) == fixture.cipherContext)
        let encoded = try JSONEncoder().encode(fixture.mutation)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["payloadRef"] is NSNull)
        let entity = SyncEntity(mutation: fixture.mutation, revision: 8, sequence: 12, receivedAt: 123)
        #expect(try JSONDecoder().decode(SyncEntity.self, from: JSONEncoder().encode(entity)) == entity)
    }

    @Test func encryptionBindsAccountTypeIdentifierAndVersion() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try SyncWire.cipherContext(accountID: "account", type: .note, entityID: "note")
        let body = Data("# Exact Markdown\n\n secret #tag 🐻".utf8)
        let cipher = try NoteCipher.seal(body, vaultKey: key, context: context)
        #expect(try NoteCipher.open(cipher, vaultKey: key, context: context) == body)
        for altered in ["baerchen-sync:1:other:note:note:1", "baerchen-sync:1:account:attachment:note:1",
                        "baerchen-sync:1:account:note:other:1", "baerchen-sync:1:account:note:note:2"] {
            #expect(throws: CryptoError.tampered) { try NoteCipher.open(cipher, vaultKey: key, context: altered) }
        }
    }

    @Test func rejectsAmbiguousWireInputs() throws {
        #expect(throws: SyncProtocolError.invalidEncoding) { try SyncWire.decode64("YR") }
        #expect(throws: SyncProtocolError.invalidEncoding) { try SyncWire.decode64("YQ==") }
        #expect(throws: SyncProtocolError.invalidIdentifier) { try SyncWire.validateID("../note") }
        var mutation = SyncMutation(mutationId: "m", entityType: .note, entityId: "n", parentRevision: 0, ciphertext: "YWJj")
        try mutation.validate()
        mutation.tombstone = true
        #expect(throws: SyncProtocolError.invalidPayload) { try mutation.validate() }
        mutation.ciphertext = nil
        try mutation.validate()
        mutation.parentRevision = .max
        #expect(throws: SyncProtocolError.invalidRevision) { try mutation.validate() }
    }
}
