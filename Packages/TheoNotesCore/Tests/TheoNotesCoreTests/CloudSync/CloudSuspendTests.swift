// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

// Task 16 fix round 1: `suspend()` stops what runs and closes the fence like a stop, but the person's switch stays ON and the next
// foreground / launch / background refresh lifts the fence and goes on.

@Suite(.serialized) struct CloudSuspendTests {
    @Test func suspendKeepsTheSwitchOnClosesTheFenceBumpsTheGenerationAndStartsNothingByItself() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            #expect(try a.store.isSwitchedOn())
            let before = try a.store.generation()
            await a.coordinator.suspend()
            #expect(try a.store.isSwitchedOn(), "the switch stays on")
            #expect(try a.store.isAccountFenced(), "the durable fence is closed")
            #expect(try a.store.generation() > before, "the generation is bumped, so a late result of the suspended cycle is refused")
            #expect(await a.coordinator.currentState == .paused)
            // nothing starts by itself while suspended: a change event and an edit
            let calls = a.gateway.callCount
            await a.fake.pushRemoteChange()
            try a.edit(note.id, "# One edited\n")
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(a.gateway.callCount == calls, "a suspended coordinator runs no cycle on an event")
            #expect(await world.cloud.record(named: "e.note.\(note.id)") != nil)
        }
    }

    @Test func theNextCycleLiftsTheFenceAndSendsWhatWasEditedMeanwhile() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let note = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            await a.coordinator.suspend()
            try a.edit(note.id, "# Edited while suspended\n")
            let state = try await a.coordinator.foreground()
            if case .upToDate = state {} else { Issue.record("expected upToDate, got \(state)") }
            let fenced = try a.store.isAccountFenced(), on = try a.store.isSwitchedOn()
            #expect(!fenced && on)
            #expect(await world.cloud.record(named: "e.note.\(note.id)") != nil)
            // and events work again
            let calls = a.gateway.callCount
            await a.fake.pushRemoteChange()
            #expect(try await eventually { a.gateway.callCount > calls })
            await a.coordinator.disable()
        }
    }

    @Test func suspendOfASwitchedOffCoordinatorDoesNothing() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            await a.coordinator.suspend()
            let fenced = try a.store.isAccountFenced(), on = try a.store.isSwitchedOn()
            #expect(!fenced && !on)
            #expect(a.gateway.callCount == 0)
        }
    }

    // MARK: round 2

    /// `prepare()` holds until it is released (the launch cycle of a device that is offline).
    final class HoldPrepareGateway: CloudKitGateway, @unchecked Sendable {
        let inner: CoordGateway
        private let lock = NSLock()
        private var entered = false, released = false
        /// Hold `accountState()` instead of `prepare()` (the read that decides whether the fence may be lifted).
        var holdsAccountState = false
        nonisolated let events: AsyncStream<CloudGatewayEvent>
        init(_ inner: CoordGateway) { self.inner = inner; events = inner.events }
        var hasEntered: Bool { lock.withLock { entered } }
        func release() { lock.withLock { released = true } }
        func prepare() async throws -> CloudAccountState {
            lock.withLock { entered = true }
            while !lock.withLock({ released }), !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return try await inner.prepare()
        }
        func accountState() async -> CloudAccountState {
            if holdsAccountState {
                lock.withLock { entered = true }
                while !lock.withLock({ released }) { try? await Task.sleep(nanoseconds: 5_000_000) }
            }
            return await inner.accountState()
        }
        func submit(_ saves: [CloudSave]) async throws { try await inner.submit(saves) }
        func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
        func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { try await inner.fetch(names, keys: keys) }
        func delete(_ names: [String]) async throws { try await inner.delete(names) }
        func deleteZone() async throws { try await inner.deleteZone() }
        func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
    }

    @Test func aSuspendBeforeTheSessionExistsClosesTheFenceAndTheStartDoesNotRunOn() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            await a.coordinator.disable()
            // the process was killed with the switch on: the persisted flags are on, no coordinator has a session
            try a.store.setSwitchedOn(true)
            _ = try a.store.enableUploads()
            let before = a.gateway.calls.count
            let hold = HoldPrepareGateway(a.gateway)
            let cold = a.makeCoordinator(gateway: hold, drainTimeout: 0.5)
            let launching = Task { try await cold.launch() }
            #expect(try await eventually { hold.hasEntered }, "the cold launch is on its way and has no session yet")
            let began = Date()
            await cold.suspend()
            #expect(Date().timeIntervalSince(began) < 3, "bounded")
            let fenced = try a.store.isAccountFenced(), on = try a.store.isSwitchedOn()
            #expect(fenced && on, "the fence is closed and the switch stays on, although no session existed")
            hold.release()
            _ = try? await launching.value
            try await Task.sleep(nanoseconds: 200_000_000)
            let after = Array(a.gateway.calls.dropFirst(before))
            #expect(!after.contains("fetchChanges") && !after.contains("submit"), "the start did not run on: \(after)")
            #expect(try a.store.isAccountFenced(), "and nothing lifted the fence")
            #expect(await cold.currentState == .paused)
            // the next launch is the resume
            let state = try await cold.launch()
            if case .upToDate = state {} else { Issue.record("expected upToDate, got \(state)") }
            #expect(try a.store.isAccountFenced() == false)
            await cold.disable()
        }
    }

    @Test func aSuspendThatLandsWhileTheAccountIsBeingReadIsNotUndoneByTheLift() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            try await a.enable()
            await a.coordinator.disable()
            try a.store.setSwitchedOn(true)
            _ = try a.store.enableUploads()
            let before = a.gateway.calls.count
            let hold = HoldPrepareGateway(a.gateway)
            hold.holdsAccountState = true
            let cold = a.makeCoordinator(gateway: hold, drainTimeout: 0.3)
            let launching = Task { try await cold.launch() }
            #expect(try await eventually { hold.hasEntered }, "the launch is reading the account")
            await cold.suspend()                                // retires the waiting launch after the deadline
            hold.release()                                      // the account answers after the suspension
            _ = try? await launching.value
            try await Task.sleep(nanoseconds: 200_000_000)
            let fenced = try a.store.isAccountFenced()
            #expect(fenced, "the lift did not undo the suspension")
            let after = Array(a.gateway.calls.dropFirst(before))
            #expect(!after.contains("prepare") && !after.contains("fetchChanges") && !after.contains("submit"), "nothing ran on: \(after)")
            #expect(await cold.currentState == .paused)
            await cold.disable()
        }
    }

    @Test func aSlowSuspendNeverOverwritesAStopThatFinishedFirst() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            _ = try a.noteStore.create(text: "# One\n")
            let calls = LockedBox<Int>(0)
            let hooks = a.hooks, clock = a.clockValue
            // the first cancellation (the suspend's) is slow, the second (the stop's) is quick: the stop finishes first
            let coordinator = CloudSyncCoordinator(
                library: a, gateway: a.gateway, seeds: a.seedStore, configuration: coordConfiguration, blobs: a.blobSettings,
                clock: { clock.value }, checkpoint: { await hooks.pass($0) }, drainTimeout: 5,
                cancelOperations: {
                    calls.update { $0 += 1 }
                    let n = calls.value
                    try? await Task.sleep(nanoseconds: n == 1 ? 600_000_000 : 10_000_000)
                })
            try await a.enable(using: coordinator)
            let suspending = Task { await coordinator.suspend() }
            try await Task.sleep(nanoseconds: 100_000_000)
            let stopping = Task { await coordinator.disable() }
            await stopping.value
            #expect(await coordinator.currentState == .off)
            await suspending.value
            #expect(await coordinator.currentState == .off, "the slower suspend did not overwrite the stop")
            let on = try a.store.isSwitchedOn()
            #expect(!on)
            // and the other order: a suspend after a finished stop does nothing
            await coordinator.suspend()
            #expect(await coordinator.currentState == .off)
        }
    }
}

