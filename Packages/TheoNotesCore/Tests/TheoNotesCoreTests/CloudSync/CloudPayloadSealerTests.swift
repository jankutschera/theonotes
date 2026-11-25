// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

/// The transport-free sealed payload (CK-R17, CK-R19) and its golden vectors `Fixtures/sync/cloudsync-payload-v1.json`.
/// Regenerate only for a deliberate format change: `BAERCHEN_WRITE_PAYLOAD_VECTORS=1 swift test --filter CloudPayloadSealerTests`.
@Suite struct CloudPayloadSealerTests {
    @Test func semanticEntityIDMatchesExistingWireRuleWithoutWriting() {
        #expect(CloudPayloadSealer.derivedEntityID(type: .keyBundle, semantic: "lock-vault", vaultKey: Self.key) == Self.hmacID(.keyBundle, "lock-vault"))
        #expect(CloudPayloadSealer.derivedEntityID(type: .tagPreference, semantic: "home/kitchen", vaultKey: Self.key) == Self.hmacID(.tagPreference, "home/kitchen"))
        #expect(CloudPayloadSealer.derivedEntityID(type: .note, semantic: "note-id", vaultKey: Self.key) == "note-id")
    }
    static let accountID = "ck-vector-account-001"
    static let keyHex = String(repeating: "02", count: 32)
    static var key: SymmetricKey { SymmetricKey(data: Data(hex: keyHex)) }
    static let stamp: Int64 = 1_793_188_800_000

    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sync/cloudsync-payload-v1.json")

    // MARK: the independent reference decoder (no NoteCipher, no payload types: CryptoKit and JSON only)

    enum Reference {
        enum Failure: Error { case malformed, tampered, unknownKind(UInt8) }
        /// BNC1 = "BNC1" || AES-GCM(noteKey, under vaultKey) [60 bytes] || AES-GCM(plaintext, under noteKey); both with
        /// AAD = "BNC1" || context. Plaintext = kind || body.
        static func open(_ sealed: Data, key: SymmetricKey, context: String) throws -> (kind: UInt8, body: Data) {
            let magic = Data("BNC1".utf8)
            guard sealed.count >= 4 + 60 + 28, sealed.prefix(4) == magic else { throw Failure.malformed }
            let aad = magic + Data(context.utf8)
            let wrapped = sealed[sealed.startIndex + 4 ..< sealed.startIndex + 64]
            let body = sealed[(sealed.startIndex + 64)...]
            let noteKeyBytes: Data
            do { noteKeyBytes = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: key, authenticating: aad) } catch { throw Failure.tampered }
            let plain: Data
            do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: body), using: SymmetricKey(data: noteKeyBytes), authenticating: aad) }
            catch { throw Failure.tampered }
            guard let kind = plain.first else { throw Failure.malformed }
            guard kind == 1 || kind == 2 else { throw Failure.unknownKind(kind) }
            return (kind, Data(plain.dropFirst()))
        }
    }

    struct Vector { let name: String; let type: SyncEntityType; let entityId: String; let payload: String?; let deletedAt: Int64? }

    static func hmacID(_ type: SyncEntityType, _ semantic: String) -> String {
        let input = Data("baerchen-semantic-id:1:\(type.rawValue):\(semantic)".utf8)
        return "m-" + HMAC<SHA256>.authenticationCode(for: input, using: key).map { String(format: "%02x", $0) }.joined()
    }

    static func canonical<T: Codable>(_ type: T.Type, _ json: String) throws -> String {
        let value = try SyncPayloadCodec.decode(type, from: Data(json.utf8))
        return String(decoding: try SyncPayloadCodec.encoder().encode(value), as: UTF8.self)
    }

    static func vectors() throws -> [Vector] {
        let noteID = "0194f6c0-1111-7000-8000-000000000001"
        let lockedID = "0194f6c0-3333-7000-8000-000000000003"
        let attachmentID = "0194f6c0-2222-7000-8000-000000000002"
        let hash = String(repeating: "ab", count: 32), fileHash = String(repeating: "cd", count: 32)
        let (envelope, _) = try CryptoEnvelope.create(password: "vector-password", iterations: CryptoEnvelope.publicIterationRange.lowerBound)
        let envelopeJSON = try JSONEncoder().encode(envelope)
        let note = try canonical(SyncNotePayload.self, """
            {"version":1,"id":"\(noteID)","text":"# Groceries\\nmilk and bread #home/kitchen\\n","title":"Groceries","createdAt":1793188800000,
             "modifiedAt":1793188860000,"location":"notes","isPinnedGlobal":false,"isReadOnly":false,"isLocked":false,
             "directTags":["home/kitchen"],"pinnedTags":[],"attachmentIds":["\(attachmentID)"],
             "attachmentNames":{"\(attachmentID)":"receipt.png"}}
            """)
        let locked = try canonical(SyncNotePayload.self, """
            {"version":1,"id":"\(lockedID)","text":"","title":"","createdAt":1793188800000,"modifiedAt":1793188860000,"location":"notes",
             "isPinnedGlobal":false,"isReadOnly":false,"isLocked":true,"encryptedPayload":"\(SyncWire.base64(Data("inner BNC1 ciphertext of the note body".utf8)))",
             "directTags":[],"pinnedTags":[],"attachmentIds":[]}
            """)
        let attachment = try canonical(SyncAttachmentPayload.self, """
            {"version":1,"id":"\(attachmentID)","noteId":"\(noteID)","filename":"receipt.png","isLocked":false,"blobHash":"\(hash)",
             "cipherBytes":2048,"fileBytes":1900,"fileHash":"\(fileHash)","uti":"public.png","width":640,"height":480,"ocrText":"TOTAL 12.50",
             "createdAt":1793188800000,"updatedAt":1793188860000}
            """)
        let tag = try canonical(SyncTagPreferencePayload.self, #"{"version":1,"path":"home/kitchen","iconName":"star","isPinned":true,"sortIndex":2}"#)
        let setting = try canonical(SyncSettingPayload.self, #"{"version":1,"key":"hideMarkdown","value":"true"}"#)
        let reference = try canonical(SyncExternalRefPayload.self, """
            {"version":1,"source":"bear","externalId":"ABC-123","noteId":"\(noteID)","lastSeenModified":1793188800000,
             "lastSeenHash":"\(hash)","lastSeenTextHash":"\(fileHash)","lastSeenMeta":null,"importedTextHash":"\(hash)"}
            """)
        let lock = String(decoding: try SyncPayloadCodec.encoder().encode(SyncLockEnvelopePayload(envelope: envelopeJSON)), as: UTF8.self)
        return [
            Vector(name: "note", type: .note, entityId: noteID, payload: note, deletedAt: nil),
            Vector(name: "protected-note", type: .note, entityId: lockedID, payload: locked, deletedAt: nil),
            Vector(name: "attachment", type: .attachment, entityId: attachmentID, payload: attachment, deletedAt: nil),
            Vector(name: "tag-preference", type: .tagPreference, entityId: hmacID(.tagPreference, "home/kitchen"), payload: tag, deletedAt: nil),
            Vector(name: "setting", type: .setting, entityId: hmacID(.setting, "hideMarkdown"), payload: setting, deletedAt: nil),
            Vector(name: "external-reference", type: .externalRef, entityId: hmacID(.externalRef, #"["bear","ABC-123"]"#), payload: reference, deletedAt: nil),
            Vector(name: "lock-envelope", type: .keyBundle, entityId: hmacID(.keyBundle, "lock-vault"), payload: lock, deletedAt: nil),
            Vector(name: "deleted-note", type: .note, entityId: noteID, payload: nil, deletedAt: stamp),
            Vector(name: "deleted-tag-preference", type: .tagPreference, entityId: hmacID(.tagPreference, "home/kitchen"), payload: nil, deletedAt: stamp),
        ]
    }

    static func base64(_ data: Data) -> String { data.base64EncodedString() }

    func sealer() -> CloudPayloadSealer { CloudPayloadSealer(accountID: Self.accountID, vaultKey: Self.key) }

    @Test func writeTheVectorsOnlyWhenAskedTo() throws {
        guard ProcessInfo.processInfo.environment["BAERCHEN_WRITE_PAYLOAD_VECTORS"] == "1" else { return }
        let sealer = sealer()
        var valid: [[String: Any]] = []
        var sealedByName: [String: Data] = [:]
        for vector in try Self.vectors() {
            let sealed = try vector.payload.map { try sealer.sealLive(Data($0.utf8), type: vector.type, entityID: vector.entityId) }
                ?? sealer.sealDeleted(atMillis: vector.deletedAt!, type: vector.type, entityID: vector.entityId)
            sealedByName[vector.name] = sealed
            var item: [String: Any] = [
                "case": vector.name, "entityType": vector.type.rawValue, "entityId": vector.entityId,
                "kind": vector.payload == nil ? "deleted" : "live",
                "context": try sealer.context(type: vector.type, entityID: vector.entityId), "sealed": Self.base64(sealed),
            ]
            if let payload = vector.payload { item["payload"] = payload } else { item["at"] = vector.deletedAt! }
            valid.append(item)
        }
        let note = try Self.vectors()[0]
        func rejected(_ name: String, _ reason: String, type: SyncEntityType = .note, id: String = note.entityId, sealed: Data) -> [String: Any] {
            ["case": name, "reason": reason, "entityType": type.rawValue, "entityId": id, "sealed": Self.base64(sealed)]
        }
        let key = Self.key
        func raw(_ plain: Data, type: SyncEntityType = .note, id: String = note.entityId) throws -> Data {
            try NoteCipher.seal(plain, vaultKey: key, context: try sealer.context(type: type, entityID: id))
        }
        var tampered = sealedByName["note"]!; tampered[tampered.count - 1] ^= 0x01
        let refused: [[String: Any]] = [
            rejected("sealed-for-another-entity", "authentication", id: "0194f6c0-9999-7000-8000-000000000009", sealed: sealedByName["note"]!),
            rejected("sealed-for-another-entity-type", "authentication", type: .attachment, sealed: sealedByName["note"]!),
            rejected("flipped-last-byte", "authentication", sealed: tampered),
            rejected("unknown-kind-byte", "unsupported-kind", sealed: try raw(Data([0x03]) + Data("{}".utf8))),
            rejected("empty-plaintext", "invalid-payload", sealed: try raw(Data())),
            rejected("deletion-without-timestamp", "invalid-payload", sealed: try raw(Data([0x02]) + Data("{}".utf8))),
            rejected("deletion-with-fractional-timestamp", "invalid-payload", sealed: try raw(Data([0x02]) + Data("{\"at\":1.5}".utf8))),
            rejected("deletion-with-negative-timestamp", "invalid-payload", sealed: try raw(Data([0x02]) + Data("{\"at\":-1}".utf8))),
        ]
        let document: [String: Any] = [
            "spec": "docs/superpowers/specs/2026-10-28-sync-payload-v1.md", "version": 1,
            "note": "Sealed with a random note key, so the bytes are fixed here once and every reader must open them; do not regenerate unless the format changes.",
            "accountId": Self.accountID, "vaultKeyHex": Self.keyHex, "valid": valid, "rejected": refused,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Self.fixtureURL)
    }

    struct Loaded { let name: String; let type: SyncEntityType; let id: String; let kind: String; let context: String; let sealed: Data
        let payload: String?; let at: Int64?; let reason: String? }

    static func load(_ key: String) throws -> [Loaded] {
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        return try (root[key] as? [[String: Any]] ?? []).map { item in
            Loaded(name: item["case"] as! String, type: try #require(SyncEntityType(rawValue: item["entityType"] as! String)), id: item["entityId"] as! String,
                   kind: item["kind"] as? String ?? "", context: item["context"] as? String ?? "",
                   sealed: try #require(Data(base64Encoded: item["sealed"] as! String)), payload: item["payload"] as? String,
                   at: (item["at"] as? NSNumber)?.int64Value, reason: item["reason"] as? String)
        }
    }

    // MARK: the vectors

    @Test func theVectorFileCoversEveryEntityTypeADeletionAndAProtectedNote() throws {
        let valid = try Self.load("valid")
        #expect(Set(valid.map(\.type.rawValue)) == ["note", "attachment", "tagPreference", "setting", "externalRef", "keyBundle"])
        #expect(valid.contains { $0.kind == "deleted" } && valid.contains { $0.name == "protected-note" })
        #expect(try Self.load("rejected").count >= 8)
    }

    @Test func aStandaloneReferenceDecoderOpensEveryVector() throws {
        let key = Self.key
        for vector in try Self.load("valid") {
            let expectedContext = "baerchen-sync:1:\(Self.accountID):\(vector.type.rawValue):\(vector.id):1"
            #expect(vector.context == expectedContext, "\(vector.name)")
            let opened = try Reference.open(vector.sealed, key: key, context: expectedContext)
            if vector.kind == "live" {
                #expect(opened.kind == 1, "\(vector.name)")
                #expect(String(decoding: opened.body, as: UTF8.self) == vector.payload, "\(vector.name)")
                let object = try #require(JSONSerialization.jsonObject(with: opened.body) as? [String: Any], "\(vector.name)")
                #expect(object["version"] as? Int == 1, "\(vector.name)")
            } else {
                #expect(opened.kind == 2, "\(vector.name)")
                let object = try #require(JSONSerialization.jsonObject(with: opened.body) as? [String: Any])
                #expect((object["at"] as? NSNumber)?.int64Value == vector.at, "\(vector.name)")
            }
        }
    }

    @Test func theSealerOpensEveryVectorToTheSameBytes() throws {
        let sealer = sealer()
        for vector in try Self.load("valid") {
            let opened = try sealer.open(vector.sealed, type: vector.type, entityID: vector.id)
            switch opened {
            case .live(let body): #expect(String(decoding: body, as: UTF8.self) == vector.payload, "\(vector.name)")
            case .deleted(let at): #expect(at == vector.at, "\(vector.name)")
            }
        }
    }

    @Test func everyLivePayloadVectorStillDecodesAsItsTypeAndReEncodesToTheSameBytes() throws {
        for vector in try Self.load("valid") where vector.kind == "live" {
            let body = Data(try #require(vector.payload).utf8)
            func roundTrip<T: Codable>(_ type: T.Type) throws -> Bool {
                String(decoding: try SyncPayloadCodec.encoder().encode(try SyncPayloadCodec.decode(type, from: body)), as: UTF8.self) == vector.payload
            }
            switch vector.type {
            case .note: #expect(try roundTrip(SyncNotePayload.self), "\(vector.name)")
            case .attachment: #expect(try roundTrip(SyncAttachmentPayload.self), "\(vector.name)")
            case .tagPreference: #expect(try roundTrip(SyncTagPreferencePayload.self), "\(vector.name)")
            case .setting: #expect(try roundTrip(SyncSettingPayload.self), "\(vector.name)")
            case .externalRef: #expect(try roundTrip(SyncExternalRefPayload.self), "\(vector.name)")
            case .keyBundle: #expect(try roundTrip(SyncLockEnvelopePayload.self), "\(vector.name)")
            }
        }
    }

    @Test func everyRejectedVectorIsRefusedWithTheStatedReason() throws {
        let sealer = sealer()
        let key = Self.key
        for vector in try Self.load("rejected") {
            switch vector.reason {
            case "authentication":
                #expect(throws: (any Error).self, "\(vector.name)") { try sealer.open(vector.sealed, type: vector.type, entityID: vector.id) }
                #expect(throws: (any Error).self, "\(vector.name)") {
                    try Reference.open(vector.sealed, key: key, context: "baerchen-sync:1:\(Self.accountID):\(vector.type.rawValue):\(vector.id):1")
                }
            case "unsupported-kind":
                #expect(throws: SyncProtocolError.unsupportedVersion, "\(vector.name)") { try sealer.open(vector.sealed, type: vector.type, entityID: vector.id) }
            case "invalid-payload":
                #expect(throws: SyncProtocolError.invalidPayload, "\(vector.name)") { try sealer.open(vector.sealed, type: vector.type, entityID: vector.id) }
            default: Issue.record("unknown reason \(vector.reason ?? "nil") in \(vector.name)")
            }
        }
    }

    // MARK: behaviour

    @Test func sealingFramesTheKindByteAndTheContextAndLimitsThePayload() throws {
        let sealer = sealer()
        let sealed = try sealer.sealLive(Data("{}".utf8), type: .setting, entityID: "m-1")
        let opened = try Reference.open(sealed, key: Self.key, context: "baerchen-sync:1:\(Self.accountID):setting:m-1:1")
        #expect(opened.kind == 1 && opened.body == Data("{}".utf8))
        let deleted = try sealer.sealDeleted(atMillis: 42, type: .setting, entityID: "m-1")
        #expect(try Reference.open(deleted, key: Self.key, context: "baerchen-sync:1:\(Self.accountID):setting:m-1:1").body == Data("{\"at\":42}".utf8))
        _ = try sealer.sealLive(Data(repeating: 0x20, count: CloudPayloadSealer.maximumPayloadBytes), type: .note, entityID: "n")
        #expect(throws: SyncProtocolError.responseTooLarge) {
            try sealer.sealLive(Data(repeating: 0x20, count: CloudPayloadSealer.maximumPayloadBytes + 1), type: .note, entityID: "n")
        }
        // Two seals of the same content differ (random note key and nonce); both open.
        #expect(try sealer.sealLive(Data("x".utf8), type: .note, entityID: "n") != sealer.sealLive(Data("x".utf8), type: .note, entityID: "n"))
    }

    @Test func aWrongKeyOrAnotherAccountOpensNothing() throws {
        let sealed = try sealer().sealLive(Data("{}".utf8), type: .note, entityID: "n")
        #expect(throws: (any Error).self) { try CloudPayloadSealer(accountID: Self.accountID, vaultKey: SymmetricKey(size: .bits256)).open(sealed, type: .note, entityID: "n") }
        #expect(throws: (any Error).self) { try CloudPayloadSealer(accountID: "other-account", vaultKey: Self.key).open(sealed, type: .note, entityID: "n") }
    }

    @Test func theSealerFileMentionsNoTransportOrStateTable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TheoNotesCore/CloudSync/CloudPayloadSealer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for banned in ["CloudKit", "CKRecord", "ck_", "CloudRecord", "CloudSyncStore", "systemFields"] {
            #expect(!source.contains(banned), "CloudPayloadSealer.swift must stay transport-free but contains \(banned)")
        }
    }
}

extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
