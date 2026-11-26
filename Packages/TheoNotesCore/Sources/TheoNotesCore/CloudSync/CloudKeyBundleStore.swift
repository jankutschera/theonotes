// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// The `KeyBundle` record (record name `keybundle`) and the library's local key state (ck_state.recoveryState,
// ck_state.bundleRevision). The record's `envelope` field carries the JSON of `CloudKeyBundle`: the public
// `AccountKeyEnvelope` plus a canary sealed under a key derived from the vault key. Everything in it is public or
// ciphertext; no recovery word, seed or key byte (pinned by the canary tests in `CloudKeyBundleTests`).

/// `ck_state.recoveryState`
/// - `none`: this library holds no CloudKit keys yet;
/// - `acknowledgedSkip`: skipped at setup with the risk acknowledged; offered again once after the first successful sync;
/// - `pending`: not saved and that one-time offer was shown; the Settings reminder stays;
/// - `saved`: a recovery key was confirmed (three-word check) or used to join.
public enum CloudRecoveryState: String, Sendable, Equatable, Codable {
    case none, pending, saved, acknowledgedSkip
}

public struct CloudKeyLocalState: Sendable, Equatable {
    /// The account whose bundle this library verified (`ck_state.accountId`); nil = none. A library never adopts a bundle
    /// of another account (detach first).
    public var accountId: String?
    public var recovery: CloudRecoveryState
    /// The highest `rev` this library verified; 0 = none. A lower one is refused as a rollback.
    public var bundleRevision: Int64
    public init(accountId: String? = nil, recovery: CloudRecoveryState, bundleRevision: Int64) {
        self.accountId = accountId; self.recovery = recovery; self.bundleRevision = bundleRevision
    }
}

public protocol CloudKeyStateStore: Sendable {
    func keyState() throws -> CloudKeyLocalState
    func setKeyState(_ state: CloudKeyLocalState) throws
}

extension CloudSyncStore: CloudKeyStateStore {
    public func keyState() throws -> CloudKeyLocalState {
        try database.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT accountId, recoveryState, bundleRevision FROM ck_state WHERE id=1")
            return CloudKeyLocalState(accountId: row?["accountId"],
                                      recovery: (row?["recoveryState"] as String?).flatMap(CloudRecoveryState.init(rawValue:)) ?? .none,
                                      bundleRevision: row?["bundleRevision"] ?? 0)
        }
    }

    public func setKeyState(_ state: CloudKeyLocalState) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE ck_state SET accountId=?, recoveryState=?, bundleRevision=? WHERE id=1",
                           arguments: [state.accountId, state.recovery.rawValue, state.bundleRevision])
        }
    }
}

/// The content of the `KeyBundle` record.
public struct CloudKeyBundle: Codable, Sendable, Equatable {
    public var accountId: String
    public var rev: Int64
    public var envelope: AccountKeyEnvelope
    /// See `CloudKeyCanary`.
    public var canary: String

    public init(accountId: String, rev: Int64, envelope: AccountKeyEnvelope, canary: String) {
        self.accountId = accountId; self.rev = rev; self.envelope = envelope; self.canary = canary
    }

    /// A bundle sealed under `keys` (the canary authenticates every other field).
    public static func sealed(keys: AccountKeys, rev: Int64, envelope: AccountKeyEnvelope, recovery: CloudRecoveryState) throws -> CloudKeyBundle {
        let canary = try CloudKeyCanary.seal(vaultKey: keys.vaultKey, accountId: keys.accountID, rev: rev, envelope: envelope, recovery: recovery)
        return CloudKeyBundle(accountId: keys.accountID, rev: rev, envelope: envelope, canary: canary)
    }
}

/// A bundle as fetched: content plus the system fields (change tag) a replacement must be based on.
public struct FetchedKeyBundle: Sendable, Equatable {
    public var bundle: CloudKeyBundle
    public var systemFields: Data?
    public init(bundle: CloudKeyBundle, systemFields: Data?) { self.bundle = bundle; self.systemFields = systemFields }
}

/// Authenticates the whole bundle under the vault key: an AES-GCM box under HKDF(vault key, salt account id, info label)
/// whose authenticated data is every other field of the bundle (account, rev, and all six envelope fields, each
/// length-prefixed) and whose sealed plaintext names the account and whether a recovery key was saved. Changing the
/// recovery wrapper, the recovery public key, the revision or the account makes it fail.
/// The labels are neutral (no working title) and frozen.
public enum CloudKeyCanary {
    static let purpose = "cloudsync-keybundle-canary"
    static let label = "cloudsync-keybundle-canary:1"

    private struct Content: Codable { let purpose: String; let account: String; let recovery: String }

    private static func key(_ vaultKey: SymmetricKey, _ accountId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, salt: Data(accountId.utf8), info: Data(label.utf8), outputByteCount: 32)
    }

    static func authenticatedData(accountId: String, rev: Int64, envelope: AccountKeyEnvelope) -> Data {
        var out = Data(label.utf8)
        for field in [accountId, String(rev), String(envelope.version), envelope.algorithm, envelope.accountId,
                      envelope.wrappedMasterKey, envelope.wrappedVaultKey, envelope.recoveryPublicKey] {
            out.append(contentsOf: "|\(field.utf8.count):".utf8)
            out.append(contentsOf: field.utf8)
        }
        return out
    }

    public static func seal(vaultKey: SymmetricKey, accountId: String, rev: Int64, envelope: AccountKeyEnvelope,
                            recovery: CloudRecoveryState) throws -> String {
        let content = Content(purpose: purpose, account: accountId, recovery: recovery == .saved ? "saved" : "skipped")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let box = try AES.GCM.seal(try encoder.encode(content), using: key(vaultKey, accountId),
                                         authenticating: authenticatedData(accountId: accountId, rev: rev, envelope: envelope)).combined
        else { throw CloudKeyError.keyMismatch }
        return SyncWire.base64(box)
    }

    /// The recovery state the bundle carries (`saved` or `acknowledgedSkip`); `keyMismatch` when the vault key is not the
    /// account's or any field of the bundle was changed.
    public static func open(_ bundle: CloudKeyBundle, vaultKey: SymmetricKey) throws -> CloudRecoveryState {
        do {
            let box = try AES.GCM.SealedBox(combined: try SyncWire.decode64(bundle.canary))
            let plain = try AES.GCM.open(box, using: key(vaultKey, bundle.accountId),
                                         authenticating: authenticatedData(accountId: bundle.accountId, rev: bundle.rev, envelope: bundle.envelope))
            let content = try JSONDecoder().decode(Content.self, from: plain)
            guard content.purpose == purpose, content.account == bundle.accountId else { throw CloudKeyError.keyMismatch }
            switch content.recovery {
            case "saved": return .saved
            case "skipped": return .acknowledgedSkip
            default: throw CloudKeyError.keyMismatch
            }
        } catch {
            throw CloudKeyError.keyMismatch
        }
    }
}

/// The checks every path runs before it trusts a bundle (join, rotation, adoption).
enum CloudKeyVerification {
    /// The pins: the library's account (`ck_state`, cleared by detach) and the device's per-account revision high-water
    /// mark (keychain, kept across detach). A bundle of another account, or with a revision lower than either the
    /// library's or the device's highest verified one, is refused.
    static func checkPin(_ bundle: CloudKeyBundle, _ local: CloudKeyLocalState, seeds: any CloudKeySeedStore) throws {
        try checkPin(bundle, local, mark: try seeds.highWaterMark(accountId: bundle.accountId))
    }

    static func checkPin(_ bundle: CloudKeyBundle, _ local: CloudKeyLocalState, mark: Int64?) throws {
        var floor: Int64 = 0
        if let pinned = local.accountId {
            guard pinned == bundle.accountId else { throw CloudKeyError.accountMismatch }
            floor = local.bundleRevision
        }
        floor = max(floor, mark ?? 0)
        guard bundle.rev >= floor else { throw CloudKeyError.bundleRollback }
    }

    /// Records a verified bundle: first the device's mark (never lowered), then the library state.
    static func record(_ next: CloudKeyLocalState, rev: Int64, accountId: String, seeds: any CloudKeySeedStore,
                       state: any CloudKeyStateStore, previous: CloudKeyLocalState? = nil) throws {
        try seeds.raiseHighWaterMark(rev, accountId: accountId)
        if next != previous { try state.setKeyState(next) }
    }

    /// Keys from the master key (the seed): the envelope must open and the canary must authenticate the bundle.
    static func open(_ bundle: CloudKeyBundle, masterKey: Data) throws -> (AccountKeys, CloudRecoveryState) {
        guard masterKey.count == 32, let keys = try? AccountKeys(masterKey: SymmetricKey(data: masterKey), envelope: bundle.envelope),
              keys.accountID == bundle.accountId
        else { throw CloudKeyError.keyMismatch }
        return (keys, try CloudKeyCanary.open(bundle, vaultKey: keys.vaultKey))
    }

    /// `keys` (already held) open this bundle to the same vault key.
    static func check(_ bundle: CloudKeyBundle, keys: AccountKeys) throws -> CloudRecoveryState {
        guard bundle.accountId == keys.accountID else { throw CloudKeyError.keyMismatch }
        let (opened, recovery) = try open(bundle, masterKey: keys.masterKeyData)
        guard sameVault(opened, keys) else { throw CloudKeyError.keyMismatch }
        return recovery
    }

    /// The recovery wrapper of `envelope` opens with `recoveryKey` to the same master and vault key.
    static func checkRecoveryWrapper(_ envelope: AccountKeyEnvelope, recoveryKey: RecoveryKey, keys: AccountKeys) throws {
        guard let reopened = try? AccountKeys(recovery: recoveryKey, envelope: envelope),
              CloudKeyConstantTime.equal(reopened.masterKeyData, keys.masterKeyData), sameVault(reopened, keys)
        else { throw CloudKeyError.keyMismatch }
    }

    static func sameVault(_ a: AccountKeys, _ b: AccountKeys) -> Bool {
        CloudKeyConstantTime.equal(a.vaultKey.withUnsafeBytes { Data($0) }, b.vaultKey.withUnsafeBytes { Data($0) })
    }

    /// The local state after verifying `bundle`: pinned account, its revision, and the recovery state (saved wins).
    static func adopted(_ local: CloudKeyLocalState, _ bundle: CloudKeyBundle, recovery: CloudRecoveryState) -> CloudKeyLocalState {
        var next = local
        next.accountId = bundle.accountId
        next.bundleRevision = max(local.bundleRevision, bundle.rev)
        switch (local.recovery, recovery) {
        case (_, .saved): next.recovery = .saved
        case (.none, _): next.recovery = .acknowledgedSkip
        default: break
        }
        return next
    }
}

public enum CloudKeyBundleCodec {
    static let format = 1

    private struct Payload: Codable { let format: Int; let envelope: AccountKeyEnvelope; let canary: String }

    public static func record(_ bundle: CloudKeyBundle, systemFields: Data?) throws -> CloudRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Payload(format: format, envelope: bundle.envelope, canary: bundle.canary))
        var record = CloudRecordCodec.encode(CloudKeyBundleHeader(account: bundle.accountId, rev: bundle.rev, envelope: payload))
        record.systemFields = systemFields
        return record
    }

    /// Fails closed: anything this build cannot read is `bundleUnreadable` (never treated as "no bundle").
    public static func decode(_ record: CloudRecord) throws -> CloudKeyBundle {
        let header: CloudKeyBundleHeader
        do {
            guard case .keyBundle(let decoded) = try CloudRecordCodec.decode(record) else { throw CloudKeyError.bundleUnreadable("record-type") }
            header = decoded
        } catch let rejection as CloudRecordRejection {
            guard case .unsupported(let reason) = rejection else { throw CloudKeyError.bundleUnreadable("rejected") }
            throw CloudKeyError.bundleUnreadable(reason.code)
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: header.envelope) else { throw CloudKeyError.bundleUnreadable("payload") }
        guard payload.format == format else { throw CloudKeyError.bundleUnreadable("payload-format:\(payload.format)") }
        guard payload.envelope.accountId == header.account else { throw CloudKeyError.bundleUnreadable("account-mismatch") }
        return CloudKeyBundle(accountId: header.account, rev: header.rev, envelope: payload.envelope, canary: payload.canary)
    }
}

/// Where a gateway's send outcomes can be read back (`ck_send_result`).
public protocol CloudSendResultSource: Sendable {
    func sendOutcome(attemptId: String) throws -> CloudSaveOutcome?
}

extension CloudSyncStore: CloudSendResultSource {
    public func sendOutcome(attemptId: String) throws -> CloudSaveOutcome? { try sendResult(attemptId: attemptId)?.outcome }
}

public enum CloudKeyBundleWrite: Sendable, Equatable {
    /// The cloud holds exactly the bundle we wrote.
    case written
    /// The cloud holds a different bundle (nil: none at all, a replace found the record gone). Nothing was overwritten.
    case conflict(FetchedKeyBundle?)
    /// The outcome is unknown or failed and the cloud does not show our bundle: try again later.
    case notWritten
}

/// Reads and writes the one `KeyBundle` record through the gateway. A create is create-only (no system fields); a replace
/// is change-tag checked against the fetched bundle it replaces. An unknown outcome (lost response, timeout) is resolved by
/// fetching the record and comparing its content, never by retrying with a fetched tag.
public struct CloudKeyBundleStore: Sendable {
    public let gateway: any CloudKitGateway
    public let results: any CloudSendResultSource
    public let accountGeneration: Int64
    public let outcomeTimeout: TimeInterval
    /// When set, the generation in force at the moment of the write replaces `accountGeneration`. A store that lives longer than one
    /// generation needs it: the library store refuses a send result of any other generation.
    public let currentGeneration: (@Sendable () throws -> Int64)?

    public init(gateway: any CloudKitGateway, results: any CloudSendResultSource, accountGeneration: Int64 = 0,
                outcomeTimeout: TimeInterval = 20, currentGeneration: (@Sendable () throws -> Int64)? = nil) {
        self.gateway = gateway; self.results = results; self.accountGeneration = accountGeneration; self.outcomeTimeout = outcomeTimeout
        self.currentGeneration = currentGeneration
    }

    public func fetch() async throws -> FetchedKeyBundle? {
        let name = CloudRecordCodec.keyBundleRecordName
        guard let record = try await gateway.fetch([name], keys: nil)[name] else { return nil }
        return FetchedKeyBundle(bundle: try CloudKeyBundleCodec.decode(record), systemFields: record.systemFields)
    }

    public func create(_ bundle: CloudKeyBundle) async throws -> CloudKeyBundleWrite {
        try await write(bundle, base: nil)
    }

    public func replace(_ bundle: CloudKeyBundle, base: FetchedKeyBundle) async throws -> CloudKeyBundleWrite {
        guard base.systemFields != nil else { return .conflict(base) }
        return try await write(bundle, base: base)
    }

    private func write(_ bundle: CloudKeyBundle, base: FetchedKeyBundle?) async throws -> CloudKeyBundleWrite {
        let attemptId = "kb-" + UUIDv7.make()
        let record = try CloudKeyBundleCodec.record(bundle, systemFields: base?.systemFields)
        let generation = try currentGeneration?() ?? accountGeneration
        try await gateway.submit([CloudSave(attemptId: attemptId, accountGeneration: generation, record: record)])
        switch try await outcome(attemptId) {
        case .saved?:
            return .written
        case .serverRecordChanged(let server)?:
            let decoded = try CloudKeyBundleCodec.decode(server)
            if decoded == bundle { return .written }
            return .conflict(FetchedKeyBundle(bundle: decoded, systemFields: server.systemFields))
        case .unknownItem?:
            return .conflict(nil)
        default:
            // No answer, or an answer that does not say what the cloud holds: look.
            guard let current = try await fetch() else { return base == nil ? .notWritten : .conflict(nil) }
            if current.bundle == bundle { return .written }
            guard let base else { return .conflict(current) }
            // A replace whose base is still the cloud's content did not land; anything else is someone else's write.
            return current.bundle == base.bundle ? .notWritten : .conflict(current)
        }
    }

    private func outcome(_ attemptId: String) async throws -> CloudSaveOutcome? {
        let deadline = Date().addingTimeInterval(outcomeTimeout)
        while true {
            if let found = try results.sendOutcome(attemptId: attemptId) { return found }
            if Date() >= deadline { return nil }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
