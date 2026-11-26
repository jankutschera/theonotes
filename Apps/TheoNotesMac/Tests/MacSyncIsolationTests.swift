// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// Records every attempt to reach the Keychain, the network or the scheduler, and refuses it:
/// no spy call touches a real Keychain item, URL session or timer.
@MainActor private final class SyncServiceSpy {
    struct Refused: Error {}
    private(set) var calls: [String] = []
    let suite = "MacSyncIsolationTests." + UUID().uuidString
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: suite)! }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
    var storedDefaults: [String: String] {
        (defaults.persistentDomain(forName: suite) ?? [:]).mapValues { "\($0)" }
    }

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

/// Phase 2 prerequisite: a library named at launch never syncs.
@MainActor @Suite struct MacSyncIsolationTests {
    /// A unique parent folder: recovery siblings made next to the library are removed with it.
    private func makeParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MacSyncIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    private func syncRows(_ database: AppDatabase) throws -> [String] {
        try database.pool.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sync%' ORDER BY name")
            return try tables.flatMap { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map { "\(table) \($0.description)" }
            }
        }
    }

    @Test func libraryCopyCallsNoCredentialTransportSchedulerOrEngineFactory() async throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // The copy looks like a connected recovery library: a marker, an original next to it,
        // an enabled sync queue and "connected" defaults under both namespaces it could use.
        let id = UUID().uuidString.lowercased()
        let original = parent.appendingPathComponent("Library", isDirectory: true)
        let root = parent.appendingPathComponent("Library-Recovery-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":1,"id":"\#(id)","origin":"Library"}"#.utf8)
            .write(to: root.appendingPathComponent(".sync-recovery-library.json"))
        let spy = SyncServiceSpy()
        defer { spy.cleanup() }
        for namespace in ["mac.recovery." + id, "mac.test." + SyncWire.hash(Data(root.path.utf8)), "mac.production.v1"] {
            spy.defaults.set(true, forKey: namespace + ".connected")
            spy.defaults.set(false, forKey: namespace + ".paused")
        }
        let environment = try AppEnvironment(paths: AppPaths(root: root), syncPolicy: .localOnly, syncServices: spy.services)
        _ = try environment.store.create(text: "copied note")
        let queue = SyncQueue(database: environment.database)
        try queue.configure(accountID: "copied-account")
        try queue.enable(accountID: "copied-account")
        let rowsBefore = try syncRows(environment.database)
        let defaultsBefore = spy.storedDefaults

        let sync = environment.sync
        #expect(sync.isLocalOnly)
        #expect(!sync.isRecoveryLibrary)
        // Startup, active / wake callbacks and the automatic run.
        environment.startSync()
        sync.setActive(true)
        sync.setActive(false)
        #expect(await sync.refreshAutomatically() == .needsUser)
        await sync.resumeIfNeeded()
        await sync.load()
        await sync.synchronize()
        await sync.resolveProtectedChanges(password: "pw", newPassword: "")
        // Manual sign-in, account recovery and the recovery key.
        await sync.signIn(create: false, setupCode: "")
        await sync.signIn(create: true, setupCode: "setup")
        await sync.recover(words: try RecoveryKey().words())
        await sync.rotateRecoveryKey()
        await sync.confirmRecoverySaved()
        // Device transfer: receive, poll, approve, send, confirm, cancel.
        await sync.beginReceiving()
        await sync.restartReceiving()
        sync.setSensitivePresentation(true)
        await sync.refreshPairingRequests()
        await sync.confirmSendingTransfer()
        await sync.sendPairingKey(code: "code")
        await sync.retrySendingTransfer()
        await sync.confirmPairing()
        await sync.cancelPairing()
        // Devices, pause, sign-out and the recovery-library workflow.
        await sync.renameDevice()
        await sync.revoke("other-device")
        await sync.setPaused(true)
        await sync.setPaused(false)
        await sync.signOut()
        await sync.prepareRecoveryCopy()
        await sync.openRecoveryCopy()
        await sync.returnToOriginalLibrary()
        environment.stopSync()
        await sync.shutdown()

        #expect(spy.calls == [])
        #expect(spy.storedDefaults == defaultsBefore)
        #expect(try syncRows(environment.database) == rowsBefore)
        #expect(sync.status == "Sync is off for this library copy")
        #expect(!sync.connected && !sync.ready && !sync.busy)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        #expect(siblings == ["Library", "Library-Recovery-" + id], "no recovery copy was prepared")
    }

    @Test func defaultLibraryStillWiresTheSchedulerAndCredentials() async throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Library", isDirectory: true)
        let spy = SyncServiceSpy()
        defer { spy.cleanup() }
        let environment = try AppEnvironment(paths: AppPaths(root: root), syncPolicy: .enabled, syncServices: spy.services)
        let sync = environment.sync
        #expect(!sync.isLocalOnly)
        environment.startSync()
        #expect(spy.calls == ["scheduler"])
        await sync.load()
        #expect(spy.calls == ["scheduler", "credentials mac.test." + SyncWire.hash(Data(root.path.utf8))])
        environment.stopSync()
        await sync.shutdown()
    }

    /// The app's own launch composition: an explicit folder is opened exactly, with sync off,
    /// even when recovery files inside it name another library.
    @Test func explicitDataDirIsOpenedExactlyAndLocalOnly() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = AppPaths(root: parent.appendingPathComponent("Real", isDirectory: true))
        try FileManager.default.createDirectory(at: real.root, withIntermediateDirectories: true)
        let copy = parent.appendingPathComponent("Copy", isDirectory: true)
        let id = UUID().uuidString.lowercased()
        let sibling = parent.appendingPathComponent("Copy-Recovery-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data(#"{"version":1,"id":"\#(id)","origin":"Copy"}"#.utf8).write(to: sibling.appendingPathComponent(".sync-recovery-library.json"))
        try Data(#"{"version":1,"name":"Copy-Recovery-\#(id)"}"#.utf8).write(to: copy.appendingPathComponent(".active-recovery-library.json"))

        for (arguments, variables) in [(["Baerchen", "--data-dir", copy.path], [String: String]()),
                                       (["Baerchen", "--data-dir=" + copy.path], [:]),
                                       (["Baerchen"], ["BAERCHEN_DATA_DIR": copy.path])] {
            let environment = try AppEnvironment.launching(arguments: arguments, environment: variables, production: real)
            #expect(environment.paths.root.path == copy.standardizedFileURL.path)
            #expect(environment.syncPolicy == .localOnly)
            #expect(environment.sync.isLocalOnly)
        }
        #expect(!FileManager.default.fileExists(atPath: sibling.appendingPathComponent("Baerchen.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: real.root.appendingPathComponent("Baerchen.sqlite").path))
        #expect(throws: AppPaths.DataDirectoryError.self) {
            try AppEnvironment.launching(arguments: ["Baerchen", "--data-dir", real.root.path], environment: [:], production: real)
        }
    }

    /// Without an override the default library (here a temp stand-in) follows its recovery
    /// selection and keeps sync.
    @Test func defaultLaunchFollowsTheRecoverySelectionWithSyncEnabled() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = AppPaths(root: parent.appendingPathComponent("Real", isDirectory: true))
        let id = UUID().uuidString.lowercased()
        let recovery = parent.appendingPathComponent("Real-Recovery-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: real.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data(#"{"version":1,"id":"\#(id)","origin":"Real"}"#.utf8).write(to: recovery.appendingPathComponent(".sync-recovery-library.json"))
        try Data(#"{"version":1,"name":"Real-Recovery-\#(id)"}"#.utf8).write(to: real.root.appendingPathComponent(".active-recovery-library.json"))
        let environment = try AppEnvironment.launching(arguments: ["Baerchen"], environment: [:], production: real)
        #expect(AppPaths.isSameDirectory(environment.paths.root, recovery))
        #expect(environment.syncPolicy == .enabled)
    }
}
