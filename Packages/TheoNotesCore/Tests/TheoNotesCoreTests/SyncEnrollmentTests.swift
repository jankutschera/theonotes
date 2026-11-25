// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import TheoNotesCore

private final class EnrollmentProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest, Data) throws -> Data)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "enroll.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            let callback = try #require(Self.handler.withLock { $0 })
            let data = try callback(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor EnrollmentCredentials: SyncCredentialStore {
    var value: SyncCredentials?
    func load() -> SyncCredentials? { value }
    func save(_ value: SyncCredentials) { self.value = value }
}

@Suite(.serialized) struct SyncEnrollmentTests {
    private let code = SyncWire.base64(Data(repeating: 9, count: 32))
    private let flowID = SyncWire.base64(Data(repeating: 8, count: 32))
    private func client(_ key: Curve25519.Signing.PrivateKey, _ credentials: EnrollmentCredentials) throws -> SyncEnrollment {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [EnrollmentProtocol.self]
        return try SyncEnrollment(endpoint: URL(string: "https://enroll.example")!, deviceID: "device", signingKey: key,
            transferPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, credentials: credentials, session: URLSession(configuration: configuration))
    }
    private func tokens() -> SyncCredentials {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        return SyncCredentials(accountId: "account", deviceId: "device", accessToken: SyncWire.base64(Data(repeating: 1, count: 32)),
            refreshToken: SyncWire.base64(Data(repeating: 2, count: 32)), accessExpiresAt: now + 900_000, refreshExpiresAt: now + 86_400_000)
    }

    @Test func browserGrantIsFlowBoundSignedAndSavedBeforeCompletion() async throws {
        let key = Curve25519.Signing.PrivateKey(), store = EnrollmentCredentials(), expected = tokens()
        let enrollment = try client(key, store), flowID = flowID, code = code
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let flow = try JSONSerialization.data(withJSONObject: ["flowId": flowID, "accountId": "account",
            "url": "https://enroll.example/auth?flow=\(flowID)", "expiresAt": now + 300_000])
        EnrollmentProtocol.handler.withLock { $0 = { request, body in
            if request.url?.path == "/v1/auth/begin" { return flow }
            let time = try #require(request.value(forHTTPHeaderField: "X-Baerchen-Time"))
            let nonce = try #require(request.value(forHTTPHeaderField: "X-Baerchen-Nonce"))
            let transcript = ["baerchen-request:1", "POST", "/v1/auth/exchange", time, nonce, SyncWire.hash(Data(code.utf8)), SyncWire.hash(body)].joined(separator: "\n")
            let signature = try SyncWire.decode64(#require(request.value(forHTTPHeaderField: "X-Baerchen-Signature")))
            #expect(key.publicKey.isValidSignature(signature, for: Data(transcript.utf8)))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + code)
            return try JSONEncoder().encode(expected)
        } }
        defer { EnrollmentProtocol.handler.withLock { $0 = nil } }
        let started = try await enrollment.begin(.login)
        await #expect(throws: SyncHTTPError.invalidResponse) {
            try await enrollment.finish(started, callback: URL(string: "baerchen://sync-auth?flow=wrong&code=\(code)")!)
        }
        #expect(await store.value == nil)
        let result = try await enrollment.finish(started, callback: URL(string: "baerchen://sync-auth?flow=\(flowID)&code=\(code)")!)
        #expect(result == expected)
        #expect(await store.value == expected)
        await enrollment.shutdown()
        await #expect(throws: SyncHTTPError.authenticationRequired) { try await enrollment.begin(.login) }
    }

    @Test func recoverySignsOnlyTheExpectedDualProofAndRecoversTheAccountKey() async throws {
        let key = Curve25519.Signing.PrivateKey(), store = EnrollmentCredentials(), expected = tokens()
        let enrollment = try client(key, store), recovery = RecoveryKey(), account = try AccountKeys(accountID: "account")
        let envelope = try account.envelope(recovery: recovery), code = code, flowID = flowID
        let transcript = Mutex("")
        EnrollmentProtocol.handler.withLock { $0 = { request, body in
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            switch request.url!.path {
            case "/v1/auth/recovery/begin":
                let device = try #require(object["device"] as? [String: String])
                let challenge = SyncWire.base64(Data(repeating: 7, count: 32))
                let message = ["baerchen-recovery:1", "account", flowID, challenge, "device",
                    try #require(device["signingKey"]), try #require(device["transferKey"]), SyncWire.hash(Data("AA".utf8))].joined(separator: "\n")
                transcript.withLock { $0 = message }
                return try JSONSerialization.data(withJSONObject: ["flowId": flowID, "accountId": "account", "challenge": challenge,
                    "message": message, "revision": 1, "envelope": JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))])
            case "/v1/auth/recovery/finish":
                let message = Data(transcript.withLock { $0 }.utf8)
                let signature = try SyncWire.decode64(#require(object["signature"] as? String))
                let deviceSignature = try SyncWire.decode64(#require(object["deviceSignature"] as? String))
                #expect(try recovery.signingKey(accountID: "account").publicKey.isValidSignature(signature, for: message))
                #expect(key.publicKey.isValidSignature(deviceSignature, for: message))
                return try JSONSerialization.data(withJSONObject: ["code": code, "accountId": "account", "deviceId": "device"])
            default: return try JSONEncoder().encode(expected)
            }
        } }
        defer { EnrollmentProtocol.handler.withLock { $0 = nil } }
        let result = try await enrollment.recover(words: recovery.words())
        #expect(result.credentials == expected)
        #expect(result.keys.vaultKey.withUnsafeBytes { Data($0) } == account.vaultKey.withUnsafeBytes { Data($0) })
        #expect(await store.value == expected)
    }

    @Test func refusesCrossOriginBrowserFlowAndModifiedRecoveryTranscript() async throws {
        let enrollment = try client(Curve25519.Signing.PrivateKey(), EnrollmentCredentials())
        let flowID = flowID, recovery = RecoveryKey(), account = try AccountKeys(accountID: "account")
        let envelope = try account.envelope(recovery: recovery)
        EnrollmentProtocol.handler.withLock { $0 = { request, _ in
            if request.url?.path == "/v1/auth/begin" {
                return try JSONSerialization.data(withJSONObject: ["flowId": flowID, "accountId": "account",
                    "url": "https://wrong.example/auth?flow=\(flowID)", "expiresAt": Int64(Date.now.timeIntervalSince1970 * 1000) + 300_000])
            }
            return try JSONSerialization.data(withJSONObject: ["flowId": flowID, "accountId": "account", "challenge": flowID,
                "message": "sign a different operation", "revision": 1, "envelope": JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))])
        } }
        defer { EnrollmentProtocol.handler.withLock { $0 = nil } }
        await #expect(throws: SyncHTTPError.invalidResponse) { try await enrollment.begin(.login) }
        await #expect(throws: SyncHTTPError.invalidResponse) { try await enrollment.recover(words: recovery.words()) }
    }
}
