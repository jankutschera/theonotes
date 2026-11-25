// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// The account decision (CK-R10), the person-visible states and words, and the zone lifecycle as the person sees it (CK-R15).
@Suite struct CloudAccountPolicyTests {
    // MARK: the decision

    static let decisions: [(String?, CloudAccountState, CloudAccountDecision)] = [
        (nil, .available(userHash: "A"), .firstBind),
        ("A", .available(userHash: "A"), .resume),
        ("A", .available(userHash: "B"), .pause(.accountChanged)),
        ("A", .noAccount, .pause(.signedOut)),
        (nil, .noAccount, .pause(.signedOut)),
        ("A", .restricted, .pause(.restricted)),
        ("A", .temporarilyUnavailable, .waitForAccount),
        ("A", .couldNotDetermine, .waitForAccount),
        (nil, .couldNotDetermine, .waitForAccount),
    ]

    @Test(arguments: decisions)
    func theDecisionForEveryAccountSituation(stored: String?, current: CloudAccountState, expected: CloudAccountDecision) {
        #expect(CloudAccountPolicy.evaluate(stored: stored, current: current) == expected)
    }

    @Test func aDifferentAccountNeverResumes() {
        for other in ["B", "", "a", "A "] {
            #expect(CloudAccountPolicy.evaluate(stored: "A", current: .available(userHash: other)) == .pause(.accountChanged))
        }
    }

    @Test func eachPauseHasItsOwnStateAndTheOtherDecisionsHaveNone() {
        #expect(CloudAccountPolicy.state(for: .pause(.accountChanged), stored: "A") == .accountChanged(previousHash: "A"))
        #expect(CloudAccountPolicy.state(for: .pause(.signedOut), stored: "A") == .signedOutOfICloud)
        #expect(CloudAccountPolicy.state(for: .pause(.restricted), stored: "A") == .restricted)
        #expect(CloudAccountPolicy.state(for: .waitForAccount, stored: "A") == .waitingForICloud)
        #expect(CloudAccountPolicy.state(for: .resume, stored: "A") == nil)
        #expect(CloudAccountPolicy.state(for: .firstBind, stored: nil) == nil)
    }

    // MARK: words

    static let everyState: [CloudSyncState] = [
        .off, .notAvailableInThisBuild, .signedOutOfICloud, .restricted, .waitingForICloud, .waitingForKeychain, .keychainUnavailable,
        .needsRecoveryKey, .recoveryNotSaved, .needsNotePassword, .accountChanged(previousHash: "abc"),
        .zoneRemoved(reason: .deleted), .zoneRemoved(reason: .userDeletedZone), .zoneRemoved(reason: .purged), .zoneRemoved(reason: .encryptedDataReset),
        .itemsMissingInCloud(count: 1), .itemsMissingInCloud(count: 7), .quotaFull, .offline(retryAt: nil), .offline(retryAt: Date(timeIntervalSince1970: 5)),
        .syncing, .upToDate(lastSync: nil), .upToDate(lastSync: Date(timeIntervalSince1970: 5)), .paused, .needsAppUpdate,
        .itemsUnreadable(count: 1), .itemsUnreadable(count: 4), .failed(kind: "zoneNotFound"), .failed(kind: "CKErrorDomain 12 record token"),
    ]

    @Test func noMessageUsesInternalVocabulary() {
        for state in Self.everyState {
            let text = CloudSyncState.message(for: state)
            #expect(!text.isEmpty, "\(state)")
            #expect(text == state.message)
            for word in ["cloudkit", "zone", "record", "token", "quarantine", "adhd", "adhs"] {
                #expect(!text.lowercased().contains(word), "\"\(text)\" contains \"\(word)\" (\(state))")
            }
            #expect(text.hasSuffix("."), "\(state)")
            #expect(text.split(separator: ".").count <= 2, "one or two short sentences: \(text)")
        }
    }

    @Test func restrictedAndNoAccountAreDistinctMessages() {
        let restricted = CloudSyncState.message(for: .restricted)
        let signedOut = CloudSyncState.message(for: .signedOutOfICloud)
        #expect(restricted != signedOut)
        #expect(restricted.lowercased().contains("restriction"))
        #expect(signedOut.lowercased().contains("not signed in"))
        // and the policy routes the two account situations to them
        #expect(CloudAccountPolicy.state(for: CloudAccountPolicy.evaluate(stored: "A", current: .restricted), stored: "A") == .restricted)
        #expect(CloudAccountPolicy.state(for: CloudAccountPolicy.evaluate(stored: "A", current: .noAccount), stored: "A") == .signedOutOfICloud)
    }

    @Test func distinctSituationsHaveDistinctWords() {
        // the states below are each a different situation for the person; none may share a message
        let distinct: [CloudSyncState] = [
            .off, .notAvailableInThisBuild, .signedOutOfICloud, .restricted, .waitingForICloud, .waitingForKeychain, .keychainUnavailable,
            .needsRecoveryKey, .recoveryNotSaved, .needsNotePassword, .accountChanged(previousHash: "x"), .zoneRemoved(reason: .deleted),
            .zoneRemoved(reason: .encryptedDataReset), .itemsMissingInCloud(count: 2), .quotaFull, .offline(retryAt: nil), .syncing,
            .upToDate(lastSync: nil), .paused, .needsAppUpdate, .itemsUnreadable(count: 2), .failed(kind: "x"),
        ]
        #expect(Set(distinct.map(CloudSyncState.message(for:))).count == distinct.count)
    }

    @Test func countsAreSpokenInSingularAndPlural() {
        #expect(CloudSyncState.message(for: .itemsUnreadable(count: 1)).hasPrefix("1 item from"))
        #expect(CloudSyncState.message(for: .itemsUnreadable(count: 3)).hasPrefix("3 items from"))
        #expect(CloudSyncState.message(for: .itemsMissingInCloud(count: 1)).hasPrefix("1 note that"))
        #expect(CloudSyncState.message(for: .itemsMissingInCloud(count: 3)).hasPrefix("3 notes that"))
    }

    // MARK: the state at launch

    @Test func theLaunchStateIsDerivedFromDurableDataInPriorityOrder() async throws {
        let w = try await CloudPolicyWorld.make(prepare: false, bind: false)
        let hash = w.one.userHash
        func state(_ account: CloudAccountState? = nil) throws -> CloudSyncState {
            try CloudAccountPolicy.launchState(store: w.store, account: account ?? .available(userHash: hash))
        }
        #expect(try state() == .off, "not bound")
        try w.store.bind(accountId: "ck-one", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: hash)
        #expect(try state() == .syncing)
        #expect(try state(.noAccount) == .signedOutOfICloud)
        #expect(try state(.restricted) == .restricted)
        #expect(try state(.couldNotDetermine) == .waitingForICloud)
        #expect(try state(.available(userHash: "other")) == .accountChanged(previousHash: hash))

        try await w.db.pool.write {
            try $0.execute(sql: "INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc) VALUES('note','n1',x'01',x'02',1,'i')")
        }
        try w.store.markMissing(entityType: "note", entityId: "n1", reason: "gone")
        #expect(try state() == .itemsMissingInCloud(count: 1))
        try w.store.quarantine(record: CloudQuarantineRecord(recordName: "e.note.q1", reason: "invalid-value:cipher", rawFields: Data("r".utf8)), pinned: [])
        #expect(try state() == .itemsUnreadable(count: 1))
        try w.store.quarantine(record: CloudQuarantineRecord(recordName: "e.note.q2", reason: "version:9", rawFields: Data("r".utf8)), pinned: [])
        #expect(try state() == .needsAppUpdate)
        _ = try w.store.ignoreQuarantine(recordName: "e.note.q2")
        #expect(try state() == .itemsUnreadable(count: 1), "an ignored item is no longer reported")

        try w.store.setAccountFenced(true)
        #expect(try state() == .paused)
        try w.store.setZoneState(.removed(.purged))
        #expect(try state() == .zoneRemoved(reason: .purged), "a removed zone outranks the rest")
        #expect(try state(.noAccount) == .signedOutOfICloud, "an unusable account outranks a removed zone")
    }

    // MARK: the zone as the person sees it (CK-R15)

    @Test func zoneDeletedByUserIsReportedNotRecreated() async throws {
        let w = try await CloudPolicyWorld.make()
        #expect(try w.store.zoneState() == .created)
        await w.one.removeZone(reason: .userDeletedZone)
        try await w.device.fetchChanges(into: RecordingSink())

        #expect(try w.store.zoneState() == .removed(.userDeletedZone))
        #expect(await w.device.eventLog.contains(.zoneRemoved(.userDeletedZone)))
        _ = try await w.device.prepare()
        _ = try await w.device.prepare()
        #expect(await w.one.zonePresent == false, "prepare() never re-creates a removed zone")
        #expect(try w.store.zoneState() == .removed(.userDeletedZone))
        #expect(try CloudAccountPolicy.launchState(store: w.store, account: await w.device.accountState()) == .zoneRemoved(reason: .userDeletedZone))

        var errors = CloudErrorPolicy()
        let decision = errors.decide(CloudErrorPolicy.classify(CloudGatewayEvent.zoneRemoved(.userDeletedZone))!)
        #expect(decision.retry == .none && decision.uploadsBlocked && decision.receivingBlocked)
        #expect(decision.state == .zoneRemoved(reason: .userDeletedZone))
    }

    @Test func initialZoneCreationIsNotConfusedWithDeletion() async throws {
        let w = try await CloudPolicyWorld.make(prepare: false)
        #expect(try w.store.zoneState() == .unknown)
        #expect(await w.one.zonePresent == false)
        // looking before anything was created is not a removal
        try await w.device.fetchChanges(into: RecordingSink())
        #expect(try w.store.zoneState() == .unknown)
        #expect(await w.device.eventLog.isEmpty)

        _ = try await w.device.prepare()
        #expect(try w.store.zoneState() == .created)
        #expect(await w.one.zonePresent)
        try await w.device.fetchChanges(into: RecordingSink())
        #expect(await w.device.eventLog.isEmpty, "creating the zone reported no removal")
        #expect(try CloudAccountPolicy.launchState(store: w.store, account: await w.device.accountState()) == .syncing)
    }

    @Test func zoneRemovedThenNewDeviceStartsFreshOnlyFromUnknown() async throws {
        let w = try await CloudPolicyWorld.make()
        await w.one.removeZone(reason: .deleted)
        try await w.device.fetchChanges(into: RecordingSink())
        #expect(try w.store.zoneState() == .removed(.deleted))

        // another device of the same person, with an empty library state, starts fresh and creates the zone
        let newStore = CloudSyncStore(database: try AppDatabase.inMemory())
        try newStore.bind(accountId: "ck-one", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: w.one.userHash)
        let newDevice = FakeCloudKitDevice(account: w.one, store: newStore)
        #expect(try newStore.zoneState() == .unknown)
        _ = try await newDevice.prepare()
        #expect(await w.one.zonePresent)
        #expect(try newStore.zoneState() == .created)

        // the first device stays removed although a zone exists again, until the person chooses "Upload again"
        _ = try await w.device.prepare()
        #expect(try w.store.zoneState() == .removed(.deleted))
        #expect(try w.store.chooseUploadAgain())
        #expect(try w.store.zoneState() == .unknown)
        _ = try await w.device.prepare()
        #expect(try w.store.zoneState() == .created)
        #expect(try w.store.chooseUploadAgain() == false, "only a removed zone can be uploaded again")
        #expect(try w.store.zoneState() == .created)
    }

    @Test func encryptedDataResetIsZoneRemoved() async throws {
        let w = try await CloudPolicyWorld.make()
        await w.one.removeZone(reason: .encryptedDataReset)
        try await w.device.fetchChanges(into: RecordingSink())

        #expect(try w.store.zoneState() == .removed(.encryptedDataReset))
        #expect(await w.device.eventLog.contains(.zoneRemoved(.encryptedDataReset)))
        #expect(CloudErrorPolicy.classify(CloudGatewayEvent.zoneRemoved(.encryptedDataReset)) == .zoneRemoved(.encryptedDataReset))
        let state = try CloudAccountPolicy.launchState(store: w.store, account: await w.device.accountState())
        #expect(state == .zoneRemoved(reason: .encryptedDataReset))
        #expect(state.message.contains("encrypted iCloud data was reset"))
        #expect(state.message != CloudSyncState.message(for: .zoneRemoved(reason: .deleted)))
    }
}
