// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

// Task 15b: the shipped services build the live gateway only behind the release flag and a valid container, and
// a long upload can neither hold the Settings UI nor the switch-off and the app quit. Nothing here reaches the real iCloud: the live
// gateway is only constructed (it touches CloudKit on its first call), and the upload is a scripted gateway in front of the fake.

/// A gateway in front of the fake whose `submit` can be made to hang until it is cancelled, the way a long attachment upload hangs.
/// `cancelOperations` (the fence's closure) and Task cancellation both end the hang.
final class HangingSubmitGateway: CloudKitGateway, @unchecked Sendable {
    let inner: FakeCloudKitDevice
    private let lock = NSLock()
    private var armed = false
    private var released = false
    private(set) var entered = 0
    private(set) var enteredOnMainThread = false
    private(set) var fenceCancels = 0

    init(_ inner: FakeCloudKitDevice) { self.inner = inner }

    var events: AsyncStream<CloudGatewayEvent> { inner.events }

    func arm() { lock.lock(); armed = true; released = false; lock.unlock() }
    /// A send that ignores both cancellations (Task and the fence's closure) and ends only when the test lets it go.
    func armStuck() { lock.lock(); stuck = true; stuckReleased = false; lock.unlock() }
    func releaseStuck() { lock.withLock { stuckReleased = true } }
    private var stuck = false
    private var stuckReleased = false
    private var shouldStayStuck: Bool { lock.lock(); defer { lock.unlock() }; return stuck && !stuckReleased }
    func cancelOperations() async { lock.withLock { fenceCancels += 1; released = true } }
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered > 0 }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return fenceCancels }
    private var shouldHang: Bool { lock.lock(); defer { lock.unlock() }; return armed && !released }

    func prepare() async throws -> CloudAccountState { try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws {
        let isStuck = lock.withLock { () -> Bool in
            if stuck && !stuckReleased { entered += 1; enteredOnMainThread = enteredOnMainThread || Thread.isMainThread; return true }
            return false
        }
        if isStuck {
            while shouldStayStuck { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        let hang = lock.withLock { () -> Bool in
            let hang = armed && !released
            if hang { entered += 1; enteredOnMainThread = enteredOnMainThread || Thread.isMainThread }
            return hang
        }
        if hang {
            while shouldHang, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        try await inner.submit(saves)
    }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { try await inner.fetch(names, keys: keys) }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws { try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
}

private final class HangBox: @unchecked Sendable { var gateway: HangingSubmitGateway? }

private final class RemoteNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    func add(_ info: [AnyHashable: Any]) -> Bool {
        lock.lock(); seen.append(info.keys.compactMap { $0 as? String }.sorted()); lock.unlock()
        return true
    }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return seen }
}

@MainActor @Suite(.serialized) struct CloudSyncLiveWiringTests {
    private let containerKey = ReleaseFeatures.cloudKitContainerInfoKey
    private let flagKey = ReleaseFeatures.iCloudSyncInfoKey
    private let container = "iCloud.com.truebrewbirdie.theonotes"

    private func library() throws -> (AppEnvironment, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudWire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (try AppEnvironment(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true))), parent)
    }

    // MARK: only the flag AND a valid container build the live gateway

    @Test func flagOffAndEmptyContainerBuildsConstructNothing() throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = CloudSyncGatewayRequest(store: CloudSyncStore(database: environment.database), paths: environment.paths)
        let pins = environment.paths.root.appendingPathComponent("CloudGatewayPins")
        let builds: [(String, [String: Any]?)] = [
            ("no Info.plist", nil),
            ("empty", [:]),
            ("container, flag missing", [containerKey: container]),
            ("container, flag NO", [containerKey: container, flagKey: "NO"]),
            ("flag YES, container empty (config/release.env today)", [containerKey: "", flagKey: "YES"]),
            ("flag YES, container unsubstituted", [containerKey: "$(THEONOTES_CLOUDKIT_CONTAINER)", flagKey: "YES"]),
            ("flag YES, container missing", [flagKey: "YES"]),
            ("flag YES, container malformed", [containerKey: "com.example.nope", flagKey: "YES"]),
        ]
        for (name, info) in builds {
            let services = CloudSyncServices.live(infoDictionary: info)
            #expect(services.configuration == nil, "\(name): no configuration")
            let parts = services.gateway(request)
            #expect(parts.gateway is UnavailableCloudKitGateway, "\(name): the gateway is the one that answers 'not available'")
            #expect(parts.handleRemoteNotification == nil, "\(name): nothing to forward to")
            #expect(!FileManager.default.fileExists(atPath: pins.path), "\(name): no folder was made")
        }
    }

    @Test func aBuildWithTheFlagAndAContainerGetsTheLiveGatewayOnADurablePinFolder() async throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = CloudSyncGatewayRequest(store: CloudSyncStore(database: environment.database), paths: environment.paths)
        let services = CloudSyncServices.live(infoDictionary: [containerKey: container, flagKey: "YES"])
        #expect(services.configuration?.containerIdentifier == container)
        let parts = services.gateway(request)
        #expect(parts.gateway is LiveCloudKitGateway)
        #expect(parts.handleRemoteNotification != nil)

        // The pin folder is inside the library folder (Application Support in a real run), not tmp, and out of backups.
        let pins = CloudSyncServices.livePinDirectory(for: environment.paths)
        #expect(pins.deletingLastPathComponent().standardizedFileURL == environment.paths.root.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: pins.path))
        #expect(try pins.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(pins.standardizedFileURL != environment.paths.cloudPinned.standardizedFileURL, "not the receiver's own folder")

        // The fence closure is the gateway's own: with no engine yet it is a no-op, never a trap.
        await parts.cancelOperations()
        // A payload that is not a CloudKit notification is not one of ours, and CloudKit is not touched to find out.
        #expect(parts.handleRemoteNotification?(["aps": ["alert": "hello"]]) == false)

        // The seed store is the data-protection keychain item of this app's access group.
        let seeds = try #require(services.keychain("mac-test") as? KeychainCloudKeySeedStore)
        #expect(seeds.accessGroup == AppIdentity.current.keychainAccessGroup)
        #expect(seeds.namespace == "mac-test")
    }

    @Test func theShippedDefaultIsBuiltFromTheMainBundleWithTheTeamContainer() {
        // Since the cutover (B7) config/release.env names the container and Debug sets the flag: the test host (the dev identity)
        // offers iCloud sync for that container. The user's switch stays off, so nothing starts on its own.
        #expect(CloudSyncServices.live().configuration?.containerIdentifier == "iCloud.com.truebrewbirdie.theonotes")
        #expect(ReleaseFeatures.cloudSyncAvailable())
    }

    @Test func aFlagOffBuildStartsNothingAndAnEmptyContainerBuildMakesNoGatewayEvenWhenSwitchedToOn() async throws {
        // Flag off: the controller is never even made (the existing guard, kept here with the live services).
        let flagOff = try CloudMacDevice(flag: false)
        defer { flagOff.cleanup() }
        flagOff.environment.startSync()
        try await Task.sleep(for: .milliseconds(150))
        flagOff.environment.stopSync()
        #expect(!flagOff.environment.cloudSyncStarted)
        #expect(flagOff.touched.value == 0)

        // Flag on but no container: the coordinator answers "not available" and the gateway that was handed over is never used.
        let noContainer = try CloudMacDevice(configured: false)
        defer { noContainer.cleanup() }
        await noContainer.controller.turnOn()
        #expect(noContainer.controller.state == .notAvailableInThisBuild)
        #expect(await noContainer.cloud.recordNames.isEmpty)
    }

    // MARK: a remote notification, if one arrives

    @Test func aRemoteNotificationIsForwardedToTheGatewayOnlyWhileSyncIsOn() async throws {
        let notes = RemoteNotes()
        let d = try CloudMacDevice(wrap: { fake in
            CloudSyncGatewayParts(gateway: fake, handleRemoteNotification: { notes.add($0) })
        })
        defer { d.cleanup() }
        #expect(d.environment.handleCloudRemoteNotification(["ck": 1]) == false, "switched off: no gateway exists, nothing is made for it")
        #expect(d.touched.value == 0)
        try await d.turnOnAndSkip()
        #expect(d.environment.handleCloudRemoteNotification(["ck": 1]) == true)
        #expect(notes.all == [["ck"]])
        await d.controller.shutdown()
        #expect(d.environment.handleCloudRemoteNotification(["ck": 1]) == false, "after shutdown nothing is forwarded")
        #expect(notes.all.count == 1)
    }

    // MARK: a long upload cannot hold the Settings UI or the quit

    /// The scripted gateway is made when the coordinator asks for it (the first turn-on), so it is read after that.
    private func hangGateway(_ box: HangBox) throws -> HangingSubmitGateway { try #require(box.gateway) }

    @Test func aHangingUploadRunsOffTheMainThreadAndShutdownCancelsItThroughTheFence() async throws {
        let box = HangBox()
        let d = try CloudMacDevice(wrap: { fake in
            let hang = HangingSubmitGateway(fake)
            box.gateway = hang
            return CloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try hangGateway(box)
        hang.arm()
        try d.note("# a big attachment goes with this one\n")

        // "Sync now" takes the upload and it hangs.
        let syncing = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered }, "the upload started")
        #expect(!hang.enteredOnMainThread, "the upload runs off the main thread")
        #expect(d.controller.isWorking, "the tab shows it as busy, and the main actor is free to show it")

        // The app quits (or the window system goes away): the fence cancels the upload, nothing waits for it to end by itself.
        let begun = Date()
        await d.controller.shutdown()
        #expect(Date().timeIntervalSince(begun) < 3, "shutdown returned in \(Date().timeIntervalSince(begun)) s")
        #expect(hang.cancelCount >= 1, "the fence's closure reached the gateway")
        _ = await syncing.value
        #expect(!d.controller.isWorking)
    }

    @Test func stopSyncingWhileATimerDrivenUploadHangsCancelsItAndShowsNoProblem() async throws {
        let box = HangBox()
        let d = try CloudMacDevice(wrap: { fake in
            let hang = HangingSubmitGateway(fake)
            box.gateway = hang
            return CloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try hangGateway(box)
        hang.arm()
        try d.note("# edited while online\n")

        // The scheduler picks the edit up after its quiet time and the upload hangs: the tab is NOT locked (a scheduled cycle does not
        // set the person's "working" state), so Settings stays usable.
        #expect(await d.eventually(8) { hang.hasEntered }, "the debounced cycle started the upload")
        #expect(!hang.enteredOnMainThread)
        #expect(!d.controller.isWorking, "the Settings tab is not held by a background upload")

        let begun = Date()
        await d.controller.stopSyncing()
        #expect(Date().timeIntervalSince(begun) < 3, "stop returned in \(Date().timeIntervalSince(begun)) s")
        #expect(hang.cancelCount >= 1)
        #expect(d.controller.state == .off)
        #expect(!d.controller.isOn)
        try await Task.sleep(for: .milliseconds(200))   // the cancelled cycle ends after the stop
        #expect(d.controller.problem == nil, "a cycle cancelled by the person's own stop is not reported as a problem")
        #expect(d.controller.state == .off, "and it does not move the state to paused after the stop: \(d.controller.state)")
        await d.controller.shutdown()
    }

    // MARK: fix round 1 (Codex review of Task 15b)

    @Test func stopSyncingWorksWhileAHungManualSyncNowIsRunning() async throws {
        let box = HangBox()
        let d = try CloudMacDevice(wrap: { fake in
            let hang = HangingSubmitGateway(fake)
            box.gateway = hang
            return CloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try hangGateway(box)
        hang.arm()
        try d.note("# a manual sync that hangs\n")
        let syncing = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered })
        #expect(d.controller.isWorking, "the manual sync holds the tab's working state")

        let begun = Date()
        await d.controller.stopSyncing()
        #expect(Date().timeIntervalSince(begun) < 3, "stop returned in \(Date().timeIntervalSince(begun)) s")
        #expect(d.controller.state == .off, "state: \(d.controller.state)")
        #expect(!d.controller.isOn)
        _ = await syncing.value
        #expect(!d.controller.isWorking)
        try await Task.sleep(for: .milliseconds(200))
        #expect(d.controller.state == .off, "the cancelled cycle does not move the state after the stop: \(d.controller.state)")
        #expect(d.controller.problem == nil)
        await d.controller.shutdown()
    }

    @Test func shutdownWithASendThatNeverReturnsFinishesWithinTheDeadlineAndTheLateResultChangesNothing() async throws {
        let box = HangBox()
        let d = try CloudMacDevice(wrap: { fake in
            let hang = HangingSubmitGateway(fake)
            box.gateway = hang
            return CloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try hangGateway(box)
        hang.armStuck()
        try d.note("# a send that never answers\n")
        let syncing = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered })

        let begun = Date()
        await d.controller.shutdown()                       // the test services use a 0.5 s drain timeout
        let took = Date().timeIntervalSince(begun)
        #expect(took < 3, "shutdown finished in \(took) s although the send never returns")
        #expect((try? d.store.isAccountFenced()) == true, "the stuck send's late writes are refused by the durable fence")

        hang.releaseStuck()                                 // the answer finally arrives
        _ = await syncing.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(d.controller.state == .off, "a late result does not move the state: \(d.controller.state)")
        #expect((try? d.store.isSwitchedOn()) == false)
    }

    @Test func syncSwitchesOnAgainAfterAStopAndSendsWhatWasEditedMeanwhile() async throws {
        let d = try CloudMacDevice()
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        await d.controller.stopSyncing()
        #expect((try? d.store.isAccountFenced()) == true, "a stop always leaves the durable fence closed (CK-R171)")
        let edited = try d.note("# edited while stopped\n")
        await d.controller.turnOn()                         // the normal way: the fence is lifted, one refetch
        if case .upToDate = d.controller.state {} else { Issue.record("expected upToDate, got \(d.controller.state)") }
        #expect((try? d.store.isAccountFenced()) == false)
        #expect(await d.cloud.recordNames.contains("e.note.\(edited.id)"))
        await d.controller.shutdown()
    }
}
