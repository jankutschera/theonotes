// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct SyncPayloadReaderTests {
    struct Blobs: SyncBlobTransport {
        var files: [String: URL] = [:]
        func ensureUploaded(_ hashes: [String]) async throws {}
        func download(hash: String) async throws -> URL {
            guard let file = files[hash] else { throw SyncProtocolError.invalidPayload }
            return file
        }
    }

    private func entity<T: Encodable>(_ value: T, type: SyncEntityType, id: String, key: SymmetricKey, refs: [String] = []) throws -> SyncEntity {
        let cipher = try NoteCipher.seal(SyncPayloadCodec.encoder().encode(value), vaultKey: key,
                                        context: SyncWire.cipherContext(accountID: "account", type: type, entityID: id))
        return SyncEntity(mutation: SyncMutation(mutationId: "mutation", entityType: type, entityId: id, parentRevision: 0,
                                                ciphertext: SyncWire.base64(cipher), blobRefs: refs), revision: 1, sequence: 1, receivedAt: 1)
    }

    @Test func decryptedPayloadMustMatchItsEntityAndPortableSettingType() async throws {
        let key = SymmetricKey(size: .bits256)
        let reader = SyncPayloadReader(accountID: "account", vaultKey: key, blobs: Blobs())
        let note = Note(id: "one", text: "exact e\u{301}\r\n", title: "Title", titleKey: "title", createdAt: .now, modifiedAt: .now)
        let value = SyncNotePayload(note: note, directTags: [], pinnedTags: [], attachmentIds: [])
        let valid = try entity(value, type: .note, id: "one", key: key)
        guard case .note(let opened) = try await reader.read(valid) else { Issue.record("Expected note"); return }
        #expect(Data(opened.text.utf8) == Data(note.text.utf8))
        await #expect(throws: SyncProtocolError.invalidPayload) {
            try await reader.read(entity(value, type: .note, id: "another", key: key))
        }
        await #expect(throws: CryptoError.tampered) {
            try await SyncPayloadReader(accountID: "other-account", vaultKey: key, blobs: Blobs()).read(valid)
        }
        await #expect(throws: (any Error).self) {
            try await reader.read(entity(SyncSettingPayload(key: "hideMarkdown", value: "\"not a boolean\""), type: .setting, id: "setting", key: key))
        }
        await #expect(throws: SyncProtocolError.invalidPayload) {
            try await reader.read(entity(SyncSettingPayload(key: "mobile.biometry", value: "false"), type: .setting, id: "setting", key: key))
        }
    }

    @Test func noteFileSnapshotsMustMatchTheirNoteAndDeclareTheirBlobReferences() async throws {
        let key = SymmetricKey(size: .bits256), hash = SyncWire.hash(Data("cipher".utf8))
        let file = SyncAttachmentPayload(id: "asset", noteId: "note", filename: "file.txt", isLocked: false,
            blobHash: hash, cipherBytes: 100, fileBytes: 20, fileHash: SyncWire.hash(Data("file".utf8)),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        var note = SyncNotePayload(note: Note(id: "note", text: "[file](file.txt)", title: "file", titleKey: "file", createdAt: .now, modifiedAt: .now), directTags: [], pinnedTags: [], attachmentIds: ["asset"])
        note.attachmentNames = ["asset": "file.txt"]; note.attachmentSnapshots = ["asset": file]
        let reader = SyncPayloadReader(accountID: "account", vaultKey: key, blobs: Blobs())
        await #expect(throws: SyncProtocolError.invalidPayload) {
            try await reader.read(entity(note, type: .note, id: note.id, key: key))
        }
        guard case .note(let received) = try await reader.read(entity(note, type: .note, id: note.id, key: key, refs: [hash])) else {
            Issue.record("Expected authenticated note snapshot"); return
        }
        #expect(received.attachmentSnapshots?["asset"] == file)
        note.id = "another-note"
        await #expect(throws: SyncProtocolError.invalidPayload) {
            try await reader.read(entity(note, type: .note, id: note.id, key: key, refs: [hash]))
        }
    }

    @Test func protectedAttachmentKeepsInnerCiphertextAndCorruptionLeavesNoOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-reader-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID().uuidString.lowercased(), name: String
        name = id + ".bch"
        let inner = folder.appendingPathComponent("inner"), outer = folder.appendingPathComponent("outer"), output = folder.appendingPathComponent("output")
        let key = SymmetricKey(size: .bits256)
        try ChunkedCipher.encrypt(data: Data("private file".utf8), output: inner, keyEncryptionKey: SymmetricKey(size: .bits256), context: name)
        try ChunkedCipher.encrypt(input: inner, output: outer, keyEncryptionKey: key,
                                  context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: id))
        let innerHash = try SyncAttachmentPreparer.hashFile(inner), outerHash = try SyncAttachmentPreparer.hashFile(outer)
        let descriptor = SyncAttachmentPayload(id: id, noteId: "note", filename: name, isLocked: true,
            blobHash: outerHash.hash, cipherBytes: outerHash.size, fileBytes: innerHash.size, fileHash: innerHash.hash,
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        let reader = SyncPayloadReader(accountID: "account", vaultKey: key, blobs: Blobs(files: [outerHash.hash: outer]))
        let remote = try entity(descriptor, type: .attachment, id: id, key: key, refs: [outerHash.hash])
        guard case .attachment(let value) = try await reader.read(remote) else { Issue.record("Expected attachment"); return }
        let downloaded = try await reader.attachmentCipher(value)
        try reader.writeAttachment(value, cipher: downloaded, to: output)
        #expect(try Data(contentsOf: output) == Data(contentsOf: inner))
        await #expect(throws: SyncProtocolError.invalidPayload) {
            try await reader.read(entity(descriptor, type: .attachment, id: id, key: key))
        }
        try FileManager.default.removeItem(at: output)
        var broken = try Data(contentsOf: outer); broken[broken.count - 1] ^= 1
        try broken.write(to: outer)
        #expect(throws: (any Error).self) { try reader.writeAttachment(value, cipher: outer, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        await #expect(throws: SyncProtocolError.invalidPayload) { try await reader.attachmentCipher(value) }
    }
}
