// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Local convenience only: the portable password envelope remains the source of recovery.
/// This cache is invalidated by biometric enrollment changes and never migrates to another device.
enum MobileBiometricKeychain {
    struct CachedKey: Codable, Sendable {
        let envelope: CryptoEnvelope
        let key: Data
    }
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Biometric unlock is unavailable." }
    }
    static let service = MobileIdentity.noteVaultKeychainService

    static func label() -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.biometryType == .faceID ? "Face ID" : "Touch ID"
    }

    static func store(_ cached: CachedKey, account: String) throws {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                          .biometryCurrentSet, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw Failure(status: errSecParam)
        }
        try remove(account: account)
        var query = base(account)
        query[kSecAttrAccessControl as String] = control
        query[kSecValueData as String] = try JSONEncoder().encode(cached)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func read(account: String) throws -> CachedKey {
        let context = LAContext()
        context.localizedReason = "Unlock your protected notes"
        context.localizedFallbackTitle = ""
        var query = base(account)
        query[kSecUseAuthenticationContext as String] = context
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data else { throw Failure(status: errSecDecode) }
        let cached = try JSONDecoder().decode(CachedKey.self, from: data)
        guard cached.key.count == 32 else { throw Failure(status: errSecDecode) }
        return cached
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
