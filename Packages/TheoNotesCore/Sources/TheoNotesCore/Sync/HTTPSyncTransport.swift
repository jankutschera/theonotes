// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public struct SyncCredentials: Codable, Equatable, Sendable {
    public var accountId: String
    public var deviceId: String
    public var accessToken: String
    public var refreshToken: String
    public var accessExpiresAt: Int64
    public var refreshExpiresAt: Int64
    public init(accountId: String, deviceId: String, accessToken: String, refreshToken: String,
                accessExpiresAt: Int64, refreshExpiresAt: Int64) {
        self.accountId = accountId; self.deviceId = deviceId; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt; self.refreshExpiresAt = refreshExpiresAt
    }
}
public protocol SyncCredentialStore: Sendable {
    func load() async throws -> SyncCredentials?
    func save(_ credentials: SyncCredentials) async throws
}
public enum SyncHTTPError: Error, Equatable, Sendable {
    case invalidEndpoint, authenticationRequired, invalidResponse
    case server(status: Int, code: String, retryAfter: TimeInterval?)
}

/// One actor owns refresh rotation for all metadata, onboarding, device and blob operations.
/// A rotated refresh token is persisted before any caller receives the new access token.
public actor HTTPSyncTransport: SyncTransport {
    private struct Failure: Decodable { let error: String }
    private let endpoint: URL
    private let session: URLSession
    private let signingKey: Curve25519.Signing.PrivateKey
    private let credentials: any SyncCredentialStore
    private var refreshing: Task<SyncCredentials, any Error>?
    private var closed = false

    public init(endpoint: URL, signingKey: Curve25519.Signing.PrivateKey, credentials: any SyncCredentialStore,
                session: URLSession = URLSession(configuration: .ephemeral)) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/"
        else { throw SyncHTTPError.invalidEndpoint }
        self.endpoint = endpoint; self.signingKey = signingKey; self.credentials = credentials; self.session = session
    }

    public func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
        guard !mutations.isEmpty, mutations.count <= 100, Set(mutations.map(\.mutationId)).count == mutations.count else { throw SyncProtocolError.invalidPayload }
        for mutation in mutations { try mutation.validate() }
        struct Batch: Encodable { let mutations: [SyncMutation] }
        let body = try JSONEncoder().encode(Batch(mutations: mutations))
        guard body.count <= 1_048_576 else { throw SyncProtocolError.responseTooLarge }
        let response: SyncPushResult = try await operation(path: "/v1/sync/push", method: "POST", body: body)
        guard response.results.count == mutations.count else { throw SyncHTTPError.invalidResponse }
        for (result, mutation) in zip(response.results, mutations) {
            guard result.mutationId == mutation.mutationId else { throw SyncHTTPError.invalidResponse }
            if result.status == .accepted, result.entity?.mutation != mutation { throw SyncHTTPError.invalidResponse }
        }
        return response
    }
    public func pull(after cursor: Int64) async throws -> SyncPullResult {
        guard cursor >= 0, cursor <= SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        let result: SyncPullResult = try await operation(path: "/v1/sync/pull?after=\(cursor)", method: "GET")
        guard result.cursor >= cursor, result.cursor <= SyncWire.maximumRevision, result.changes.count <= 500,
              !result.hasMore || !result.changes.isEmpty else { throw SyncHTTPError.invalidResponse }
        var previous = cursor
        for entity in result.changes {
            guard entity.sequence > previous, entity.sequence <= result.cursor else { throw SyncHTTPError.invalidResponse }
            previous = entity.sequence
        }
        guard result.changes.last?.sequence ?? cursor == result.cursor else { throw SyncHTTPError.invalidResponse }
        return result
    }
    public func acknowledge(_ cursor: Int64) async throws {
        guard cursor >= 0, cursor <= SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        struct Body: Encodable { let cursor: Int64 }
        struct Ack: Decodable, Sendable { let ok: Bool }
        let result: Ack = try await operation(path: "/v1/sync/ack", method: "POST", body: JSONEncoder().encode(Body(cursor: cursor)))
        guard result.ok else { throw SyncHTTPError.invalidResponse }
    }

    /// Await before deleting Keychain credentials on disconnect. A suspended token rotation
    /// must finish or cancel before deletion, otherwise its late save could reconnect the app.
    public func shutdown() async {
        closed = true
        let pending = refreshing
        pending?.cancel()
        session.invalidateAndCancel()
        _ = try? await pending?.value
    }

    func operation<T: Decodable & Sendable>(path: String, method: String, body: Data = Data()) async throws -> T {
        var current = try await activeCredentials()
        do { return try await send(path: path, method: method, body: body, token: current.accessToken) }
        catch SyncHTTPError.server(status: 401, code: "session_expired", retryAfter: _) {
            // Another suspended operation may already have rotated this exact access token.
            if let latest = try await credentials.load(), latest.accessToken != current.accessToken { current = latest }
            else { current = try await refresh(current) }
            return try await send(path: path, method: method, body: body, token: current.accessToken)
        }
    }
    private func activeCredentials() async throws -> SyncCredentials {
        guard !closed else { throw SyncHTTPError.authenticationRequired }
        guard let current = try await credentials.load() else { throw SyncHTTPError.authenticationRequired }
        if current.accessExpiresAt <= Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000 { return try await refresh(current) }
        return current
    }

    func accountIdentity() async throws -> (account: String, device: String) {
        let value = try await activeCredentials()
        return (value.accountId, value.deviceId)
    }
    private func refresh(_ current: SyncCredentials) async throws -> SyncCredentials {
        if let refreshing { return try await refreshing.value }
        guard current.refreshExpiresAt > Int64(Date.now.timeIntervalSince1970 * 1000) else { throw SyncHTTPError.authenticationRequired }
        let task = Task { try await self.rotate(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
    private func rotate(_ old: SyncCredentials) async throws -> SyncCredentials {
        struct Body: Encodable { let refreshToken: String }
        struct Tokens: Decodable, Sendable { let accessToken: String; let refreshToken: String; let accessExpiresAt: Int64; let refreshExpiresAt: Int64 }
        let tokens: Tokens = try await send(path: "/v1/auth/refresh", method: "POST",
            body: JSONEncoder().encode(Body(refreshToken: old.refreshToken)), token: old.refreshToken)
        guard try SyncWire.decode64(tokens.accessToken).count == 32, try SyncWire.decode64(tokens.refreshToken).count == 32,
              tokens.accessExpiresAt > Int64(Date.now.timeIntervalSince1970 * 1000), tokens.refreshExpiresAt > tokens.accessExpiresAt
        else { throw SyncHTTPError.invalidResponse }
        let value = SyncCredentials(accountId: old.accountId, deviceId: old.deviceId, accessToken: tokens.accessToken,
                                    refreshToken: tokens.refreshToken, accessExpiresAt: tokens.accessExpiresAt, refreshExpiresAt: tokens.refreshExpiresAt)
        try Task.checkCancellation()
        try await credentials.save(value)
        return value
    }
    private func send<T: Decodable & Sendable>(path: String, method: String, body: Data, token: String) async throws -> T {
        guard path.hasPrefix("/v1/"), let url = URL(string: path, relativeTo: endpoint)?.absoluteURL,
              url.host == endpoint.host, url.scheme == endpoint.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw SyncHTTPError.invalidEndpoint }
        let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000), nonce = UUIDv7.make()
        let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let transcript = [ProtocolLabels.request, method, target, String(timestamp), nonce,
                          SyncWire.hash(Data(token.utf8)), SyncWire.hash(body)].joined(separator: "\n")
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Baerchen-Time")
        request.setValue(nonce, forHTTPHeaderField: "X-Baerchen-Nonce")
        request.setValue(SyncWire.base64(try signingKey.signature(for: Data(transcript.utf8))), forHTTPHeaderField: "X-Baerchen-Signature")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !body.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (stream, response) = try await session.bytes(for: request, delegate: SyncNoRedirectDelegate.shared)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw SyncHTTPError.invalidResponse }
        let maximum = 4_194_304
        guard response.expectedContentLength <= maximum else { throw SyncProtocolError.responseTooLarge }
        var data = Data(); data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maximum)))))
        for try await byte in stream {
            guard data.count < maximum else { throw SyncProtocolError.responseTooLarge }
            data.append(byte)
        }
        if !(200..<300).contains(response.statusCode) {
            let code = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "http_error"
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw SyncHTTPError.server(status: response.statusCode, code: code, retryAfter: retry)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SyncHTTPError.invalidResponse }
    }
}

private final class SyncNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SyncNoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
