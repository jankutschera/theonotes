// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct CheckedReencryptionIntegrityTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checked-reencrypt-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A cryptographically authentic BCH1 stream that normal encrypt() never emits: one full
    /// non-final block followed by an authenticated empty final block. Returning that empty
    /// plaintext as the output encoder's EOF used to skip the descriptor verification entirely.
    private func emptyFinalStream(plain: Data, key: SymmetricKey, context: String) throws -> Data {
        #expect(plain.count == ChunkedCipher.chunkSize)
        let prefix = Data(0..<8), fileKeyBytes = Data(repeating: 0x31, count: 32)
        let fileKey = SymmetricKey(data: fileKeyBytes), magic = Data("BCH1".utf8)
        let wrapped = try #require(try AES.GCM.seal(fileKeyBytes, using: key,
            authenticating: magic + prefix + Data(context.utf8)).combined)
        let header = magic + prefix + wrapped
        var result = header
        for (counter, bytes, final) in [(UInt32(0), plain, false), (UInt32(1), Data(), true)] {
            let count = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
            let box = try AES.GCM.seal(bytes, using: fileKey,
                nonce: AES.GCM.Nonce(data: prefix + count),
                authenticating: header + count + Data([final ? 1 : 0]))
            result.append(box.ciphertext); result.append(box.tag)
        }
        return result
    }

    @Test(arguments: [false, true])
    func uncheckedReencryptionHandlesAuthenticatedEmptyFinalChunkAndRejectsTamperedTail(tamper: Bool) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256), plain = Data(repeating: 0x61, count: ChunkedCipher.chunkSize)
        let input = dir.appendingPathComponent("source.bch"), output = dir.appendingPathComponent("copy.bch")
        var wire = try emptyFinalStream(plain: plain, key: key, context: "source")
        if tamper { wire[wire.count - 1] ^= 1 }
        try wire.write(to: input)
        let sentinel = Data("existing output retained on authentication failure".utf8)
        try sentinel.write(to: output)
        if tamper {
            #expect(throws: CryptoError.tampered) {
                try ChunkedCipher.reencrypt(input: input, output: output, fromKey: key, toKey: key, fromContext: "source", toContext: "copy")
            }
            #expect(try Data(contentsOf: output) == sentinel)
        } else {
            try ChunkedCipher.reencrypt(input: input, output: output, fromKey: key, toKey: key, fromContext: "source", toContext: "copy")
            #expect(try ChunkedCipher.decrypt(input: output, keyEncryptionKey: key, context: "copy", maximumBytes: plain.count) == plain)
        }
    }

    @Test(arguments: ["hash", "long", "short"])
    func authenticatedEmptyChunkCannotBypassHashOrLengthBeforeAtomicCommit(fault: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256), plain = Data(repeating: 0x79, count: ChunkedCipher.chunkSize)
        let source = dir.appendingPathComponent("source.bch"), output = dir.appendingPathComponent("existing.bch")
        try emptyFinalStream(plain: plain, key: key, context: "source").write(to: source)
        // Prove this is authenticated source data, not a regression that merely rejects bad tags.
        #expect(try ChunkedCipher.decrypt(input: source, keyEncryptionKey: key, context: "source", maximumBytes: plain.count) == plain)
        let sentinel = Data("existing ciphertext must survive".utf8); try sentinel.write(to: output)
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.reencrypt(input: source, output: output, fromKey: key, toKey: key,
                fromContext: "source", toContext: "copy",
                expectedPlaintextHash: fault == "hash" ? String(repeating: "0", count: 64) : SyncWire.hash(plain),
                expectedPlaintextBytes: Int64(plain.count + (fault == "long" ? 1 : fault == "short" ? -1 : 0)))
        }
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["existing.bch", "source.bch"])
    }

    @Test func authenticatedEmptyFinalChunkWithExactDescriptorPreservesBytes() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256), plain = Data(repeating: 0x79, count: ChunkedCipher.chunkSize)
        let source = dir.appendingPathComponent("source.bch"), output = dir.appendingPathComponent("copy.bch")
        try emptyFinalStream(plain: plain, key: key, context: "source").write(to: source)
        try ChunkedCipher.reencrypt(input: source, output: output, fromKey: key, toKey: key,
            fromContext: "source", toContext: "copy", expectedPlaintextHash: SyncWire.hash(plain), expectedPlaintextBytes: Int64(plain.count))
        #expect(try ChunkedCipher.decrypt(input: output, keyEncryptionKey: key, context: "copy", maximumBytes: plain.count) == plain)
    }

    @Test func emptySourceVerifiesDescriptorBeforeEmittingAnyOutput() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256), empty = Data()
        let source = dir.appendingPathComponent("empty.bch"), output = dir.appendingPathComponent("copy.bch")
        try ChunkedCipher.encrypt(data: empty, output: source, keyEncryptionKey: key, context: "source")
        try ChunkedCipher.reencrypt(input: source, output: output, fromKey: key, toKey: key,
            fromContext: "source", toContext: "copy", expectedPlaintextHash: SyncWire.hash(empty), expectedPlaintextBytes: 0)
        #expect(try ChunkedCipher.decrypt(input: output, keyEncryptionKey: key, context: "copy", maximumBytes: 0).isEmpty)
        let before = try Data(contentsOf: output)
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.reencrypt(input: source, output: output, fromKey: key, toKey: key,
                fromContext: "source", toContext: "copy", expectedPlaintextHash: String(repeating: "0", count: 64), expectedPlaintextBytes: 0)
        }
        #expect(try Data(contentsOf: output) == before)
    }

    @Test(arguments: ["hash", "length", "authentication"])
    func protectedReaderReportsInvalidPayloadForReconcilerQuarantine(fault: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256), plain = Data("verified source bytes".utf8)
        let source = dir.appendingPathComponent("source.bch"), output = dir.appendingPathComponent("existing.bch")
        let context = try SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: "asset")
        try ChunkedCipher.encrypt(data: plain, output: source, keyEncryptionKey: key, context: context)
        if fault == "authentication" {
            var cipher = try Data(contentsOf: source); cipher[cipher.count - 1] ^= 1; try cipher.write(to: source)
        }
        let cipher = try Data(contentsOf: source), sentinel = Data("existing ciphertext".utf8)
        try sentinel.write(to: output)
        let payload = SyncAttachmentPayload(id: "asset", noteId: "note", filename: "file.bin", isLocked: false,
            blobHash: SyncWire.hash(cipher), cipherBytes: Int64(cipher.count),
            fileBytes: Int64(plain.count + (fault == "length" ? 1 : 0)),
            fileHash: fault == "hash" ? String(repeating: "0", count: 64) : SyncWire.hash(plain),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        let reader = SyncPayloadReader(accountID: "account", vaultKey: key, blobs: SyncPayloadReaderTests.Blobs())
        // CloudReconciler catches this exact type/value as payload:invalid; a raw CryptoError
        // escaping this materialization stage instead aborts the pass without quarantining it.
        #expect(throws: SyncProtocolError.invalidPayload) {
            try reader.writeProtectedAttachment(payload, cipher: source, to: output, noteKey: key, context: "copy")
        }
        #expect(try Data(contentsOf: output) == sentinel)
    }
}
