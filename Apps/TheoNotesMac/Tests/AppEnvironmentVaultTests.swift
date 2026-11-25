// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// The vault as the app environment owns it (M9M-R16): one per library environment.
@MainActor
@Suite struct AppEnvironmentVaultTests {
    private func makeEnvironment(cache: FakeVaultKeyCache) throws -> (AppEnvironment, ManualLifecycleSource, URL) {
        let root = URL(fileURLWithPath: "/tmp/theo-envvault-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let lifecycle = ManualLifecycleSource()
        let environment = try AppEnvironment(paths: AppPaths(root: root), vaultCache: cache, vaultLifecycle: lifecycle)
        return (environment, lifecycle, root)
    }

    /// The bug the gap analysis names: `unlockNotes(password:)` validated the password and then
    /// revoked the access it had just made, so the vault could never be unlocked.
    @Test func unlockNotesLeavesTheVaultUnlocked() async throws {
        let cache = FakeVaultKeyCache()
        let (environment, _, root) = try makeEnvironment(cache: cache)
        defer { try? FileManager.default.removeItem(at: root) }
        try await environment.vault.createPassword("correct horse")
        environment.vault.relock()
        #expect(!environment.vault.isUnlocked)

        try await environment.unlockNotes(password: "correct horse")
        #expect(environment.vault.isUnlocked)
        let note = try environment.store.create(text: "protected")
        try environment.vault.requireAccess().lock(noteId: note.id)
        #expect(try environment.vault.requireAccess().note(id: note.id)?.text == "protected")

        environment.vault.relock()
        await #expect(throws: CryptoError.wrongPassword) { try await environment.unlockNotes(password: "wrong") }
        #expect(!environment.vault.isUnlocked)
    }

    @Test func eachEnvironmentHasItsOwnVaultAccountDerivedFromItsLibrary() async throws {
        let cacheA = FakeVaultKeyCache(), cacheB = FakeVaultKeyCache()
        let (a, _, rootA) = try makeEnvironment(cache: cacheA)
        let (b, _, rootB) = try makeEnvironment(cache: cacheB)
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        #expect(a.vault !== b.vault)
        #expect(AppEnvironment.vaultAccount(for: a.paths) != AppEnvironment.vaultAccount(for: b.paths))
        #expect(AppEnvironment.vaultAccount(for: a.paths) == AppEnvironment.vaultAccount(for: AppPaths(root: rootA)))
        try a.vault.setUsesBiometricUnlock(true)
        try await a.vault.createPassword("pw a")
        #expect(cacheA.items.count == 1 && cacheB.items.isEmpty)
    }

    @Test func aSyncedPasswordChangeDropsTheCacheAndRelocksTheVault() async throws {
        let cache = FakeVaultKeyCache()
        let (environment, _, root) = try makeEnvironment(cache: cache)
        defer { try? FileManager.default.removeItem(at: root) }
        try environment.vault.setUsesBiometricUnlock(true)
        try await environment.vault.createPassword("correct horse")
        #expect(cache.items.count == 1)
        let privacy = NotePrivacy(store: environment.store)

        _ = try environment.commitSyncedChange {
            try privacy.changePassword(from: "correct horse", to: "changed elsewhere")
            return .applied
        }

        #expect(!environment.vault.isUnlocked)
        #expect(cache.items.isEmpty)
    }

    @Test func aSyncThatLeavesTheEnvelopeAloneKeepsTheVaultUnlocked() async throws {
        let cache = FakeVaultKeyCache()
        let (environment, _, root) = try makeEnvironment(cache: cache)
        defer { try? FileManager.default.removeItem(at: root) }
        try environment.vault.setUsesBiometricUnlock(true)
        try await environment.vault.createPassword("correct horse")

        _ = try environment.commitSyncedChange { .applied }

        #expect(environment.vault.isUnlocked)
        #expect(cache.items.count == 1)
    }

    /// M9M-R17: the first-sync password check proves the password and leaves nothing unlocked
    /// and nothing in the Keychain; only the explicit unlock does.
    @Test func theFirstSyncPasswordCheckLeavesTheVaultLocked() async throws {
        let cache = FakeVaultKeyCache()
        let (environment, _, root) = try makeEnvironment(cache: cache)
        defer { try? FileManager.default.removeItem(at: root) }
        try environment.vault.setUsesBiometricUnlock(true)
        try await environment.vault.createPassword("correct horse")
        environment.vault.relock()
        try cache.remove(account: AppEnvironment.vaultAccount(for: environment.paths))

        try await environment.verifyNotePassword("correct horse")

        #expect(!environment.vault.isUnlocked)
        #expect(cache.items.isEmpty, "the check does not cache a key either")
        await #expect(throws: CryptoError.wrongPassword) { try await environment.verifyNotePassword("wrong") }
        #expect(!environment.vault.isUnlocked)

        try await environment.unlockNotes(password: "correct horse")
        #expect(environment.vault.isUnlocked, "the explicit note-unlock action unlocks")
    }

    @Test func noKeychainItemIsWrittenBeforeAnExplicitOptIn() async throws {
        let cache = FakeVaultKeyCache()
        let (environment, _, root) = try makeEnvironment(cache: cache)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(TheoNotesCore.Settings(db: environment.database).useTouchIDForNotes == false)

        try await environment.vault.createPassword("correct horse")
        environment.vault.relock()
        try await environment.unlockNotes(password: "correct horse")

        #expect(cache.items.isEmpty && cache.storeInputs.isEmpty)
    }
}
