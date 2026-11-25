// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

// Fixed bytes are generated offline without importing TheoNotesCore; tests never regenerate them.
struct CanonicalCryptoV1Fixture: Decodable {
    struct Attachment: Decodable { let size: Int; let sealed: Data }
    let vaultKey: Data
    let password: String
    let derivedKey: Data
    let envelope: CryptoEnvelope
    let noteId: String
    let blobName: String
    let payloadJSON: String
    let bnc1: Data
    let bch1: [Attachment]
    let baseJSON: String
    let entryJSON: [String]
    let bjb1: String
    let bje1: [String]
    let baseAAD: String
    let entryAAD: [String]
    let unsupportedBaseVersion: String
    let unsupportedEntryVersion: String

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/crypto/v1/canonical.json")))
    }
    var key: SymmetricKey { SymmetricKey(data: vaultKey) }
    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    static func plaintext(size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }) }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-crypto-v1-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
    }
}

@Suite struct CanonicalCryptoV1Tests {
    @Test func envelopeAndNormalizedPBKDF2MatchFixedBytes() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let derived = try CryptoEnvelope.deriveKey(password: f.password, salt: f.envelope.salt, iterations: 1_000)
        #expect(CanonicalCryptoV1Fixture.bytes(derived) == f.derivedKey)
        let decomposed = f.password.decomposedStringWithCanonicalMapping
        #expect(CanonicalCryptoV1Fixture.bytes(try CryptoEnvelope.deriveKey(
            password: decomposed, salt: f.envelope.salt, iterations: 1_000)) == f.derivedKey)
        #expect(CanonicalCryptoV1Fixture.bytes(try f.envelope.unwrap(
            password: decomposed, allowedIterations: CryptoEnvelope.testIterationRange)) == f.vaultKey)
        #expect(throws: CryptoError.wrongPassword) {
            try f.envelope.unwrap(password: "wrong", allowedIterations: CryptoEnvelope.testIterationRange)
        }
        #expect(throws: CryptoError.malformed) { try f.envelope.unwrap(password: f.password) }
        let encoded = try JSONEncoder().encode(f.envelope)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["version", "kdf", "salt", "iterations", "wrappedVaultKey"])
        for change in 0..<5 {
            var bad = f.envelope
            switch change {
            case 0: bad.version = 2
            case 1: bad.kdf = "pbkdf2-sha512"
            case 2: bad.salt.removeLast()
            case 3: bad.iterations = 0
            default: bad.wrappedVaultKey = Data(bad.wrappedVaultKey.prefix(12))
            }
            #expect(throws: CryptoError.malformed) {
                try bad.unwrap(password: f.password, allowedIterations: CryptoEnvelope.testIterationRange)
            }
        }
        var tampered = f.envelope
        tampered.wrappedVaultKey[tampered.wrappedVaultKey.count - 1] ^= 1
        #expect(throws: CryptoError.wrongPassword) {
            try tampered.unwrap(password: f.password, allowedIterations: CryptoEnvelope.testIterationRange)
        }
    }

    @Test func bnc1ReadsGoldenPayloadWithRawNoteIdOnly() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        #expect(try NoteCipher.open(f.bnc1, vaultKey: f.key, context: f.noteId) == Data(f.payloadJSON.utf8))
        let payload = try JSONDecoder().decode(LockedNotePayload.self, from: Data(f.payloadJSON.utf8))
        #expect(payload.version == 1)
        #expect(payload.attachments == ["diagram.png": f.blobName])
        #expect(payload.attachmentIDs == ["diagram.png": "synthetic-attachment-01"])
        for context in ["note:" + f.noteId, "other-note", ""] {
            #expect(throws: CryptoError.tampered) { try NoteCipher.open(f.bnc1, vaultKey: f.key, context: context) }
        }
        for offset in [4, 63, 64, f.bnc1.count - 1] {
            var bad = f.bnc1
            bad[offset] ^= 1
            #expect(throws: CryptoError.tampered) { try NoteCipher.open(bad, vaultKey: f.key, context: f.noteId) }
        }
        var version = f.bnc1
        version[3] = UInt8(ascii: "2")
        for bad in [version, Data(f.bnc1.prefix(91))] {
            #expect(throws: CryptoError.malformed) { try NoteCipher.open(bad, vaultKey: f.key, context: f.noteId) }
        }
    }

    @Test func bch1ReadsGoldenEmptyBoundaryAndMultichunkStreams() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(f.bch1.map(\.size) == [0, 17, 65_536, 65_553])
        for vector in f.bch1 {
            let input = dir.appendingPathComponent("input"), output = dir.appendingPathComponent("output")
            try vector.sealed.write(to: input)
            try ChunkedCipher.decrypt(input: input, output: output, keyEncryptionKey: f.key, context: f.blobName)
            #expect(try Data(contentsOf: output) == CanonicalCryptoV1Fixture.plaintext(size: vector.size))
        }
    }

    @Test func bch1RejectsContextFramingTamperingTruncationAndChunkReorderAtomically() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input"), output = dir.appendingPathComponent("output")
        let sentinel = Data("untouched destination".utf8)
        try sentinel.write(to: output)
        let vector = try #require(f.bch1.last).sealed
        var version = vector; version[3] = UInt8(ascii: "2")
        var prefix = vector; prefix[4] ^= 1
        var wrapped = vector; wrapped[71] ^= 1
        var body = vector; body[72] ^= 1
        var tag = vector; tag[tag.count - 1] ^= 1
        let boundary = 72 + 65_536 + 16
        let reordered = Data(vector.prefix(72)) + Data(vector.suffix(from: boundary)) + Data(vector[72..<boundary])
        let cases: [(Data, String, CryptoError)] = [
            (vector, "attachment:synthetic-attachment-01", .tampered),
            (vector, "synthetic-attachment-01", .tampered),
            (vector, "other.bch", .tampered), (version, f.blobName, .malformed),
            (Data(vector.prefix(71)), f.blobName, .malformed),
            (prefix, f.blobName, .tampered), (wrapped, f.blobName, .tampered),
            (body, f.blobName, .tampered), (tag, f.blobName, .tampered),
            (Data(vector.prefix(72)), f.blobName, .truncated),
            (Data(vector.prefix(boundary)), f.blobName, .truncated),
            (reordered, f.blobName, .tampered), (vector + Data([0]), f.blobName, .tampered)]
        for (data, context, error) in cases {
            try data.write(to: input)
            #expect(throws: error) { try ChunkedCipher.decrypt(input: input, output: output, keyEncryptionKey: f.key, context: context) }
            #expect(try Data(contentsOf: output) == sentinel)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["input", "output"])
        }
    }

    @Test func randomizedWritersPreserveEnvelopeAndNoteWireSemantics() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let (envelope, key) = try CryptoEnvelope.create(password: f.password, iterations: 1_000)
        #expect(envelope.version == 1 && envelope.kdf == "pbkdf2-sha256")
        #expect(envelope.salt.count == 16 && envelope.iterations == 1_000 && envelope.wrappedVaultKey.count == 60)
        let derived = try CryptoEnvelope.deriveKey(password: f.password, salt: envelope.salt, iterations: 1_000)
        #expect(try CanonicalCryptoV1Fixture.open(envelope.wrappedVaultKey, key: derived,
            aad: Data("baerchen-envelope-v1".utf8)) == CanonicalCryptoV1Fixture.bytes(key))
        let plain = Data(f.payloadJSON.utf8)
        let sealed = try NoteCipher.seal(plain, vaultKey: f.key, context: f.noteId)
        #expect(sealed.prefix(4) == Data("BNC1".utf8) && sealed.count == 92 + plain.count)
        let aad = Data(("BNC1" + f.noteId).utf8)
        let noteKey = try CanonicalCryptoV1Fixture.open(Data(sealed[4..<64]), key: f.key, aad: aad)
        #expect(noteKey.count == 32)
        #expect(try CanonicalCryptoV1Fixture.open(Data(sealed.dropFirst(64)), key: SymmetricKey(data: noteKey), aad: aad) == plain)
    }

    @Test func randomizedAttachmentWriterPreservesHeaderCounterAndFinalFlag() throws {
        let f = try CanonicalCryptoV1Fixture.load()
        let dir = try CanonicalCryptoV1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("output")
        #expect(ChunkedCipher.chunkSize == 65_536)
        for size in [0, 65_536, 65_553] {
            let plain = CanonicalCryptoV1Fixture.plaintext(size: size)
            try ChunkedCipher.encrypt(data: plain, output: output, keyEncryptionKey: f.key, context: f.blobName)
            let sealed = try Data(contentsOf: output), header = Data(sealed.prefix(72))
            #expect(header.prefix(4) == Data("BCH1".utf8))
            let prefix = Data(header[4..<12])
            let fileKey = try CanonicalCryptoV1Fixture.open(Data(header[12..<72]), key: f.key,
                aad: Data("BCH1".utf8) + prefix + Data(f.blobName.utf8))
            #expect(fileKey.count == 32)
            let count = max(1, (size + 65_535) / 65_536)
            #expect(sealed.count == 72 + size + count * 16)
            for index in 0..<count {
                let counter = withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) }
                let chunk = Data(sealed.dropFirst(72 + index * 65_552).prefix(65_552))
                let combined = prefix + counter + chunk
                let decoded = try CanonicalCryptoV1Fixture.open(combined, key: SymmetricKey(data: fileKey),
                    aad: header + counter + Data([index == count - 1 ? 1 : 0]))
                #expect(decoded == Data(plain.dropFirst(index * 65_536).prefix(65_536)))
            }
        }
    }
}
