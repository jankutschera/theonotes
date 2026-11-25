// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

extension SyncMaterializer {
    func preparedAttachmentCipher(_ value: SyncAttachmentPayload) async throws -> URL {
        let source = try await reader.attachmentCipher(value)
        return try SyncBlobLocation.pinDownloaded(source, paths: paths, hash: value.blobHash, size: value.cipherBytes)
    }

    func cacheDownloadedAttachment(_ download: DownloadedAttachment, in db: Database) throws {
        let attachment = download.payload
        let context = try SyncWire.cipherContext(accountID: reader.accountID, type: .attachment, entityID: attachment.id)
        let cipher = try NoteCipher.seal(SyncPayloadCodec.encoder().encode(attachment), vaultKey: reader.vaultKey, context: context + ":cache")
        try db.execute(sql: """
            INSERT INTO sync_blob_state(hash,localPath,byteSize,uploaded) VALUES(?,?,?,1)
            ON CONFLICT(hash) DO UPDATE SET uploaded=1
            """, arguments: [attachment.blobHash, try SyncBlobLocation.relative(download.cipher.path), attachment.cipherBytes])
        // A future local attachment edit starts a nonzero generation and must be prepared
        // again. Until then this authenticated descriptor can pin a new note version.
        try db.execute(sql: """
            INSERT INTO sync_attachment_cache(attachmentId,generation,fingerprint,encryptedDescriptor,blobHash)
            VALUES(?,0,'',?,?) ON CONFLICT(attachmentId) DO UPDATE SET generation=0,fingerprint='',
              encryptedDescriptor=excluded.encryptedDescriptor,blobHash=excluded.blobHash
            """, arguments: [attachment.id, cipher, attachment.blobHash])
    }
}
