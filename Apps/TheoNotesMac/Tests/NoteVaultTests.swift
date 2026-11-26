// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Testing
@testable import TheoNotes

/// M9M tasks: the vault, its Keychain cache and the relock lifecycle. Every library is temporary
/// and every cache is the in-memory fake: nothing here touches the real Keychain or library.
@MainActor
@Suite struct NoteVaultTests {
    private let account = VaultLibrary.account

    // MARK: unlock and cache

    @Test func createPasswordUnlocksAndCachesWhenAvailable() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        #expect(!vault.hasPassword && !vault.isUnlocked)

        try await vault.createPassword("correct horse")

        #expect(vault.hasPassword && vault.isUnlocked)
        let cached = try #require(library.cache.items[account])
        #expect(cached.envelope == (try NotePrivacy(store: library.store).envelope()))
        #expect(cached.key.count == 32)
        #expect(try vault.requireAccess().journalKey().withUnsafeBytes { Data($0) } == cached.key.dataForTesting)
    }

    @Test func noCacheWhenTouchIDIsOffOrUnavailable() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        library.cache.available = false
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        #expect(library.cache.items.isEmpty)

        vault.relock()
        library.cache.available = true
        library.settings.useTouchIDForNotes = false
        try await vault.unlock(password: "correct horse")
        #expect(library.cache.items.isEmpty, "the opt-out is honoured")
        #expect(!vault.canUnlockWithBiometrics)
    }

    @Test func wrongPasswordStaysLocked() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()

        await #expect(throws: CryptoError.wrongPassword) { try await vault.unlock(password: "battery staple") }
        #expect(!vault.isUnlocked)
        try await vault.unlock(password: "correct horse")
        #expect(vault.isUnlocked)
    }

    @Test func unlockingAnAlreadyUnlockedVaultKeepsTheAccessSessionsHold() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let first = try vault.requireAccess()
        try await vault.unlock(password: "correct horse")
        #expect(try vault.requireAccess() === first)
        #expect(throws: Never.self) { _ = try first.journalKey() }
    }

    @Test func touchIDUnlocksAfterARelaunchAndReadsLockedNotes() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let first = library.makeVault()
        try await first.createPassword("correct horse")
        let note = try library.store.create(text: "# Secret title\n\nsecret body")
        try first.requireAccess().lock(noteId: note.id)

        // A relaunch: a new vault over the same library and the same Keychain.
        let relaunched = library.makeVault()
        #expect(relaunched.hasPassword && !relaunched.isUnlocked)
        #expect(relaunched.canUnlockWithBiometrics)

        #expect(try await relaunched.unlockWithBiometrics() == .unlocked)
        #expect(relaunched.isUnlocked)
        #expect(try relaunched.requireAccess().note(id: note.id)?.text == "# Secret title\n\nsecret body")
    }

    @Test func staleCachedKeyIsDroppedAndPasswordAsked() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let first = library.makeVault()
        try await first.createPassword("correct horse")
        first.relock()
        let staleEnvelope = try #require(library.cache.items[account]).envelope

        // The password is changed behind the cache's back (another process, a synced envelope).
        try NotePrivacy(store: library.store).changePassword(from: "correct horse", to: "new password")
        #expect(try NotePrivacy(store: library.store).envelope() != staleEnvelope)

        let relaunched = library.makeVault()
        #expect(try await relaunched.unlockWithBiometrics() == .staleCacheRemoved)
        #expect(!relaunched.isUnlocked)
        #expect(library.cache.removed.contains(account))
        #expect(library.cache.items[account] == nil)
        #expect(!relaunched.canUnlockWithBiometrics)

        // The password path works and caches the fresh envelope.
        try await relaunched.unlock(password: "new password")
        #expect(relaunched.isUnlocked)
        #expect(library.cache.items[account]?.envelope == (try NotePrivacy(store: library.store).envelope()))
    }

    @Test func aCachedKeyThatOpensNothingIsDropped() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let note = try library.store.create(text: "locked one")
        try vault.requireAccess().lock(noteId: note.id)
        vault.relock()
        // Right envelope, wrong key: restoreAccess must fail on a real note and the item goes.
        let good = try #require(library.cache.items[account])
        try library.cache.store(CachedVaultKey(envelope: good.envelope, key: SecretBytes(Data(repeating: 7, count: 32))), account: account)

        #expect(try await vault.unlockWithBiometrics() == .staleCacheRemoved)
        #expect(!vault.isUnlocked && library.cache.items[account] == nil)
    }

    @Test func aCancelledPromptKeepsTheItemAndStaysLocked() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        library.cache.loadBehavior = .cancel

        #expect(try await vault.unlockWithBiometrics() == .cancelled)
        #expect(!vault.isUnlocked)
        #expect(library.cache.items[account] != nil)
        #expect(!vault.isAuthenticating, "the prompt scope ended")
    }

    @Test func aCorruptItemIsRemoved() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        library.cache.loadBehavior = .corrupt

        #expect(try await vault.unlockWithBiometrics() == .staleCacheRemoved)
        #expect(library.cache.items[account] == nil)
    }

    @Test func biometricUnlockIsUnavailableWithoutPasswordCacheOrOptIn() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        #expect(try await vault.unlockWithBiometrics() == .unavailable, "no password yet")
        try await vault.createPassword("correct horse")
        vault.relock()
        library.settings.useTouchIDForNotes = false
        #expect(try await vault.unlockWithBiometrics() == .unavailable)
        #expect(library.cache.loads == 0, "never prompts when it cannot use the result")
        library.settings.useTouchIDForNotes = true
        try library.cache.remove(account: account)
        #expect(try await vault.unlockWithBiometrics() == .noCachedKey)
    }

    /// (task B3): after the team move the new access group holds no cached key. That is a normal state: no
    /// error, no Keychain prompt, the person types the password once, and the key is cached again for Touch ID.
    @Test func test_absent_cache_asks_for_password_once() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()
        // The cache of the new group is empty.
        try library.cache.remove(account: account)

        #expect(!vault.canUnlockWithBiometrics, "no Touch ID button while nothing is cached")
        #expect(try await vault.unlockWithBiometrics() == .noCachedKey, "absent is an outcome, not a thrown error")
        #expect(library.cache.loads == 0, "nothing to read, so no prompt")
        #expect(!vault.isUnlocked)
        let model = LockedNoteModel(vault: vault, noteId: "note-1", title: "Locked")
        await model.unlockWithTouchID()
        #expect(model.errorMessage == LockedNoteModel.touchIDUnavailableMessage, "the lock view asks for the password inline")
        #expect(library.cache.loads == 0)

        try await vault.unlock(password: "correct horse")
        #expect(vault.isUnlocked)
        let cached = try #require(library.cache.items[account], "the password unlock re-arms the cache")
        #expect(cached.envelope == (try NotePrivacy(store: library.store).envelope()))

        // From now on Touch ID alone unlocks: the password was needed once.
        vault.relock()
        #expect(vault.canUnlockWithBiometrics)
        #expect(try await vault.unlockWithBiometrics() == .unlocked)
        #expect(library.cache.loads == 1)
    }

    // MARK: password change and replacement

    @Test func changingThePasswordInvalidatesTheCacheAndCachesTheNewEnvelope() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let oldEnvelope = try #require(library.cache.items[account]).envelope
        let oldKey = try #require(library.cache.items[account]).key

        try await vault.changePassword(old: "correct horse", new: "new password")

        #expect(library.cache.removed == [account], "the old item was removed first")
        let cached = try #require(library.cache.items[account])
        #expect(cached.envelope != oldEnvelope)
        #expect(cached.envelope == (try NotePrivacy(store: library.store).envelope()))
        #expect(cached.key == oldKey, "a password change re-wraps the vault key, it does not replace it")
        #expect(vault.isUnlocked)
        // The new cache unlocks, the old password no longer does.
        vault.relock()
        #expect(try await vault.unlockWithBiometrics() == .unlocked)
        vault.relock()
        await #expect(throws: CryptoError.wrongPassword) { try await vault.unlock(password: "correct horse") }
    }

    @Test func changingThePasswordWhileLockedLeavesNoCache() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()

        try await vault.changePassword(old: "correct horse", new: "new password")

        #expect(!vault.isUnlocked)
        #expect(library.cache.items[account] == nil)
        try await vault.unlock(password: "new password")
        #expect(library.cache.items[account]?.envelope == (try NotePrivacy(store: library.store).envelope()))
    }

    @Test func aWrongOldPasswordChangesNothing() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let before = library.cache.items[account]

        await #expect(throws: CryptoError.wrongPassword) {
            try await vault.changePassword(old: "nope", new: "new password")
        }
        #expect(library.cache.items[account] == before)
        #expect(vault.isUnlocked)
    }

    @Test func envelopeReplacedRemovesTheCacheAndRelocks() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        var flushed = 0
        _ = vault.addWillRelockHandler { flushed += 1 }

        try vault.envelopeReplaced()

        #expect(flushed == 1)
        #expect(!vault.isUnlocked)
        #expect(library.cache.items[account] == nil)
    }

    @Test func turningTouchIDOffRemovesTheItemAndOnCachesAgainWhileUnlocked() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")

        try vault.setUsesBiometricUnlock(false)
        #expect(library.cache.items[account] == nil)
        #expect(library.settings.useTouchIDForNotes == false)

        try vault.setUsesBiometricUnlock(true)
        #expect(library.cache.items[account] != nil)
    }

    // MARK: relock lifecycle

    @Test func resignRelocksAfterTheDelay() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        library.settings.noteRelockDelay = 300
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")

        library.lifecycle.send(.appResigned)
        await library.clock.waitForSleeper()
        library.clock.advance(by: .seconds(299))
        await Task.yield()
        #expect(vault.isUnlocked, "still unlocked at 299 s")

        library.clock.advance(by: .seconds(1))
        await vault.waitForPendingWork()
        #expect(!vault.isUnlocked, "locked at 300 s")
    }

    @Test func aZeroDelayRelocksAtOnceOnResign() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        #expect(library.settings.noteRelockDelay == 0)

        library.lifecycle.send(.appResigned)
        #expect(!vault.isUnlocked)
    }

    @Test func becomeActiveCancelsAPendingRelock() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        library.settings.noteRelockDelay = 60
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")

        library.lifecycle.send(.appResigned)
        await library.clock.waitForSleeper()
        library.lifecycle.send(.appBecameActive)
        library.clock.advance(by: .seconds(3600))
        await vault.waitForPendingWork()
        #expect(vault.isUnlocked)
        #expect(library.clock.sleeperCount == 0)
    }

    @Test func aSecondResignDoesNotRestartTheCountdownUnlessItWasCancelled() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        library.settings.noteRelockDelay = 60
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")

        library.lifecycle.send(.appResigned)
        await library.clock.waitForSleeper()
        library.clock.advance(by: .seconds(40))
        library.lifecycle.send(.appResigned)
        await Task.yield()
        library.clock.advance(by: .seconds(20))
        await vault.waitForPendingWork()
        #expect(!vault.isUnlocked, "the first resign's 60 s still counts")
    }

    @Test func screenLockRelocksImmediatelyDespiteTheDelay() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        library.settings.noteRelockDelay = 3600
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")

        library.lifecycle.send(.deviceLocked)
        #expect(!vault.isUnlocked)
    }

    @Test func screenLockCancelsAPendingDelayedRelock() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        library.settings.noteRelockDelay = 300
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        library.lifecycle.send(.appResigned)
        await library.clock.waitForSleeper()

        library.lifecycle.send(.deviceLocked)
        #expect(!vault.isUnlocked)
        await vault.waitForPendingWork()
        #expect(library.clock.sleeperCount == 0)
    }

    @Test func resignDuringAuthenticationDoesNotRelock() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")

        vault.beginAuthentication()
        library.lifecycle.send(.appResigned)
        #expect(vault.isUnlocked, "a password sheet or Touch ID prompt took focus")
        vault.endAuthentication()
        #expect(!vault.isAuthenticating)

        // Screen lock still wins during authentication.
        vault.beginAuthentication()
        library.lifecycle.send(.deviceLocked)
        #expect(!vault.isUnlocked)
        vault.endAuthentication()
    }

    @Test func aRelockDuringTheKeyDerivationDiscardsTheUnlock() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        vault.relock()

        let attempt = Task { try await vault.unlock(password: "correct horse") }
        await Task.yield()  // the attempt is now waiting for its key derivation
        vault.relock()

        await #expect(throws: NotePrivacyError.accessRevoked) { try await attempt.value }
        #expect(!vault.isUnlocked)
    }

    @Test func sleepAndResignEventsStopWhenTheVaultGoesAway() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        var vault: NoteVault? = library.makeVault()
        #expect(library.lifecycle.isObserved)
        vault = nil
        _ = vault
        #expect(!library.lifecycle.isObserved, "the observation token is released with the vault")
    }

    // MARK: flush before revoke, cleanup

    @Test func willRelockHandlersRunBeforeTheKeyIsDropped() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let note = try library.store.create(text: "body")
        let access = try vault.requireAccess()
        try access.lock(noteId: note.id)

        var log: [String] = []
        _ = vault.addWillRelockHandler {
            // A session flush writes through the access: it must still work here.
            log.append(vault.access != nil ? "handler:key-present" : "handler:key-gone")
            do {
                _ = try access.updateText(id: note.id, text: "body edited", expectedRevision: try access.note(id: note.id)!.revision)
                log.append("handler:flush-ok")
            } catch { log.append("handler:flush-failed") }
        }
        _ = vault.addWillRelockHandler { log.append("handler2") }

        vault.relock()

        #expect(log == ["handler:key-present", "handler:flush-ok", "handler2"])
        #expect(vault.access == nil)
        #expect(throws: NotePrivacyError.accessRevoked) { _ = try access.note(id: note.id) }
    }

    /// Task 4: sessions of locked notes are closed after the revoke, and the sealed journals are
    /// replayed once an unlock made the key available.
    @Test func didRelockRunsAfterTheKeyIsGoneAndDidUnlockOnceItIsBack() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        var log: [String] = []
        _ = vault.addWillRelockHandler { log.append("will:\(vault.access == nil ? "gone" : "present")") }
        _ = vault.addDidRelockHandler { log.append("did:\(vault.access == nil ? "gone" : "present")") }
        _ = vault.addDidUnlockHandler { log.append("unlocked:\(vault.access == nil ? "gone" : "present")") }

        vault.relock()
        vault.relock()  // already locked: nothing runs again
        try await vault.unlock(password: "correct horse")
        try await vault.unlock(password: "correct horse")  // already unlocked: the new access only proves the password

        #expect(log == ["will:present", "did:gone", "unlocked:present"])
    }

    /// Review Focus 1: every acknowledged edit of an open locked note is committed (encrypted)
    /// before the key is dropped, and is there after the next unlock.
    @Test func relockCommitsAnOpenLockedSessionsAckedEditsBeforeTheKeyGoes() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let note = try library.store.create(text: "body")
        let access = try vault.requireAccess()
        try access.lock(noteId: note.id)
        let session = try NoteSession(
            noteId: note.id, store: access, journalDirectory: library.paths.journal,
            journalKey: try access.journalKey(), commitDelay: .seconds(3600))
        let edit = ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " more")])
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
        _ = vault.addWillRelockHandler { try? session.flush() }  // what AppEnvironment registers

        vault.relock()

        try await vault.unlock(password: "correct horse")
        #expect(try vault.requireAccess().note(id: note.id)?.text == "body more")
        let stored = try #require(try library.store.note(id: note.id))
        #expect(stored.isLocked && stored.text.isEmpty, "nothing was written in plaintext")
    }

    @Test func aRemovedHandlerIsNotCalled() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        var calls = 0
        let token = vault.addWillRelockHandler { calls += 1 }
        vault.removeWillRelockHandler(token)
        vault.relock()
        #expect(calls == 0)
    }

    @Test func cleanupRunsAfterTheRevokeAndIsAwaited() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let log = LockedLog()
        let holder = AccessHolder()
        let vault = library.makeVault(cleanup: {
            let revoked = holder.access.map { (try? $0.journalKey()) == nil }
            log.add(revoked == true ? "cleanup:key-revoked" : "cleanup:key-still-valid")
        })
        try await vault.createPassword("correct horse")
        let access = try vault.requireAccess()
        holder.access = access
        _ = vault.addWillRelockHandler {
            log.add((try? access.journalKey()) != nil ? "handler:key-valid" : "handler:key-revoked")
        }

        await vault.relockAndFinishCleanup()

        #expect(log.entries == ["handler:key-valid", "cleanup:key-revoked"],
                "flush first, then revoke, then the awaited cleanup")
        #expect(vault.cleanupState == .clean)
    }

    @Test func aBusyCleanupIsReportedAndRetriedOnTheNextRelockOrRetry() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let attempts = Counter()
        let vault = library.makeVault(cleanup: {
            if await attempts.next() == 1 { throw NotePrivacyError.cleanupPending }
        })
        try await vault.createPassword("correct horse")

        await vault.relockAndFinishCleanup()
        #expect(vault.cleanupState == .pending)

        // Nothing is unlocked, but a pending cleanup is still retried by the next relock event.
        library.lifecycle.send(.deviceLocked)
        await vault.waitForPendingWork()
        #expect(vault.cleanupState == .clean)
        #expect(await attempts.value == 2)
    }

    @Test func anotherCleanupFailureIsReportedAsFailed() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault(cleanup: { throw NotePrivacyError.pendingEdits })
        try await vault.createPassword("correct horse")

        await vault.relockAndFinishCleanup()
        #expect(vault.cleanupState == .failed("pendingEdits"))
        await vault.retryPendingCleanup()
        #expect(vault.cleanupState == .failed("pendingEdits"))
    }

    @Test func theDefaultCleanupIsTheCoreRetryAndFinishesACommittedLockTransition() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        try await vault.createPassword("correct horse")
        let note = try library.store.create(text: "to lock")
        try vault.requireAccess().lock(noteId: note.id)

        await vault.relockAndFinishCleanup()
        #expect(vault.cleanupState == .clean)
        #expect(throws: Never.self) { try NotePrivacy(store: library.store).finishPendingCleanup() }
    }

    @Test func recoverAtLaunchReportsPendingTransitions() async throws {
        let library = try VaultLibrary()
        defer { library.destroy() }
        let vault = library.makeVault()
        vault.recoverAtLaunch()
        #expect(vault.cleanupState == .clean)
    }
}

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var entries: [String] { lock.withLock { storage } }
    func add(_ entry: String) { lock.withLock { storage.append(entry) } }
}

private final class AccessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LockedNoteAccess?
    var access: LockedNoteAccess? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}
