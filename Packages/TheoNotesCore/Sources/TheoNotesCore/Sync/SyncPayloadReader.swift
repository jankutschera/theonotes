// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

enum SyncRemoteValue: Sendable {
    case deleted
    case note(SyncNotePayload)
    case attachment(SyncAttachmentPayload)
    case tag(SyncTagPreferencePayload)
    case setting(SyncSettingPayload)
    case externalRef(SyncExternalRefPayload)
    case lockEnvelope(Data)
}

/// Opens only account ciphertext whose entity identity and blob references match its signed
/// wire envelope. Password-locked note bodies remain opaque here. No plaintext cache is written.
struct SyncPayloadReader: Sendable {
    let accountID: String
    let vaultKey: SymmetricKey
    let blobs: any SyncBlobTransport

    func read(_ entity: SyncEntity) async throws -> SyncRemoteValue {
        let mutation = entity.mutation
        try mutation.validate()
        if mutation.tombstone { return .deleted }
        let cipher: Data
        if let inline = mutation.ciphertext { cipher = try SyncWire.decode64(inline) }
        else if let hash = mutation.payloadRef {
            let url = try await blobs.download(hash: hash)
            let facts = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard facts.isRegularFile == true, facts.isSymbolicLink != true,
                  let size = facts.fileSize, size <= 4_194_304 else { throw SyncProtocolError.responseTooLarge }
            cipher = try Data(contentsOf: url)
            guard SyncWire.hash(cipher) == hash else { throw SyncProtocolError.invalidPayload }
        } else { throw SyncProtocolError.invalidPayload }
        let context = try SyncWire.cipherContext(accountID: accountID, type: mutation.entityType, entityID: mutation.entityId)
        let plain = try NoteCipher.open(cipher, vaultKey: vaultKey, context: context)
        guard plain.count <= 4_194_304 else { throw SyncProtocolError.responseTooLarge }
        switch mutation.entityType {
        case .note:
            let value = try SyncPayloadCodec.decode(SyncNotePayload.self, from: plain)
            try value.validate()
            guard value.id == mutation.entityId else { throw SyncProtocolError.invalidPayload }
            guard (value.attachmentSnapshots ?? [:]).values.allSatisfy({ mutation.blobRefs.contains($0.blobHash) }) else { throw SyncProtocolError.invalidPayload }
            for tag in value.directTags + value.pinnedTags { _ = try NoteStore.tagToken(tag) }
            return .note(value)
        case .attachment:
            let value = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: plain)
            try value.validate()
            guard value.id == mutation.entityId, mutation.blobRefs.contains(value.blobHash) else { throw SyncProtocolError.invalidPayload }
            return .attachment(value)
        case .tagPreference:
            let value = try SyncPayloadCodec.decode(SyncTagPreferencePayload.self, from: plain)
            guard value.version == 1 else { throw SyncProtocolError.unsupportedVersion }
            _ = try NoteStore.tagToken(value.path)
            return .tag(value)
        case .setting:
            let value = try SyncPayloadCodec.decode(SyncSettingPayload.self, from: plain)
            try value.validate()
            return .setting(value)
        case .externalRef:
            let value = try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: plain)
            guard value.version == 1, !value.source.isEmpty, !value.externalId.isEmpty,
                  value.source.utf8.count <= 1024, value.externalId.utf8.count <= 4096 else { throw SyncProtocolError.invalidPayload }
            if let id = value.noteId { try SyncWire.validateID(id) }
            return .externalRef(value)
        case .keyBundle:
            let value = try SyncPayloadCodec.decode(SyncLockEnvelopePayload.self, from: plain)
            let envelope = try JSONDecoder().decode(CryptoEnvelope.self, from: value.envelope)
            guard value.version == 1, envelope.version == 1, envelope.kdf == CryptoEnvelope.kdfName,
                  CryptoEnvelope.publicIterationRange.contains(envelope.iterations), envelope.salt.count == 16,
                  envelope.wrappedVaultKey.count == 60 else { throw SyncProtocolError.invalidPayload }
            return .lockEnvelope(value.envelope)
        }
    }

    /// Download outside the database writer, then decrypt only into a durable attachment batch.
    func attachmentCipher(_ value: SyncAttachmentPayload) async throws -> URL {
        try value.validate()
        let url = try await blobs.download(hash: value.blobHash)
        let measured = try SyncAttachmentPreparer.hashFile(url)
        guard measured.hash == value.blobHash, measured.size == value.cipherBytes else { throw SyncProtocolError.invalidPayload }
        return url
    }

    /// Protect a plaintext-side recovery copy without ever materializing plaintext on disk.
    /// Retain normal descriptor hash/length checks while transcoding the outer sync envelope
    /// directly into the destination note-key envelope.
    func writeProtectedAttachment(_ value: SyncAttachmentPayload, cipher: URL, to output: URL,
                                   noteKey: SymmetricKey, context: String) throws {
        guard !value.isLocked else { throw SyncProtocolError.invalidPayload }
        do {
            try ChunkedCipher.reencrypt(input: cipher, output: output, fromKey: vaultKey, toKey: noteKey,
                fromContext: SyncWire.cipherContext(accountID: accountID, type: .attachment, entityID: value.id),
                toContext: context, expectedPlaintextHash: value.fileHash, expectedPlaintextBytes: value.fileBytes)
        } catch CryptoError.tampered {
            // Materialization integrity failures must enter the reconciler's invalid-payload
            // quarantine path, just like ordinary attachment descriptor verification failures.
            throw SyncProtocolError.invalidPayload
        }
    }

    func writeAttachment(_ value: SyncAttachmentPayload, cipher: URL, to output: URL) throws {
        var verified = false
        defer { if !verified { try? FileManager.default.removeItem(at: output) } }
        let context = try SyncWire.cipherContext(accountID: accountID, type: .attachment, entityID: value.id)
        try ChunkedCipher.decrypt(input: cipher, output: output, keyEncryptionKey: vaultKey, context: context)
        let measured = try SyncAttachmentPreparer.hashFile(output)
        guard measured.hash == value.fileHash, measured.size == value.fileBytes else { throw SyncProtocolError.invalidPayload }
        if value.isLocked {
            let reader = try FileHandle(forReadingFrom: output); defer { try? reader.close() }
            guard try reader.read(upToCount: 4) == Data("BCH1".utf8) else { throw SyncProtocolError.invalidPayload }
        }
        verified = true
    }
}
