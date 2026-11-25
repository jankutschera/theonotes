// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

/// Drift guard for the copied reader switch (E0 record, risk 1): the same payloads go through the Cloudflare original
/// (`SyncPayloadReader.read`) and the copy (`CloudRemoteReader.read`); valid ones must open to equal values and every invalid
/// shape must fail with the same error.
@Suite struct CloudRemoteReaderDifferentialTests {
    struct Blobs: SyncBlobTransport {
        func ensureUploaded(_ hashes: [String]) async throws {}
        func download(hash: String) async throws -> URL { throw SyncProtocolError.invalidPayload }
    }

    struct Case {
        let name: String
        let type: SyncEntityType
        let id: String
        let plain: Data
        let refs: [String]
    }

    static let account = "account", key = SymmetricKey(data: Data(repeating: 3, count: 32))
    static let hash = String(repeating: "ab", count: 32), otherHash = String(repeating: "cd", count: 32)

    static func json<T: Encodable>(_ value: T) -> Data { try! SyncPayloadCodec.encoder().encode(value) }

    static func note(_ id: String, locked: Bool = false, text: String = "# T\nbody", tags: [String] = [], snapshot: SyncAttachmentPayload? = nil) -> SyncNotePayload {
        var note = SyncNotePayload(note: Note(id: id, text: locked ? "" : text, title: "T", titleKey: "t", createdAt: .now, modifiedAt: .now),
                                   directTags: tags, pinnedTags: [], attachmentIds: snapshot.map { [$0.id] } ?? [])
        if locked { note.isLocked = true; note.encryptedPayload = Data([1, 2, 3]) }
        if let snapshot { note.attachmentNames = [snapshot.id: snapshot.filename]; note.attachmentSnapshots = [snapshot.id: snapshot] }
        return note
    }

    static func attachment(_ id: String, noteId: String = "note", blob: String = hash, locked: Bool = false, bytes: Int64 = 100) -> SyncAttachmentPayload {
        SyncAttachmentPayload(id: id, noteId: noteId, filename: locked ? id + ".bch" : "file.txt", isLocked: locked, blobHash: blob, cipherBytes: bytes,
                              fileBytes: 20, fileHash: otherHash, uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
    }

    static func envelope(version: Int = 1, kdf: String = CryptoEnvelope.kdfName, salt: Int = 16, iterations: Int = 600_000, wrapped: Int = 60) -> Data {
        try! JSONEncoder().encode(CryptoEnvelope(version: version, kdf: kdf, salt: Data(count: salt), iterations: iterations, wrappedVaultKey: Data(count: wrapped)))
    }

    static var cases: [Case] {
        let snap = attachment("asset", noteId: "n1")
        var out: [Case] = [
            Case(name: "note valid", type: .note, id: "n1", plain: json(note("n1")), refs: []),
            Case(name: "note valid with tags", type: .note, id: "n1", plain: json(note("n1", tags: ["a/b", "c"])), refs: []),
            Case(name: "note locked valid", type: .note, id: "n1", plain: json(note("n1", locked: true)), refs: []),
            Case(name: "note id mismatch", type: .note, id: "n2", plain: json(note("n1")), refs: []),
            Case(name: "note snapshot blob not listed", type: .note, id: "n1", plain: json(note("n1", snapshot: snap)), refs: []),
            Case(name: "note snapshot blob listed", type: .note, id: "n1", plain: json(note("n1", snapshot: snap)), refs: [hash]),
            Case(name: "note invalid tag", type: .note, id: "n1", plain: json(note("n1", tags: ["bad tag with space"])), refs: []),
            Case(name: "note empty tag", type: .note, id: "n1", plain: json(note("n1", tags: [""])), refs: []),
            Case(name: "note locked with text", type: .note, id: "n1", plain: { var n = note("n1", locked: true); n.text = "leak"; return json(n) }(), refs: []),
            Case(name: "note unsupported version", type: .note, id: "n1", plain: { var n = note("n1"); n.version = 2; return json(n) }(), refs: []),
            Case(name: "note not json", type: .note, id: "n1", plain: Data("{".utf8), refs: []),
            Case(name: "attachment valid", type: .attachment, id: "asset", plain: json(attachment("asset")), refs: [hash]),
            Case(name: "attachment blob not listed", type: .attachment, id: "asset", plain: json(attachment("asset")), refs: [otherHash]),
            Case(name: "attachment id mismatch", type: .attachment, id: "other", plain: json(attachment("asset")), refs: [hash]),
            Case(name: "attachment locked valid", type: .attachment, id: "asset", plain: json(attachment("asset", locked: true)), refs: [hash]),
            Case(name: "tag valid", type: .tagPreference, id: "t1", plain: json(SyncTagPreferencePayload(path: "work/alpha", iconName: "star", isPinned: true, sortIndex: 2)), refs: []),
            Case(name: "tag version 2", type: .tagPreference, id: "t1", plain: json(SyncTagPreferencePayload(version: 2, path: "work", iconName: nil, isPinned: false, sortIndex: nil)), refs: []),
            Case(name: "tag invalid path", type: .tagPreference, id: "t1", plain: json(SyncTagPreferencePayload(path: "has space", iconName: nil, isPinned: false, sortIndex: nil)), refs: []),
            Case(name: "setting valid", type: .setting, id: "s1", plain: json(SyncSettingPayload(key: "hideMarkdown", value: "true")), refs: []),
            Case(name: "setting wrong value type", type: .setting, id: "s1", plain: json(SyncSettingPayload(key: "hideMarkdown", value: "\"yes\"")), refs: []),
            Case(name: "setting not portable", type: .setting, id: "s1", plain: json(SyncSettingPayload(key: "mobile.biometry", value: "false")), refs: []),
            Case(name: "setting version 2", type: .setting, id: "s1", plain: json(SyncSettingPayload(version: 2, key: "hideMarkdown", value: "true")), refs: []),
            Case(name: "externalRef valid", type: .externalRef, id: "e1", plain: json(SyncExternalRefPayload(source: "import", externalId: "x", noteId: "n1", lastSeenModified: 1, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)), refs: []),
            Case(name: "externalRef no note", type: .externalRef, id: "e1", plain: json(SyncExternalRefPayload(source: "import", externalId: "x", noteId: nil, lastSeenModified: nil, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)), refs: []),
            Case(name: "externalRef version 2", type: .externalRef, id: "e1", plain: json(SyncExternalRefPayload(version: 2, source: "import", externalId: "x", noteId: nil, lastSeenModified: nil, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)), refs: []),
            Case(name: "externalRef empty source", type: .externalRef, id: "e1", plain: json(SyncExternalRefPayload(source: "", externalId: "x", noteId: nil, lastSeenModified: nil, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)), refs: []),
            Case(name: "externalRef long source", type: .externalRef, id: "e1", plain: json(SyncExternalRefPayload(source: String(repeating: "s", count: 1025), externalId: "x", noteId: nil, lastSeenModified: nil, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)), refs: []),
            Case(name: "externalRef bad note id", type: .externalRef, id: "e1", plain: json(SyncExternalRefPayload(source: "import", externalId: "x", noteId: "bad id!", lastSeenModified: nil, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)), refs: []),
        ]
        for (name, bytes) in [("valid", envelope()), ("version 2", envelope(version: 2)), ("other kdf", envelope(kdf: "scrypt")), ("few iterations", envelope(iterations: 5)),
                              ("short salt", envelope(salt: 8)), ("short wrapped key", envelope(wrapped: 59))] {
            out.append(Case(name: "keyBundle \(name)", type: .keyBundle, id: "k1", plain: json(SyncLockEnvelopePayload(envelope: bytes)), refs: []))
        }
        out.append(Case(name: "keyBundle payload version 2", type: .keyBundle, id: "k1", plain: json(SyncLockEnvelopePayload(version: 2, envelope: envelope())), refs: []))
        return out
    }

    static func describe(_ value: SyncRemoteValue) -> String {
        switch value {
        case .deleted: return "deleted"
        case .note(let v): return "note " + String(decoding: json(v), as: UTF8.self)
        case .attachment(let v): return "attachment " + String(decoding: json(v), as: UTF8.self)
        case .tag(let v): return "tag " + String(decoding: json(v), as: UTF8.self)
        case .setting(let v): return "setting " + String(decoding: json(v), as: UTF8.self)
        case .externalRef(let v): return "externalRef " + String(decoding: json(v), as: UTF8.self)
        case .lockEnvelope(let data): return "envelope " + data.base64EncodedString()
        }
    }

    static func original(_ c: Case, key: SymmetricKey = key, account: String = account, tombstone: Bool = false) async -> String {
        do {
            let context = try SyncWire.cipherContext(accountID: Self.account, type: c.type, entityID: c.id)
            let mutation = tombstone
                ? SyncMutation(mutationId: "mutation", entityType: c.type, entityId: c.id, parentRevision: 0, tombstone: true)
                : SyncMutation(mutationId: "mutation", entityType: c.type, entityId: c.id, parentRevision: 0,
                               ciphertext: SyncWire.base64(try NoteCipher.seal(c.plain, vaultKey: Self.key, context: context)), blobRefs: c.refs)
            let reader = SyncPayloadReader(accountID: account, vaultKey: key, blobs: Blobs())
            return "ok: " + describe(try await reader.read(SyncEntity(mutation: mutation, revision: 1, sequence: 1, receivedAt: 1)))
        } catch { return "error: \(error)" }
    }

    static func copy(_ c: Case, key: SymmetricKey = key, account: String = account, tombstone: Bool = false) -> String {
        do {
            let sealer = CloudPayloadSealer(accountID: Self.account, vaultKey: Self.key)
            let sealed = tombstone ? try sealer.sealDeleted(atMillis: 1, type: c.type, entityID: c.id) : try sealer.sealLive(c.plain, type: c.type, entityID: c.id)
            let reader = CloudRemoteReader(sealer: CloudPayloadSealer(accountID: account, vaultKey: key))
            return "ok: " + describe(try reader.read(sealed: sealed, type: c.type, entityId: c.id, blobRefs: c.refs))
        } catch { return "error: \(error)" }
    }

    @Test(arguments: cases.map(\.name))
    func theCopyOpensEveryPayloadLikeTheOriginal(name: String) async throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let original = await Self.original(c), copy = Self.copy(c)
        #expect(original == copy, "\(name): original `\(original.prefix(160))` vs copy `\(copy.prefix(160))`")
    }

    @Test func validCasesOpenAndInvalidOnesDoNot() async throws {
        let outcomes = await Self.cases.asyncMap { (name: $0.name, ok: await Self.original($0).hasPrefix("ok:")) }
        for valid in ["note valid", "attachment valid", "tag valid", "setting valid", "externalRef valid", "keyBundle valid", "note snapshot blob listed"] {
            #expect(outcomes.first { $0.name == valid }?.ok == true, "\(valid) should open")
        }
        for invalid in ["note id mismatch", "note snapshot blob not listed", "attachment blob not listed", "tag version 2", "setting not portable", "keyBundle few iterations"] {
            #expect(outcomes.first { $0.name == invalid }?.ok == false, "\(invalid) should fail")
        }
    }

    /// The wire envelope of the original validates the blob references (`SyncMutation.validate`); in a CloudKit record the codec
    /// does it, before any payload is opened, so the reader needs no copy of that check.
    @Test func blobReferenceFormatIsCheckedByTheRecordCodecInsteadOfTheReader() throws {
        var record = CloudRecordCodec.encode(CloudEntityHeader(entityType: .attachment, entityId: "asset", inc: "incA", incs: [], ver: 1, sid: "sid-1", sids: ["sid-1"],
                                                               payload: .inline(Data([1])), blobs: [Self.hash]))
        _ = try CloudRecordCodec.decode(record)
        record.fields["blobs"] = .strings(["nothex"])
        #expect(throws: CloudRecordRejection.self) { try CloudRecordCodec.decode(record) }
    }

    @Test func aTombstoneAndAWrongKeyOrAccountBehaveTheSame() async throws {
        let c = Self.cases[0]
        #expect(await Self.original(c, tombstone: true) == Self.copy(c, tombstone: true))
        #expect(Self.copy(c, tombstone: true) == "ok: deleted")
        let wrong = SymmetricKey(data: Data(repeating: 9, count: 32))
        #expect(await Self.original(c, key: wrong) == Self.copy(c, key: wrong))
        #expect(await Self.original(c, account: "other") == Self.copy(c, account: "other"))
        #expect(Self.copy(c, key: wrong).hasPrefix("error:"))
    }
}
