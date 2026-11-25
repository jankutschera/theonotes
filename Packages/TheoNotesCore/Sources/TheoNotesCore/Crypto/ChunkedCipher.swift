// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

/// Streaming AES-GCM for attachments.
/// Header v1 (72 bytes): `BCH1` ‖ 8-byte nonce prefix ‖ 60-byte wrapped per-file key
/// (AES-GCM combined under the key-encryption key, AAD = `BCH1` ‖ prefix ‖ UTF-8(context)).
/// Then chunks (ciphertext ‖ 16-byte tag) under the per-file key.
/// Chunk nonce = prefix ‖ UInt32 BE counter; AAD = header ‖ counter (4 BE) ‖ isFinal (1).
/// Output appears at its destination only after the whole stream is written/verified.
public enum ChunkedCipher {
    public static let chunkSize = 65_536
    static let magic = Data("BCH1".utf8)
    static let prefixLength = 8
    static let wrappedKeyLength = 60
    static let headerLength = 4 + prefixLength + wrappedKeyLength
    static let tagLength = 16

    public static func encrypt(input: URL, output: URL, keyEncryptionKey: SymmetricKey, context: String) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        try encrypt(output: output, keyEncryptionKey: keyEncryptionKey, context: context) {
            try reader.read(upToCount: chunkSize) ?? Data()
        }
    }

    public static func encrypt(data: Data, output: URL, keyEncryptionKey: SymmetricKey, context: String) throws {
        var offset = data.startIndex
        try encrypt(output: output, keyEncryptionKey: keyEncryptionKey, context: context) {
            let end = min(offset + chunkSize, data.endIndex)
            defer { offset = end }
            return Data(data[offset..<end])
        }
    }

    static func encrypt(output: URL, keyEncryptionKey: SymmetricKey, context: String,
                                read: () throws -> Data) throws {
        var prefix = Data(count: prefixLength)
        let status = prefix.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, prefixLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CryptoError.keyDerivationFailed }
        let fileKey = SymmetricKey(size: .bits256)
        let fileKeyBytes = fileKey.withUnsafeBytes { Data($0) }
        guard let wrapped = try AES.GCM.seal(
            fileKeyBytes, using: keyEncryptionKey, authenticating: wrapAAD(prefix: prefix, context: context)).combined
        else { throw CryptoError.malformed }
        let header = magic + prefix + wrapped

        try withTempOutput(output) { writer in
            try writer.write(contentsOf: header)
            var current = try read()
            var counter: UInt32 = 0
            var done = false
            while !done {
                try autoreleasepool {
                    let next = try read()
                    let isFinal = next.isEmpty
                    let box = try AES.GCM.seal(
                        current, using: fileKey,
                        nonce: nonce(prefix: prefix, counter: counter),
                        authenticating: chunkAAD(header: header, counter: counter, isFinal: isFinal))
                    try writer.write(contentsOf: box.ciphertext + box.tag)
                    if isFinal { done = true; return }
                    guard counter < UInt32.max else { throw CryptoError.malformed }
                    counter += 1
                    current = next
                }
            }
        }
    }

    public static func decrypt(input: URL, output: URL, keyEncryptionKey: SymmetricKey, context: String) throws {
        let reader = try VerifiedReader(input: input, key: keyEncryptionKey, context: context)
        try withTempOutput(output) { writer in
            while !reader.done {
                try autoreleasepool {
                    if let bytes = try reader.next() { try writer.write(contentsOf: bytes) }
                }
            }
        }
    }

    /// The plaintext length of a file, from its size alone (nothing is read or decrypted): every
    /// chunk is its ciphertext plus a 16-byte tag after the 72-byte header.
    public static func plaintextSize(of input: URL) throws -> Int {
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= headerLength + tagLength else { throw CryptoError.truncated }
        let body = size - headerLength
        let chunks = (body + chunkSize + tagLength - 1) / (chunkSize + tagLength)
        return body - chunks * tagLength
    }

    /// The whole verified plaintext in memory (nothing is written); same checks as the file form.
    /// A file whose plaintext would exceed `maximumBytes` is refused from its size, before any
    /// plaintext is allocated (`NotePrivacyError.attachmentTooLarge`).
    public static func decrypt(input: URL, keyEncryptionKey: SymmetricKey, context: String,
                               maximumBytes: Int) throws -> Data {
        guard try plaintextSize(of: input) <= maximumBytes else { throw NotePrivacyError.attachmentTooLarge }
        let reader = try VerifiedReader(input: input, key: keyEncryptionKey, context: context)
        var plain = Data()
        while !reader.done {
            try autoreleasepool {
                if let bytes = try reader.next() { plain.append(bytes) }
            }
        }
        return plain
    }

    /// Rebinds a copied attachment to its new stable identifier, without a plaintext temp file.
    /// Neither a partial input nor failed authentication can replace an existing output.
    public static func reencrypt(input: URL, output: URL, keyEncryptionKey: SymmetricKey,
                                  fromContext: String, toContext: String) throws {
        try reencrypt(input: input, output: output, fromKey: keyEncryptionKey, toKey: keyEncryptionKey,
                      fromContext: fromContext, toContext: toContext)
    }

    /// Streams an authenticated attachment between password vaults during backup merge.
    public static func reencrypt(input: URL, output: URL, fromKey: SymmetricKey, toKey: SymmetricKey,
                                  fromContext: String, toContext: String) throws {
        let reader = try VerifiedReader(input: input, key: fromKey, context: fromContext)
        try encrypt(output: output, keyEncryptionKey: toKey, context: toContext) {
            while let chunk = try reader.next() {
                if !chunk.isEmpty { return chunk }
            }
            return Data()
        }
    }

    /// Streams verified plaintext directly between encryption envelopes. The expected digest
    /// and length describe the decrypted SOURCE, not the new randomized ciphertext. Validation
    /// finishes inside withTempOutput, before output can replace an existing file.
    static func reencrypt(input: URL, output: URL, fromKey: SymmetricKey, toKey: SymmetricKey,
                          fromContext: String, toContext: String,
                          expectedPlaintextHash: String, expectedPlaintextBytes: Int64) throws {
        guard expectedPlaintextBytes >= 0 else { throw CryptoError.tampered }
        let reader = try VerifiedReader(input: input, key: fromKey, context: fromContext)
        var hash = SHA256(), count: Int64 = 0
        var verifiedEOF = false
        try encrypt(output: output, keyEncryptionKey: toKey, context: toContext) {
            if verifiedEOF { return Data() }
            // Empty authenticated plaintext is not necessarily the verified reader's EOF.
            // Never hand the output encoder its empty-data EOF sentinel before the source
            // reader has authenticated the entire stream and the descriptor has been checked.
            while true {
                try Task.checkCancellation()
                guard let chunk = try reader.next() else {
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard count == expectedPlaintextBytes, digest == expectedPlaintextHash else { throw CryptoError.tampered }
                    verifiedEOF = true
                    return Data()
                }
                guard Int64(chunk.count) <= expectedPlaintextBytes - count else { throw CryptoError.tampered }
                count += Int64(chunk.count)
                hash.update(data: chunk)
                if !chunk.isEmpty { return chunk }
            }
        }
    }

    private final class VerifiedReader {
        let reader: FileHandle
        let header: Data
        let prefix: Data
        let key: SymmetricKey
        var current: Data
        var counter: UInt32 = 0
        var done = false

        init(input: URL, key wrappingKey: SymmetricKey, context: String) throws {
            reader = try FileHandle(forReadingFrom: input)
            header = try reader.read(upToCount: ChunkedCipher.headerLength) ?? Data()
            guard header.count == ChunkedCipher.headerLength, header.prefix(ChunkedCipher.magic.count) == ChunkedCipher.magic else {
                throw CryptoError.malformed
            }
            prefix = Data(header[4..<(4 + ChunkedCipher.prefixLength)])
            let wrapped = header[(4 + ChunkedCipher.prefixLength)...]
            do {
                let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: wrappingKey,
                    authenticating: ChunkedCipher.wrapAAD(prefix: prefix, context: context))
                guard bytes.count == 32 else { throw CryptoError.malformed }
                key = SymmetricKey(data: bytes)
            } catch let error as CryptoError { throw error }
            catch CryptoKitError.authenticationFailure { throw CryptoError.tampered }
            catch { throw CryptoError.malformed }
            current = try reader.read(upToCount: ChunkedCipher.chunkSize + ChunkedCipher.tagLength) ?? Data()
            guard !current.isEmpty else { throw CryptoError.truncated }
        }

        deinit { try? reader.close() }

        func next() throws -> Data? {
            guard !done else { return nil }
            let next = try reader.read(upToCount: ChunkedCipher.chunkSize + ChunkedCipher.tagLength) ?? Data()
            let isFinal = next.isEmpty
            guard current.count >= ChunkedCipher.tagLength else { throw isFinal ? CryptoError.truncated : CryptoError.tampered }
            let plain: Data
            do {
                plain = try ChunkedCipher.open(current, prefix: prefix, header: header, counter: counter, isFinal: isFinal, key: key)
            } catch CryptoKitError.authenticationFailure {
                if isFinal, (try? ChunkedCipher.open(current, prefix: prefix, header: header, counter: counter, isFinal: false, key: key)) != nil {
                    throw CryptoError.truncated
                }
                throw CryptoError.tampered
            }
            if isFinal { done = true }
            else {
                guard counter < UInt32.max else { throw CryptoError.malformed }
                counter += 1; current = next
            }
            return plain
        }
    }

    /// Runs `body` against a temp file next to `output`, then moves it into place.
    /// The temp file is removed if `body` throws; `output` is untouched on failure.
    private static func withTempOutput(_ output: URL, _ body: (FileHandle) throws -> Void) throws {
        let fm = FileManager.default
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CryptoError.malformed }
        do {
            let writer = try FileHandle(forWritingTo: temp)
            do {
                try body(writer)
                try writer.synchronize()
                try writer.close()
            } catch {
                try? writer.close()
                throw error
            }
            if fm.fileExists(atPath: output.path) {
                _ = try fm.replaceItemAt(output, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: output)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static func open(
        _ chunk: Data, prefix: Data, header: Data, counter: UInt32, isFinal: Bool, key: SymmetricKey
    ) throws -> Data {
        let ciphertext = chunk.prefix(chunk.count - tagLength)
        let tag = chunk.suffix(tagLength)
        let box = try AES.GCM.SealedBox(
            nonce: nonce(prefix: prefix, counter: counter), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: chunkAAD(header: header, counter: counter, isFinal: isFinal))
    }

    private static func counterBytes(_ counter: UInt32) -> Data {
        withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    private static func nonce(prefix: Data, counter: UInt32) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: prefix + counterBytes(counter))
    }

    private static func wrapAAD(prefix: Data, context: String) -> Data {
        magic + prefix + Data(context.utf8)
    }

    private static func chunkAAD(header: Data, counter: UInt32, isFinal: Bool) -> Data {
        header + counterBytes(counter) + Data([isFinal ? 1 : 0])
    }
}
