// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// How a cloud version the publisher obtained by name or inside a conflict becomes a stored fetched version (`ck_remote`),
/// exactly like a record delivered by a fetch: validated, assets pinned durably first, quarantined if it cannot be understood.
/// The receiver's sink (Task 6) is the production implementation of this seam; `CloudBasicRemoteIntake` is the minimal
/// one the publisher ships with and tests against.
public protocol CloudRemoteIntake: Sendable {
    func intake(_ record: CloudRecord, delivery: CloudDelivery) throws -> CloudIntakeOutcome
}

public enum CloudIntakeOutcome: Sendable, Equatable {
    case stored
    case echo
    case ignoredStale
    case ignoredSupersededIncarnation
    /// Not understood or divergent: held in quarantine, the entity is fenced.
    case quarantined
}

public struct CloudBasicRemoteIntake: CloudRemoteIntake {
    private let store: CloudSyncStore
    private let pinDirectory: URL
    private let clock: @Sendable () -> Date

    /// `pinDirectory` is the durable, no-backup folder pinned assets are copied into (relative paths from
    /// `CloudSyncStore.newPinnedPath` are stored in the rows).
    private let syncDirectory: @Sendable (URL) throws -> Void

    public init(store: CloudSyncStore, pinDirectory: URL, clock: @escaping @Sendable () -> Date = { Date() },
                syncDirectory: @escaping @Sendable (URL) throws -> Void = CloudBasicRemoteIntake.fsyncDirectory) {
        self.store = store; self.pinDirectory = pinDirectory; self.clock = clock; self.syncDirectory = syncDirectory
    }

    public func intake(_ record: CloudRecord, delivery: CloudDelivery) throws -> CloudIntakeOutcome {
        let raw = try Self.rawFields(record)
        let header: CloudEntityHeader
        do {
            guard case .entity(let decoded) = try CloudRecordCodec.decode(record) else { throw CloudIntakeError.notAnEntity(record.name) }
            header = decoded
        } catch CloudRecordRejection.unsupported(let reason) {
            let pinned = try pinAll(record)
            let obsolete = try store.quarantine(record: CloudQuarantineRecord(recordName: record.name, reason: reason.code, v: Self.version(of: record), rawFields: raw),
                                                pinned: pinned)
            remove(obsolete)
            return .quarantined
        }
        guard let systemFields = record.systemFields else { throw CloudIntakeError.missingSystemFields(record.name) }
        var pinned: [CloudPinnedAsset] = []
        var sealed: Data?, sealedPath: String?, sealedSha256: String?
        switch header.payload {
        case .inline(let data): sealed = data
        case .asset:
            pinned = try pinAll(record)
            guard let asset = pinned.first else { throw CloudIntakeError.pinMismatch(record.name) }
            sealedPath = asset.path; sealedSha256 = asset.sha256
        }
        let version = CloudRemoteVersion(entity: CloudEntityRef(entityType: header.entityType.rawValue, entityId: header.entityId),
                                         inc: header.inc, incs: header.incs, ver: header.ver, sid: header.sid, sids: header.sids,
                                         systemFields: systemFields, sealed: sealed, sealedPath: sealedPath, sealedSha256: sealedSha256,
                                         blobRefs: header.blobs, receivedAt: clock(), rawFields: raw, pinnedAssets: pinned)
        switch try store.storeRemote(version, delivery: delivery) {
        case .stored: return .stored
        case .echo: removeUnstored(pinned); return .echo
        case .ignoredStale: removeUnstored(pinned); return .ignoredStale
        case .ignoredSupersededIncarnation: removeUnstored(pinned); return .ignoredSupersededIncarnation
        case .quarantinedDivergent(let obsolete): remove(obsolete); return .quarantined
        }
    }

    // MARK: pinning

    private var pinner: CloudAssetPinner { CloudAssetPinner(directory: pinDirectory, syncDirectory: syncDirectory) }
    private func pinAll(_ record: CloudRecord) throws -> [CloudPinnedAsset] { try pinner.pin(record) }

    /// `fsync` on the directory itself (F_FULLFSYNC where the file system supports it).
    public static func fsyncDirectory(_ url: URL) throws { try CloudAssetPinner.fsyncDirectory(url) }

    private func remove(_ relativePaths: [String]) { pinner.remove(relativePaths) }

    /// Files pinned for a version the store did not keep: nothing references them.
    private func removeUnstored(_ pinned: [CloudPinnedAsset]) { remove(pinned.map(\.path)) }

    static func rawFields(_ record: CloudRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    static func version(of record: CloudRecord) -> Int64? {
        if case .int(let v)? = record.fields["v"] { return v }
        return nil
    }
}

public enum CloudIntakeError: Error, Equatable {
    case notAnEntity(String)
    case missingSystemFields(String)
    case pinMismatch(String)
}
