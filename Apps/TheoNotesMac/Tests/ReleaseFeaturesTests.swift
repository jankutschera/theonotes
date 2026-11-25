// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// REL-R4 ... REL-R9: a build made for the public hides the sync setup; Jan's own builds keep it.
/// The switch is the build setting THEONOTES_SYNC_SETUP, read through `ReleaseFeatures` (parsing is tested in core).
@MainActor @Suite struct ReleaseFeaturesTests {
    private struct Refused: Error {}
    @MainActor private final class Spy {
        var calls: [String] = []
        let suite = "ReleaseFeaturesTests." + UUID().uuidString
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: suite)! }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        var services: MacSyncServices {
            MacSyncServices(
                defaults: defaults,
                credentials: { [self] namespace in calls.append("credentials " + namespace); throw Refused() },
                transport: { [self] _, _ in calls.append("transport"); throw Refused() },
                enrollment: { [self] _, _ in calls.append("enrollment"); throw Refused() },
                engine: { [self] _, _, _ in calls.append("engine"); throw Refused() },
                scheduler: { [self] _, _ in calls.append("scheduler"); return nil })
        }
    }

    private func makeRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("SyncUIAvailability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent("Library", isDirectory: true)
    }

    private func syncTableCount(_ environment: AppEnvironment) throws -> Int? {
        try environment.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'sync%'")
        }
    }

    // MARK: the switch

    @Test func theDevBuildTheTestsRunInKeepsSync() throws {
        // Debug (the dev identity) sets YES: tests and agents need the sync code reachable.
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["THEONOTES_SyncSetupAvailable"] as? String == "YES")
        #expect(ReleaseFeatures.syncSetupAvailable())
        #expect(ReleaseFeatures.syncSetupAvailable(infoDictionary: info))
    }

    // MARK: Settings

    @Test func settingsHaveNoSyncPaneWhenSyncIsHidden() {
        let hidden = SettingsTab.order(syncSetup: false)
        #expect(hidden.map(\.title) == ["General", "Capture", "Appearance", "Typography", "Automation", "Privacy", "Advanced"])
        #expect(!hidden.contains(.sync))
    }

    @Test func settingsKeepTheSyncPaneWhenSyncIsOn() {
        let shown = SettingsTab.order(syncSetup: true)
        #expect(shown.map(\.title) == ["General", "Capture", "Appearance", "Typography", "Automation", "Sync", "Privacy", "Advanced"])
        #expect(Set(shown + [.icloud]) == Set(SettingsTab.allCases))
        #expect(SettingsTab.order == SettingsTab.order(syncSetup: true, icloud: ReleaseFeatures.cloudSyncAvailable()),
                "in this (dev) build the default keeps Sync; iCloud follows its own flag")
    }

    @Test func aSavedSyncTabFallsBackToGeneralWhenSyncIsHidden() {
        // Jan's Production build saved "sync" as the last tab; a public build on the same defaults must not select it.
        #expect(SettingsTab.sync.shown(syncSetup: false) == .general)
        #expect(SettingsTab.sync.shown(syncSetup: true) == .sync)
        #expect(SettingsTab.privacy.shown(syncSetup: false) == .privacy)
    }

    // MARK: the controller

    /// The app's launch order: `startSync()` is the first thing that reaches sync, before anything has read
    /// `environment.sync`. With the switch off it must change nothing (the T2 audit's case).
    @Test func startSyncAtLaunchIsANoOpWhenHidden() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spy = Spy()
        defer { spy.cleanup() }
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), syncPolicy: .enabled, syncSetup: false, syncServices: spy.services)
        environment.startSync()
        #expect(spy.calls == [], "launch did not wake the scheduler or read the Keychain")
        #expect(spy.defaults.persistentDomain(forName: spy.suite)?.isEmpty ?? true)
        environment.stopSync()
        #expect(spy.calls == [])
    }

    @Test func hiddenSyncNeverStartsAndTouchesNothingEvenOnTheDefaultLibrary() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spy = Spy()
        defer { spy.cleanup() }
        // The most permissive launch (.enabled, the default library) with the switch off.
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), syncPolicy: .enabled, syncSetup: false, syncServices: spy.services)
        #expect(!environment.syncSetupAvailable)
        let sync = environment.sync
        #expect(sync.isLocalOnly)
        #expect(sync.isUnavailable)
        let tablesBefore = try syncTableCount(environment)

        environment.startSync()
        sync.setActive(true)
        sync.setActive(false)
        #expect(await sync.refreshAutomatically() == .needsUser)
        await sync.resumeIfNeeded()
        await sync.load()
        await sync.synchronize()
        await sync.signIn(create: false, setupCode: "")
        await sync.signIn(create: true, setupCode: "setup")
        await sync.signOut()
        await sync.beginReceiving()
        await sync.setPaused(true)
        // The Note Password reset waits for sync to be quiet: with nothing running it answers at once.
        #expect(await sync.quiesce())
        sync.endQuiesce()
        environment.stopSync()
        await sync.shutdown()

        #expect(spy.calls == [], "no credential, transport, engine or scheduler factory was called")
        #expect(spy.defaults.persistentDomain(forName: spy.suite)?.isEmpty ?? true, "no saved flag was written")
        #expect(sync.status == MacSyncController.unavailableStatus)
        #expect(MacSyncController.unavailableStatus == "Sync is not available in this version")
        #expect(!sync.connected && !sync.ready && !sync.busy)
        #expect(try syncTableCount(environment) == tablesBefore)
    }

    @Test func shownSyncStillWiresTheSchedulerAndCredentials() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spy = Spy()
        defer { spy.cleanup() }
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), syncPolicy: .enabled, syncSetup: true, syncServices: spy.services)
        let sync = environment.sync
        #expect(!sync.isLocalOnly && !sync.isUnavailable)
        environment.startSync()
        #expect(spy.calls == ["scheduler"])
        await sync.load()
        #expect(spy.calls == ["scheduler", "credentials mac.test." + SyncWire.hash(Data(root.path.utf8))])
        environment.stopSync()
        await sync.shutdown()
    }

    @Test func aLibraryCopyKeepsItsOwnStatusWhenSyncIsOn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spy = Spy()
        defer { spy.cleanup() }
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), syncPolicy: .localOnly, syncSetup: true, syncServices: spy.services)
        #expect(environment.sync.isLocalOnly)
        #expect(!environment.sync.isUnavailable)
        #expect(environment.sync.status == MacSyncController.localOnlyStatus)
    }

    @Test func sharingFollowsTheLaunchNotTheSwitch() {
        // The share extension's inbox is decided by the launch policy; a public build still receives shares.
        let container = URL(fileURLWithPath: "/tmp/share-container")
        #expect(AppEnvironment.shareContainer(syncPolicy: .enabled, environment: [:], resolve: { container }) == container)
    }
}
