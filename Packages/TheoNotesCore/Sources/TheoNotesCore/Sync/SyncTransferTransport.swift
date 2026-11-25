// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public struct SyncTransferInvitation: Codable, Equatable, Sendable {
    public let version: Int
    public let accountId: String
    public let transferId: String
    public let publicKey: String
    public let expiresAt: Int64

    public var expiration: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }

    public func validate(now: Date = .now) throws {
        try SyncWire.validateID(accountId); try SyncWire.validateID(transferId)
        guard version == 1, try SyncWire.decode64(publicKey).count == 32 else { throw SyncProtocolError.invalidPayload }
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        guard expiresAt > milliseconds, expiresAt <= milliseconds + 600_000 else { throw AccountKeyError.expiredTransfer }
    }

    public func qrPayload(endpoint: URL, now: Date = .now) throws -> String {
        try validate(now: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var url = URLComponents()
        url.scheme = LegacyNames.urlScheme; url.host = "pair"
        url.queryItems = [.init(name: "origin", value: endpoint.absoluteString),
                          .init(name: "invitation", value: SyncWire.base64(try encoder.encode(self)))]
        guard let encoded = url.string else { throw SyncProtocolError.invalidPayload }
        return encoded
    }

    public static func decodeQR(_ value: String, endpoint: URL, now: Date = .now) throws -> Self {
        guard value.utf8.count <= 8192, let url = URLComponents(string: value),
              url.scheme == LegacyNames.urlScheme, url.host == "pair", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let query = url.queryItems, query.count == 2,
              query.filter({ $0.name == "origin" }).count == 1,
              query.filter({ $0.name == "invitation" }).count == 1,
              query.first(where: { $0.name == "origin" })?.value == endpoint.absoluteString,
              let encoded = query.first(where: { $0.name == "invitation" })?.value else { throw SyncProtocolError.invalidPayload }
        let data = try SyncWire.decode64(encoded)
        guard data.count <= 4096 else { throw SyncProtocolError.invalidPayload }
        let invitation = try JSONDecoder().decode(Self.self, from: data)
        try invitation.validate(now: now)
        return invitation
    }
}

public struct SyncPendingTransferRequest: Codable, Equatable, Sendable, Identifiable {
    public let transferId: String
    public let accountId: String
    public let publicKey: String
    public let expiresAt: Int64
    public let deviceID: String

    public var id: String { transferId }
    public var invitation: SyncTransferInvitation {
        SyncTransferInvitation(version: 1, accountId: accountId, transferId: transferId,
                               publicKey: publicKey, expiresAt: expiresAt)
    }

    public init(invitation: SyncTransferInvitation, deviceID: String) {
        transferId = invitation.transferId; accountId = invitation.accountId
        publicKey = invitation.publicKey; expiresAt = invitation.expiresAt
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey {
        case transferId, accountId, publicKey, expiresAt
        case deviceID = "deviceId"
    }
}

extension HTTPSyncTransport {
    /// Expired entries are omitted to tolerate invitations expiring while the response is in flight.
    /// All entries, including expired ones, must still have valid identity and key fields.
    public func pendingTransferRequests() async throws -> [SyncPendingTransferRequest] {
        struct Result: Decodable, Sendable { let transfers: [SyncPendingTransferRequest] }
        let result: Result = try await operation(path: "/v1/transfers/pending", method: "GET")
        let identity = try await accountIdentity()
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        guard result.transfers.count <= 20 else { throw SyncHTTPError.invalidResponse }
        var ids = Set<String>()
        for request in result.transfers {
            try SyncWire.validateID(request.transferId)
            try SyncWire.validateID(request.accountId)
            try SyncWire.validateID(request.deviceID)
            guard ids.insert(request.id).inserted, request.accountId == identity.account,
                  request.deviceID != identity.device,
                  try SyncWire.decode64(request.publicKey).count == 32,
                  request.expiresAt > 0, request.expiresAt <= now + 600_000 else {
                throw SyncHTTPError.invalidResponse
            }
        }
        return result.transfers.filter { $0.expiresAt > now }
    }

    public func startTransfer(publicKey: Curve25519.KeyAgreement.PublicKey) async throws -> SyncTransferInvitation {
        struct Body: Encodable { let publicKey: String }
        struct Result: Decodable, Sendable { let transferId: String; let accountId: String; let publicKey: String; let expiresAt: Int64 }
        let key = SyncWire.base64(publicKey.rawRepresentation)
        let result: Result = try await operation(path: "/v1/transfers/start", method: "POST", body: JSONEncoder().encode(Body(publicKey: key)))
        let invitation = SyncTransferInvitation(version: 1, accountId: result.accountId, transferId: result.transferId,
                                                publicKey: result.publicKey, expiresAt: result.expiresAt)
        try invitation.validate()
        guard try await accountIdentity().account == result.accountId, result.publicKey == key else { throw SyncHTTPError.invalidResponse }
        return invitation
    }

    /// Publishes only public handshake keys. The sender must compare words before offering a key package.
    public func prepareTransfer(_ challenge: AccountKeys.TransferChallenge) async throws {
        try challenge.validate()
        guard try await accountIdentity().account == challenge.accountId else { throw SyncHTTPError.invalidResponse }
        struct Body: Encodable { let challenge: AccountKeys.TransferChallenge }
        struct Result: Decodable, Sendable { let ok: Bool }
        let result: Result = try await operation(path: "/v1/transfers/prepare", method: "POST",
            body: JSONEncoder().encode(Body(challenge: challenge)))
        guard result.ok else { throw SyncHTTPError.invalidResponse }
    }

    public func receiveTransferChallenge(_ invitation: SyncTransferInvitation) async throws -> AccountKeys.TransferChallenge? {
        try invitation.validate()
        guard try await accountIdentity().account == invitation.accountId else { throw SyncHTTPError.invalidResponse }
        struct Body: Encodable { let transferId: String }
        struct Result: Decodable, Sendable { let challenge: AccountKeys.TransferChallenge }
        let result: Result
        do {
            result = try await operation(path: "/v1/transfers/challenge", method: "POST",
                body: JSONEncoder().encode(Body(transferId: invitation.transferId)))
        } catch SyncHTTPError.server(status: 404, code: "transfer_not_ready", retryAfter: _) { return nil }
        try result.challenge.validate()
        guard result.challenge.accountId == invitation.accountId,
              result.challenge.transferId == invitation.transferId,
              result.challenge.recipientPublicKey == invitation.publicKey,
              result.challenge.expiresAt == invitation.expiresAt else { throw SyncHTTPError.invalidResponse }
        return result.challenge
    }

    public func offerTransfer(_ package: AccountKeys.Transfer) async throws {
        try Self.validateTransferPackage(package)
        guard try await accountIdentity().account == package.accountId else { throw SyncHTTPError.invalidResponse }
        struct Body: Encodable { let package: AccountKeys.Transfer }
        struct Result: Decodable, Sendable { let ok: Bool }
        let result: Result = try await operation(path: "/v1/transfers/offer", method: "POST", body: JSONEncoder().encode(Body(package: package)))
        guard result.ok else { throw SyncHTTPError.invalidResponse }
    }

    public func receiveTransfer(_ invitation: SyncTransferInvitation) async throws -> AccountKeys.Transfer? {
        try invitation.validate()
        guard try await accountIdentity().account == invitation.accountId else { throw SyncHTTPError.invalidResponse }
        struct Body: Encodable { let transferId: String }
        struct Result: Decodable, Sendable { let package: AccountKeys.Transfer }
        let result: Result
        do { result = try await operation(path: "/v1/transfers/receive", method: "POST", body: JSONEncoder().encode(Body(transferId: invitation.transferId))) }
        catch SyncHTTPError.server(status: 404, code: "transfer_not_ready", retryAfter: _) { return nil }
        try Self.validateTransferPackage(result.package)
        guard result.package.accountId == invitation.accountId, result.package.transferId == invitation.transferId,
              result.package.recipientPublicKey == invitation.publicKey,
              result.package.expiresAt <= invitation.expiresAt else { throw SyncHTTPError.invalidResponse }
        return result.package
    }

    /// Call only after persisting the device-wrapped keys, or to cancel an owned invitation.
    public func acknowledgeTransfer(_ transferID: String) async throws {
        try SyncWire.validateID(transferID)
        struct Body: Encodable { let transferId: String }
        struct Result: Decodable, Sendable { let ok: Bool }
        let result: Result = try await operation(path: "/v1/transfers/ack", method: "POST", body: JSONEncoder().encode(Body(transferId: transferID)))
        guard result.ok else { throw SyncHTTPError.invalidResponse }
    }

    private static func validateTransferPackage(_ package: AccountKeys.Transfer) throws {
        try SyncWire.validateID(package.accountId); try SyncWire.validateID(package.transferId)
        guard package.version == 1,
              try SyncWire.decode64(package.senderPublicKey).count == 32,
              try SyncWire.decode64(package.recipientPublicKey).count == 32,
              try SyncWire.decode64(package.wrappedMasterKey).count == 60 else { throw SyncHTTPError.invalidResponse }
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        guard package.expiresAt > now, package.expiresAt <= now + 600_000 else { throw AccountKeyError.expiredTransfer }
    }
}
