// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
@testable import TheoNotesCore

private let fastIterations = 1_000
private let ctx = "note-1"

private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

@Suite("CryptoEnvelope")
struct CryptoEnvelopeTests {
    @Test func defaultsMatchSpec() throws {
        #expect(CryptoEnvelope.defaultIterations == 600_000)
        let (envelope, _) = try CryptoEnvelope.create(password: "pw", iterations: fastIterations)
        #expect(envelope.version == 1)
        #expect(envelope.kdf == "pbkdf2-sha256")
        #expect(envelope.salt.count == 16)
        #expect(envelope.iterations == fastIterations)
    }

    @Test func publicCreateUses600kIterations() throws {
        // Slow (~0.3 s); only asserts the persisted parameter.
        let (envelope, _) = try CryptoEnvelope.create(password: "pw")
        #expect(envelope.iterations == 600_000)
    }

    @Test func roundTrip() throws {
        let (envelope, vaultKey) = try CryptoEnvelope.create(password: "correct horse", iterations: fastIterations)
        let unwrapped = try envelope.unwrap(password: "correct horse", allowedIterations: 1...10_000_000)
        #expect(bytes(unwrapped) == bytes(vaultKey))
    }

    @Test func wrongPasswordThrows() throws {
        let (envelope, _) = try CryptoEnvelope.create(password: "right", iterations: fastIterations)
        #expect(throws: CryptoError.wrongPassword) { try envelope.unwrap(password: "wrong", allowedIterations: 1...10_000_000) }
    }

    @Test func rewrapKeepsVaultKey() throws {
        let (envelope, vaultKey) = try CryptoEnvelope.create(password: "old", iterations: fastIterations)
        let rewrapped = try envelope.rewrapped(oldPassword: "old", newPassword: "new", iterations: fastIterations)
        #expect(rewrapped.salt != envelope.salt)
        #expect(bytes(try rewrapped.unwrap(password: "new", allowedIterations: 1...10_000_000)) == bytes(vaultKey))
        #expect(throws: CryptoError.wrongPassword) { try rewrapped.unwrap(password: "old", allowedIterations: 1...10_000_000) }
        #expect(throws: CryptoError.wrongPassword) {
            try envelope.rewrapped(oldPassword: "nope", newPassword: "new", iterations: fastIterations)
        }
    }

    @Test func hostileParametersAreMalformed() throws {
        let (envelope, _) = try CryptoEnvelope.create(password: "pw", iterations: fastIterations)
        // Below the public floor (tests use a 1_000 envelope)
        #expect(throws: CryptoError.malformed) { try envelope.unwrap(password: "pw") }
        var huge = envelope
        huge.iterations = Int(UInt32.max) + 1
        #expect(throws: CryptoError.malformed) { try huge.unwrap(password: "pw") }
        huge.iterations = Int.max
        #expect(throws: CryptoError.malformed) { try huge.unwrap(password: "pw") }
        var shortSalt = envelope
        shortSalt.salt = Data(count: 8)
        #expect(throws: CryptoError.malformed) {
            try shortSalt.unwrap(password: "pw", allowedIterations: 1...10_000_000)
        }
    }

    @Test func emptyPasswordRejected() throws {
        #expect(throws: CryptoError.emptyPassword) { try CryptoEnvelope.create(password: "", iterations: fastIterations) }
        let (envelope, _) = try CryptoEnvelope.create(password: "pw", iterations: fastIterations)
        #expect(throws: CryptoError.emptyPassword) {
            try envelope.rewrapped(oldPassword: "pw", newPassword: "", iterations: fastIterations)
        }
    }

    @Test func envelopeJSONRoundTrip() throws {
        let (envelope, vaultKey) = try CryptoEnvelope.create(password: "pw", iterations: fastIterations)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(CryptoEnvelope.self, from: data)
        #expect(decoded == envelope)
        #expect(bytes(try decoded.unwrap(password: "pw", allowedIterations: 1...10_000_000)) == bytes(vaultKey))
    }

    @Test func unicodePasswordIsNormalized() throws {
        let (envelope, vaultKey) = try CryptoEnvelope.create(password: "caf\u{E9}", iterations: fastIterations)
        let decomposed = "cafe\u{301}"
        #expect(bytes(try envelope.unwrap(password: decomposed, allowedIterations: 1...10_000_000)) == bytes(vaultKey))
    }
}

@Suite("NoteCipher")
struct NoteCipherTests {
    @Test func sealOpenRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("secret note 👩‍👩‍👧 漢字".utf8)
        let sealed = try NoteCipher.seal(plaintext, vaultKey: key, context: ctx)
        #expect(sealed.prefix(4) == Data("BNC1".utf8))
        #expect(sealed.count == 4 + 60 + 12 + plaintext.count + 16)
        #expect(try NoteCipher.open(sealed, vaultKey: key, context: ctx) == plaintext)
    }

    @Test func sealsAreRandomized() throws {
        let key = SymmetricKey(size: .bits256)
        let a = try NoteCipher.seal(Data("x".utf8), vaultKey: key, context: ctx)
        let b = try NoteCipher.seal(Data("x".utf8), vaultKey: key, context: ctx)
        #expect(a != b)
    }

    @Test func emptyPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try NoteCipher.seal(Data(), vaultKey: key, context: ctx)
        #expect(try NoteCipher.open(sealed, vaultKey: key, context: ctx) == Data())
    }

    @Test func wrongKeyAndTamperingFail() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try NoteCipher.seal(Data("hello".utf8), vaultKey: key, context: ctx)
        #expect(throws: CryptoError.tampered) { try NoteCipher.open(sealed, vaultKey: SymmetricKey(size: .bits256), context: ctx) }
        var flipped = sealed
        flipped[flipped.count - 1] ^= 0x01
        #expect(throws: CryptoError.tampered) { try NoteCipher.open(flipped, vaultKey: key, context: ctx) }
        var badMagic = sealed
        badMagic[0] = 0
        #expect(throws: CryptoError.malformed) { try NoteCipher.open(badMagic, vaultKey: key, context: ctx) }
        #expect(throws: CryptoError.malformed) { try NoteCipher.open(sealed.prefix(10), vaultKey: key, context: ctx) }
    }

    @Test func swappedContextIsTampered() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try NoteCipher.seal(Data("a".utf8), vaultKey: key, context: "note-1")
        #expect(throws: CryptoError.tampered) { try NoteCipher.open(sealed, vaultKey: key, context: "note-2") }
    }
}
