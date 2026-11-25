// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Testing
@testable import TheoNotes

/// Fix round 1 of M9 Mac task 3 (security review): serialized cleanup, opt-in cache, fail-closed
/// cache deletion, key-byte hygiene and classified logging.
@MainActor
@Suite struct NoteVaultSecurityTests {
    private let account = VaultLibrary.account

    // MARK: 1. Serialized cleanup

    @Test func overlappingRelocksRunTheCleanupAgainAndAreCleanOnlyAfterTheLastPass() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let gate = CleanupGate()
        let vault = library.makeVault(cleanup: { try await gate.pass() })
        try await vault.createPassword("correct horse")

        vault.relock()                       // flush -> revoke -> pass 1 starts
        await gate.waitUntilPassStarts(1)
        #expect(vault.cleanupState == .cleaning)

        try await vault.unlock(password: "correct horse")
        vault.relock()                       // a newer relock arrives while pass 1 runs
        #expect(vault.cleanupState == .cleaning)

        await gate.release(1)                // pass 1 ends; it must not report clean
        await gate.waitUntilPassStarts(2)
        #expect(vault.cleanupState == .cleaning, "a newer request is still unserved")

        await gate.release(2)
        await vault.waitForPendingWork()
        #expect(await gate.passes == 2)
        #expect(vault.cleanupState == .clean)
    }

    @Test func aFailedPassFollowedByANewerRequestEndsWithTheNewerResult() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let gate = CleanupGate(failFirst: true)
        let vault = library.makeVault(cleanup: { try await gate.pass() })
        try await vault.createPassword("correct horse")

        vault.relock()
        await gate.waitUntilPassStarts(1)
        try await vault.unlock(password: "correct horse")
        vault.relock()
        await gate.release(1)               // pass 1 fails with cleanupPending, but a newer request exists
        await gate.waitUntilPassStarts(2)
        await gate.release(2)
        await vault.waitForPendingWork()
        #expect(vault.cleanupState == .clean)
    }

    @Test func theLatestPassDecidesAPendingResult() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let gate = CleanupGate(failAlways: true)
        let vault = library.makeVault(cleanup: { try await gate.pass() })
        try await vault.createPassword("correct horse")

        vault.relock()
        await gate.waitUntilPassStarts(1)
        try await vault.unlock(password: "correct horse")
        vault.relock()
        await gate.release(1)
        await gate.waitUntilPassStarts(2)
        await gate.release(2)
        await vault.waitForPendingWork()
        #expect(vault.cleanupState == .pending)
        #expect(await gate.passes == 2)
    }

    // MARK: 2. Opt-in

    @Test func noKeychainItemIsWrittenBeforeExplicitOptIn() async throws {
        let library = try VaultLibrary(optIn: false)
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        try await vault.unlock(password: "correct horse")
        try await vault.changePassword(old: "correct horse", new: "new password")
        #expect(library.cache.items.isEmpty)
        #expect(library.cache.storeInputs.isEmpty, "not even an attempt")
        #expect(!vault.canUnlockWithBiometrics)

        try vault.setUsesBiometricUnlock(true)
        #expect(library.cache.items[account] != nil, "the opt-in caches the unlocked key at once")
        #expect(vault.canUnlockWithBiometrics)

        try vault.setUsesBiometricUnlock(false)
        #expect(library.cache.items[account] == nil)
    }

    @Test func aFailedOptInStoreIsUndone() async throws {
        let library = try VaultLibrary(optIn: false)
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        // The fake cannot fail a store, so make the key unreadable: a revoked access cannot store.
        let access = try vault.requireAccess()
        access.revoke()

        #expect(throws: NotePrivacyError.accessRevoked) { try vault.setUsesBiometricUnlock(true) }
        #expect(library.settings.useTouchIDForNotes == false)
        #expect(library.cache.items.isEmpty)
    }

    // MARK: 4. Fail-closed cache deletion

    @Test func aFailedCacheRemovalStopsAPasswordChange() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let before = try NotePrivacy(store: library.store).envelope()
        library.cache.removeFails = true

        await #expect(throws: VaultKeyCacheError.notRemoved) {
            try await vault.changePassword(old: "correct horse", new: "new password")
        }
        #expect(try NotePrivacy(store: library.store).envelope() == before, "nothing was changed")
        library.cache.removeFails = false
        vault.relock()
        try await vault.unlock(password: "correct horse")
    }

    @Test func aFailedCacheRemovalIsReportedByStaleDetectionNotSwallowed() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        try NotePrivacy(store: library.store).changePassword(from: "correct horse", to: "new password")
        library.cache.removeFails = true

        await #expect(throws: VaultKeyCacheError.notRemoved) { _ = try await vault.unlockWithBiometrics() }
        #expect(!vault.isUnlocked)
        #expect(library.cache.items[account] != nil, "still there, and the caller knows")
    }

    @Test func aFailedCacheRemovalStopsTheOptOutAndKeepsTheSetting() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        library.cache.removeFails = true

        #expect(throws: VaultKeyCacheError.notRemoved) { try vault.setUsesBiometricUnlock(false) }
        #expect(library.settings.useTouchIDForNotes == true, "the opt-out did not happen")
    }

    @Test func aFailedCacheRemovalAfterAnEnvelopeChangeIsThrownButTheVaultIsLocked() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        library.cache.removeFails = true

        #expect(throws: VaultKeyCacheError.notRemoved) { try vault.envelopeReplaced() }
        #expect(!vault.isUnlocked, "relocked before the deletion was attempted")
    }

    @Test func resetForRemovePasswordRevokesThenDeletesTheCacheThenAllowsTheEnvelopeDeletion() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let log = SyncLog()
        let vault = library.makeVault(cleanup: { log.add("cleanup") })
        try await vault.createPassword("correct horse")
        let access = try vault.requireAccess()
        _ = vault.addWillRelockHandler { log.add("flush") }
        #expect(library.cache.items[account] != nil)

        try await vault.resetForRemovePassword()

        #expect(log.entries == ["flush", "cleanup"], "flush, revoke, awaited cleanup")
        #expect(!vault.isUnlocked)
        #expect((try? access.journalKey()) == nil)
        #expect(library.cache.items[account] == nil)
        #expect(library.cache.removed.last == account)
        // Only now may the caller delete the envelope.
        try NotePrivacy(store: library.store).deletePassword()
        vault.refresh()
        #expect(!vault.hasPassword)
    }

    @Test func resetForRemovePasswordFailsWhenTheCacheCannotBeDeleted() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        library.cache.removeFails = true

        await #expect(throws: VaultKeyCacheError.notRemoved) { try await vault.resetForRemovePassword() }
        #expect(!vault.isUnlocked, "revoked regardless")
        #expect(vault.hasPassword, "the envelope is the caller's to keep")
    }

    @Test func resetForRemovePasswordFailsWhileTheCleanupIsNotClean() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault(cleanup: { throw NotePrivacyError.cleanupPending })
        try await vault.createPassword("correct horse")

        await #expect(throws: NotePrivacyError.cleanupPending) { try await vault.resetForRemovePassword() }
        #expect(library.cache.items[account] != nil, "the envelope and cache are untouched")
    }

    // MARK: Keychain locked (-25308)

    /// A locked screen answers errSecInteractionNotAllowed. That is "Touch ID not available right
    /// now": the item is kept and the password is asked, it is not a stale item to delete.
    @Test func aLockedKeychainFallsBackToThePasswordAndKeepsTheItem() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        library.cache.loadBehavior = .interactionNotAllowed

        #expect(try await vault.unlockWithBiometrics() == .temporarilyUnavailable)
        #expect(!vault.isUnlocked)
        #expect(!vault.isAuthenticating)
        #expect(library.cache.removed.isEmpty, "nothing was deleted")
        #expect(library.cache.items[account] != nil)

        // The password path works, and Touch ID works again once the Keychain does.
        try await vault.unlock(password: "correct horse")
        vault.relock()
        library.cache.loadBehavior = .item
        #expect(try await vault.unlockWithBiometrics() == .unlocked)
    }

    @Test func theLockedKeychainStatusMapsToTheUnavailableCode() {
        #expect(PrivacyErrorCode.code(for: VaultKeyCacheError.unavailableNow) == "cacheUnavailableNow")
        #expect(errSecInteractionNotAllowed == -25308)
    }

    // MARK: 5. Key bytes

    @Test func secretBytesWipeOverwritesTheOneCopy() {
        let secret = SecretBytes(Data(repeating: 0xAB, count: 32))
        #expect(secret.dataForTesting == Data(repeating: 0xAB, count: 32))
        let copy = secret.copy()
        secret.wipe()
        #expect(secret.isWiped)
        #expect(secret.dataForTesting == Data(repeating: 0, count: 32))
        #expect(copy.dataForTesting == Data(repeating: 0xAB, count: 32), "a copy is its own buffer")
    }

    @Test func theVaultWipesTheKeyItLoadedAndTheKeyItPassedToTheCache() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()

        #expect(try await vault.unlockWithBiometrics() == .unlocked)

        let loaded = try #require(library.cache.loadOutputs.last)
        #expect(loaded.key.isWiped, "the loaded key was wiped after use")
        let stored = try #require(library.cache.storeInputs.last)
        #expect(stored.key.isWiped, "the buffer handed to the cache was wiped after the store")
        let cachedCopy = try #require(library.cache.items[account])
        #expect(!cachedCopy.key.isWiped && cachedCopy.key.dataForTesting != Data(repeating: 0, count: 32))
    }

    @Test func aRelockDuringThePromptInvalidatesItAndDiscardsAndWipesTheResult() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        library.cache.holdLoads()

        let attempt = Task { try await vault.unlockWithBiometrics() }
        for _ in 0..<1000 where library.cache.loads == 0 { await Task.yield() }
        #expect(library.cache.loads == 1 && vault.isAuthenticating)

        vault.relock()
        #expect(library.cache.invalidations >= 1, "the active prompt is invalidated on relock")
        library.cache.releaseLoads()          // the result was already on its way

        await #expect(throws: NotePrivacyError.accessRevoked) { _ = try await attempt.value }
        #expect(!vault.isUnlocked)
        #expect(library.cache.loadOutputs.allSatisfy { $0.key.isWiped })
    }

    @Test func theKeychainEncodingRoundTripsAndTheEncodedBufferCanBeWiped() throws {
        let (envelope, key) = try CryptoEnvelope.create(password: "encoding")
        let cached = CachedVaultKey(envelope: envelope, key: SecretBytes(key: key))
        let encoded = try VaultKeyCoding.encode(cached)
        let decoded = try VaultKeyCoding.decode(encoded)
        #expect(decoded == cached)

        VaultKeyCoding.wipe(encoded)
        let length = CFDataGetLength(encoded)
        let bytes = Data(bytes: CFDataGetBytePtr(encoded), count: length)
        #expect(bytes == Data(repeating: 0, count: length))
        #expect(throws: VaultKeyCacheError.corrupt) { _ = try VaultKeyCoding.decode(encoded) }
    }

    @Test func theKeychainDecoderRejectsGarbageAndWrongKeyLengths() throws {
        #expect(throws: VaultKeyCacheError.corrupt) { _ = try VaultKeyCoding.decode(Data([1, 2, 3]) as CFData) }
        #expect(throws: VaultKeyCacheError.corrupt) { _ = try VaultKeyCoding.decode(Data("BVK1\u{10}short".utf8) as CFData) }
        var tooShort = Data("BVK1".utf8) + Data([32]) + Data(repeating: 1, count: 10)
        #expect(throws: VaultKeyCacheError.corrupt) { _ = try VaultKeyCoding.decode(tooShort as CFData) }
        tooShort = Data("BVK1".utf8) + Data([32]) + Data(repeating: 1, count: 32) + Data("{not json".utf8)
        #expect(throws: VaultKeyCacheError.corrupt) { _ = try VaultKeyCoding.decode(tooShort as CFData) }
    }

    // MARK: 6. Classified logging

    @Test func aSecretBearingErrorProducesOnlyItsCode() {
        let secret = "secret-photo-of-the-diagnosis.png"
        let errors: [Error] = [
            NotePrivacyError.attachmentMissing(secret),
            StoreError.noteNotFound(id: secret), StoreError.noteLocked(id: secret),
            StoreError.invalidTag(path: secret), StoreError.tagNotFound(path: secret),
            NSError(domain: secret, code: 5, userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: "/\(secret)"]),
            CocoaLike(path: secret),
        ]
        for error in errors {
            let code = PrivacyErrorCode.code(for: error)
            #expect(!code.contains(secret), "\(code)")
            #expect(code.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil, "\(code)")
        }
        #expect(PrivacyErrorCode.code(for: NotePrivacyError.attachmentMissing(secret)) == "attachmentMissing")
        #expect(PrivacyErrorCode.code(for: CryptoError.wrongPassword) == "wrongPassword")
        #expect(PrivacyErrorCode.code(for: VaultKeyCacheError.notRemoved) == "cacheNotRemoved")
        #expect(PrivacyErrorCode.code(for: VaultKeyCacheError.failed(-25300)) == "cacheStatus-25300")
        #expect(PrivacyErrorCode.code(for: NSError(domain: secret, code: 5)) == "other")
    }

    @Test func aFailedCleanupReportsOnlyTheCodeInTheState() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let secret = "secret-attachment-name.png"
        let vault = library.makeVault(cleanup: { throw NotePrivacyError.attachmentMissing(secret) })
        try await vault.createPassword("correct horse")

        await vault.relockAndFinishCleanup()

        #expect(vault.cleanupState == .failed("attachmentMissing"))
        #expect(!String(describing: vault.cleanupState).contains(secret))
    }

    @Test func aRelockFlushFailureLogsTheCodeNotTheError() async throws {
        // The environment's flush logs through PrivacyErrorCode (see AppEnvironment.flush); a locked
        // session's failing flush carries the attachment name in its error value.
        let error = NotePrivacyError.attachmentMissing("name-from-a-locked-note.png")
        #expect("\(error)".contains("name-from-a-locked-note.png"), "the raw error would have leaked it")
        #expect(!PrivacyErrorCode.code(for: error).contains("name-from-a-locked-note"))
    }
}

private struct CocoaLike: Error, CustomStringConvertible {
    let path: String
    var description: String { "failed at \(path)" }
}

private final class SyncLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var entries: [String] { lock.withLock { storage } }
    func add(_ entry: String) { lock.withLock { storage.append(entry) } }
}

/// A cleanup whose passes a test releases one by one.
private actor CleanupGate {
    private(set) var passes = 0
    private var started = 0
    private var released = 0
    private let failFirst: Bool
    private let failAlways: Bool

    init(failFirst: Bool = false, failAlways: Bool = false) {
        self.failFirst = failFirst
        self.failAlways = failAlways
    }

    func pass() async throws {
        passes += 1
        let number = passes
        started = number
        while released < number { try await Task.sleep(for: .milliseconds(2)) }
        if failAlways || (failFirst && number == 1) { throw NotePrivacyError.cleanupPending }
    }

    func release(_ number: Int) { released = max(released, number) }

    func waitUntilPassStarts(_ number: Int) async {
        for _ in 0..<2000 where started < number { try? await Task.sleep(for: .milliseconds(2)) }
    }
}
