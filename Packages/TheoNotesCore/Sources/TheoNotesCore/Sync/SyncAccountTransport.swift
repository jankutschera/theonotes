// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public struct SyncKeyBundle: Decodable, Sendable {
    public let envelope: AccountKeyEnvelope
    public let revision: Int64
}
public struct SyncDeviceInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let encryptedName: String
    public let createdAt: Int64
    public let lastSeen: Int64
    public let revokedAt: Int64?

    public func name(accountID: String, vaultKey: SymmetricKey) throws -> String? {
        if encryptedName == "AA" { return nil }
        let data = try NoteCipher.open(SyncWire.decode64(encryptedName), vaultKey: vaultKey, context: Self.nameContext(accountID, id))
        guard let name = String(data: data, encoding: .utf8), !name.isEmpty, data.count <= 256 else { throw SyncProtocolError.invalidPayload }
        return name
    }
    static func nameContext(_ account: String, _ device: String) -> String { "\(ProtocolLabels.deviceName):\(account):\(device)" }
}

extension HTTPSyncTransport {
    public func keyBundle() async throws -> SyncKeyBundle {
        let result: SyncKeyBundle = try await operation(path: "/v1/keys", method: "GET")
        try Self.validateKeyEnvelope(result.envelope)
        let identity = try await accountIdentity()
        guard result.envelope.accountId == identity.account,
              result.revision > 0, result.revision <= SyncWire.maximumRevision else { throw SyncHTTPError.invalidResponse }
        return result
    }

    public func writeKeyEnvelope(_ envelope: AccountKeyEnvelope, parentRevision: Int64) async throws -> Int64 {
        try Self.validateKeyEnvelope(envelope)
        guard try await accountIdentity().account == envelope.accountId else { throw SyncHTTPError.invalidResponse }
        guard parentRevision >= 0, parentRevision < SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        struct Body: Encodable { let envelope: AccountKeyEnvelope; let parentRevision: Int64 }
        struct Result: Decodable, Sendable { let revision: Int64 }
        let result: Result = try await operation(path: "/v1/keys", method: "POST",
            body: JSONEncoder().encode(Body(envelope: envelope, parentRevision: parentRevision)))
        guard result.revision == parentRevision + 1 else { throw SyncHTTPError.invalidResponse }
        return result.revision
    }

    public func devices() async throws -> [SyncDeviceInfo] {
        struct Result: Decodable, Sendable { let devices: [SyncDeviceInfo] }
        let result: Result = try await operation(path: "/v1/devices", method: "GET")
        guard result.devices.count <= 1000, Set(result.devices.map(\.id)).count == result.devices.count else { throw SyncHTTPError.invalidResponse }
        for device in result.devices {
            try SyncWire.validateID(device.id)
            guard device.createdAt >= 0, device.lastSeen >= 0, device.revokedAt.map({ $0 >= 0 }) ?? true,
                  try SyncWire.decode64(device.encryptedName).count <= 4096 else { throw SyncHTTPError.invalidResponse }
        }
        return result.devices
    }

    public func renameDevice(_ name: String, accountID: String, deviceID: String, vaultKey: SymmetricKey) async throws {
        try SyncWire.validateID(accountID); try SyncWire.validateID(deviceID)
        let identity = try await accountIdentity()
        guard accountID == identity.account, deviceID == identity.device else { throw SyncHTTPError.invalidResponse }
        let data = Data(name.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty, data.count <= 256 else { throw SyncProtocolError.invalidPayload }
        struct Body: Encodable { let encryptedName: String }
        struct Result: Decodable, Sendable { let ok: Bool }
        let cipher = try NoteCipher.seal(data, vaultKey: vaultKey, context: SyncDeviceInfo.nameContext(accountID, deviceID))
        let result: Result = try await operation(path: "/v1/devices/name", method: "POST",
                                               body: JSONEncoder().encode(Body(encryptedName: SyncWire.base64(cipher))))
        guard result.ok else { throw SyncHTTPError.invalidResponse }
    }

    public func revokeDevice(_ deviceID: String) async throws {
        try SyncWire.validateID(deviceID)
        struct Body: Encodable { let deviceId: String }
        struct Result: Decodable, Sendable { let ok: Bool }
        let result: Result = try await operation(path: "/v1/devices/revoke", method: "POST", body: JSONEncoder().encode(Body(deviceId: deviceID)))
        guard result.ok else { throw SyncHTTPError.invalidResponse }
    }

    private static func validateKeyEnvelope(_ envelope: AccountKeyEnvelope) throws {
        try SyncWire.validateID(envelope.accountId)
        guard envelope.version == 1, envelope.algorithm == "HKDF-SHA256+AES-256-GCM+Ed25519",
              try SyncWire.decode64(envelope.wrappedMasterKey).count == 60,
              try SyncWire.decode64(envelope.wrappedVaultKey).count == 60,
              try SyncWire.decode64(envelope.recoveryPublicKey).count == 32 else { throw SyncHTTPError.invalidResponse }
    }
}
