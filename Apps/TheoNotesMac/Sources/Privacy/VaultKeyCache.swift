// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Secret bytes in memory we own: allocated outside Swift's copy-on-write storage so that
/// `wipe()` really overwrites the one copy (`memset_s` is not optimized away). Wiped on `deinit`.
/// Limits (M9M-R19): CryptoKit's `SymmetricKey` keeps its own copy, and bytes the Keychain
/// hands back in an immutable `CFData` cannot be scrubbed by us.
final class SecretBytes: @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer
    let count: Int
    private let lock = NSLock()
    private var wiped = false

    var isWiped: Bool { lock.withLock { wiped } }

    init(copying bytes: UnsafeRawBufferPointer) {
        count = bytes.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 16)
        if let base = bytes.baseAddress, bytes.count > 0 { buffer.copyMemory(from: base, byteCount: bytes.count) }
        pointer = buffer
    }

    init(_ data: Data) {
        count = data.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        data.withUnsafeBytes { if let base = $0.baseAddress, $0.count > 0 { buffer.copyMemory(from: base, byteCount: $0.count) } }
        pointer = buffer
    }

    init(key: SymmetricKey) {
        let size = key.bitCount / 8
        count = size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
        key.withUnsafeBytes { if let base = $0.baseAddress, $0.count > 0 { buffer.copyMemory(from: base, byteCount: min($0.count, size)) } }
        pointer = buffer
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try lock.withLock { try body(UnsafeRawBufferPointer(start: pointer, count: count)) }
    }

    func symmetricKey() -> SymmetricKey { withUnsafeBytes { SymmetricKey(data: $0) } }

    /// A second independent buffer (a cache that must outlive the caller's wipe).
    func copy() -> SecretBytes { withUnsafeBytes { SecretBytes(copying: $0) } }

    func wipe() {
        lock.withLock {
            _ = memset_s(pointer, count, 0, count)
            wiped = true
        }
    }

    deinit {
        _ = memset_s(pointer, count, 0, count)
        pointer.deallocate()
    }

    static func == (lhs: SecretBytes, rhs: SecretBytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { a in rhs.withUnsafeBytes { b in a.elementsEqual(b) } }
    }
}

/// What the Keychain holds for one library: the unwrapped vault key and the envelope it came
/// from. The envelope is the freshness check: `NotePrivacy.restoreAccess` refuses a key whose
/// envelope is no longer the library's (password changed, library replaced).
struct CachedVaultKey: Sendable, Equatable {
    let envelope: CryptoEnvelope
    let key: SecretBytes

    init(envelope: CryptoEnvelope, key: SecretBytes) {
        self.envelope = envelope
        self.key = key
    }

    static func == (lhs: CachedVaultKey, rhs: CachedVaultKey) -> Bool {
        lhs.envelope == rhs.envelope && lhs.key == rhs.key
    }

    func copy() -> CachedVaultKey { CachedVaultKey(envelope: envelope, key: key.copy()) }
}

/// The item's bytes: `BVK1` | key length (1 byte) | key | envelope JSON (public data). Built in
/// one mutable `CFData` that is wiped after the Keychain took its copy, so the key never passes
/// through a `JSONEncoder` or a `Data` we cannot scrub.
enum VaultKeyCoding {
    static let magic = Array("BVK1".utf8)

    static func encode(_ cached: CachedVaultKey) throws -> CFMutableData {
        let envelope = try JSONEncoder().encode(cached.envelope)
        let total = magic.count + 1 + cached.key.count + envelope.count
        guard cached.key.count == 32, let data = CFDataCreateMutable(nil, total) else {
            throw VaultKeyCacheError.corrupt
        }
        CFDataSetLength(data, total)
        let out = UnsafeMutableRawBufferPointer(start: CFDataGetMutableBytePtr(data), count: total)
        var offset = 0
        for byte in magic { out[offset] = byte; offset += 1 }
        out[offset] = UInt8(cached.key.count); offset += 1
        cached.key.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: out[offset..<offset + $0.count]).copyMemory(from: $0) }
        offset += cached.key.count
        envelope.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: out[offset...]).copyMemory(from: $0) }
        return data
    }

    static func wipe(_ data: CFMutableData) {
        _ = memset_s(CFDataGetMutableBytePtr(data), CFDataGetLength(data), 0, CFDataGetLength(data))
    }

    static func decode(_ data: CFData) throws -> CachedVaultKey {
        let length = CFDataGetLength(data)
        guard let base = CFDataGetBytePtr(data), length > magic.count + 1 else { throw VaultKeyCacheError.corrupt }
        let bytes = UnsafeBufferPointer(start: base, count: length)
        guard Array(bytes.prefix(magic.count)) == magic, bytes[magic.count] == 32,
              length > magic.count + 1 + 32 else { throw VaultKeyCacheError.corrupt }
        let keyStart = magic.count + 1
        let key = SecretBytes(copying: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[keyStart..<keyStart + 32]))
        let envelopeJSON = Data(bytes[(keyStart + 32)...])
        guard let envelope = try? JSONDecoder().decode(CryptoEnvelope.self, from: envelopeJSON) else {
            key.wipe()
            throw VaultKeyCacheError.corrupt
        }
        return CachedVaultKey(envelope: envelope, key: key)
    }
}

/// LAContext is thread-safe for what we do with it (reading by the Keychain, `invalidate()`).
private struct ContextBox: @unchecked Sendable {
    let context: LAContext?
    init(_ context: LAContext?) { self.context = context }
}

enum VaultKeyCacheError: Error, Equatable, Sendable {
    /// The user dismissed the prompt or failed the biometric check. The item stays.
    case cancelled
    /// The item exists but cannot be decoded.
    case corrupt
    /// The Keychain cannot be used right now (`errSecInteractionNotAllowed`, -25308): the Mac or
    /// its screen is locked, or no UI may be shown. The item is fine; ask for the password instead.
    case unavailableNow
    /// Deleting the item failed, or it was still there when read back (M9M-R18).
    case notRemoved
    case failed(OSStatus)
}

/// A device-local, authenticated cache of the vault key (M9M-R4). Never synced, never backed up.
protocol VaultKeyCache: Sendable {
    /// Whether a new item can be protected as designed (biometry enrolled).
    var isAvailable: Bool { get }
    /// Replaces any item for `account`. The cache must not keep `cached`: the caller wipes it.
    func store(_ cached: CachedVaultKey, account: String) throws
    /// An item exists. Never prompts.
    func contains(account: String) -> Bool
    /// nil: no item. Prompts for the biometric check, off the calling actor. The caller wipes
    /// the returned key after use.
    func load(account: String, reason: String) async throws -> CachedVaultKey?
    /// Deletes the item and reads back that it is gone; throws `notRemoved` otherwise.
    func remove(account: String) throws
    /// Cancels any prompt that is still up (relock): its result is then never produced.
    func invalidatePendingPrompts()
}

/// Generic-password item in the data-protection keychain, protected by `.biometryCurrentSet` and
/// `WhenPasscodeSetThisDeviceOnly`: adding or removing a fingerprint invalidates it, and it never
/// leaves this Mac. `requiresBiometry: false` exists for tests that run without enrolled biometry.
final class KeychainVaultKeyCache: VaultKeyCache, @unchecked Sendable {
    static let defaultService = AppIdentity.vaultKeychainService
    static var protection: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    static let flags: SecAccessControlCreateFlags = .biometryCurrentSet

    let service: String
    let requiresBiometry: Bool
    private let lock = NSLock()
    private var activeContexts: [ObjectIdentifier: LAContext] = [:]

    init(service: String = defaultService, requiresBiometry: Bool = true) {
        self.service = service
        self.requiresBiometry = requiresBiometry
    }

    var isAvailable: Bool {
        guard requiresBiometry else { return true }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, protection, flags, &error) else {
            throw error?.takeRetainedValue() ?? VaultKeyCacheError.failed(errSecParam)
        }
        return control
    }

    static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// Pure, so tests can inspect it. `access` nil means an item without biometry (tests only).
    static func addQuery(service: String, account: String, data: CFData, access: SecAccessControl?) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        if let access {
            query[kSecAttrAccessControl as String] = access
        } else {
            // Test-only item (no biometry). "AfterFirstUnlock", not "WhenUnlocked": the latter answers
            // errSecInteractionNotAllowed (-25308) whenever the screen is locked, so a test run on a
            // locked Mac failed for a reason that has nothing to do with the code under test.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return query
    }

    static func readQuery(service: String, account: String, context: LAContext?) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        if let context { query[kSecUseAuthenticationContext as String] = context }
        return query
    }

    func store(_ cached: CachedVaultKey, account: String) throws {
        try remove(account: account)
        let access = requiresBiometry ? try Self.makeAccessControl() : nil
        let encoded = try VaultKeyCoding.encode(cached)
        defer { VaultKeyCoding.wipe(encoded) }
        let query = Self.addQuery(service: service, account: account, data: encoded, access: access)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultKeyCacheError.failed(status) }
    }

    func contains(account: String) -> Bool {
        // Attributes only and no interaction: an item behind biometry answers without a prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func load(account: String, reason: String) async throws -> CachedVaultKey? {
        let service = service, requiresBiometry = requiresBiometry
        let context = requiresBiometry ? LAContext() : nil
        context?.localizedReason = reason
        context?.localizedFallbackTitle = ""
        if let context { lock.withLock { activeContexts[ObjectIdentifier(context)] = context } }
        defer { if let context { lock.withLock { activeContexts[ObjectIdentifier(context)] = nil } } }
        let box = ContextBox(context)
        return try await Task.detached(priority: .userInitiated) {
            let query = Self.readQuery(service: service, account: account, context: box.context)
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let result, CFGetTypeID(result) == CFDataGetTypeID() else { throw VaultKeyCacheError.corrupt }
                return try VaultKeyCoding.decode(result as! CFData)
            case errSecItemNotFound: return nil
            default: throw Self.loadError(forStatus: status)
            }
        }.value
    }

    /// How a failed read is classified (pure, so tests pin it).
    static func loadError(forStatus status: OSStatus) -> VaultKeyCacheError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: .cancelled
        case errSecInteractionNotAllowed: .unavailableNow
        default: .failed(status)
        }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultKeyCacheError.notRemoved }
        // Read back (attributes only, no prompt): anything but "not found" means it is still there.
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context
        guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else {
            throw VaultKeyCacheError.notRemoved
        }
    }

    func invalidatePendingPrompts() {
        let contexts = lock.withLock { Array(activeContexts.values) }
        for context in contexts { context.invalidate() }
    }
}
