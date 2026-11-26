// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import UIKit
@testable import TheoNotesCore
@testable import BaerchenIOS

// Task 16 fix round 1: the background lifecycle. A cycle that the system takes the time back from is suspended
// through the coordinator (fence closed, cancelled and drained, generation bumped, switch stays on); the next foreground resumes.
// A push that launches the process fetches; registration does not wait for the launch; Stop does not requeue a refresh.

private final class HangBox: @unchecked Sendable { var gateway: MobileHangingSubmitGateway? }

@MainActor @Suite(.serialized) struct MobileCloudSyncBackgroundTests {
    private func isUpToDate(_ state: CloudSyncState) -> Bool { if case .upToDate = state { true } else { false } }

    /// A device whose gateway is one shared hanging gateway (also for a controller made later on the same library).
    private func hangingDevice(cloud: FakeCloudKitAccount = FakeCloudKitAccount(), keychain: InMemoryCloudKeychain = InMemoryCloudKeychain(),
                               timing: MobileCloudSyncScheduler.Timing = .init(), box: HangBox) throws -> MobileCloudDevice {
        try MobileCloudDevice(cloud: cloud, keychain: keychain, timing: timing, wrap: { fake in
            if box.gateway == nil { box.gateway = MobileHangingSubmitGateway(fake) }
            let hang = box.gateway!
            return MobileCloudSyncGatewayParts(gateway: hang, cancelOperations: { await hang.cancelOperations() })
        })
    }

    // MARK: 1. an expiring background refresh leaves nothing running

    @Test func anExpiringBackgroundRefreshSuspendsTheSyncAndLeavesNothingRunning() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# written before the system took the time back\n")

        let refresh = Task { await d.controller.backgroundRefresh() }
        #expect(await d.eventually { hang.hasEntered }, "the refresh started an upload")
        let before = try d.store.generation()
        refresh.cancel()                                        // what the system does when the background time is over
        #expect(await d.eventually(5) { d.controller.state == .paused }, "state: \(d.controller.state)")
        #expect(hang.cancelCount >= 1, "the cancellation reached the gateway through the fence, not only the Swift task")
        #expect((try? d.store.isAccountFenced()) == true, "the durable fence is closed")
        #expect((try d.store.generation()) > before, "the generation is bumped")
        #expect(d.controller.isOn && d.switchedOn, "unlike Stop the person's switch stays on")
        #expect(d.controller.suspendedForBackground)
        await hang.cancelOperations()                           // never leave a hung send behind, whatever the assertions said
        _ = await refresh.value
        #expect(d.controller.problem == nil, "an expired refresh is not a problem to show")
        await d.controller.shutdown()
    }

    @Test func aLateResultOfTheSuspendedCycleIsRefused() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.armStuck()                                         // a send that ignores every cancellation
        try d.note("# a send that never answers\n")
        let cycle = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered })

        let began = Date()
        await d.controller.backgroundTimeExpired()
        #expect(Date().timeIntervalSince(began) < 3, "suspension is bounded by the drain deadline (0.5 s in these tests)")
        #expect((try? d.store.isAccountFenced()) == true)
        let generation = try d.store.generation()
        hang.releaseStuck()                                     // the answer finally arrives, late
        _ = await cycle.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(hang.completedLate, "the stuck send really did complete after the suspension")
        #expect((try? d.store.isAccountFenced()) == true, "the late result did not reopen the fence")
        #expect((try d.store.generation()) == generation, "and moved nothing")
        #expect(d.controller.state == .paused, "state: \(d.controller.state)")
        #expect(d.controller.isOn)
        await d.controller.shutdown()
    }

    @Test func theNextForegroundLiftsTheFenceAndResumes() async throws {
        let d = try MobileCloudDevice(timing: .init(debounce: 5, interval: 600))
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        await d.controller.backgroundTimeExpired()
        #expect(await d.eventually { d.controller.state == .paused }, "state: \(d.controller.state)")
        #expect(d.controller.suspendedForBackground)
        let edited = try d.note("# edited while suspended\n")
        // nothing starts by itself: the timer would, a local change would; the suspended controller holds both
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(await d.cloud.recordNames.contains("e.note.\(edited.id)")), "a suspended sync sends nothing")

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await d.eventually(8) { self.isUpToDate(d.controller.state) }, "state: \(d.controller.state)")
        #expect(!d.controller.suspendedForBackground)
        #expect((try? d.store.isAccountFenced()) == false, "the fence was lifted")
        #expect(d.switchedOn)
        #expect(await d.cloud.recordNames.contains("e.note.\(edited.id)"), "what was edited meanwhile was sent")
        await d.controller.shutdown()
    }

    @Test func aBackgroundRefreshAfterASuspensionResumes() async throws {
        let d = try MobileCloudDevice()
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        await d.controller.backgroundTimeExpired()
        let edited = try d.note("# edited, then a refresh\n")
        await d.controller.backgroundRefresh()
        #expect(isUpToDate(d.controller.state), "state: \(d.controller.state)")
        #expect(await d.cloud.recordNames.contains("e.note.\(edited.id)"))
        await d.controller.shutdown()
    }

    @Test func theGraceExpiryHandlerIsTheSamePath() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# in flight\n")
        // a cycle the scheduler runs holds the grace; the system takes it back
        let cycle = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered })
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await d.eventually { d.controller.holdsBackgroundGrace }, "backgrounding with a running cycle holds the background time")
        d.controller.expireBackgroundGrace()
        #expect(await d.eventually(5) { d.controller.state == .paused }, "state: \(d.controller.state)")
        #expect(hang.cancelCount >= 1)
        #expect((try? d.store.isAccountFenced()) == true)
        #expect(d.controller.isOn)
        #expect(!d.controller.holdsBackgroundGrace, "the assertion is ended at once, as the system demands")
        await hang.cancelOperations()
        _ = await cycle.value
        await d.controller.shutdown()
    }

    // MARK: 2. backgrounding lets a running cycle finish, and suspends it if it outlives the grace

    @Test func backgroundingWhileACycleRunsHoldsTheGraceAndReleasesItWhenTheCycleEnds() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# running while the app is backgrounded\n")
        let cycle = Task { await d.controller.syncNow() }
        #expect(await d.eventually { hang.hasEntered })
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await d.eventually { d.controller.holdsBackgroundGrace })
        #expect(!d.controller.suspendedForBackground, "inside the grace the cycle is left to finish")
        await hang.cancelOperations()                           // the cycle ends by itself (here: the upload gives up)
        _ = await cycle.value
        #expect(await d.eventually(5) { !d.controller.holdsBackgroundGrace }, "the grace is released when the cycle has ended")
        #expect(!d.controller.suspendedForBackground)
        await d.controller.shutdown()
    }

    @Test func backgroundingWithNothingRunningRequestsARefreshAndHoldsNothing() async throws {
        let d = try MobileCloudDevice()
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let before = d.system.scheduleCount
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await d.eventually { d.system.scheduleCount > before })
        #expect(!d.controller.holdsBackgroundGrace)
        await d.controller.shutdown()
    }

    // MARK: round 2

    @Test func anExpiryDuringAColdStartLeavesNothingRunning() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        let cold = try await d.relaunchedController()
        let cancelsBefore = hang.cancelCount
        hang.armPrepare()                                       // the cold start hangs in its launch cycle
        let refresh = Task { await cold.backgroundRefresh() }   // a BGAppRefresh that starts the controller itself
        #expect(await d.eventually { hang.prepareEntered > 0 }, "the cold start is on its way")
        refresh.cancel()                                        // the system takes the time back during `start()`
        #expect(await d.eventually(5) { cold.state == .paused }, "state: \(cold.state)")
        #expect(hang.cancelCount > cancelsBefore, "the cancellation reached the gateway")
        #expect((try? d.store.isAccountFenced()) == true)
        #expect(cold.isOn && d.switchedOn, "the switch stays on")
        #expect(cold.suspendedForBackground)
        await hang.cancelOperations()
        _ = await refresh.value
        #expect(!cold.launchInFlight)
        let fetches = hang.fetchCalls
        try await Task.sleep(for: .milliseconds(300))
        #expect(hang.fetchCalls == fetches, "nothing runs on after the expiry")
        await cold.shutdown()
    }

    @Test func anExpiryBeforeTheColdStartCanBeginDoesNotLetItRunOn() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        let cold = try await d.relaunchedController()
        let fetches = hang.fetchCalls
        let refresh = Task { await cold.backgroundRefresh() }
        refresh.cancel()                                        // cancelled before the controller even exists as a coordinator
        _ = await refresh.value
        #expect(await d.eventually(5) { cold.state == .paused }, "state: \(cold.state)")
        #expect((try? d.store.isAccountFenced()) == true, "the fence is closed although no session existed")
        #expect(cold.isOn && d.switchedOn)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hang.fetchCalls == fetches, "the start did not fetch")
        // the next foreground resumes
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await d.eventually(8) { self.isUpToDate(cold.state) }, "state: \(cold.state)")
        #expect((try? d.store.isAccountFenced()) == false)
        await cold.shutdown()
    }

    @Test func aHungLaunchThenBackgroundEndsInSuspension() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        let cold = try await d.relaunchedController()
        let cancelsBefore = hang.cancelCount
        hang.armPrepare()
        let launching = Task { await cold.start() }
        #expect(await d.eventually { hang.prepareEntered > 0 }, "the launch hangs")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await d.eventually { cold.holdsBackgroundGrace }, "the observer was installed before the launch: the hung launch holds the background time")
        cold.expireBackgroundGrace()
        #expect(await d.eventually(5) { cold.state == .paused }, "state: \(cold.state)")
        #expect((try? d.store.isAccountFenced()) == true)
        #expect(cold.isOn && d.switchedOn)
        #expect(hang.cancelCount > cancelsBefore)
        await hang.cancelOperations()
        _ = await launching.value
        await cold.shutdown()
    }

    // MARK: 3. a push that launches the process fetches

    @Test func aPushThatLaunchesTheProcessStartsTheControllerFromThePersistedSwitchAndFetches() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let first = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        let second = try MobileCloudDevice(cloud: cloud, keychain: keychain)
        defer { first.cleanup(); second.cleanup() }
        try await first.turnOnAndSkip()
        await second.controller.turnOn()
        #expect(isUpToDate(second.controller.state), "state: \(second.controller.state)")
        let note = try first.note("# written while the second device's app was not running\n")
        await first.controller.syncNow()

        // The process of the second device is gone; a silent push starts it. No view exists, `start()` was never called.
        let cold = try await second.relaunchedController()
        #expect(cold.isOn, "the persisted switch is read without a view")
        #expect(!cold.launchInFlight && second.text(of: note.id) == nil)
        MobileCloudSyncRouter.connect(cold)
        defer { MobileCloudSyncRouter.connect(nil) }
        let result = await MobileCloudSyncRouter.handle(["ck": 1])
        #expect(result == .newData, "the push is not dropped")
        #expect(second.text(of: note.id) == "# written while the second device's app was not running\n", "and it fetched")
        #expect(cold.registeredForPush)
        await cold.shutdown(); await first.controller.shutdown()
    }

    @Test func aPushForAnOffLibraryStaysADropAndStartsNothing() async throws {
        let d = try MobileCloudDevice()
        defer { d.cleanup() }
        MobileCloudSyncRouter.connect(d.controller)
        defer { MobileCloudSyncRouter.connect(nil) }
        #expect(await MobileCloudSyncRouter.handle(["ck": 1]) == .noData)
        #expect(d.touched.value == 0 && d.system.registerCount == 0)
    }

    // MARK: 4. registration does not wait for the launch

    @Test func aHungLaunchStillRegistersForPush() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        let cold = try await d.relaunchedController()
        hang.armPrepare()                                       // the launch cycle hangs
        let registered = d.system.registerCount
        let launching = Task { await cold.start() }
        #expect(await d.eventually { d.system.registerCount == registered + 1 }, "registered while the launch is still hanging")
        #expect(cold.launchInFlight, "the launch has not finished")
        await hang.cancelOperations()
        await cold.shutdown()
        _ = await launching.value
    }

    @Test func aLibraryThatIsOffNeverRegistersAtStart() async throws {
        let d = try MobileCloudDevice()
        defer { d.cleanup() }
        await d.controller.start()
        #expect(d.system.registerCount == 0)
        let unavailable = try MobileCloudDevice(flag: false)
        defer { unavailable.cleanup() }
        await unavailable.controller.start()
        #expect(unavailable.system.registerCount == 0)
    }

    // MARK: 5. Stop does not requeue background work

    @Test func stopDuringARunningRefreshSchedulesNothingNewAndWithdrawsThePendingRequest() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# a refresh is running\n")
        let refresh = Task { await d.controller.backgroundRefresh() }
        #expect(await d.eventually { hang.hasEntered })
        let scheduled = d.system.scheduleCount
        let cancelled = d.system.cancelCount
        await d.controller.stopSyncing()
        _ = await refresh.value
        #expect(d.system.scheduleCount == scheduled, "the refresh that was running through the Stop did not ask for the next one")
        #expect(d.system.cancelCount > cancelled, "the pending CloudKit request was withdrawn")
        #expect(d.system.restoreCount >= 1, "and the private-server sync was asked to request its own again")
        #expect(!d.controller.isOn)
        // a refresh of a library that is off does nothing and schedules nothing
        await d.controller.backgroundRefresh()
        #expect(d.system.scheduleCount == scheduled)
    }

    @Test func aRefreshThatStartedBeforeTheControllerClosedDoesNotScheduleAfterwards() async throws {
        let box = HangBox()
        let d = try hangingDevice(box: box)
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let hang = try #require(box.gateway)
        hang.arm()
        try d.note("# a refresh is running\n")
        let refresh = Task { await d.controller.backgroundRefresh() }
        #expect(await d.eventually { hang.hasEntered })
        let scheduled = d.system.scheduleCount
        await d.controller.shutdown()
        _ = await refresh.value
        #expect(d.system.scheduleCount == scheduled)
    }
}
