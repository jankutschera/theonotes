// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// M9M task 6: Settings ▸ Privacy. Libraries are temporary folders under /tmp, the Keychain is the
/// in-memory fake and the identity check is a fake: nothing here prompts or touches real state.
@MainActor
struct PrivacySettingsFixture {
    let app: AppLockFixture
    let vault: NoteVault
    var library: VaultLibrary { app.library }
    let appLock: AppLock
    let model: PrivacySettingsModel
    let log = HookLog()

    final class HookLog {
        var events: [String] = []
        /// What the sync barrier answers; a test may also replace the whole barrier.
        var barrierHolds = true
        var barrier: (@MainActor () async -> Bool)?
    }

    init(appLockEnabled: Bool = false, touchIDOptIn: Bool = false) throws {
        app = try AppLockFixture(enabled: appLockEnabled)
        app.library.settings.useTouchIDForNotes = touchIDOptIn
        vault = app.library.makeVault()
        appLock = app.makeLock()
        let log = log
        model = PrivacySettingsModel(
            vault: vault, store: app.library.store, settings: app.library.settings, appLock: appLock,
            flush: { log.events.append("flush") },
            quiesceSync: {
                log.events.append("quiesce")
                if let barrier = log.barrier { return await barrier() }
                return log.barrierHolds
            },
            resumeSync: { log.events.append("resume") })
    }

    var cache: FakeVaultKeyCache { library.cache }
    var privacy: NotePrivacy { NotePrivacy(store: library.store) }

    func destroy() { app.destroy() }

    /// A password, then one locked note; the vault stays unlocked.
    @discardableResult
    func lockedNote(_ text: String = "# Locked\n\nbody") async throws -> String {
        if !vault.hasPassword { try await vault.createPassword("correct horse") }
        let note = try library.store.create(text: text)
        try vault.requireAccess().lock(noteId: note.id)
        model.refreshStatus()
        return note.id
    }
}

@MainActor
@Suite struct PrivacySettingsTests {
    // MARK: tab

    @Test func privacyIsTheTabBetweenSyncAndAdvanced() {
        let titles = SettingsTab.order(syncSetup: true).map(\.title)
        #expect(titles == ["General", "Capture", "Appearance", "Typography", "Automation", "Sync", "Privacy", "Advanced"])
        #expect(SettingsTab.privacy.systemImage == "lock")
        #expect(Set(SettingsTab.order(syncSetup: true, icloud: true)) == Set(SettingsTab.allCases))
    }

    // MARK: Touch ID for notes

    @Test func touchIDIsOffUntilTheUserTurnsItOnAndThenStoresTheKey() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        #expect(!fixture.model.usesTouchID)
        #expect(fixture.cache.items.isEmpty, "no Keychain item before the opt-in")

        fixture.model.setUsesTouchID(true)
        #expect(fixture.model.usesTouchID && fixture.model.touchIDError == nil)
        #expect(fixture.library.settings.useTouchIDForNotes)
        #expect(fixture.cache.items[VaultLibrary.account] != nil)

        fixture.model.setUsesTouchID(false)
        #expect(!fixture.model.usesTouchID)
        #expect(!fixture.library.settings.useTouchIDForNotes)
        #expect(fixture.cache.items.isEmpty, "turning it off deletes the stored key")
    }

    @Test func aFailedKeyRemovalKeepsTheOptionOnAndSaysSo() async throws {
        let fixture = try PrivacySettingsFixture(touchIDOptIn: true)
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        #expect(fixture.cache.items.count == 1)

        fixture.cache.removeFails = true
        fixture.model.setUsesTouchID(false)
        #expect(fixture.model.usesTouchID, "the stored key is still there, so the switch must not claim otherwise")
        #expect(fixture.library.settings.useTouchIDForNotes)
        #expect(fixture.model.touchIDError != nil)
    }

    @Test func touchIDIsUnavailableWithoutBiometryOnThisMac() throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        fixture.cache.available = false
        #expect(!fixture.model.touchIDSupported)
        fixture.cache.available = true
        #expect(fixture.model.touchIDSupported)
    }

    // MARK: relock delays

    @Test func everyNoteRelockOptionWritesItsSetting() throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        #expect(fixture.model.noteRelockOptions == [0, 60, 300, 900, 3600])
        for seconds in [60, 300, 900, 3600, 0] {
            fixture.model.setNoteRelockDelay(seconds)
            #expect(fixture.model.noteRelockDelay == seconds)
            #expect(fixture.library.settings.noteRelockDelay == seconds)
        }
        fixture.model.setNoteRelockDelay(7)
        #expect(fixture.library.settings.noteRelockDelay == 0, "a value that is not offered is ignored")
    }

    @Test func everyAppLockOptionWritesItsSetting() throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        #expect(fixture.model.appLockOptions == [0, 60, 300, 900, 3600])
        for seconds in [0, 60, 900, 3600, 300] {
            fixture.model.setAppLockDelay(seconds)
            #expect(fixture.model.appLockDelay == seconds)
            #expect(fixture.library.settings.appLockDelay == seconds)
        }
    }

    @Test func theOptionLabelsAreWordsNotSeconds() {
        #expect(PrivacySettingsModel.label(forDelay: 0) == "Immediately")
        #expect(PrivacySettingsModel.label(forDelay: 60) == "1 minute")
        #expect(PrivacySettingsModel.label(forDelay: 300) == "5 minutes")
        #expect(PrivacySettingsModel.label(forDelay: 900) == "15 minutes")
        #expect(PrivacySettingsModel.label(forDelay: 3600) == "1 hour")
    }

    // MARK: App Lock switch

    @Test func theAppLockSwitchGoesThroughTheIdentityCheck() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        fixture.app.authenticator.script(.cancelled)
        await fixture.model.setAppLockEnabled(true)
        #expect(!fixture.model.appLockEnabled && fixture.model.appLockMessage == nil)

        fixture.app.authenticator.script(.success)
        await fixture.model.setAppLockEnabled(true)
        #expect(fixture.model.appLockEnabled && fixture.library.settings.appLockEnabled)

        fixture.app.authenticator.available = false
        await fixture.model.setAppLockEnabled(false)
        #expect(!fixture.model.appLockEnabled, "a Mac that cannot ask may still switch the lock off")

        await fixture.model.setAppLockEnabled(true)
        #expect(!fixture.model.appLockEnabled && fixture.model.appLockMessage != nil, "and says why it cannot be switched on")
    }

    // MARK: reset

    @Test func resetIsBlockedWhileLockedNotesOrTrashRemainAndNothingIsDeleted() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        let id = try await fixture.lockedNote()
        let trashed = try fixture.library.store.create(text: "gone")
        try fixture.library.store.trash([trashed.id])
        fixture.model.refreshStatus()

        #expect(!fixture.model.canReset)
        #expect(fixture.model.resetBlockers.count == 2, "locked notes and Trash: \(fixture.model.resetBlockers)")
        fixture.model.resetPhrase = PrivacySettingsModel.resetPhrase
        #expect(await fixture.model.resetNotePassword() == false)
        #expect(fixture.model.resetError != nil)
        #expect(try fixture.privacy.hasPassword, "the envelope is untouched")
        #expect(fixture.vault.hasPassword)
        #expect(try fixture.library.store.note(id: id)?.isLocked == true)
        #expect(fixture.log.events.isEmpty, "a blocked reset does not even pause sync")
    }

    @Test func resetNeedsTheTypedConfirmationEvenWhenNothingBlocksIt() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        fixture.model.refreshStatus()
        #expect(fixture.model.canReset && fixture.model.resetBlockers.isEmpty)
        #expect(!fixture.model.canConfirmReset)

        for wrong in ["", "yes", "rese", "reset it"] {
            fixture.model.resetPhrase = wrong
            #expect(!fixture.model.canConfirmReset)
            #expect(await fixture.model.resetNotePassword() == false)
            #expect(try fixture.privacy.hasPassword, "'\(wrong)' must not reset anything")
        }
        #expect(fixture.model.resetError != nil)
        #expect(fixture.log.events.isEmpty)
    }

    @Test func aConfirmedResetDeletesThePasswordAndItsKeyAndLeavesTheNotes() async throws {
        let fixture = try PrivacySettingsFixture(touchIDOptIn: true)
        defer { fixture.destroy() }
        let id = try await fixture.lockedNote("# Mine\n\nbody")
        try fixture.vault.requireAccess().removeLock(noteId: id)
        let plain = try fixture.library.store.create(text: "# Plain")
        #expect(fixture.cache.items.count == 1)
        fixture.model.refreshStatus()
        #expect(fixture.model.canReset)

        fixture.model.resetPhrase = " Reset "
        #expect(fixture.model.canConfirmReset, "trimmed and case-insensitive")
        #expect(await fixture.model.resetNotePassword())

        #expect(try !fixture.privacy.hasPassword)
        #expect(!fixture.vault.hasPassword && !fixture.vault.isUnlocked)
        #expect(fixture.cache.items.isEmpty, "the Touch ID key goes with it")
        #expect(try fixture.library.store.note(id: id)?.text == "# Mine\n\nbody")
        #expect(try fixture.library.store.note(id: plain.id) != nil)
        #expect(fixture.model.resetError == nil && fixture.model.resetPhrase.isEmpty)
        #expect(fixture.log.events == ["quiesce", "flush", "resume"], "sync is quiet first, then edits are saved, then sync resumes")
        #expect(!fixture.model.canReset, "there is no password left to reset")
    }

    @Test func theKeyCacheIsEmptyBeforeTheEnvelopeIsDeleted() async throws {
        let fixture = try PrivacySettingsFixture(touchIDOptIn: true)
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        fixture.cache.removeFails = true
        fixture.model.refreshStatus()
        fixture.model.resetPhrase = "reset"
        #expect(await fixture.model.resetNotePassword() == false)
        #expect(try fixture.privacy.hasPassword, "a key that cannot be deleted stops the reset before the envelope goes")
        #expect(fixture.log.events.last == "resume", "sync is resumed after a failure too")
    }

    @Test func theResetWaitsForTheRunningSyncBeforeItSavesOrChangesAnything() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        fixture.model.refreshStatus()
        let log = fixture.log
        // A sync run in flight: the barrier returns only when it has ended.
        let run = AsyncGateForTests()
        log.barrier = {
            await run.wait()
            log.events.append("run ended")
            return true
        }
        fixture.model.resetPhrase = "reset"
        async let outcome = fixture.model.resetNotePassword()
        for _ in 0..<200 where !log.events.contains("quiesce") { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(log.events == ["quiesce"], "nothing is saved, revoked or deleted while the run is still going")
        #expect(try fixture.privacy.hasPassword)

        run.open()
        #expect(await outcome)
        #expect(log.events == ["quiesce", "run ended", "flush", "resume"])
        #expect(try !fixture.privacy.hasPassword)
    }

    @Test func aSyncThatCannotBeQuietedStopsTheResetAndStillResumes() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        fixture.model.refreshStatus()
        fixture.log.barrierHolds = false
        fixture.model.resetPhrase = "reset"
        #expect(await fixture.model.resetNotePassword() == false)
        #expect(fixture.model.resetError != nil)
        #expect(try fixture.privacy.hasPassword)
        #expect(fixture.log.events == ["quiesce", "resume"])
    }

    @Test func preconditionsAreCheckedAgainOnceSyncIsQuiet() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        fixture.model.refreshStatus()
        #expect(fixture.model.canReset)
        let library = fixture.library
        let vault = fixture.vault
        // The run that was in flight brought a locked note in while we waited for it.
        fixture.log.barrier = {
            let note = try? library.store.create(text: "# arrived by sync")
            if let note { try? vault.requireAccess().lock(noteId: note.id) }
            return true
        }
        fixture.model.resetPhrase = "reset"
        #expect(await fixture.model.resetNotePassword() == false)
        #expect(try fixture.privacy.hasPassword, "the envelope stays: a locked note exists now")
        #expect(fixture.model.resetError != nil)
        #expect(fixture.log.events == ["quiesce", "flush", "resume"])
    }

    // MARK: change password

    @Test func changingThePasswordNeedsTheOldOneAndAMatchingNewOne() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        try await fixture.vault.createPassword("correct horse")
        fixture.vault.relock()

        #expect(await fixture.model.changePassword(old: "correct horse", new: "", confirm: "") == .emptyNew)
        #expect(await fixture.model.changePassword(old: "correct horse", new: "one", confirm: "two") == .mismatch)
        #expect(await fixture.model.changePassword(old: "wrong", new: "battery staple", confirm: "battery staple") == .wrongOld)
        await #expect(throws: CryptoError.wrongPassword) { try await fixture.vault.unlock(password: "battery staple") }

        #expect(await fixture.model.changePassword(old: "correct horse", new: "battery staple", confirm: "battery staple") == .changed)
        await #expect(throws: CryptoError.wrongPassword) { try await fixture.vault.unlock(password: "correct horse") }
        try await fixture.vault.unlock(password: "battery staple")
        #expect(fixture.vault.isUnlocked)
    }

    @Test func changingThePasswordIsRefusedWhenThereIsNone() async throws {
        let fixture = try PrivacySettingsFixture()
        defer { fixture.destroy() }
        #expect(!fixture.model.canChangePassword)
        #expect(await fixture.model.changePassword(old: "a", new: "b", confirm: "b") == .noPassword)
    }

    // MARK: pane

    @Test func thePaneRenders() async throws {
        let root = URL(fileURLWithPath: "/tmp/theo-privacy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: FakeAppAuthenticator(), appLockLifecycle: nil, appIdleSeconds: { 0 })
        _ = try environment.store.create(text: "# Quarterly numbers zqx")
        let settings = SettingsModel(database: environment.database)
        let host = NSHostingView(rootView: SettingsPane(tab: .privacy, settings: settings, environment: environment).frame(width: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0 && host.fittingSize.height > 0)
    }
}

/// A one-shot gate: `wait()` suspends until `open()`.
@MainActor
final class AsyncGateForTests {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}
