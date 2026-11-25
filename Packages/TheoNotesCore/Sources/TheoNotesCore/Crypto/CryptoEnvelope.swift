// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: Error, Equatable, Sendable {
    case wrongPassword
    case tampered
    case truncated
    case malformed
    case keyDerivationFailed
    case emptyPassword
}

/// Vault-key envelope. Travels with the data (salt, KDF params, wrapped key) so
/// restored or synced notes stay decryptable with the Note Password alone.
public struct CryptoEnvelope: Codable, Sendable, Equatable {
    public static let defaultIterations = 600_000
    static let kdfName = "pbkdf2-sha256"
    static let aad = Data(ProtocolLabels.envelope.utf8)
    static let publicIterationRange = 100_000...10_000_000
    static let testIterationRange = 1...10_000_000

    public var version: Int
    public var kdf: String
    public var salt: Data
    public var iterations: Int
    public var wrappedVaultKey: Data

    public static func create(password: String) throws -> (CryptoEnvelope, SymmetricKey) {
        try create(password: password, iterations: defaultIterations)
    }

    /// `iterations` is internal so tests can run with a cheap KDF.
    static func create(password: String, iterations: Int) throws -> (CryptoEnvelope, SymmetricKey) {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }
        guard testIterationRange.contains(iterations) else { throw CryptoError.malformed }
        let vaultKey = SymmetricKey(size: .bits256)
        let envelope = try wrap(vaultKey, password: password, iterations: iterations)
        return (envelope, vaultKey)
    }

    public func unwrap(password: String) throws -> SymmetricKey {
        try unwrap(password: password, allowedIterations: Self.publicIterationRange)
    }

    func unwrap(password: String, allowedIterations: ClosedRange<Int>) throws -> SymmetricKey {
        guard version == 1, kdf == Self.kdfName, salt.count == 16,
              allowedIterations.contains(iterations), UInt32(exactly: iterations) != nil
        else { throw CryptoError.malformed }
        let kdfKey = try Self.deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: wrappedVaultKey)
            let bytes = try AES.GCM.open(box, using: kdfKey, authenticating: Self.aad)
            guard bytes.count == 32 else { throw CryptoError.malformed }
            return SymmetricKey(data: bytes)
        } catch let error as CryptoError {
            throw error
        } catch CryptoKitError.authenticationFailure {
            throw CryptoError.wrongPassword
        } catch {
            throw CryptoError.malformed
        }
    }

    public func rewrapped(oldPassword: String, newPassword: String) throws -> CryptoEnvelope {
        try rewrapped(
            oldPassword: oldPassword, newPassword: newPassword, iterations: Self.defaultIterations,
            allowedIterations: Self.publicIterationRange)
    }

    func rewrapped(
        oldPassword: String, newPassword: String, iterations: Int,
        allowedIterations: ClosedRange<Int> = CryptoEnvelope.testIterationRange
    ) throws -> CryptoEnvelope {
        guard !newPassword.isEmpty else { throw CryptoError.emptyPassword }
        guard Self.testIterationRange.contains(iterations) else { throw CryptoError.malformed }
        let vaultKey = try unwrap(password: oldPassword, allowedIterations: allowedIterations)
        return try Self.wrap(vaultKey, password: newPassword, iterations: iterations)
    }

    private static func wrap(_ vaultKey: SymmetricKey, password: String, iterations: Int) throws -> CryptoEnvelope {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CryptoError.keyDerivationFailed }
        let kdfKey = try deriveKey(password: password, salt: salt, iterations: iterations)
        let keyBytes = vaultKey.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(keyBytes, using: kdfKey, authenticating: aad)
        guard let combined = box.combined else { throw CryptoError.malformed }
        return CryptoEnvelope(
            version: 1, kdf: kdfName, salt: salt, iterations: iterations, wrappedVaultKey: combined)
    }

    /// PBKDF2-HMAC-SHA256, 32-byte output. Password is NFC-normalized so the same
    /// text typed on different input paths derives the same key.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuf in
            passwordBytes.withUnsafeBufferPointer { pwBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(pwBuf.baseAddress ?? UnsafePointer(bitPattern: 1)!).assumingMemoryBound(to: Int8.self),
                    passwordBytes.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

/// Per-note encryption. Format v1: `BNC1` ‖ wrapped note key (60 bytes) ‖ AES-GCM box.
/// AAD = magic ‖ UTF-8(context) (context = note id) so blobs cannot be swapped between notes.
public enum NoteCipher {
    static let magic = Data("BNC1".utf8)
    static let wrappedKeyLength = 60

    private static func aad(_ context: String) -> Data { magic + Data(context.utf8) }

    public static func seal(_ plaintext: Data, vaultKey: SymmetricKey, context: String) throws -> Data {
        let noteKey = SymmetricKey(size: .bits256)
        let noteKeyBytes = noteKey.withUnsafeBytes { Data($0) }
        let aad = aad(context)
        guard let wrapped = try AES.GCM.seal(noteKeyBytes, using: vaultKey, authenticating: aad).combined,
              let body = try AES.GCM.seal(plaintext, using: noteKey, authenticating: aad).combined
        else { throw CryptoError.malformed }
        return magic + wrapped + body
    }

    public static func open(_ sealed: Data, vaultKey: SymmetricKey, context: String) throws -> Data {
        let sealed = Data(sealed)
        guard sealed.count >= magic.count + wrappedKeyLength + 28, sealed.prefix(magic.count) == magic else {
            throw CryptoError.malformed
        }
        let wrapped = sealed[magic.count..<(magic.count + wrappedKeyLength)]
        let body = sealed[(magic.count + wrappedKeyLength)...]
        let aad = aad(context)
        do {
            let noteKeyBytes = try AES.GCM.open(
                AES.GCM.SealedBox(combined: wrapped), using: vaultKey, authenticating: aad)
            guard noteKeyBytes.count == 32 else { throw CryptoError.malformed }
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: body), using: SymmetricKey(data: noteKeyBytes), authenticating: aad)
        } catch let error as CryptoError {
            throw error
        } catch CryptoKitError.authenticationFailure {
            throw CryptoError.tampered
        } catch {
            throw CryptoError.malformed
        }
    }
}
