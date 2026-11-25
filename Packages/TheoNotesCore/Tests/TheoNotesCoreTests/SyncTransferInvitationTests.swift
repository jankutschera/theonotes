// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

struct SyncTransferInvitationTests {
    let endpoint = URL(string: "https://sync.example")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func invitation() -> SyncTransferInvitation {
        SyncTransferInvitation(version: 1, accountId: "account", transferId: "transfer",
            publicKey: SyncWire.base64(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            expiresAt: Int64(now.timeIntervalSince1970 * 1000) + 600_000)
    }
    @Test func roundTripBindsServiceOriginAndRejectsAlteredURL() throws {
        let expected = invitation(), code = try expected.qrPayload(endpoint: endpoint, now: now)
        #expect(try SyncTransferInvitation.decodeQR(code, endpoint: endpoint, now: now) == expected)
        #expect(throws: Error.self) { try SyncTransferInvitation.decodeQR(code, endpoint: URL(string: "https://other.example")!, now: now) }
        for invalid in [code + "&origin=https://sync.example", code + "#fragment", code.replacingOccurrences(of: "baerchen://pair?", with: "baerchen://pair/path?"), code.replacingOccurrences(of: "baerchen://pair", with: "baerchen://person@pair")] {
            #expect(throws: Error.self) { try SyncTransferInvitation.decodeQR(invalid, endpoint: endpoint, now: now) }
        }
    }
    @Test func rejectsExpiredFutureAndMalformedInvitation() throws {
        let valid = invitation()
        #expect(throws: AccountKeyError.expiredTransfer) { try valid.validate(now: now.addingTimeInterval(600)) }
        #expect(throws: AccountKeyError.expiredTransfer) { try valid.validate(now: now.addingTimeInterval(-1)) }
        let bad = SyncTransferInvitation(version: 1, accountId: "account", transferId: "transfer", publicKey: "AA", expiresAt: valid.expiresAt)
        #expect(throws: Error.self) { try bad.qrPayload(endpoint: endpoint, now: now) }
        #expect(throws: Error.self) { try SyncTransferInvitation.decodeQR(String(repeating: "x", count: 8193), endpoint: endpoint, now: now) }
    }
}
