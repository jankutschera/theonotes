// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Hand-made records for the sink tests: structurally valid, payload bytes arbitrary (the sink never opens them).
enum Rec {
    static func entity(_ id: String, _ ver: Int64, sid: String? = nil, inc: String = "incA", incs: [String] = [], payload: Data = Data([9, 9, 9]),
                       type: SyncEntityType = .note, asset: URL? = nil, blobs: [String] = []) -> CloudRecord {
        let sid = sid ?? "sid-\(ver)"
        let header = CloudEntityHeader(entityType: type, entityId: id, inc: inc, incs: incs, ver: ver, sid: sid, sids: [sid],
                                       payload: asset.map { .asset($0) } ?? .inline(payload), blobs: blobs)
        var record = CloudRecordCodec.encode(header)
        record.systemFields = Data("tag-\(id)-\(inc)-\(ver)-\(sid)".utf8)
        return record
    }

    static func version(_ record: CloudRecord) throws -> CloudRemoteVersion {
        guard case .entity(let h) = try CloudRecordCodec.decode(record) else { throw CloudIntakeError.notAnEntity(record.name) }
        guard case .inline(let data) = h.payload else { throw CloudIntakeError.notAnEntity(record.name) }
        return CloudRemoteVersion(entity: CloudEntityRef(entityType: h.entityType.rawValue, entityId: h.entityId), inc: h.inc, incs: h.incs, ver: h.ver,
                                  sid: h.sid, sids: h.sids, systemFields: record.systemFields ?? Data(), sealed: data, blobRefs: h.blobs)
    }

    static func tempFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ck-asset-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }
}

extension PublisherDevice {
    /// The sealed bytes the publisher would send for this note's current content (for tests that hand-deliver versions).
    func pinnedFiles() throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: paths.cloudPinned, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.append(String(url.standardizedFileURL.path.dropFirst(paths.cloudPinned.standardizedFileURL.path.count + 1)))
        }
        return files.sorted()
    }

    func remoteVersions() throws -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: try store.allRemote().map { ($0.recordName, $0.ver) })
    }

    /// Moves a hand-made version into the pair the way an applied merge does (so later deliveries are compared with it).
    func adopt(_ record: CloudRecord) throws {
        let version = try Rec.version(record)
        try store.recordApplied(accountGeneration: try store.generation(), remote: version, ancestor: version.sealed ?? Data())
    }
}
