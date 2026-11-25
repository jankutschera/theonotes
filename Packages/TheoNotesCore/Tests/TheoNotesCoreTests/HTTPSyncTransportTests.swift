// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import TheoNotesCore

private final class SyncMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let handler = Mutex<Handler?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler.withLock({ $0 }), let url = request.url else { throw SyncHTTPError.invalidResponse }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}
private actor TestCredentials: SyncCredentialStore {
    var value: SyncCredentials?
    var writes = 0
    init(_ value: SyncCredentials?) { self.value = value }
    func load() -> SyncCredentials? { value }
    func save(_ value: SyncCredentials) { self.value = value; writes += 1 }
}

@Suite(.serialized) struct HTTPSyncTransportTests {
    private func credentials(expired: Bool = false) -> SyncCredentials {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        return SyncCredentials(accountId: "account", deviceId: "device", accessToken: SyncWire.base64(Data(repeating: 1, count: 32)),
            refreshToken: SyncWire.base64(Data(repeating: 2, count: 32)), accessExpiresAt: now + (expired ? -1000 : 600_000), refreshExpiresAt: now + 86_400_000)
    }
    private func transport(_ key: Curve25519.Signing.PrivateKey, _ store: TestCredentials) throws -> HTTPSyncTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncMockURLProtocol.self]
        return try HTTPSyncTransport(endpoint: URL(string: "https://sync.example")!, signingKey: key, credentials: store, session: URLSession(configuration: configuration))
    }
    @Test func signsExactMethodTargetBodyAndTokenAndRejectsInvalidPullOrder() async throws {
        let key = Curve25519.Signing.PrivateKey(), stored = credentials()
        let client = try transport(key, TestCredentials(stored))
        let valid = Data("{\"changes\":[],\"cursor\":7,\"hasMore\":false}".utf8)
        SyncMockURLProtocol.handler.withLock { $0 = { request in
            let time = try #require(request.value(forHTTPHeaderField: "X-Baerchen-Time"))
            let nonce = try #require(request.value(forHTTPHeaderField: "X-Baerchen-Nonce"))
            let signature = try SyncWire.decode64(#require(request.value(forHTTPHeaderField: "X-Baerchen-Signature")))
            let target = request.url!.path + "?" + request.url!.query!
            let transcript = ["baerchen-request:1", "GET", target, time, nonce, SyncWire.hash(Data(stored.accessToken.utf8)), SyncWire.hash(SyncMockURLProtocol.body(request))].joined(separator: "\n")
            #expect(key.publicKey.isValidSignature(signature, for: Data(transcript.utf8)))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + stored.accessToken)
            return (200, valid)
        } }
        #expect(try await client.pull(after: 7).cursor == 7)
        SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, Data("{\"changes\":[],\"cursor\":8,\"hasMore\":true}".utf8)) } }
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.pull(after: 7) }
        SyncMockURLProtocol.handler.withLock { $0 = nil }
    }
    @Test func concurrentExpiryRotatesOnceAndPersistsBeforeRetryingRequests() async throws {
        let key = Curve25519.Signing.PrivateKey(), old = credentials(expired: true), store = TestCredentials(old)
        let client = try transport(key, store)
        let count = Mutex(0)
        let access = SyncWire.base64(Data(repeating: 3, count: 32)), refresh = SyncWire.base64(Data(repeating: 4, count: 32))
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let refreshBody = try JSONSerialization.data(withJSONObject: ["accessToken": access, "refreshToken": refresh,
            "accessExpiresAt": now + 600_000, "refreshExpiresAt": now + 86_400_000])
        SyncMockURLProtocol.handler.withLock { $0 = { request in
            if request.url?.path == "/v1/auth/refresh" {
                count.withLock { $0 += 1 }
                let payload = try JSONSerialization.jsonObject(with: SyncMockURLProtocol.body(request)) as? [String: String]
                #expect(payload?["refreshToken"] == old.refreshToken)
                return (200, refreshBody)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + access)
            return (200, Data("{\"changes\":[],\"cursor\":0,\"hasMore\":false}".utf8))
        } }
        async let a = client.pull(after: 0)
        async let b = client.pull(after: 0)
        async let c = client.pull(after: 0)
        _ = try await (a, b, c)
        #expect(count.withLock { $0 } == 1)
        #expect(await store.writes == 1)
        #expect(await store.value?.refreshToken == refresh)
        SyncMockURLProtocol.handler.withLock { $0 = nil }
    }
    @Test func rejectsInsecureEndpointOversizedResponseAndMalformedAcknowledgment() async throws {
        let key = Curve25519.Signing.PrivateKey(), store = TestCredentials(credentials())
        #expect(throws: SyncHTTPError.invalidEndpoint) { try HTTPSyncTransport(endpoint: URL(string: "http://sync.example")!, signingKey: key, credentials: store) }
        let client = try transport(key, store)
        SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, Data(repeating: 32, count: 4_194_305)) } }
        await #expect(throws: SyncProtocolError.responseTooLarge) { try await client.pull(after: 0) }
        SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, Data("{\"ok\":false}".utf8)) } }
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.acknowledge(1) }
        await client.shutdown()
        await #expect(throws: SyncHTTPError.authenticationRequired) { try await client.pull(after: 0) }
        SyncMockURLProtocol.handler.withLock { $0 = nil }
    }

    @Test func accountOperationsBindKeyEnvelopesAndEncryptedNamesToCurrentIdentity() async throws {
        let key = Curve25519.Signing.PrivateKey(), store = TestCredentials(credentials())
        let client = try transport(key, store), account = try AccountKeys(accountID: "account")
        let envelope = try account.envelope(recovery: RecoveryKey())
        let nameCipher = Mutex("AA")
        SyncMockURLProtocol.handler.withLock { $0 = { request in
            switch request.url!.path {
            case "/v1/devices/name":
                let body = try #require(try JSONSerialization.jsonObject(with: SyncMockURLProtocol.body(request)) as? [String: String])
                let name = try #require(body["encryptedName"])
                nameCipher.withLock { $0 = name }
                let plain = try NoteCipher.open(SyncWire.decode64(name), vaultKey: account.vaultKey,
                                               context: SyncDeviceInfo.nameContext("account", "device"))
                #expect(String(decoding: plain, as: UTF8.self) == "Jan’s iPhone")
                return (200, Data("{\"ok\":true}".utf8))
            case "/v1/devices":
                return (200, try JSONSerialization.data(withJSONObject: ["devices": [["id": "device", "encryptedName": nameCipher.withLock { $0 },
                    "createdAt": 1, "lastSeen": 2, "revokedAt": NSNull()]]]))
            default:
                if request.httpMethod == "POST" { return (200, Data("{\"revision\":1}".utf8)) }
                return (200, try JSONSerialization.data(withJSONObject: ["revision": 1, "envelope": JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))]))
            }
        } }
        defer { SyncMockURLProtocol.handler.withLock { $0 = nil } }
        let pending = try #require(try await client.devices().first)
        #expect(try pending.name(accountID: "account", vaultKey: account.vaultKey) == nil)
        try await client.renameDevice("Jan’s iPhone", accountID: "account", deviceID: "device", vaultKey: account.vaultKey)
        let renamed = try #require(try await client.devices().first)
        #expect(try renamed.name(accountID: "account", vaultKey: account.vaultKey) == "Jan’s iPhone")
        await #expect(throws: SyncHTTPError.invalidResponse) {
            try await client.renameDevice("Wrong device", accountID: "account", deviceID: "another", vaultKey: account.vaultKey)
        }
        #expect(try await client.writeKeyEnvelope(envelope, parentRevision: 0) == 1)
        #expect(try await client.keyBundle().envelope == envelope)
        let other = try AccountKeys(accountID: "other").envelope(recovery: RecoveryKey())
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.writeKeyEnvelope(other, parentRevision: 0) }
    }
    @Test func pendingTransfersUseSignedGETAndExposeInvitations() async throws {
        let key = Curve25519.Signing.PrivateKey(), stored = credentials()
        let client = try transport(key, TestCredentials(stored))
        let invitation = SyncTransferInvitation(version: 1, accountId: "account", transferId: "pending",
            publicKey: SyncWire.base64(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            expiresAt: Int64(Date.now.addingTimeInterval(590).timeIntervalSince1970 * 1000))
        let expected = SyncPendingTransferRequest(invitation: invitation, deviceID: "new-device")
        let body = try JSONSerialization.data(withJSONObject: ["transfers": [JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))]])
        SyncMockURLProtocol.handler.withLock { $0 = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/transfers/pending")
            #expect(request.url?.query == nil)
            #expect(SyncMockURLProtocol.body(request).isEmpty)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + stored.accessToken)
            let time = try #require(request.value(forHTTPHeaderField: "X-Baerchen-Time"))
            let nonce = try #require(request.value(forHTTPHeaderField: "X-Baerchen-Nonce"))
            let signature = try SyncWire.decode64(#require(request.value(forHTTPHeaderField: "X-Baerchen-Signature")))
            let transcript = ["baerchen-request:1", "GET", "/v1/transfers/pending", time, nonce,
                SyncWire.hash(Data(stored.accessToken.utf8)), SyncWire.hash(Data())].joined(separator: "\n")
            #expect(key.publicKey.isValidSignature(signature, for: Data(transcript.utf8)))
            return (200, body)
        } }
        defer { SyncMockURLProtocol.handler.withLock { $0 = nil } }
        let requests = try await client.pendingTransferRequests()
        #expect(requests == [expected])
        #expect(requests.first?.invitation == invitation)
        #expect(requests.first?.id == invitation.transferId)
        #expect(requests.first?.deviceID == "new-device")
    }

    @Test func pendingTransfersRejectMalformedOrUnboundListsAndFilterExpiryRaces() async throws {
        let client = try transport(Curve25519.Signing.PrivateKey(), TestCredentials(credentials()))
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let valid: [String: Any] = ["transferId": "pending", "accountId": "account", "deviceId": "new-device",
            "publicKey": SyncWire.base64(Data(repeating: 1, count: 32)), "expiresAt": now + 590_000]
        defer { SyncMockURLProtocol.handler.withLock { $0 = nil } }
        var invalidLists: [[[String: Any]]] = [[valid, valid], Array(repeating: valid, count: 21)]
        for (field, value) in [("accountId", "other"), ("deviceId", "device"), ("deviceId", ""),
                               ("transferId", ""), ("publicKey", "AA")] {
            var item = valid; item[field] = value; invalidLists.append([item])
        }
        var future = valid; future["expiresAt"] = now + 700_000; invalidLists.append([future])
        var missing = valid; missing.removeValue(forKey: "deviceId"); invalidLists.append([missing])
        for list in invalidLists {
            let body = try JSONSerialization.data(withJSONObject: ["transfers": list])
            SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, body) } }
            await #expect(throws: (any Error).self) { try await client.pendingTransferRequests() }
        }
        var expired = valid; expired["expiresAt"] = now - 1
        let body = try JSONSerialization.data(withJSONObject: ["transfers": [expired]])
        SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, body) } }
        #expect(try await client.pendingTransferRequests().isEmpty)
        SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, Data("{\"transfers\":[]}".utf8)) } }
        #expect(try await client.pendingTransferRequests().isEmpty)
    }

    @Test func transferChallengePublishesOnlyPublicFieldsAndBindsEveryInvitationField() async throws {
        let client = try transport(Curve25519.Signing.PrivateKey(), TestCredentials(credentials()))
        let recipient = Curve25519.KeyAgreement.PrivateKey(), account = try AccountKeys(accountID: "account")
        let transfer = try account.transfer(to: recipient.publicKey, transferID: "transfer", expiresAt: Date.now.addingTimeInterval(590))
        let challenge = transfer.package.challenge
        let invitation = SyncTransferInvitation(version: 1, accountId: challenge.accountId, transferId: challenge.transferId,
            publicKey: challenge.recipientPublicKey, expiresAt: challenge.expiresAt)
        let challengeBody = try JSONSerialization.data(withJSONObject: ["challenge": JSONSerialization.jsonObject(with: JSONEncoder().encode(challenge))])
        let ready = Mutex(false), preparedBodies = Mutex<[Data]>([])
        SyncMockURLProtocol.handler.withLock { $0 = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Baerchen-Signature") != nil)
            if request.url?.path == "/v1/transfers/prepare" {
                let body = SyncMockURLProtocol.body(request)
                preparedBodies.withLock { $0.append(body) }
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String: Any]])
                #expect(object["challenge"]?["wrappedMasterKey"] == nil)
                #expect(!String(decoding: body, as: UTF8.self).contains(transfer.package.wrappedMasterKey))
                ready.withLock { $0 = true }
                return (200, Data("{\"ok\":true}".utf8))
            }
            #expect(request.url?.path == "/v1/transfers/challenge")
            return ready.withLock { $0 } ? (200, challengeBody) : (404, Data("{\"error\":\"transfer_not_ready\"}".utf8))
        } }
        defer { SyncMockURLProtocol.handler.withLock { $0 = nil } }
        #expect(try await client.receiveTransferChallenge(invitation) == nil)
        try await client.prepareTransfer(challenge)
        try await client.prepareTransfer(challenge)
        #expect(preparedBodies.withLock { $0.count } == 2)
        #expect(try await client.receiveTransferChallenge(invitation) == challenge)
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(challenge)) as? [String: Any])
        for (field, value) in [("accountId", "other"), ("transferId", "other"), ("recipientPublicKey", SyncWire.base64(Data(repeating: 2, count: 32))), ("senderPublicKey", "AA")] {
            var changed = fields; changed[field] = value
            let body = try JSONSerialization.data(withJSONObject: ["challenge": changed])
            SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, body) } }
            await #expect(throws: Error.self) { try await client.receiveTransferChallenge(invitation) }
        }
        var changed = fields; changed["expiresAt"] = challenge.expiresAt - 1000
        let body = try JSONSerialization.data(withJSONObject: ["challenge": changed])
        SyncMockURLProtocol.handler.withLock { $0 = { _ in (200, body) } }
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.receiveTransferChallenge(invitation) }
    }

    @Test func pairingRequiresMatchingAccountRecipientAndExplicitAcknowledgment() async throws {
        let signing = Curve25519.Signing.PrivateKey(), store = TestCredentials(credentials())
        let client = try transport(signing, store), account = try AccountKeys(accountID: "account")
        let recipient = Curve25519.KeyAgreement.PrivateKey(), expiration = Date.now.addingTimeInterval(590)
        let package = try account.transfer(to: recipient.publicKey, transferID: "transfer", expiresAt: expiration).package
        let startBody = try JSONSerialization.data(withJSONObject: ["transferId": "transfer", "accountId": "account",
            "publicKey": SyncWire.base64(recipient.publicKey.rawRepresentation), "expiresAt": package.expiresAt])
        let packageBody = try JSONSerialization.data(withJSONObject: ["package": JSONSerialization.jsonObject(with: JSONEncoder().encode(package))])
        let offered = Mutex(false), acknowledged = Mutex(false)
        SyncMockURLProtocol.handler.withLock { $0 = { request in
            #expect(request.value(forHTTPHeaderField: "X-Baerchen-Signature") != nil)
            switch request.url!.path {
            case "/v1/transfers/start": return (200, startBody)
            case "/v1/transfers/offer": offered.withLock { $0 = true }; return (200, Data("{\"ok\":true}".utf8))
            case "/v1/transfers/receive":
                if offered.withLock({ $0 }) && !acknowledged.withLock({ $0 }) { return (200, packageBody) }
                return (404, Data("{\"error\":\"transfer_not_ready\"}".utf8))
            case "/v1/transfers/ack": acknowledged.withLock { $0 = true }; return (200, Data("{\"ok\":true}".utf8))
            default: throw SyncHTTPError.invalidResponse
            }
        } }
        defer { SyncMockURLProtocol.handler.withLock { $0 = nil } }
        let invitation = try await client.startTransfer(publicKey: recipient.publicKey)
        #expect(try await client.receiveTransfer(invitation) == nil)
        try await client.offerTransfer(package)
        #expect(try await client.receiveTransfer(invitation)?.wrappedMasterKey == package.wrappedMasterKey)
        #expect(try await client.receiveTransfer(invitation)?.wrappedMasterKey == package.wrappedMasterKey)
        let wrongRecipient = SyncTransferInvitation(version: 1, accountId: "account", transferId: "transfer",
            publicKey: SyncWire.base64(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation), expiresAt: package.expiresAt)
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.receiveTransfer(wrongRecipient) }
        let wrongAccount = SyncTransferInvitation(version: 1, accountId: "other", transferId: "transfer", publicKey: invitation.publicKey, expiresAt: package.expiresAt)
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.receiveTransfer(wrongAccount) }
        try await client.acknowledgeTransfer(invitation.transferId)
        #expect(try await client.receiveTransfer(invitation) == nil)
        await #expect(throws: SyncHTTPError.invalidResponse) { try await client.startTransfer(publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey) }
    }

}
