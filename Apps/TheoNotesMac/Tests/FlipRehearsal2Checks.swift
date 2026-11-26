// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import LocalAuthentication
import Security
import Testing

@testable import TheoNotes

/// Rehearsal 2 of the identity and team cutover (stage-2 plan B6, R62). It runs inside the dev build that is
/// signed by the new team and answers, with counts and booleans only, what rehearsal 1 could not: the signed access
/// groups, the App Group container under the new team prefix with the share drain on it, and the empty vault key cache
/// in the new keychain group. `scripts/rehearse-team-signed-dev.sh` passes the output path as a `TEST_RUNNER_` variable;
/// without it the test is skipped. No Touch ID: the cache is read without any authentication context that could prompt,
/// and the one item it writes is a no-biometry throw-away account that it removes again.
@MainActor
@Suite struct FlipRehearsal2Checks {
    private nonisolated static let output = ProcessInfo.processInfo.environment["THEONOTES_REHEARSAL2_OUT"]

    @Test(.enabled(if: output != nil, "set by scripts/rehearse-team-signed-dev.sh"))
    func test_new_team_signature_group_container_and_empty_vault_cache() async throws {
        let out = URL(fileURLWithPath: try #require(Self.output))
        var result: [String: Any] = [:]

        // 1. What the host was really signed with.
        let team = HostEntitlements.value("com.apple.developer.team-identifier") as? String
        result["teamIdentifier"] = team ?? "none"
        result["applicationIdentifier"] = (HostEntitlements.value("com.apple.application-identifier") as? String) ?? "none"
        result["keychainGroups"] = (HostEntitlements.value("keychain-access-groups") as? [String]) ?? []
        result["appGroups"] = (HostEntitlements.value("com.apple.security.application-groups") as? [String]) ?? []
        result["identityIsDev"] = AppIdentity.current == .dev
        result["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? "none"
        result["accessGroupIsNewTeam"] = (result["keychainGroups"] as? [String]) == [AppIdentity.current.keychainAccessGroup]
        result["appGroupIsNewTeam"] = (result["appGroups"] as? [String]) == [AppIdentity.current.appGroupIdentifier]

        // 2. The App Group container of the new team prefix: created on first use, then the share drain runs on it.
        let group = AppEnvironment.shareGroupIdentifier
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(group)", isDirectory: true)
        result["appGroup"] = group
        result["containerExistedBefore"] = FileManager.default.fileExists(atPath: folder.path)
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        result["containerResolved"] = container != nil
        if let container {
            result["containerIsInGroupFolder"] = container.standardizedFileURL.path == folder.standardizedFileURL.path
            let env = try ShareInboxDrainTests.Env(container: container)
            let id = UUID().uuidString.lowercased()
            try env.inbox.enqueue(CaptureRequest(itemId: id, mode: .save, text: "rehearsal 2 share item"), files: [])
            result["inboxHoldsTheItem"] = (try? FileManager.default.contentsOfDirectory(atPath: env.inbox.directory.path))?.isEmpty == false
            let drained = env.environment.drainShareInbox()
            result["drainedItems"] = drained.count
            result["noteArrived"] = (try env.store.note(id: id)) != nil
            result["inboxEmptyAfterDrain"] = (try FileManager.default.contentsOfDirectory(atPath: env.inbox.directory.path)).isEmpty
            result["containerWritable"] = FileManager.default.isWritableFile(atPath: container.path)
        }

        // 3. The vault key cache of the new keychain group: nothing under the service (no item, no prompt) ...
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = KeychainVaultKeyCache.baseQuery(service: AppIdentity.vaultKeychainService, account: "unused")
        query[kSecAttrAccount as String] = nil
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        result["vaultServiceName"] = AppIdentity.vaultKeychainService
        result["vaultItemsInNewGroupStatus"] = Int(status)
        result["vaultCacheEmptyInNewGroup"] = status == errSecItemNotFound
        let realCache = KeychainVaultKeyCache()
        result["absentAccountContains"] = realCache.contains(account: "rehearsal-" + UUID().uuidString)
        result["absentAccountLoadIsNil"] = try await realCache.load(account: "rehearsal-" + UUID().uuidString, reason: "rehearsal") == nil

        // ... and the group is usable: a no-biometry throw-away item under the real service is written, read and removed.
        let probe = KeychainVaultKeyCache(service: AppIdentity.vaultKeychainService, requiresBiometry: false)
        let account = "rehearsal-probe-" + UUID().uuidString
        let (envelope, key) = try CryptoEnvelope.create(password: "rehearsal password")
        let entry = CachedVaultKey(envelope: envelope, key: SecretBytes(key: key))
        try probe.store(entry, account: account)
        result["probeStoredAndFound"] = probe.contains(account: account)
        result["probeRoundTrips"] = try await probe.load(account: account, reason: "rehearsal") == entry
        try probe.remove(account: account)
        result["probeRemoved"] = !probe.contains(account: account)

        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try data.write(to: out)
    }
}
