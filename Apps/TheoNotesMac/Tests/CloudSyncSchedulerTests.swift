// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import Testing
@testable import TheoNotes

/// When the iCloud sync runs a cycle: a settled local edit, the timer, coming to the front, retries, and never while off.
@MainActor @Suite(.serialized) struct CloudSyncSchedulerTests {
    private final class Runs {
        var reasons: [CloudSyncScheduler.Reason] = []
        var outcome: CloudSyncScheduler.Outcome = .done
    }

    private func library() throws -> (AppEnvironment, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (try AppEnvironment(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true))), parent)
    }

    /// A local edit as the sync journal sees it: one dirty row (the triggers write exactly this once uploads are on).
    private func journal(_ environment: AppEnvironment, _ id: String) async throws {
        try await environment.database.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES ('note',?,1,0)", arguments: [id])
        }
    }

    private func wait(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aLocalEditRunsOneCycleAfterTheQuietTime() async throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = CloudSyncScheduler(database: environment.database, timing: .init(debounce: 0.1, interval: 600)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        defer { scheduler.stop() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.reasons.isEmpty, "starting is not a reason to sync; the launch did that")
        for i in 0..<3 { try await journal(environment, "n\(i)") }
        let dirty = try await environment.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") }
        #expect(dirty == 3, "the edits were journaled: \(String(describing: dirty))")
        #expect(await wait { !runs.reasons.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.reasons == [.localChange], "three quick edits make one cycle: \(runs.reasons)")
    }

    @Test func theTimerRunsACycleAndSchedulesTheNext() async throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = CloudSyncScheduler(database: environment.database, timing: .init(debounce: 5, interval: 0.1)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        defer { scheduler.stop() }
        #expect(await wait { runs.reasons.count >= 3 }, "a timer every interval: \(runs.reasons)")
        #expect(Set(runs.reasons) == [.timer])
    }

    @Test func comingToTheFrontRunsACycleNow() async throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = CloudSyncScheduler(database: environment.database, timing: .init(debounce: 5, interval: 600)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        defer { scheduler.stop() }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await wait { runs.reasons == [.foreground] }, "\(runs.reasons)")
    }

    @Test func aFailureIsRetriedAfterAtLeastTheFloorAndAPersonWaitedForIsNotRetriedInALoop() async throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        runs.outcome = .retry(after: 0)
        let scheduler = CloudSyncScheduler(database: environment.database, timing: .init(debounce: 5, interval: 0.05, retryFloor: 0.15, needsPersonInterval: 5)) { reason in
            runs.reasons.append(reason); return runs.outcome
        }
        scheduler.start()
        defer { scheduler.stop() }
        #expect(await wait { runs.reasons.count >= 2 })
        #expect(runs.reasons.dropFirst().first == .retry)
        runs.outcome = .needsPerson
        try await Task.sleep(for: .milliseconds(400))
        let count = runs.reasons.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(runs.reasons.count <= count + 1, "a state that needs the person is looked at slowly, not in a loop")
    }

    @Test func stoppingRemovesTheObserverTheTimerAndTheNotificationHandlers() async throws {
        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = CloudSyncScheduler(database: environment.database, timing: .init(debounce: 0.05, interval: 0.05)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        #expect(await wait { !runs.reasons.isEmpty })
        scheduler.stop()
        let count = runs.reasons.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await journal(environment, "after-stop")
        try await Task.sleep(for: .milliseconds(400))
        #expect(runs.reasons.count == count, "nothing runs after stop")
    }

    @Test func stopOutcomeEndsSchedulingAndAnOffControllerNeverMakesAScheduler() async throws {
        let device = try CloudMacDevice()
        defer { device.cleanup() }
        await device.controller.start()
        #expect(device.touched.value == 0)
        // An off library has no scheduler: editing it triggers no cycle and no use of the services.
        try await device.environment.database.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES ('note','edit',1,0)")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(device.touched.value == 0)

        let (environment, parent) = try library()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        runs.outcome = .stop
        let scheduler = CloudSyncScheduler(database: environment.database, timing: .init(debounce: 5, interval: 0.05)) { reason in
            runs.reasons.append(reason); return runs.outcome
        }
        scheduler.start()
        #expect(await wait { runs.reasons.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.reasons.count == 1)
    }
}
