// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Model-based test, publisher part (CK-R4, CK-R5): 2 to 4 devices of one person on one fake cloud, a seeded random schedule of
/// creates, edits, trashes, syncs, offline periods, crashes at the publisher's boundaries, lost responses (reported and silent),
/// and duplicated, reordered or token-expired fetches. After quiescence every library is equal, and every edit that was ever
/// acknowledged to the person (every token written into a note) is present in some note of every library (the note itself or a
/// conflict copy). The receiver is a notes-only stand-in; the receiver's own model test belongs to Task 6.
/// Seeds: `BAERCHEN_CONVERGENCE_SEEDS=<n>` (default 200; the nightly run uses 5,000).
/// The receiver is the real one (Task 6): sink, reconciler, applier, and the explicit recovery of a record deleted by hand. A failing seed is printed in the test name.
@Suite struct CloudSyncConvergenceModelTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static var seeds: [UInt64] {
        let count = ProcessInfo.processInfo.environment["BAERCHEN_CONVERGENCE_SEEDS"].flatMap(Int.init) ?? 200
        return (0..<count).map { UInt64($0) }
    }

    static let boundaries = ["publisher.afterPrepare", "publisher.afterSending", "publisher.afterSubmit", "afterSend",
                             "publisher.afterResultStored", "publisher.afterRecordSaved",
                             // the receiver (Task 6): the sink, the applier and the transaction that moves the base pair
                             "sink.beforeRecord", "sink.afterRecord", "sink.beforeStateSave", "applier.afterLibraryWrite", "applier.afterNote"]

    struct State: Equatable { var notes: [String]; var settings: [String]; var tags: [String]; var dirty: Int; var inflight: Int; var missing: Int }

    @Test(arguments: seeds)
    func devicesConvergeAndNoAcknowledgedEditIsLost(seed: UInt64) async throws { try await play(seed: seed) }

    /// Recovery-heavy schedules (fix round 1, C1): records deleted by hand up to three times and devices recovering at random
    /// moments, so lagging devices win races and clean devices meet older recovered content. No acknowledged edit may be lost.
    static var recoverySeeds: [UInt64] {
        let count = ProcessInfo.processInfo.environment["BAERCHEN_RECOVERY_SEEDS"].flatMap(Int.init) ?? 100
        return (0..<count).map { UInt64(5_000 + $0) }
    }

    @Test(arguments: recoverySeeds)
    func noAcknowledgedEditIsEverLostAcrossRecovery(seed: UInt64) async throws { try await play(seed: seed, heavy: true) }

    @Test func theScheduleReachesTheInterestingPaths() async throws {
        for seed in 1_000..<1_040 { try await play(seed: UInt64(seed)) }
        let counters = ModelCounters.shared
        for key in ["merge", "requeued", "crash", "lostResponse", "conflictCopy", "saved", "removedByHand", "recovered"] {
            #expect(counters.value(key) > 0, "the schedules never reached \(key)")
        }
    }

    func play(seed: UInt64, heavy: Bool = false) async throws {
        var rng = SplitMix64(state: seed &* 7919 &+ 13)
        let count = Int.random(in: 2...4, using: &rng)
        let crash = CrashPoint()
        let world = try await PublisherWorld.make(count, crash: crash); defer { world.cleanup() }
        var tokens: [String] = []
        var removedByHand = 0
        var log: [String] = ["seed \(seed), \(count) devices"]
        func device() -> PublisherDevice { world.devices[Int.random(in: 0..<count, using: &rng)] }

        func run(_ d: PublisherDevice, _ work: () async throws -> Void) async throws {
            do { try await work() }
            catch is CloudSyncError { log.append("\(d.name): offline") }
            catch is CrashInjected { ModelCounters.shared.bump("crash"); log.append("\(d.name): crashed"); d.restart(crash: crash); try d.publisher.treatSendingAsUnknown() }
        }

        for step in 0..<40 {
            let d = device()
            if heavy {
                let roll = Int.random(in: 0..<100, using: &rng)
                if roll < 10 {
                    let names = await world.account.recordNames.filter { $0.hasPrefix("e.note.") }
                    if removedByHand < 3, let name = names.randomElement(using: &rng) {
                        removedByHand += 1
                        await world.account.removeRecord(name)
                        ModelCounters.shared.bump("removedByHand")
                        log.append("record \(name) removed by hand")
                    }
                    continue
                }
                if roll < 24 {
                    // the person presses "Upload them again" on this device, whatever it has seen so far
                    var prepared = 0
                    for (_, outcome) in try d.incarnation.recoverAll() { if case .prepared = outcome { prepared += 1 } }
                    if prepared > 0 { ModelCounters.shared.bump("recovered") }
                    log.append("\(d.name): recover \(prepared)")
                    if Bool.random(using: &rng) { try await run(d) { try await d.sync(rounds: 2) } }
                    continue
                }
            }
            switch Int.random(in: 0..<112, using: &rng) {
            case 100..<104:
                let key = ["hideMarkdown", "showNoteCounts", "autoSortTodos"].randomElement(using: &rng)!
                let value = Bool.random(using: &rng) ? "true" : "false"
                try d.sql("INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
                log.append("\(d.name): setting \(key)=\(value)")
            case 104..<108:
                guard let note = try d.notes().filter({ $0.location == .notes }).randomElement(using: &rng) else { continue }
                let tag = "tag\(Int.random(in: 0..<3, using: &rng))"
                tokens.append("tok-\(seed)-\(step)")
                try d.edit(note.id, note.text + "#\(tag) tok-\(seed)-\(step)\n")
                // Tag preferences (icon, pin) are covered by the applier tests: the model keeps tags to their text, because a tag row
                // that leaves every note and comes back is a new local row, and what the reused capture does then is not the receiver's.
                log.append("\(d.name): tag \(tag) in \(note.id)")
            case 108..<110:
                // The record is deleted by hand (Console, another tool). At most once per run.
                let names = await world.account.recordNames.filter { $0.hasPrefix("e.note.") }
                guard removedByHand == 0, let name = names.randomElement(using: &rng) else { continue }
                removedByHand += 1
                await world.account.removeRecord(name)
                ModelCounters.shared.bump("removedByHand")
                log.append("record \(name) removed by hand")
            case 110..<112:
                if Bool.random(using: &rng) { await d.gateway.expireTokenNextFetch() } else { await d.gateway.redeliverBatch() }
                log.append("\(d.name): full refetch or redelivery")
                try await run(d) { try await d.sync(rounds: 2) }
            case 0..<18:
                let token = "tok-\(seed)-\(step)"
                tokens.append(token)
                let note = try d.noteStore.create(text: "# Note \(step)\n\(token)\n")
                log.append("\(d.name): create \(note.id) \(token)")
            case 18..<48:
                let mine = try d.notes().filter { $0.location == .notes }
                guard let note = mine.randomElement(using: &rng) else { continue }
                let token = "tok-\(seed)-\(step)"
                tokens.append(token)
                try d.edit(note.id, note.text + token + "\n")
                log.append("\(d.name): edit \(note.id) \(token)")
            case 48..<54:
                let mine = try d.notes().filter { $0.location == .notes }
                guard let note = mine.randomElement(using: &rng) else { continue }
                try d.noteStore.trash([note.id])
                log.append("\(d.name): trash \(note.id)")
            case 54..<80:
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: await d.gateway.redeliverBatch()
                case 1: await d.gateway.reorderBatch(seed: rng.next())
                case 2: await d.gateway.expireTokenNextFetch()
                default: break
                }
                log.append("\(d.name): sync")
                try await run(d) { try await d.sync(rounds: Int.random(in: 1...2, using: &rng)) }
            case 80..<86:
                await d.gateway.loseNextResponseAfterCommit(report: Bool.random(using: &rng) ? .offline : .silence)
                ModelCounters.shared.bump("lostResponse")
                log.append("\(d.name): lose next response")
                try await run(d) { try await d.publish() }
            case 86..<91:
                await d.gateway.failNext(Bool.random(using: &rng) ? .offline : .unauthenticated)
                log.append("\(d.name): next operation fails")
                try await run(d) { try await d.sync(rounds: 1) }
            default:
                let boundary = Self.boundaries.randomElement(using: &rng)!
                crash.arm(boundary)
                log.append("\(d.name): crash at \(boundary)")
                try await run(d) { try await d.sync(rounds: 2) }
                crash.arm(boundary, afterHits: 1_000_000)      // never fires again if it was not reached
                try await d.gateway.sendPending()
            }
        }

        // Quiescence: the network is fine, every process restarted once, then rounds until nothing moves.
        var previous: [State] = []
        for round in 0..<40 {
            for d in world.devices {
                d.restart(crash: .never)
                try d.publisher.treatSendingAsUnknown()
                try await d.gateway.sendPending()
                if removedByHand > 0 { await d.gateway.expireTokenNextFetch() }
                try await d.sync(rounds: 3)
                // The person pressed "Upload them again" for what the cloud no longer returned.
                for (entity, outcome) in try d.incarnation.recoverAll() {
                    if case .prepared = outcome { ModelCounters.shared.bump("recovered"); log.append("\(d.name): recovered \(entity.recordName)") }
                }
            }
            let state = try world.devices.map { d in
                State(notes: try d.notes().map { "\($0.id)|\($0.location.rawValue)|\($0.text)" }.sorted(),
                      settings: try d.strings("SELECT key||'='||value FROM setting ORDER BY key"),
                      tags: try d.strings("SELECT pathKey||'|'||ifnull(iconName,'')||'|'||isPinned FROM tag WHERE iconName IS NOT NULL OR isPinned=1 ORDER BY pathKey"),
                      dirty: try d.dirtyCount(), inflight: try d.store.allInflight().count, missing: try d.store.allMissing().count)
            }
            if state == previous && state.allSatisfy({ $0.dirty == 0 && $0.inflight == 0 && $0.missing == 0 }) { log.append("quiet after \(round) rounds"); break }
            previous = state
        }

        // No ping-pong: once quiet, another full round of everything (restart, full refetch, sync) creates no new version in the
        // cloud, no new note (conflict copy) and no unpublished work on any device.
        var versions: [String: Int] = [:]
        for name in await world.account.recordNames { versions[name] = await world.account.versionCount(of: name) }
        let notesBefore = try world.devices.map { try $0.snapshot() }
        for d in world.devices {
            d.restart(crash: .never)
            try d.publisher.treatSendingAsUnknown()
            await d.gateway.expireTokenNextFetch()
            try await d.sync(rounds: 3)
        }
        var versionsAfter: [String: Int] = [:]
        for name in await world.account.recordNames { versionsAfter[name] = await world.account.versionCount(of: name) }
        var report = log.joined(separator: "\n")
        #expect(versionsAfter == versions, "a quiet system saved again\n\(report)")
        #expect(try world.devices.map { try $0.snapshot() } == notesBefore, "a quiet system changed a library (a new conflict copy?)\n\(report)")
        report += "\ncloud: \(await world.account.recordNames.count)"
        for d in world.devices where (try? d.store.allInflight().isEmpty) == false {
            do { report += "\n\(d.name) resolve: \(try await d.publisher.resolveAmbiguous())" } catch { report += "\n\(d.name) resolve threw \(error)" }
            for a in (try? d.store.allInflight()) ?? [] {
                let server = await world.account.record(named: a.entity.recordName)
                let shown = server.flatMap { try? decodedEntity($0) }.map { "inc=\($0.inc.prefix(4)) ver=\($0.ver) sid=\($0.sid.suffix(4)) sids=\($0.sids.map { String($0.suffix(4)) })" } ?? "absent"
                report += "\n  cloud record \(a.entity.recordName.suffix(4)): \(shown) vs attempt \(a.attemptId.suffix(4))"
                let pair = try? d.store.pair(for: a.entity)
                let header = server.flatMap { try? decodedEntity($0) }
                let decision = CloudOutcomeResolver.decide(attempt: a, pair: pair ?? nil, server: header, serverSystemFields: server?.systemFields)
                report += "\n  state=\(a.state) fenced=\((try? d.store.isFenced(entityType: a.entity.entityType, entityId: a.entity.entityId)) ?? false) pending=\((try? d.store.hasPendingRemote(a.entity)) ?? false) result=\(String(describing: try? d.store.sendResult(attemptId: a.attemptId))) decision=\(decision) pairInc=\(String(describing: (pair ?? nil)?.inc.prefix(4))) pairSup=\(String(describing: (pair ?? nil)?.supersededIncs.map { String($0.prefix(4)) })) attemptInc=\(a.inc.prefix(4))"
            }
        }
        for d in world.devices {
            let inflight = (try? d.store.allInflight().map { "\($0.entity.recordName) \($0.state.rawValue) inc=\($0.inc.prefix(4)) base=\($0.baseSystemFields != nil) gen=\($0.accountGeneration) att=\($0.attemptId.suffix(4)) ver=\($0.baseVer)" }) ?? []
            let remote = (try? d.store.allRemote().map { "\($0.recordName) v\($0.ver) inc=\($0.inc.prefix(4)) wait=\(String(describing: $0.waitingFor))" }) ?? []
            let missing = (try? d.store.allMissing().map { "\($0.entity.recordName)" }) ?? []
            let dirty = (try? d.strings("SELECT entityType||':'||localId||':'||generation FROM sync_dirty")) ?? []
            let pairs = (try? d.strings("SELECT entityType||':'||entityId||' v'||ver||' inc='||substr(inc,1,4) FROM ck_record")) ?? []
            let results = (try? d.strings("SELECT attemptId||' gen'||accountGeneration FROM ck_send_result")) ?? []
            report += "\n[\(d.name)] inflight=\(inflight) results=\(results) remote=\(remote) missing=\(missing) dirty=\(dirty) gen=\((try? d.store.generation()) ?? -1) fenced=\((try? d.store.isAccountFenced()) ?? false)"
        }
        for d in world.devices { if try d.rowCount("sync_conflict") > 0 { ModelCounters.shared.bump("conflictCopy") } }
        let first = try world.devices[0].notes().map { "\($0.id)|\($0.location.rawValue)|\($0.text)" }.sorted()
        let firstSettings = try world.devices[0].strings("SELECT key||'='||value FROM setting ORDER BY key")
        let firstTags = try world.devices[0].strings("SELECT pathKey||'|'||ifnull(iconName,'')||'|'||isPinned FROM tag WHERE iconName IS NOT NULL OR isPinned=1 ORDER BY pathKey")
        for d in world.devices {
            #expect(try d.strings("SELECT key||'='||value FROM setting ORDER BY key") == firstSettings, "settings differ, \(d.name)\n\(report)")
            #expect(try d.strings("SELECT pathKey||'|'||ifnull(iconName,'')||'|'||isPinned FROM tag WHERE iconName IS NOT NULL OR isPinned=1 ORDER BY pathKey") == firstTags, "tag preferences differ, \(d.name): \((try? d.strings("SELECT pathKey||'|'||ifnull(iconName,'')||'|'||isPinned FROM tag ORDER BY pathKey")) ?? []) vs \(firstTags) dirty \((try? d.strings("SELECT entityType||localId FROM sync_dirty")) ?? [])\n\(report)")
            #expect(try d.store.allMissing().isEmpty, "paused entities left on \(d.name)\n\(report)")
            #expect(try d.store.quarantineRows().isEmpty, "quarantine left on \(d.name): \((try? d.store.quarantineRows().map { "\($0.recordName) \($0.reason)" }) ?? [])\n\(report)")
            #expect(try d.notes().map { "\($0.id)|\($0.location.rawValue)|\($0.text)" }.sorted() == first, "libraries differ, \(d.name)\n\(report)")
            #expect(try d.dirtyCount() == 0, "dirty left on \(d.name)\n\(report)")
            #expect(try d.store.allInflight().isEmpty, "in-flight left on \(d.name)\n\(report)")
            #expect(try d.rowCount("ck_send_result") == 0 && d.rowCount("ck_remote") == 0, "results or fetched versions left on \(d.name)\n\(report)")
            let union = try d.notes().map(\.text).joined(separator: "\n")
            for token in tokens { #expect(union.contains(token), "\(token) lost on \(d.name)\n\(report)") }
        }
        // The cloud itself: versions advance by one per landed save, and every device's pair is the cloud's current version.
        for name in await world.account.recordNames where name.hasPrefix("e.note.") {
            let record = try #require(await world.account.record(named: name))
            #expect(Int(record.ver ?? 0) == (await world.account.versionCount(of: name)), "\(name) skipped or duplicated a version\n\(report)")
            let id = String(name.dropFirst("e.note.".count))
            for d in world.devices {
                let pair = try d.store.pair(for: d.ref(id))
                #expect(pair?.ver == record.ver && pair?.systemFields == record.systemFields, "\(d.name) pair differs from the cloud for \(name)\n\(report)")
            }
        }
    }
}
