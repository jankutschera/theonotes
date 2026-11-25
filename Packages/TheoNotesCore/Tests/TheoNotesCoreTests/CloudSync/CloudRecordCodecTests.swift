// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Fixture decoding shared by the codec tests and the fake's tests.
enum CloudRecordFixture {
    struct Case { let name: String; let kind: String?; let reason: String?; let record: CloudRecord }

    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sync/cloudkit-record-v1.json")
    }

    static func load() throws -> (valid: [Case], rejected: [Case]) {
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func cases(_ key: String) throws -> [Case] {
            try (root[key] as? [[String: Any]] ?? []).map { item in
                Case(name: item["case"] as! String, kind: item["kind"] as? String, reason: item["reason"] as? String,
                     record: try record(item["record"] as! [String: Any]))
            }
        }
        return (try cases("valid"), try cases("rejected"))
    }

    static func record(_ json: [String: Any]) throws -> CloudRecord {
        var fields: [String: CloudValue] = [:]
        for (key, raw) in json["fields"] as! [String: [String: Any]] {
            let (kind, value) = raw.first!
            switch kind {
            case "int": fields[key] = .int((value as! NSNumber).int64Value)
            case "string": fields[key] = .string(value as! String)
            case "bytes": fields[key] = .bytes(Data(base64Encoded: value as! String)!)
            case "strings": fields[key] = .strings(value as! [String])
            case "asset": fields[key] = .asset(URL(string: value as! String)!)
            default: Issue.record("unknown fixture kind \(kind)")
            }
        }
        return CloudRecord(name: json["name"] as! String, type: CloudRecordType(rawValue: json["type"] as! String)!, fields: fields)
    }
}

@Suite struct CloudRecordCodecTests {
    static let hash = String(repeating: "a", count: 64)
    static let hash2 = String(repeating: "b", count: 64)

    static func entity(
        type: SyncEntityType = .note, id: String = "n-1", inc: String = "inc-1", incs: [String] = [], ver: Int64 = 1,
        sid: String = "att-1", sids: [String]? = nil, payload: CloudEntityPayload = .inline(Data([1, 2, 3])), blobs: [String] = []
    ) -> CloudEntityHeader {
        CloudEntityHeader(entityType: type, entityId: id, inc: inc, incs: incs, ver: ver, sid: sid, sids: sids ?? [sid], payload: payload, blobs: blobs)
    }

    static func reason(_ record: CloudRecord) -> CloudRecordRejection.Reason? {
        do { _ = try CloudRecordCodec.decode(record); return nil } catch let rejection as CloudRecordRejection {
            if case .unsupported(let reason) = rejection { return reason }
            return nil
        } catch { return nil }
    }

    // MARK: round trips

    @Test func entityWithInlineCipherRoundTrips() throws {
        let header = Self.entity(type: .tagPreference, id: "t-9", incs: ["a", "b"], ver: 7, sid: "s3", sids: ["s3", "s2", "s1"], blobs: [Self.hash])
        let record = CloudRecordCodec.encode(header)
        #expect(record.name == "e.tagPreference.t-9")
        #expect(record.type == .entity)
        #expect(try CloudRecordCodec.decode(record) == .entity(header))
    }

    @Test func entityWithAssetRoundTripsAndKeepsTheAssetUrl() throws {
        let url = URL(fileURLWithPath: "/tmp/some-cipher.bin")
        let header = Self.entity(payload: .asset(url))
        let record = CloudRecordCodec.encode(header)
        #expect(record.fields["cipherAsset"] == .asset(url))
        #expect(record.fields["cipher"] == nil)
        #expect(try CloudRecordCodec.decode(record) == .entity(header))
    }

    @Test func blobPartRoundTrips() throws {
        let part = CloudBlobPartHeader(hash: Self.hash, part: 2, parts: 3, partBytes: 33_554_432, totalBytes: 70_000_000,
                                       partSha256: Self.hash2, asset: URL(fileURLWithPath: "/tmp/part"))
        let record = CloudRecordCodec.encode(part)
        #expect(record.name == "b.\(Self.hash).32.2")
        #expect(try CloudRecordCodec.decode(record) == .blobPart(part))
    }

    @Test func keyBundleRoundTrips() throws {
        let bundle = CloudKeyBundleHeader(account: "ck-abc", rev: 4, envelope: Data([1, 2, 3]))
        let record = CloudRecordCodec.encode(bundle)
        #expect(record.name == "keybundle")
        #expect(try CloudRecordCodec.decode(record) == .keyBundle(bundle))
    }

    @Test func systemFieldsAreNotPartOfTheDecodedHeader() throws {
        var record = CloudRecordCodec.encode(Self.entity())
        record.systemFields = Data([9, 9])
        #expect(try CloudRecordCodec.decode(record) == .entity(Self.entity()))
    }

    // MARK: the shared fixture

    @Test func fixtureValidRecordsDecodeToTheirKind() throws {
        let (valid, _) = try CloudRecordFixture.load()
        #expect(valid.count >= 4)
        for item in valid {
            let decoded = try CloudRecordCodec.decode(item.record)
            switch (decoded, item.kind) {
            case (.entity, "entity"), (.blobPart, "blobPart"), (.keyBundle, "keyBundle"): break
            default: Issue.record("fixture \(item.name) decoded to the wrong kind")
            }
        }
    }

    @Test func fixtureValidRecordsReEncodeToTheSameFields() throws {
        let (valid, _) = try CloudRecordFixture.load()
        for item in valid {
            let again: CloudRecord
            switch try CloudRecordCodec.decode(item.record) {
            case .entity(let h): again = CloudRecordCodec.encode(h)
            case .blobPart(let h): again = CloudRecordCodec.encode(h)
            case .keyBundle(let h): again = CloudRecordCodec.encode(h)
            }
            #expect(again.name == item.record.name, "\(item.name)")
            #expect(again.fields == item.record.fields, "\(item.name)")
        }
    }

    @Test func fixtureRejectedRecordsAreUnsupportedWithTheExpectedReason() throws {
        let (_, rejected) = try CloudRecordFixture.load()
        #expect(rejected.count >= 10)
        for item in rejected {
            let found = Self.reason(item.record)
            #expect(found?.code == item.reason, "\(item.name): expected \(item.reason ?? "-") got \(found?.code ?? "decoded")")
        }
    }

    // MARK: rejection

    @Test func unknownVersionIsUnsupportedNotACrash() {
        for version: Int64 in [0, 2, 99, -1, Int64.max] {
            var record = CloudRecordCodec.encode(Self.entity())
            record.fields["v"] = .int(version)
            #expect(Self.reason(record) == .version(version))
        }
    }

    @Test func versionIsCheckedBeforeAnythingElseSoFutureShapesAreRecognisedAsNewer() {
        let record = CloudRecord(name: "e.note.n-1", type: .entity, fields: ["v": .int(2), "somethingNew": .bytes(Data([1]))])
        #expect(Self.reason(record) == .version(2))
    }

    @Test func missingVersionAndWrongVersionShapeAreRejected() {
        var record = CloudRecordCodec.encode(Self.entity())
        record.fields["v"] = nil
        #expect(Self.reason(record) == .missingField("v"))
        record.fields["v"] = .string("1")
        #expect(Self.reason(record) == .fieldShape("v"))
    }

    @Test func nameMustEqualTheNameDerivedFromTheFields() {
        var record = CloudRecordCodec.encode(Self.entity(id: "n-1"))
        record.name = "e.note.n-2"
        #expect(Self.reason(record) == .nameMismatch)
        record.name = "e.setting.n-1"
        #expect(Self.reason(record) == .nameMismatch)
        record.name = "n-1"
        #expect(Self.reason(record) == .nameMismatch)
    }

    @Test func recordTypeMustMatchTheName() {
        var record = CloudRecordCodec.encode(CloudKeyBundleHeader(account: "ck-1", rev: 1, envelope: Data([1])))
        record.type = .entity
        #expect(Self.reason(record) != nil)
    }

    @Test func unknownFieldsAreRejectedBecauseAShapeWeDoNotKnowIsFailClosed() {
        var record = CloudRecordCodec.encode(Self.entity())
        record.fields["plaintextTitle"] = .string("hello")
        #expect(Self.reason(record) == .unknownField("plaintextTitle"))
    }

    @Test func fieldShapesAreEnforced() {
        for (field, wrong): (String, CloudValue) in [
            ("etype", .int(1)), ("eid", .bytes(Data())), ("inc", .int(1)), ("incs", .string("x")), ("ver", .string("1")),
            ("sid", .int(1)), ("sids", .bytes(Data())), ("blobs", .string("x")), ("cipher", .string("x")),
        ] {
            var record = CloudRecordCodec.encode(Self.entity(sids: ["att-1"], blobs: [Self.hash]))
            record.fields[field] = wrong
            #expect(Self.reason(record) == .fieldShape(field), "\(field)")
        }
        var asset = CloudRecordCodec.encode(Self.entity(payload: .asset(URL(fileURLWithPath: "/tmp/a"))))
        asset.fields["cipherAsset"] = .bytes(Data([1]))
        #expect(Self.reason(asset) == .fieldShape("cipherAsset"))
    }

    @Test func requiredFieldsAreEnforced() {
        for field in ["etype", "eid", "inc", "incs", "ver", "sid", "sids", "blobs"] {
            var record = CloudRecordCodec.encode(Self.entity())
            record.fields[field] = nil
            #expect(Self.reason(record) == .missingField(field), "\(field)")
        }
    }

    @Test func exactlyOneOfCipherAndCipherAssetMustBePresent() {
        var both = CloudRecordCodec.encode(Self.entity())
        both.fields["cipherAsset"] = .asset(URL(fileURLWithPath: "/tmp/a"))
        #expect(Self.reason(both) == .invalidValue("cipher"))
        var neither = CloudRecordCodec.encode(Self.entity())
        neither.fields["cipher"] = nil
        #expect(Self.reason(neither) == .missingField("cipher"))
    }

    @Test func boundsAreEnforced() {
        func mutated(_ change: (inout CloudRecord) -> Void) -> CloudRecordRejection.Reason? {
            var record = CloudRecordCodec.encode(Self.entity())
            change(&record)
            return Self.reason(record)
        }
        #expect(mutated { $0.fields["ver"] = .int(0) } == .invalidValue("ver"))
        #expect(mutated { $0.fields["ver"] = .int(-3) } == .invalidValue("ver"))
        #expect(mutated { $0.fields["ver"] = .int(SyncWire.maximumRevision + 1) } == .invalidValue("ver"))
        #expect(mutated { $0.fields["cipher"] = .bytes(Data(count: 204_801)) } == .invalidValue("cipher"))
        #expect(mutated { $0.fields["cipher"] = .bytes(Data()) } == .invalidValue("cipher"))
        #expect(mutated { $0.fields["sids"] = .strings((0..<9).map { "s\($0)" }); $0.fields["sid"] = .string("s0") } == .invalidValue("sids"))
        #expect(mutated { $0.fields["sids"] = .strings(["other"]) } == .invalidValue("sids"))
        #expect(mutated { $0.fields["sids"] = .strings([]) } == .invalidValue("sids"))
        #expect(mutated { $0.fields["incs"] = .strings((0..<5).map { "i\($0)" }) } == .invalidValue("incs"))
        #expect(mutated { $0.fields["blobs"] = .strings(["not-a-hash"]) } == .invalidValue("blobs"))
        #expect(mutated { $0.fields["blobs"] = .strings(Array(repeating: Self.hash, count: 1001)) } == .invalidValue("blobs"))
        #expect(mutated { $0.fields["inc"] = .string("has space") } == .invalidValue("inc"))
        #expect(mutated { $0.fields["inc"] = .string("") } == .invalidValue("inc"))
        #expect(mutated { $0.fields["sid"] = .string("bad/id"); $0.fields["sids"] = .strings(["bad/id"]) } == .invalidValue("sid"))
        #expect(mutated { $0.fields["eid"] = .string("a.b"); $0.name = "e.note.a.b" } == .invalidValue("eid"))
    }

    @Test func everyEntityTypeOfTheWireIsAccepted() throws {
        for type in SyncEntityType.allCases {
            let header = Self.entity(type: type, id: "id-1")
            #expect(try CloudRecordCodec.decode(CloudRecordCodec.encode(header)) == .entity(header))
        }
    }

    @Test func blobPartBoundsAreEnforced() {
        func part(_ change: (inout CloudRecord) -> Void) -> CloudRecordRejection.Reason? {
            var record = CloudRecordCodec.encode(CloudBlobPartHeader(
                hash: Self.hash, part: 0, parts: 2, partBytes: 33_554_432, totalBytes: 40_000_000,
                partSha256: Self.hash2, asset: URL(fileURLWithPath: "/tmp/p")))
            change(&record)
            return Self.reason(record)
        }
        #expect(part { $0.fields["hash"] = .string("zz") } == .invalidValue("hash"))
        #expect(part { $0.fields["parts"] = .int(9) } == .invalidValue("parts"))
        #expect(part { $0.fields["parts"] = .int(0) } == .invalidValue("parts"))
        #expect(part { $0.fields["part"] = .int(2) } == .invalidValue("part"))
        #expect(part { $0.fields["part"] = .int(-1) } == .invalidValue("part"))
        #expect(part { $0.fields["partBytes"] = .int(1_000) } == .invalidValue("partBytes"))
        #expect(part { $0.fields["totalBytes"] = .int(0) } == .invalidValue("totalBytes"))
        #expect(part { $0.fields["totalBytes"] = .int(Int64(SyncWire.maximumBlobBytes) + 1) } == .invalidValue("totalBytes"))
        #expect(part { $0.fields["totalBytes"] = .int(10) } == .invalidValue("totalBytes"))
        #expect(part { $0.fields["partSha256"] = .string("nope") } == .invalidValue("partSha256"))
        #expect(part { $0.fields["asset"] = nil } == .missingField("asset"))
        #expect(part { $0.name = "b.\(Self.hash).32.1" } == .nameMismatch)
        #expect(part { $0.name = "b.\(Self.hash).16.0" } == .nameMismatch)
    }

    @Test func keyBundleBoundsAreEnforced() {
        func bundle(_ change: (inout CloudRecord) -> Void) -> CloudRecordRejection.Reason? {
            var record = CloudRecordCodec.encode(CloudKeyBundleHeader(account: "ck-1", rev: 1, envelope: Data([1])))
            change(&record)
            return Self.reason(record)
        }
        #expect(bundle { $0.fields["rev"] = .int(-1) } == .invalidValue("rev"))
        #expect(bundle { $0.fields["envelope"] = .bytes(Data()) } == .invalidValue("envelope"))
        #expect(bundle { $0.fields["envelope"] = .bytes(Data(count: 65_537)) } == .invalidValue("envelope"))
        #expect(bundle { $0.fields["account"] = .string("bad id") } == .invalidValue("account"))
        #expect(bundle { $0.name = "keybundle-2" } == .nameMismatch)
    }

    // MARK: size

    @Test func largestLegalEntityIsUnder700KB() throws {
        let hashes = (0..<1000).map { String(format: "%064x", $0) }
        let header = Self.entity(
            type: .note, id: String(repeating: "i", count: 128), inc: String(repeating: "c", count: 64),
            incs: (0..<4).map { _ in String(repeating: "d", count: 64) }, ver: SyncWire.maximumRevision,
            sid: String(repeating: "s", count: 128), sids: (0..<8).map { _ in String(repeating: "s", count: 128) },
            payload: .inline(Data(count: 200 * 1024)), blobs: hashes)
        let record = CloudRecordCodec.encode(header)
        #expect(record.approximateSize < 700_000, "size \(record.approximateSize)")
        #expect(record.approximateSize > 200 * 1024 + 1000 * 64)
        #expect(try CloudRecordCodec.decode(record) == .entity(header))
    }

    @Test func allowListIsExactlyTheSpecFields() {
        let entity = CloudRecordCodec.encode(Self.entity(blobs: [Self.hash]))
        #expect(Set(entity.fields.keys) == ["v", "etype", "eid", "inc", "incs", "ver", "sid", "sids", "cipher", "blobs"])
        let asset = CloudRecordCodec.encode(Self.entity(payload: .asset(URL(fileURLWithPath: "/tmp/a"))))
        #expect(Set(asset.fields.keys) == ["v", "etype", "eid", "inc", "incs", "ver", "sid", "sids", "cipherAsset", "blobs"])
        #expect(CloudRecordCodec.entityFieldNames == ["v", "etype", "eid", "inc", "incs", "ver", "sid", "sids", "cipher", "cipherAsset", "blobs"])
        #expect(CloudRecordCodec.blobPartFieldNames == ["v", "hash", "part", "parts", "partBytes", "totalBytes", "partSha256", "asset"])
        #expect(CloudRecordCodec.keyBundleFieldNames == ["v", "account", "rev", "envelope"])
    }

    static let specURL = CloudRecordFixture.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/superpowers/specs/2026-10-28-cloudkit-record-v1.md")

    /// The design record is private (PUB-R1): a public checkout has no spec to compare with.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: specURL.path), "needs the private design record"))
    func specDocumentListsEveryFieldTheCodecAllows() throws {
        let spec = try String(contentsOf: Self.specURL, encoding: .utf8)
        for field in CloudRecordCodec.entityFieldNames.union(CloudRecordCodec.blobPartFieldNames).union(CloudRecordCodec.keyBundleFieldNames) {
            #expect(spec.contains("`\(field)`"), "spec does not mention `\(field)`")
        }
    }
}

@Suite struct CloudSaveOutcomeCodingTests {
    @Test func everyOutcomeRoundTripsThroughItsStoredForm() throws {
        let server = CloudRecord(name: "e.note.n", type: .entity, fields: [
            "v": .int(1), "cipher": .bytes(Data([1, 2])), "blobs": .strings(["x"]), "cipherAsset": .asset(URL(fileURLWithPath: "/tmp/staged")),
            "etype": .string("note"),
        ], systemFields: Data([7]))
        let outcomes: [CloudSaveOutcome] = [
            .saved(systemFields: Data([1, 2, 3])), .serverRecordChanged(server: server), .unknownItem, .quotaExceeded, .limitExceeded,
            .zoneNotFound, .unauthenticated, .offline, .fenced, .failed(code: "assetFileNotFound"),
        ]
        for outcome in outcomes {
            #expect(try CloudSaveOutcome.decode(outcome.encoded()) == outcome)
        }
    }
}

@Suite struct CloudKitConfigurationTests {
    @Test func validContainerIsAccepted() {
        let config = CloudKitConfiguration.from(infoDictionary: ["THEONOTES_CloudKitContainer": "iCloud.com.truebrewbirdie.theonotes"])
        #expect(config?.containerIdentifier == "iCloud.com.truebrewbirdie.theonotes")
        #expect(config?.zoneName == "TheoNotes")
    }

    @Test func missingEmptyUnsubstitutedOrMalformedGivesNil() {
        let key = "THEONOTES_CloudKitContainer"
        #expect(CloudKitConfiguration.from(infoDictionary: [:]) == nil)
        for bad in ["", "  ", "$(THEONOTES_CLOUDKIT_CONTAINER)", "com.truebrewbirdie.theonotes", "icloud.com.x", "iCloud.", "iCloud.has space", "iCloud.x/y", "iCloud.com.x\n"] {
            #expect(CloudKitConfiguration.from(infoDictionary: [key: bad]) == nil, "\(bad.debugDescription)")
        }
        #expect(CloudKitConfiguration.from(infoDictionary: [key: 5]) == nil)
    }

    @Test func fromBundleReadsTheInfoDictionary() {
        #expect(CloudKitConfiguration.fromBundle(Bundle.main) == nil)
    }
}

@Suite struct CrashPointTests {
    @Test func armedBoundaryThrowsOnceThenPasses() throws {
        let crash = CrashPoint()
        try crash.hit("a")
        crash.arm("b")
        try crash.hit("a")
        #expect(throws: CrashInjected(boundary: "b")) { try crash.hit("b") }
        try crash.hit("b")
        #expect(crash.hits == ["a", "a", "b", "b"])
    }

    @Test func armAfterSkipsTheFirstHits() throws {
        let crash = CrashPoint()
        crash.arm("x", afterHits: 2)
        try crash.hit("x"); try crash.hit("x")
        #expect(throws: CrashInjected.self) { try crash.hit("x") }
    }

    @Test func neverIsInert() throws {
        for _ in 0..<3 { try CrashPoint.never.hit("anything") }
    }
}
