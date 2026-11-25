// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public struct SyncAuthFlow: Decodable, Sendable {
    public let flowId: String
    public let accountId: String
    public let url: URL
    public let expiresAt: Int64
}

public struct SyncRecoveredAccount: Sendable {
    public let credentials: SyncCredentials
    public let keys: AccountKeys
    public let envelope: AccountKeyEnvelope
}

/// The device keys must be durably stored before beginning. Browser authentication yields a
/// short-lived grant, bound to this signing key; it never exposes account encryption keys.
public actor SyncEnrollment {
    private struct Failure: Decodable { let error: String }
    public enum Kind: String, Encodable, Sendable { case register, login }
    struct Device: Encodable, Sendable {
        let deviceId: String, signingKey: String, transferKey: String
        // Explicit pending-name marker. The account vault is unavailable before enrollment;
        // a signed rename replaces this with account-encrypted name bytes after key recovery.
        let encryptedName = "AA"
    }
    private let endpoint: URL
    private let signingKey: Curve25519.Signing.PrivateKey
    private let device: Device
    private let credentials: any SyncCredentialStore
    private let session: URLSession
    private var closed = false
    private var persisting: Task<Void, any Error>?

    public init(endpoint: URL, deviceID: String, signingKey: Curve25519.Signing.PrivateKey,
                transferPublicKey: Curve25519.KeyAgreement.PublicKey, credentials: any SyncCredentialStore,
                session: URLSession = URLSession(configuration: .ephemeral)) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/" else { throw SyncHTTPError.invalidEndpoint }
        try SyncWire.validateID(deviceID)
        self.endpoint = endpoint; self.signingKey = signingKey; self.credentials = credentials; self.session = session
        device = Device(deviceId: deviceID, signingKey: SyncWire.base64(signingKey.publicKey.rawRepresentation),
                        transferKey: SyncWire.base64(transferPublicKey.rawRepresentation))
    }

    public func begin(_ kind: Kind, provisioningToken: String? = nil) async throws -> SyncAuthFlow {
        struct Body: Encodable { let kind: Kind; let device: Device; let provisioningToken: String? }
        let flow: SyncAuthFlow = try await post("/v1/auth/begin", Body(kind: kind, device: device, provisioningToken: provisioningToken))
        try Self.validateFlow(flow, endpoint: endpoint)
        return flow
    }

    public func finish(_ flow: SyncAuthFlow, callback: URL) async throws -> SyncCredentials {
        try Self.validateFlow(flow, endpoint: endpoint)
        guard callback.scheme == LegacyNames.urlScheme, callback.host == "sync-auth", callback.user == nil, callback.password == nil,
              callback.port == nil, callback.fragment == nil, callback.path.isEmpty || callback.path == "/",
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), let items = parts.queryItems,
              items.count == 2, Set(items.map(\.name)) == ["code", "flow"],
              items.first(where: { $0.name == "flow" })?.value == flow.flowId,
              let code = items.first(where: { $0.name == "code" })?.value,
              try SyncWire.decode64(code).count == 32 else { throw SyncHTTPError.invalidResponse }
        return try await exchange(code: code, accountID: flow.accountId)
    }

    public func recover(words: String) async throws -> SyncRecoveredAccount {
        struct Begin: Encodable { let device: Device }
        struct Challenge: Decodable, Sendable {
            let flowId: String, accountId: String, challenge: String, message: String
            let envelope: AccountKeyEnvelope
            let revision: Int64
        }
        let recovery = try RecoveryKey(words: words)
        let challenge: Challenge = try await post("/v1/auth/recovery/begin", Begin(device: device))
        try SyncWire.validateID(challenge.accountId)
        guard try SyncWire.decode64(challenge.flowId).count == 32,
              try SyncWire.decode64(challenge.challenge).count == 32,
              challenge.revision > 0, challenge.revision <= SyncWire.maximumRevision,
              challenge.envelope.accountId == challenge.accountId else { throw SyncHTTPError.invalidResponse }
        let transcript = [ProtocolLabels.recovery, challenge.accountId, challenge.flowId, challenge.challenge,
                          device.deviceId, device.signingKey, device.transferKey, SyncWire.hash(Data(device.encryptedName.utf8))].joined(separator: "\n")
        guard transcript == challenge.message else { throw SyncHTTPError.invalidResponse }
        let keys = try AccountKeys(recovery: recovery, envelope: challenge.envelope)
        struct Proof: Encodable { let flowId: String, signature: String, deviceSignature: String }
        struct Grant: Decodable, Sendable { let code: String, accountId: String, deviceId: String }
        let bytes = Data(transcript.utf8)
        let proof = Proof(flowId: challenge.flowId,
                          signature: try SyncWire.base64(recovery.signingKey(accountID: challenge.accountId).signature(for: bytes)),
                          deviceSignature: try SyncWire.base64(signingKey.signature(for: bytes)))
        let grant: Grant = try await post("/v1/auth/recovery/finish", proof)
        guard grant.accountId == challenge.accountId, grant.deviceId == device.deviceId else { throw SyncHTTPError.invalidResponse }
        let tokens = try await exchange(code: grant.code, accountID: grant.accountId)
        return SyncRecoveredAccount(credentials: tokens, keys: keys, envelope: challenge.envelope)
    }

    public func shutdown() async {
        closed = true
        session.invalidateAndCancel()
        _ = try? await persisting?.value
    }

    private static func validateFlow(_ flow: SyncAuthFlow, endpoint: URL) throws {
        try SyncWire.validateID(flow.accountId)
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let query = URLComponents(url: flow.url, resolvingAgainstBaseURL: false)?.queryItems
        guard try SyncWire.decode64(flow.flowId).count == 32, flow.expiresAt > now, flow.expiresAt <= now + 360_000,
              flow.url.scheme == "https", flow.url.host == endpoint.host, flow.url.port == endpoint.port,
              flow.url.user == nil, flow.url.password == nil, flow.url.fragment == nil, flow.url.path == "/auth",
              query?.count == 1, query?.first?.name == "flow", query?.first?.value == flow.flowId else { throw SyncHTTPError.invalidResponse }
    }

    private func exchange(code: String, accountID: String) async throws -> SyncCredentials {
        guard try SyncWire.decode64(code).count == 32 else { throw SyncHTTPError.invalidResponse }
        struct Body: Encodable { let code: String }
        let result: SyncCredentials = try await post("/v1/auth/exchange", Body(code: code), proofToken: code)
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        guard result.accountId == accountID, result.deviceId == device.deviceId,
              try SyncWire.decode64(result.accessToken).count == 32, try SyncWire.decode64(result.refreshToken).count == 32,
              result.accessExpiresAt > now, result.refreshExpiresAt > result.accessExpiresAt else { throw SyncHTTPError.invalidResponse }
        try Task.checkCancellation()
        guard !closed, persisting == nil else { throw SyncHTTPError.authenticationRequired }
        // Disconnect awaits a save already in flight; no completed network request can save
        // credentials after shutdown has returned and the caller cleared its Keychain item.
        let store = credentials
        let saving = Task { try await store.save(result) }
        persisting = saving
        defer { persisting = nil }
        try await saving.value
        return result
    }

    private func post<Body: Encodable, Result: Decodable & Sendable>(_ path: String, _ value: Body, proofToken: String? = nil) async throws -> Result {
        guard !closed else { throw SyncHTTPError.authenticationRequired }
        guard path.hasPrefix("/v1/auth/"), let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { throw SyncHTTPError.invalidEndpoint }
        let body = try JSONEncoder().encode(value)
        guard body.count <= 65_536 else { throw SyncProtocolError.responseTooLarge }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let proofToken {
            let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000), nonce = UUIDv7.make()
            let transcript = [ProtocolLabels.request, "POST", path, String(timestamp), nonce, SyncWire.hash(Data(proofToken.utf8)), SyncWire.hash(body)].joined(separator: "\n")
            request.setValue("Bearer \(proofToken)", forHTTPHeaderField: "Authorization")
            request.setValue(String(timestamp), forHTTPHeaderField: "X-Baerchen-Time")
            request.setValue(nonce, forHTTPHeaderField: "X-Baerchen-Nonce")
            request.setValue(try SyncWire.base64(signingKey.signature(for: Data(transcript.utf8))), forHTTPHeaderField: "X-Baerchen-Signature")
        }
        let (stream, response) = try await session.bytes(for: request, delegate: EnrollmentNoRedirect.shared)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw SyncHTTPError.invalidResponse }
        guard response.expectedContentLength <= 262_144 else { throw SyncProtocolError.responseTooLarge }
        var data = Data()
        for try await byte in stream {
            guard data.count < 262_144 else { throw SyncProtocolError.responseTooLarge }
            data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "http_error"
            throw SyncHTTPError.server(status: response.statusCode, code: code,
                                       retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        do { return try JSONDecoder().decode(Result.self, from: data) }
        catch { throw SyncHTTPError.invalidResponse }
    }
}

private final class EnrollmentNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = EnrollmentNoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
