// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
import UIKit
@testable import TheoNotesCore
@testable import BaerchenIOS

/// When the iCloud sync runs a cycle on the iPhone: a settled local edit, the timer, coming to the front, going to the background,
/// retries, and never while off.
@MainActor @Suite(.serialized) struct MobileCloudSyncSchedulerTests {
    private final class Runs {
        var reasons: [MobileCloudSyncScheduler.Reason] = []
        var outcome: MobileCloudSyncScheduler.Outcome = .done
        var backgrounded = 0
    }

    private func library() throws -> (MobileLibrary, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudIOSSched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (try MobileLibrary(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true))), parent)
    }

    /// A local edit as the sync journal sees it: one dirty row (the triggers write exactly this once uploads are on).
    private func journal(_ library: MobileLibrary, _ id: String) async throws {
        try await library.database.pool.write {
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
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = MobileCloudSyncScheduler(database: library.database, timing: .init(debounce: 0.1, interval: 600)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        defer { scheduler.stop() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.reasons.isEmpty, "starting is not a reason to sync; the launch did that")
        for i in 0..<3 { try await journal(library, "n\(i)") }
        #expect(await wait { !runs.reasons.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.reasons == [.localChange], "three quick edits make one cycle: \(runs.reasons)")
    }

    @Test func theTimerRunsACycleAndSchedulesTheNext() async throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = MobileCloudSyncScheduler(database: library.database, timing: .init(debounce: 5, interval: 0.1)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        defer { scheduler.stop() }
        #expect(await wait { runs.reasons.count >= 3 }, "a timer every interval: \(runs.reasons)")
        #expect(Set(runs.reasons) == [.timer])
    }

    @Test func comingToTheFrontRunsACycleNow() async throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = MobileCloudSyncScheduler(database: library.database, timing: .init(debounce: 5, interval: 600)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        defer { scheduler.stop() }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await wait { runs.reasons == [.foreground] }, "\(runs.reasons)")
    }

    @Test func goingToTheBackgroundAsksForTheBackgroundRefresh() async throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = MobileCloudSyncScheduler(database: library.database, timing: .init(debounce: 5, interval: 600),
                                                 didEnterBackground: { runs.backgrounded += 1 }) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await wait { runs.backgrounded == 1 })
        scheduler.stop()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs.backgrounded == 1, "a stopped scheduler asks for nothing")
    }

    @Test func aFailureIsRetriedAfterAtLeastTheFloorAndAPersonWaitedForIsNotRetriedInALoop() async throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        runs.outcome = .retry(after: 0)
        let scheduler = MobileCloudSyncScheduler(database: library.database,
                                                 timing: .init(debounce: 5, interval: 0.05, retryFloor: 0.15, needsPersonInterval: 5)) { reason in
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
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        let scheduler = MobileCloudSyncScheduler(database: library.database, timing: .init(debounce: 0.05, interval: 0.05)) { reason in
            runs.reasons.append(reason); return .done
        }
        scheduler.start()
        #expect(await wait { !runs.reasons.isEmpty })
        scheduler.stop()
        let count = runs.reasons.count
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await journal(library, "after-stop")
        try await Task.sleep(for: .milliseconds(400))
        #expect(runs.reasons.count == count, "nothing runs after stop")
    }

    @Test func anOffControllerNeverMakesASchedulerAndAStopOutcomeEndsScheduling() async throws {
        let device = try MobileCloudDevice()
        defer { device.cleanup() }
        await device.controller.start()
        #expect(device.touched.value == 0)
        // An off library has no scheduler: editing it triggers no cycle and no use of the services.
        try await device.library.database.pool.write {
            try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES ('note','edit',1,0)")
        }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(device.touched.value == 0)
        #expect(device.system.scheduleCount == 0 && device.system.registerCount == 0)

        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let runs = Runs()
        runs.outcome = .stop
        let scheduler = MobileCloudSyncScheduler(database: library.database, timing: .init(debounce: 5, interval: 0.05)) { reason in
            runs.reasons.append(reason); return runs.outcome
        }
        scheduler.start()
        #expect(await wait { runs.reasons.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.reasons.count == 1)
    }

    @Test func aSwitchedOnControllerRunsTheForegroundAndLocalSaveTriggersAndAsksForTheBackgroundRefresh() async throws {
        let d = try MobileCloudDevice(timing: .init(debounce: 0.1, interval: 600))
        defer { d.cleanup() }
        try await d.turnOnAndSkip()
        let before = d.system.scheduleCount
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await wait { d.system.scheduleCount > before }, "going to the background requests a refresh")
        let note = try d.note("# saved locally\n")
        // the local-save trigger: the debounced cycle sends the note
        var names = await d.cloud.recordNames
        for _ in 0..<80 where !names.contains("e.note.\(note.id)") {
            try await Task.sleep(for: .milliseconds(100))
            names = await d.cloud.recordNames
        }
        #expect(names.contains("e.note.\(note.id)"), "a local save reached iCloud without any other trigger")
        await d.controller.shutdown()
    }
}
