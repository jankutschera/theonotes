// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import TheoNotes

@MainActor
@Suite struct KeychainVaultKeyCacheTests {
    private func sampleEntry() throws -> CachedVaultKey {
        let (envelope, key) = try CryptoEnvelope.create(password: "sample password")
        return CachedVaultKey(envelope: envelope, key: SecretBytes(key: key))
    }

    @Test func addQueryUsesDataProtectionAndBiometryCurrentSet() throws {
        let control = try KeychainVaultKeyCache.makeAccessControl()
        let query = KeychainVaultKeyCache.addQuery(
            service: "svc", account: "acct", data: Data([1, 2, 3]) as CFData, access: control)

        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false, "never iCloud Keychain")
        #expect((query[kSecValueData as String] as? Data) == Data([1, 2, 3]))
        #expect(query[kSecAttrAccessControl as String] != nil)
        #expect(query[kSecAttrAccessible as String] == nil, "protection lives in the access control")
        // The two values the access control is made of (a SecAccessControl cannot be opened).
        #expect(KeychainVaultKeyCache.flags == .biometryCurrentSet)
        #expect(KeychainVaultKeyCache.protection as String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
    }

    /// The test-only variant must work with a locked screen (the root cause of the -25308 failure
    /// that only showed on a locked Mac); the production item is always the access-control one.
    @Test func addQueryWithoutBiometryUsesThisDeviceOnlyAccessibility() {
        let query = KeychainVaultKeyCache.addQuery(service: "svc", account: "acct", data: Data() as CFData, access: nil)
        #expect(query[kSecAttrAccessControl as String] == nil)
        #expect(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test func readQueryCarriesTheAuthenticationContextAndAsksForOneResult() {
        let context = LAContext()
        let query = KeychainVaultKeyCache.readQuery(service: "svc", account: "acct", context: context)
        #expect(query[kSecUseAuthenticationContext as String] as? LAContext === context)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test func readFailuresAreClassified() {
        #expect(KeychainVaultKeyCache.loadError(forStatus: errSecInteractionNotAllowed) == .unavailableNow)
        #expect(KeychainVaultKeyCache.loadError(forStatus: errSecUserCanceled) == .cancelled)
        #expect(KeychainVaultKeyCache.loadError(forStatus: errSecAuthFailed) == .cancelled)
        #expect(KeychainVaultKeyCache.loadError(forStatus: errSecMissingEntitlement) == .failed(errSecMissingEntitlement))
    }

    /// Runs in the signed app host (like the sync Keychain test): a per-test service name keeps it
    /// away from every real item, and the item is removed at the end.
    @Test(.enabled(if: HostEntitlements.hasKeychainAccessGroup, HostEntitlements.keychainSkipReason))
    func roundTripWithoutBiometry() async throws {
        let cache = KeychainVaultKeyCache(service: "vault-test." + UUID().uuidString, requiresBiometry: false)
        defer { try? cache.remove(account: "acct") }
        let entry = try sampleEntry()

        #expect(cache.contains(account: "acct") == false)
        #expect(try await cache.load(account: "acct", reason: "test") == nil)

        try cache.store(entry, account: "acct")
        #expect(cache.contains(account: "acct"))
        #expect(try await cache.load(account: "acct", reason: "test") == entry)

        let replacement = try sampleEntry()
        try cache.store(replacement, account: "acct")
        #expect(try await cache.load(account: "acct", reason: "test") == replacement, "store replaces")

        try cache.remove(account: "acct")
        #expect(cache.contains(account: "acct") == false)
        #expect(try await cache.load(account: "acct", reason: "test") == nil)
    }
}

/// The real notification names reach the vault as the right events, on injected centers.
@MainActor
@Suite struct SystemVaultLifecycleSourceTests {
    @MainActor private struct Centers {
        let app = NotificationCenter()
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var source: SystemVaultLifecycleSource {
            SystemVaultLifecycleSource(center: app, workspace: workspace, distributed: distributed)
        }
    }

    @Test func notificationsBecomeEvents() async throws {
        let centers = Centers()
        var events: [VaultLifecycleEvent] = []
        let observation = centers.source.observe { events.append($0) }

        centers.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        centers.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        centers.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        centers.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        centers.workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        centers.distributed.post(name: SystemVaultLifecycleSource.screenLockedName, object: nil)
        centers.distributed.post(name: SystemVaultLifecycleSource.screensaverStartedName, object: nil)

        #expect(events == [.appResigned, .appBecameActive, .deviceLocked, .deviceLocked,
                          .deviceLocked, .deviceLocked, .deviceLocked])
        _ = observation
    }

    @Test func releasingTheObservationStopsTheEvents() async throws {
        let centers = Centers()
        var events: [VaultLifecycleEvent] = []
        var observation: (any VaultLifecycleObservation)? = centers.source.observe { events.append($0) }
        observation = nil
        _ = observation
        centers.distributed.post(name: SystemVaultLifecycleSource.screenLockedName, object: nil)
        #expect(events.isEmpty)
    }

    @Test func theScreenLockNamesAreTheSystemsOwn() {
        #expect(SystemVaultLifecycleSource.screenLockedName.rawValue == "com.apple.screenIsLocked")
        #expect(SystemVaultLifecycleSource.screensaverStartedName.rawValue == "com.apple.screensaver.didstart")
    }
}
