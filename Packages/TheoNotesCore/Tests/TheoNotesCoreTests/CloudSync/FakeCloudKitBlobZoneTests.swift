// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// `BlobPart` records live in a second zone the engine never fetches. The fake models what Gate G0 measured
/// a fetch delivers Entity and KeyBundle records only; parts are read by name, with or without their asset.
@Suite struct FakeCloudKitBlobZoneTests {
    private func part(_ tag: String = "a") throws -> CloudRecord {
        CloudRecordCodec.encode(CloudBlobPartHeader(
            hash: String(repeating: tag, count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: 3,
            partSha256: String(repeating: "b", count: 64), asset: try tempFile(Data([1, 2, 3]))))
    }

    @Test func aFetchNeverDeliversBlobParts() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let blob = try part()
        try await a.save([entity("with-part"), blob])
        try await b.fetch()
        #expect(b.sink.changedNames == ["e.note.with-part"])
        #expect(b.sink.changed(named: blob.name) == nil)
    }

    @Test func aPartIsReadByNameWithItsAssetOrWithoutIt() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let blob = try part()
        try await a.save(blob)
        let metadataOnly = try await b.device.fetch([blob.name], keys: ["v", "hash", "part", "parts", "partBytes", "totalBytes", "partSha256"])
        #expect(metadataOnly[blob.name]?.fields["asset"] == nil)
        #expect(metadataOnly[blob.name]?.fields["hash"] != nil)
        let full = try await b.device.fetch([blob.name], keys: nil)
        guard case .asset(let url)? = full[blob.name]?.fields["asset"] else { Issue.record("the asset must come with a full read"); return }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func aDeletedPartIsNotAnnouncedByTheFetchEither() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let blob = try part()
        try await a.save(blob)
        try await b.fetch()
        try await a.device.delete([blob.name])
        try await b.fetch()
        #expect(b.sink.deletedNames.isEmpty)
    }

    @Test func aPeerThatPutsPartsIntoTheFetchedZoneCanStillBeModelled() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud), b = try await Peer.make(cloud)
        let blob = try part()
        try await a.save(blob)
        await b.device.setFetchesBlobZone(true)
        try await b.fetch()
        #expect(b.sink.changed(named: blob.name) != nil)
    }

    @Test func deletingTheZoneTakesBothZonesAndTheirPartsWithIt() async throws {
        let cloud = FakeCloudKitAccount()
        let a = try await Peer.make(cloud)
        let blob = try part()
        try await a.save([entity("e1"), blob])
        let userHash = cloud.userHash
        try await a.device.deleteZone(expecting: userHash)
        #expect(await cloud.recordNames.isEmpty)
        #expect(try await a.device.fetch([blob.name], keys: nil).isEmpty)
    }
}
