// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite("ChunkedCipher")
struct ChunkedCipherTests {
    private let encChunk = ChunkedCipher.chunkSize + 16
    private let headerSize = 72
    private let ctx = "att-1"

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func roundTrip(size: Int) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        let out = dir.appendingPathComponent("out")
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: ctx)
        let encrypted = try Data(contentsOf: enc)
        #expect(encrypted.prefix(4) == Data("BCH1".utf8))
        let chunks = max(1, (size + ChunkedCipher.chunkSize - 1) / ChunkedCipher.chunkSize)
        #expect(encrypted.count == headerSize + size + chunks * 16)
        try ChunkedCipher.decrypt(input: enc, output: out, keyEncryptionKey: key, context: ctx)
        #expect(try Data(contentsOf: out) == data)
    }

    @Test(arguments: [0, 1, 65_536, 65_537, 1_000_000])
    func roundTripSizes(size: Int) throws { try roundTrip(size: size) }

    @Test func droppingLastChunkIsTruncated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data(repeating: 9, count: 1_000_000).write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: ctx)
        let encrypted = try Data(contentsOf: enc)
        let fullChunks = (1_000_000 - 1) / ChunkedCipher.chunkSize   // all but the last
        try encrypted.prefix(headerSize + fullChunks * encChunk).write(to: enc)
        let out = dir.appendingPathComponent("out")
        #expect(throws: CryptoError.truncated) {
            try ChunkedCipher.decrypt(input: enc, output: out, keyEncryptionKey: key, context: ctx)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func headerOnlyAndSingleChunkDropAreTruncated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data("hi".utf8).write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: ctx)
        try Data(contentsOf: enc).prefix(headerSize).write(to: enc)
        #expect(throws: CryptoError.truncated) {
            try ChunkedCipher.decrypt(input: enc, output: dir.appendingPathComponent("out"), keyEncryptionKey: key, context: ctx)
        }
    }

    @Test func flippedByteIsTampered() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data(repeating: 1, count: 200_000).write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: ctx)
        for offset in [headerSize + 5, headerSize + encChunk + 100, try Data(contentsOf: enc).count - 1] {
            var encrypted = try Data(contentsOf: enc)
            encrypted[offset] ^= 0x01
            let bad = dir.appendingPathComponent("bad")
            try encrypted.write(to: bad)
            let out = dir.appendingPathComponent("out")
            #expect(throws: CryptoError.tampered) {
                try ChunkedCipher.decrypt(input: bad, output: out, keyEncryptionKey: key, context: ctx)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".tmp") })
        }
    }

    @Test func swappedChunksAreTampered() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data((0..<(3 * ChunkedCipher.chunkSize)).map { UInt8(truncatingIfNeeded: $0) }).write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: ctx)
        var e = try Data(contentsOf: enc)
        let a = headerSize, b = headerSize + encChunk
        let first = e[a..<b], second = e[b..<(b + encChunk)]
        e.replaceSubrange(a..<b, with: second)
        e.replaceSubrange(b..<(b + encChunk), with: first)
        try e.write(to: enc)
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.decrypt(input: enc, output: dir.appendingPathComponent("out"), keyEncryptionKey: key, context: ctx)
        }
    }

    @Test func wrongKeyAndBadHeader() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data("hi".utf8).write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: SymmetricKey(size: .bits256), context: ctx)
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.decrypt(input: enc, output: dir.appendingPathComponent("out"), keyEncryptionKey: SymmetricKey(size: .bits256), context: ctx)
        }
        try Data("nope".utf8).write(to: plain)
        #expect(throws: CryptoError.malformed) {
            try ChunkedCipher.decrypt(input: plain, output: dir.appendingPathComponent("out"), keyEncryptionKey: SymmetricKey(size: .bits256), context: ctx)
        }
    }

    @Test func wrongContextIsTampered() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data("hi".utf8).write(to: plain)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: "a")
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.decrypt(input: enc, output: dir.appendingPathComponent("out"), keyEncryptionKey: key, context: "b")
        }
    }

    @Test func perFileKeysDiffer() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        try Data("same".utf8).write(to: plain)
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try ChunkedCipher.encrypt(input: plain, output: a, keyEncryptionKey: key, context: ctx)
        try ChunkedCipher.encrypt(input: plain, output: b, keyEncryptionKey: key, context: ctx)
        let da = try Data(contentsOf: a), db = try Data(contentsOf: b)
        #expect(da[12..<72] != db[12..<72])
    }

    @Test func overwritesExistingOutputOnSuccess() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("plain")
        let enc = dir.appendingPathComponent("enc")
        try Data("new".utf8).write(to: plain)
        try Data("old".utf8).write(to: enc)
        try ChunkedCipher.encrypt(input: plain, output: enc, keyEncryptionKey: key, context: ctx)
        let out = dir.appendingPathComponent("out")
        try ChunkedCipher.decrypt(input: enc, output: out, keyEncryptionKey: key, context: ctx)
        #expect(try Data(contentsOf: out) == Data("new".utf8))
    }
    @Test(arguments: [0, 65_536, 65_537, 200_017])
    func encryptedCopiesAreReboundWithoutPlaintextStaging(size: Int) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let source = dir.appendingPathComponent("source"), copy = dir.appendingPathComponent("copy"), output = dir.appendingPathComponent("output")
        let bytes = Data(repeating: 93, count: size)
        try ChunkedCipher.encrypt(data: bytes, output: source, keyEncryptionKey: key, context: "original")
        try ChunkedCipher.reencrypt(input: source, output: copy, keyEncryptionKey: key, fromContext: "original", toContext: "copy")
        #expect(throws: CryptoError.tampered) { try ChunkedCipher.decrypt(input: copy, output: output, keyEncryptionKey: key, context: "original") }
        try ChunkedCipher.decrypt(input: copy, output: output, keyEncryptionKey: key, context: "copy")
        #expect(try Data(contentsOf: output) == bytes)
        let preserved = try Data(contentsOf: copy)
        var damaged = try Data(contentsOf: source)
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: source)
        #expect(throws: CryptoError.tampered) {
            try ChunkedCipher.reencrypt(input: source, output: copy, keyEncryptionKey: key, fromContext: "original", toContext: "copy")
        }
        #expect(try Data(contentsOf: copy) == preserved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

}
