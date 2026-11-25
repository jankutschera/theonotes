// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The first sync killed at every boundary and started again from what is on disk (`CrashPoint`): the old coordinator is gone (its
/// owner lock with it), a new one is made over the same library, the same fake cloud and the same keychain, and the person's
/// switch is still on, so `enable()` is called again. After every interruption: no duplicate, no loss, equal counts and equal
/// content hashes on both devices, nothing left in flight.
@Suite(.serialized) struct CloudInterruptionTests {
    struct Boundary: Sendable, CustomTestStringConvertible {
        let name: String
        let afterHits: Int
        var testDescription: String { afterHits == 0 ? name : "\(name) #\(afterHits + 1)" }
        init(_ name: String, _ afterHits: Int = 0) { self.name = name; self.afterHits = afterHits }
    }

    static func library(_ device: CoordDevice, notes: Int, prefix: String = "Note") throws -> [String] {
        try (0..<notes).map { index in try device.noteStore.create(text: "# \(prefix) \(index)\nbody \(index) #interrupt\n").id }
    }

    /// Everything that must hold once both devices are done.
    static func expectIntact(_ world: CoordWorld, notes ids: [String], context: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let first = try world.devices[0].fingerprint()
        for device in world.devices {
            #expect(try device.fingerprint() == first, "\(context): \(device.name) differs", sourceLocation: sourceLocation)
            let count = try device.count("note")
            #expect(count == ids.count, "\(context): \(device.name) has \(count) notes, expected \(ids.count)", sourceLocation: sourceLocation)
            #expect(try device.conflictCopies() == 0, "\(context): conflict copy on \(device.name)", sourceLocation: sourceLocation)
            #expect(try device.count("ck_inflight") == 0 && device.count("ck_remote") == 0 && device.count("ck_missing") == 0,
                    "\(context): work left on \(device.name)", sourceLocation: sourceLocation)
            #expect(try device.dirty().isEmpty, "\(context): \(device.name) still has unsent edits", sourceLocation: sourceLocation)
            #expect(Set(try device.visibleTitles()).count == ids.count || ids.isEmpty, "\(context): duplicate titles on \(device.name)", sourceLocation: sourceLocation)
        }
        let names = await world.cloud.recordNames.filter { $0.hasPrefix("e.note.") }
        #expect(Set(names) == Set(ids.map { "e.note.\($0)" }), "\(context): the cloud holds \(names.count) note records for \(ids.count) notes", sourceLocation: sourceLocation)
    }

    // MARK: the uploading device is killed

    static let uploaderBoundaries: [Boundary] = [
        Boundary("firstRun.afterBackup"), Boundary("firstRun.afterConfigure"), Boundary("firstRun.afterKeyCreation"),
        Boundary("keys.afterProbe"), Boundary("keys.afterPending"), Boundary("keys.afterSeed"), Boundary("keys.afterBundleWritten"),
        Boundary("keys.afterBundle"), Boundary("keys.afterRecoveryState"), Boundary("keys.afterPendingCleared"),
        Boundary("firstRun.afterKeys"), Boundary("firstRun.afterDownload"), Boundary("firstRun.afterEnable"), Boundary("firstRun.afterCleanup"),
        Boundary("publisher.afterPrepare", 3), Boundary("publisher.afterSending", 3), Boundary("publisher.afterSubmit"),
        Boundary("publisher.afterResultStored", 2), Boundary("publisher.afterRecordSaved", 2), Boundary("afterSend"),
    ]

    @Test(arguments: uploaderBoundaries)
    func theUploadingDeviceKilledAtABoundaryRestartsWithoutDuplicatesOrLoss(boundary: Boundary) async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let ids = try Self.library(a, notes: 12)
        let crash = CrashPoint()
        // `afterSend` belongs to the fake cloud connection, every other boundary to the coordinator and the code it drives
        let armed = boundary.name == "afterSend" ? a.fakeCrash : crash
        armed.arm(boundary.name, afterHits: boundary.afterHits)
        await #expect(throws: CrashInjected(boundary: boundary.name)) { _ = try await a.enable(using: a.makeCoordinator(crash: crash)) }
        // the process is gone; the switch is still on, so the app calls enable again
        try await a.enable(using: a.makeCoordinator())
        try await b.enable()
        try await world.converge()
        try await Self.expectIntact(world, notes: ids, context: boundary.testDescription)
    }

    @Test func killedBeforeAndAfterEachOfThreeUploadBatches() async throws {
        for (name, hit) in [("cycle.beforeUpload", 0), ("cycle.beforeUpload", 1), ("cycle.beforeUpload", 2),
                            ("cycle.afterUpload", 0), ("cycle.afterUpload", 1), ("cycle.afterUpload", 2)] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let ids = try Self.library(a, notes: 230)             // three batches: 100, 100, 30
            let crash = CrashPoint()
            crash.arm(name, afterHits: hit)
            await #expect(throws: CrashInjected(boundary: name)) { _ = try await a.enable(using: a.makeCoordinator(crash: crash)) }
            let landed = await world.cloud.recordNames.filter { $0.hasPrefix("e.note.") }.count
            #expect(landed <= ids.count)
            try await a.enable(using: a.makeCoordinator())
            try await b.enable()
            try await world.converge()
            try await Self.expectIntact(world, notes: ids, context: "\(name) #\(hit + 1) (\(landed) landed before the restart)")
        }
    }

    // MARK: the downloading device is killed

    static let downloaderBoundaries: [Boundary] = [
        Boundary("sink.beforeRecord", 2), Boundary("sink.afterRecord", 2), Boundary("sink.beforeStateSave"), Boundary("sink.afterPin"),
        Boundary("applier.afterLibraryWrite", 3), Boundary("applier.afterNote", 3), Boundary("cycle.afterFetch"), Boundary("cycle.afterApply"),
        Boundary("firstRun.afterBackup"), Boundary("firstRun.afterConfigure"), Boundary("firstRun.afterDownload"), Boundary("firstRun.afterEnable"),
        Boundary("firstRun.afterCleanup"),
    ]

    @Test(arguments: downloaderBoundaries)
    func theDownloadingDeviceKilledAtABoundaryRestartsWithoutDuplicatesOrLoss(boundary: Boundary) async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let ids = try Self.library(a, notes: 12)
        // B has two notes of its own (so the merge and the markers have something to say), A the other twelve
        let own = try Self.library(b, notes: 2, prefix: "Own")
        try await a.enable()
        let crash = CrashPoint()
        crash.arm(boundary.name, afterHits: boundary.afterHits)
        await #expect(throws: CrashInjected(boundary: boundary.name)) { _ = try await b.enable(using: b.makeCoordinator(crash: crash)) }
        try await b.enable(using: b.makeCoordinator())
        try await world.converge()
        try await Self.expectIntact(world, notes: ids + own, context: boundary.testDescription)
    }

    // MARK: blobs

    @Test func killedInTheMiddleOfABlobPartRestartsAndTheFileArrivesWhole() async throws {
        for (name, hit, onDownloader) in [("blob.beforePart", 1, false), ("blob.afterPartSaved", 0, false), ("blob.afterPartSaved", 1, false),
                                          ("blob.afterDownloadedPart", 0, true), ("blob.afterDownloadedPart", 1, true)] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# Scan\n![Big](big.bin)\n")
            let bytes = Data((0..<(3 * blobMiB + 777)).map { UInt8(($0 &* 31 &+ ($0 >> 8)) % 251) })
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "big.bin", to: note.id)
            let crash = CrashPoint()
            crash.arm(name, afterHits: hit)
            if onDownloader {
                try await a.enable()
                await #expect(throws: CrashInjected(boundary: name)) { _ = try await b.enable(using: b.makeCoordinator(crash: crash)) }
                try await b.enable(using: b.makeCoordinator())
            } else {
                await #expect(throws: CrashInjected(boundary: name)) { _ = try await a.enable(using: a.makeCoordinator(crash: crash)) }
                try await a.enable(using: a.makeCoordinator())
                try await b.enable()
            }
            try await world.converge()
            try await Self.expectIntact(world, notes: [note.id], context: "\(name) #\(hit + 1)")
            let installed = b.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("big.bin")
            #expect(try Data(contentsOf: installed) == bytes, "\(name) #\(hit + 1): the file arrived whole")
            // the blob exists once: every part record once, none deleted
            let parts = await world.cloud.recordNames.filter { $0.hasPrefix("b.") }
            #expect(parts.count >= 3 && Set(parts).count == parts.count)
            #expect(a.gateway.deletes.isEmpty && b.gateway.deletes.isEmpty)
        }
    }

    // MARK: the account changes

    @Test func anAccountChangeDuringTheFirstRunUploadsNothingToTheNewAccountAndTheRunFinishesAfterTheReturn() async throws {
        for restartTheApp in [false, true] {
            let world = try CoordWorld.make(2); defer { world.cleanup() }
            let a = world.devices[0], b = world.devices[1]
            let ids = try Self.library(a, notes: 12)
            let other = FakeCloudKitAccount(user: "someone-else")
            let coordinator = a.makeCoordinator()
            // the person signs in to another iCloud account right after the first-run switched uploads on
            a.hooks.on("firstRun.afterEnable") { await a.fake.switchAccount(to: other) }
            let state = try await a.enable(using: coordinator)
            a.hooks.clear()
            #expect(state != .upToDate(lastSync: a.clockValue.value), "restart: \(restartTheApp)")
            let paused = try await coordinator.syncNow()
            if case .accountChanged = paused {} else { Issue.record("expected the account-changed state, got \(paused)") }
            #expect(await other.recordNames.isEmpty, "the other account received nothing")
            #expect(try a.dirty().isEmpty == false, "the library still has everything to send")
            // the original account returns
            await a.fake.signIn(user: world.cloud)
            if restartTheApp {
                // the app was quit meanwhile: the next launch finds the account again and the run goes on
                await coordinator.endAsIfTheProcessDied()
                #expect(try await a.makeCoordinator().launch() == .upToDate(lastSync: a.clockValue.value))
            } else {
                // the running engine takes the account event, lifts the fence and finishes the work
                let resumed = try await eventually(timeout: 10) { await world.cloud.recordNames.filter { $0.hasPrefix("e.note.") }.count == ids.count }
                let shown = await coordinator.currentState, fenced = try a.store.isAccountFenced(), stage = a.hooks.steps.suffix(6)
                #expect(resumed, "state \(shown), fenced \(fenced), last steps \(stage), calls \(a.gateway.calls.suffix(8))")
            }
            #expect(await other.recordNames.isEmpty)
            try await b.enable()
            try await world.converge()
            try await Self.expectIntact(world, notes: ids, context: "account change, restart: \(restartTheApp)")
        }
    }
}
