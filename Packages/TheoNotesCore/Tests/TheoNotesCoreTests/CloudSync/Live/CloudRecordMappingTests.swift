// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

/// `CKRecord` can be created and archived without a container or an entitlement, so the whole mapping is testable in `swift test`.
@Suite struct CloudRecordMappingTests {
    private let zones = CloudZones(configuration: CloudKitConfiguration(containerIdentifier: "iCloud.example.test", zoneName: "TheoNotesUnit"))

    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mapping-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    private func entity(id: String = "n1", incs: [String] = ["old1"], payload: CloudEntityPayload = .inline(Data([1, 2, 3]))) -> CloudRecord {
        CloudRecordCodec.encode(CloudEntityHeader(entityType: .note, entityId: id, inc: "inc-1", incs: incs, ver: 2, sid: "s1", sids: ["s1", "s0"],
                                                  payload: payload, blobs: [String(repeating: "a", count: 64)]))
    }

    private func blobPart(asset: URL) -> CloudRecord {
        CloudRecordCodec.encode(CloudBlobPartHeader(hash: String(repeating: "c", count: 64), part: 0, parts: 1, partBytes: 33_554_432, totalBytes: 3,
                                                    partSha256: String(repeating: "d", count: 64), asset: asset))
    }

    private func keyBundle() -> CloudRecord {
        CloudRecordCodec.encode(CloudKeyBundleHeader(account: "acct-1", rev: 3, envelope: Data("{}".utf8)))
    }

    @Test func everyCodecCaseRoundTripsAndStillDecodes() throws {
        let asset = try file([9, 8, 7])
        let cases: [CloudRecord] = [
            entity(),
            entity(id: "n2", payload: .asset(asset)),
            blobPart(asset: asset),
            keyBundle(),
        ]
        for original in cases {
            let ck = try CloudRecordMapping.makeCKRecord(from: original, base: nil, zones: zones)
            #expect(ck.recordType == original.type.rawValue)
            #expect(ck.recordID.recordName == original.name)
            let back = try #require(CloudRecordMapping.makeCloudRecord(from: ck))
            #expect(back.name == original.name && back.type == original.type)
            #expect(back.fields == original.fields)
            #expect(try CloudRecordCodec.decode(back) == CloudRecordCodec.decode(original))
        }
    }

    @Test func theAssetUrlIsKeptAsGiven() throws {
        let asset = try file([1])
        let ck = try CloudRecordMapping.makeCKRecord(from: blobPart(asset: asset), base: nil, zones: zones)
        #expect((ck["asset"] as? CKAsset)?.fileURL == asset)
        #expect(CloudRecordMapping.makeCloudRecord(from: ck)?.fields["asset"] == .asset(asset))
    }

    @Test func aMissingAssetFileIsRefusedBeforeAnythingIsSent() throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("not-there-\(UUID().uuidString)")
        #expect(throws: CloudRecordMappingError.assetFileMissing(field: "asset")) {
            try CloudRecordMapping.makeCKRecord(from: blobPart(asset: gone), base: nil, zones: zones)
        }
    }

    @Test func recordTypesLiveInTheirZones() throws {
        let asset = try file([1])
        #expect(try CloudRecordMapping.makeCKRecord(from: entity(), base: nil, zones: zones).recordID.zoneID.zoneName == "TheoNotesUnit")
        #expect(try CloudRecordMapping.makeCKRecord(from: keyBundle(), base: nil, zones: zones).recordID.zoneID.zoneName == "TheoNotesUnit")
        #expect(try CloudRecordMapping.makeCKRecord(from: blobPart(asset: asset), base: nil, zones: zones).recordID.zoneID.zoneName == "TheoNotesUnitBlobs")
        #expect(zones.zoneID(forRecordName: "b.abc.32.0").zoneName == "TheoNotesUnitBlobs")
        #expect(zones.zoneID(forRecordName: "e.note.x").zoneName == "TheoNotesUnit")
        #expect(zones.zoneID(forRecordName: "keybundle").zoneName == "TheoNotesUnit")
    }

    @Test func theSystemFieldsValueNamesTheVersionAndNothingElse() throws {
        let one = CloudRecordMapping.SystemFields.make(tag: "3", name: "e.note.n1")
        #expect(one == CloudRecordMapping.SystemFields.make(tag: "3", name: "e.note.n1"), "equal versions must give equal bytes")
        #expect(one != CloudRecordMapping.SystemFields.make(tag: "4", name: "e.note.n1"))
        let parsed = try #require(CloudRecordMapping.SystemFields.parse(one))
        #expect(parsed.tag == "3" && parsed.name == "e.note.n1")
        #expect(CloudRecordMapping.SystemFields.parse(Data([1, 2, 3])) == nil)
    }

    @Test func aSaveContinuesItsBaseRecord() throws {
        // A base as CloudKit would hand it back. (A change tag cannot be forged locally; id, type and zone are what is checked here.)
        let base = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "e.note.n1", zoneID: zones.main))
        var next = entity()
        next.systemFields = CloudRecordMapping.SystemFields.make(tag: "3", name: "e.note.n1")
        let ck = try CloudRecordMapping.makeCKRecord(from: next, base: base, zones: zones)
        #expect(ck.recordID == base.recordID && ck.recordType == "Entity")
        #expect(ck["etype"] as? String == "note")
    }

    @Test func aSaveWithAVersionButWithoutABaseIsRefused() {
        var next = entity()
        next.systemFields = CloudRecordMapping.SystemFields.make(tag: "3", name: "e.note.n1")
        #expect(throws: CloudRecordMappingError.systemFieldsUnreadable) { try CloudRecordMapping.makeCKRecord(from: next, base: nil, zones: zones) }
    }

    @Test func aBaseOfAnotherRecordIsRefused() {
        let other = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "e.note.other", zoneID: zones.main))
        var next = entity()
        next.systemFields = CloudRecordMapping.SystemFields.make(tag: "3", name: "e.note.n1")
        #expect(throws: CloudRecordMappingError.systemFieldsMismatch("name")) { try CloudRecordMapping.makeCKRecord(from: next, base: other, zones: zones) }
        let wrongType = CKRecord(recordType: "KeyBundle", recordID: CKRecord.ID(recordName: "e.note.n1", zoneID: zones.main))
        #expect(throws: CloudRecordMappingError.systemFieldsMismatch("type")) { try CloudRecordMapping.makeCKRecord(from: next, base: wrongType, zones: zones) }
    }

    @Test func theArchiveOfARecordRoundTripsForTheBaseCache() throws {
        let record = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "e.note.n1", zoneID: zones.main))
        let restored = try CloudRecordMapping.record(fromArchive: CloudRecordMapping.archive(of: record))
        #expect(restored.recordID == record.recordID && restored.recordType == "Entity")
        #expect(throws: CloudRecordMappingError.systemFieldsUnreadable) { try CloudRecordMapping.record(fromArchive: Data([1, 2, 3])) }
    }

    @Test func aFieldOutsideTheSpecIsNeverWritten() throws {
        var record = entity()
        record.fields["note"] = .string("would enter the Production schema")
        #expect(throws: CloudRecordMappingError.fieldNotAllowed(recordType: "Entity", field: "note")) {
            try CloudRecordMapping.makeCKRecord(from: record, base: nil, zones: zones)
        }
        var part = blobPart(asset: try file([1]))
        part.fields["cipher"] = .bytes(Data([1]))
        #expect(throws: CloudRecordMappingError.fieldNotAllowed(recordType: "BlobPart", field: "cipher")) {
            try CloudRecordMapping.makeCKRecord(from: part, base: nil, zones: zones)
        }
    }

    @Test func aVersionWithAnAssetPayloadCarriesNoInlineCipher() throws {
        // (That setting an absent field to nil really removes it on the server is exercised by the live contract run, L3.)
        let base = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "e.note.n1", zoneID: zones.main))
        base["cipher"] = Data([1, 2, 3])
        var next = entity(payload: .asset(try file([4, 5])))
        next.systemFields = CloudRecordMapping.SystemFields.make(tag: "3", name: "e.note.n1")
        let ck = try CloudRecordMapping.makeCKRecord(from: next, base: base, zones: zones)
        #expect(ck["cipher"] == nil && ck["cipherAsset"] != nil)
    }

    @Test func emptyListsRoundTrip() throws {
        let original = entity(incs: [])
        let ck = try CloudRecordMapping.makeCKRecord(from: original, base: nil, zones: zones)
        let back = try #require(CloudRecordMapping.makeCloudRecord(from: ck))
        #expect(back.fields["incs"] == .strings([]))
        #expect(try CloudRecordCodec.decode(back) == CloudRecordCodec.decode(original))
    }

    @Test func aValueOfAnUnknownTypeIsNeverMisreadAsOneOfOurs() throws {
        let ck = try CloudRecordMapping.makeCKRecord(from: entity(), base: nil, zones: zones)
        ck["ver"] = Date()                       // a known field with a wrong type
        ck["extra"] = Date()                     // an unknown field
        let back = try #require(CloudRecordMapping.makeCloudRecord(from: ck))
        if case .string = back.fields["ver"] {} else { Issue.record("a Date must not read as an integer") }
        #expect(throws: CloudRecordRejection.self) { _ = try CloudRecordCodec.decode(back) }
    }

    @Test func aRecordTypeWeDoNotModelIsSkipped() {
        let ck = CKRecord(recordType: "Newer", recordID: CKRecord.ID(recordName: "x", zoneID: zones.main))
        #expect(CloudRecordMapping.makeCloudRecord(from: ck) == nil)
    }

    @Test func theUserHashIsTheHexSha256OfTheRecordName() {
        let expected = SHA256.hash(data: Data("_abc".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(CloudRecordMapping.userHash(recordName: "_abc") == expected)
    }

    @Test func theBlobZoneNameFollowsTheMainZoneName() {
        let configuration = CloudKitConfiguration(containerIdentifier: "iCloud.example.test")
        #expect(configuration.zoneName == "TheoNotes" && configuration.blobZoneName == "TheoNotesBlobs")
    }
}
