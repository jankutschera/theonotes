// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Security
import Testing
@testable import TheoNotesCore

// MARK: - Test world for the key tasks (Task 8)

extension InMemoryCloudGatewayStore: CloudSendResultSource {
    func sendOutcome(attemptId: String) throws -> CloudSaveOutcome? { outcome(for: attemptId) }
}

extension RecoveryChoice {
    /// Tests only: the skip with the acknowledgement ticked (the app builds it through `skip(acknowledged:)` too).
    static var acknowledgedRisk: RecoveryChoice { try! .skip(acknowledged: true) }
}

extension CloudKeyLocalState {
    /// "recovery/revision", for expectations that do not care about the pinned account id.
    var summary: String { "\(recovery.rawValue)/\(bundleRevision)" }
}

final class InMemoryCloudKeyStateStore: CloudKeyStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = CloudKeyLocalState(recovery: .none, bundleRevision: 0)
    func keyState() throws -> CloudKeyLocalState { lock.lock(); defer { lock.unlock() }; return value }
    func setKeyState(_ state: CloudKeyLocalState) throws { lock.lock(); defer { lock.unlock() }; value = state }
}

/// Forwards to a fake device and keeps every save it was asked to make (for "only the bundle" and canary checks).
actor RecordingGateway: CloudKitGateway {
    let inner: FakeCloudKitDevice
    nonisolated let events: AsyncStream<CloudGatewayEvent>
    private(set) var saves: [CloudSave] = []
    init(_ inner: FakeCloudKitDevice) { self.inner = inner; events = inner.events }
    func prepare() async throws -> CloudAccountState { try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ batch: [CloudSave]) async throws { saves += batch; try await inner.submit(batch) }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { try await inner.fetch(names, keys: keys) }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws { try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
}

final class KeyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; current = current.addingTimeInterval(seconds) }
}

/// One device: its gateway (fake + recorder), durable send results, keychain view and library key state.
struct KeyDevice {
    let fake: FakeCloudKitDevice
    let gateway: RecordingGateway
    let results: InMemoryCloudGatewayStore
    let seeds: InMemoryCloudKeySeedStore
    let state: InMemoryCloudKeyStateStore
    let crash: CrashPoint
    let clock: KeyTestClock

    static func make(cloud: FakeCloudKitAccount, keychain: InMemoryCloudKeychain, clock: KeyTestClock = KeyTestClock(),
                     seeds: InMemoryCloudKeySeedStore? = nil, state: InMemoryCloudKeyStateStore = InMemoryCloudKeyStateStore(),
                     results: InMemoryCloudGatewayStore = InMemoryCloudGatewayStore(), crash: CrashPoint = CrashPoint()) async throws -> KeyDevice {
        let fake = FakeCloudKitDevice(account: cloud, store: results)
        _ = try await fake.prepare()
        return KeyDevice(fake: fake, gateway: RecordingGateway(fake), results: results, seeds: seeds ?? InMemoryCloudKeySeedStore(keychain: keychain),
                         state: state, crash: crash, clock: clock)
    }

    /// The same durable stores with a new gateway process and no armed crash.
    func restarted(cloud: FakeCloudKitAccount) async throws -> KeyDevice {
        try await KeyDevice.make(cloud: cloud, keychain: seeds.keychain, clock: clock, seeds: seeds, state: state, results: results)
    }

    var bundles: CloudKeyBundleStore { CloudKeyBundleStore(gateway: gateway, results: results, outcomeTimeout: 0.05) }
    var creation: CloudKeyCreation {
        let clock = clock
        return CloudKeyCreation(seeds: seeds, probe: seeds, bundles: bundles, state: state, crash: crash, now: { clock.now })
    }
    func joiner() -> CloudKeyJoin {
        let clock = clock
        return CloudKeyJoin(seeds: seeds, probe: seeds, bundles: bundles, state: state, now: { clock.now })
    }
    var rotation: CloudRecoveryRotation { CloudRecoveryRotation(seeds: seeds, bundles: bundles, state: state) }
    var savedNames: [String] { get async { await gateway.saves.map(\.record.name) } }

    /// Keys of a device that is ready (created or joined), via the join evaluation.
    func readyKeys() async throws -> AccountKeys {
        let evaluation = try await joiner().evaluate()
        guard evaluation.state == .ready, let keys = evaluation.keys else { throw CloudKeyError.creationIncomplete }
        return keys
    }
}

enum KeyTest {
    /// A recovery key whose entropy the test knows, and the matching three-word confirmation.
    static func knownRecovery(fill: UInt8? = nil) throws -> (secret: Data, words: String, choice: RecoveryChoice) {
        var secret = Data(count: 32)
        for index in secret.indices { secret[index] = fill ?? UInt8.random(in: 0...255) }
        let offer = try RecoveryKeyOffer(key: RecoveryKey(secret: secret), checkPositions: [2, 11, 23])
        return (secret, offer.words, try confirm(offer))
    }

    /// Types back the offered words correctly.
    static func confirm(_ offer: RecoveryKeyOffer) throws -> RecoveryChoice {
        let list = offer.words.split(separator: " ").map(String.init)
        return try offer.confirm(Dictionary(uniqueKeysWithValues: offer.checkPositions.map { ($0, list[$0]) }))
    }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    /// Compares secrets without letting a failure message print them (callers bind the result to a Bool first).
    static func same(_ a: SymmetricKey, _ b: SymmetricKey) -> Bool { bytes(a) == bytes(b) }
    static func hasSeed(_ store: any CloudKeySeedStore, _ account: String) throws -> Bool { try store.seed(accountId: account) != nil }
    static func noPending(_ store: any CloudKeySeedStore) throws -> Bool { try store.pending() == nil }
    static let dummyKeys = try! AccountKeys(accountID: "ck-dummy")

    static func interleavings(_ a: Int, _ b: Int) -> [[Bool]] {
        if a == 0 { return [Array(repeating: false, count: b)] }
        if b == 0 { return [Array(repeating: true, count: a)] }
        return interleavings(a - 1, b).map { [true] + $0 } + interleavings(a, b - 1).map { [false] + $0 }
    }

    /// Every textual form a secret could leak in.
    static func forms(of secret: Data) -> [Data] {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        return [secret, Data(secret.base64EncodedString().utf8), Data(SyncWire.base64(secret).utf8),
                Data(hex.utf8), Data(hex.uppercased().utf8)]
    }

    static func forms(of text: String) -> [Data] {
        let utf8 = Data(text.utf8)
        var forms = [utf8, Data(utf8.base64EncodedString().utf8), Data(SyncWire.base64(utf8).utf8)]
        if let le = text.data(using: .utf16LittleEndian) { forms.append(le) }
        if let be = text.data(using: .utf16BigEndian) { forms.append(be) }
        return forms
    }

    /// Every byte string a record exposes: field names, values, the name.
    static func exposedBytes(_ record: CloudRecord) -> [Data] {
        var out = [Data(record.name.utf8)]
        for (key, value) in record.fields {
            out.append(Data(key.utf8))
            switch value {
            case .int(let i): out.append(Data(String(i).utf8))
            case .string(let s): out.append(Data(s.utf8))
            case .bytes(let d): out.append(d)
            case .strings(let list): out += list.map { Data($0.utf8) }
            case .asset(let url): out.append((try? Data(contentsOf: url)) ?? Data())
            }
        }
        return out
    }

    static func leaks(_ haystacks: [Data], _ needles: [Data]) -> Bool {
        haystacks.contains { hay in needles.contains { !$0.isEmpty && hay.range(of: $0) != nil } }
    }
}

// MARK: - Bundle record, canary, names, canaries, rotation

@Suite struct CloudKeyBundleTests {
    func sampleBundle(recovery: CloudRecoveryState = .saved) throws -> (CloudKeyBundle, AccountKeys) {
        let account = "ck-" + UUIDv7.make()
        let keys = try AccountKeys(accountID: account)
        let envelope = try keys.envelope(recovery: RecoveryKey())
        return (try CloudKeyBundle.sealed(keys: keys, rev: 1, envelope: envelope, recovery: recovery), keys)
    }

    @Test func theFixtureKeyBundleMatchesTheSpecPayload() throws {
        let fixture = try #require(try CloudRecordFixture.load().valid.first { $0.name == "key-bundle" })
        let bundle = try CloudKeyBundleCodec.decode(fixture.record)
        #expect(bundle.accountId == "ck-0194f6c0-3333-7000-8000-000000000003")
        #expect(bundle.rev == 1)
        #expect(bundle.envelope.accountId == bundle.accountId)
    }

    @Test func theBundleRecordRoundTripsAndUsesOnlyTheSpecFields() throws {
        let (bundle, _) = try sampleBundle()
        let record = try CloudKeyBundleCodec.record(bundle, systemFields: nil)
        #expect(record.name == "keybundle")
        #expect(record.type == .keyBundle)
        #expect(Set(record.fields.keys) == CloudRecordCodec.keyBundleFieldNames)
        #expect(try CloudKeyBundleCodec.decode(record) == bundle)
    }

    @Test func anUnreadableBundleFailsClosed() async throws {
        let (bundle, _) = try sampleBundle()
        var record = try CloudKeyBundleCodec.record(bundle, systemFields: nil)
        var newer = record; newer.fields["v"] = .int(2)
        #expect(throws: CloudKeyError.bundleUnreadable("version:2")) { try CloudKeyBundleCodec.decode(newer) }
        var junk = record; junk.fields["envelope"] = .bytes(Data("not json".utf8))
        #expect(throws: CloudKeyError.bundleUnreadable("payload")) { try CloudKeyBundleCodec.decode(junk) }
        var moved = record; moved.fields["account"] = .string("ck-another")
        #expect(throws: CloudKeyError.bundleUnreadable("account-mismatch")) { try CloudKeyBundleCodec.decode(moved) }
        let future = try JSONSerialization.data(withJSONObject: ["format": 2, "canary": bundle.canary,
            "envelope": try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle.envelope))])
        record.fields["envelope"] = .bytes(future)
        #expect(throws: CloudKeyError.bundleUnreadable("payload-format:2")) { try CloudKeyBundleCodec.decode(record) }

        // Through the store: an unreadable bundle in the cloud is an error, never "no bundle".
        let cloud = FakeCloudKitAccount()
        let device = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        try await device.gateway.submit([CloudSave(attemptId: "a1", accountGeneration: 0, record: newer)])
        await #expect(throws: CloudKeyError.bundleUnreadable("version:2")) { _ = try await device.bundles.fetch() }
        await #expect(throws: CloudKeyError.bundleUnreadable("version:2")) { _ = try await device.joiner().evaluate() }
    }

    @Test func theCanaryOpensOnlyWithTheAccountsVaultKeyAndAnUnchangedBundle() throws {
        let (bundle, keys) = try sampleBundle(recovery: .acknowledgedSkip)
        #expect(try CloudKeyCanary.open(bundle, vaultKey: keys.vaultKey) == .acknowledgedSkip)
        #expect(throws: CloudKeyError.keyMismatch) { try CloudKeyCanary.open(bundle, vaultKey: SymmetricKey(size: .bits256)) }
        var moved = bundle; moved.accountId = "ck-other"
        #expect(throws: CloudKeyError.keyMismatch) { try CloudKeyCanary.open(moved, vaultKey: keys.vaultKey) }
        var garbage = bundle; garbage.canary = "AAAA"
        #expect(throws: CloudKeyError.keyMismatch) { try CloudKeyCanary.open(garbage, vaultKey: keys.vaultKey) }
        var newerRev = bundle; newerRev.rev = 2
        #expect(throws: CloudKeyError.keyMismatch) { try CloudKeyCanary.open(newerRev, vaultKey: keys.vaultKey) }
        let other = try keys.envelope(recovery: RecoveryKey())
        for field in 0..<3 {
            var changed = bundle
            changed.envelope = AccountKeyEnvelope(version: bundle.envelope.version, algorithm: bundle.envelope.algorithm,
                accountId: bundle.envelope.accountId,
                wrappedMasterKey: field == 0 ? other.wrappedMasterKey : bundle.envelope.wrappedMasterKey,
                wrappedVaultKey: field == 1 ? other.wrappedVaultKey : bundle.envelope.wrappedVaultKey,
                recoveryPublicKey: field == 2 ? other.recoveryPublicKey : bundle.envelope.recoveryPublicKey)
            #expect(throws: CloudKeyError.keyMismatch) { try CloudKeyCanary.open(changed, vaultKey: keys.vaultKey) }
        }
        let saved = try CloudKeyBundle.sealed(keys: keys, rev: 1, envelope: bundle.envelope, recovery: .saved)
        #expect(try CloudKeyCanary.open(saved, vaultKey: keys.vaultKey) == .saved)
    }

    @Test func thePendingCreationIsAddOnlyAndChangedOnlyByCompareAndSwap() throws {
        let store = InMemoryCloudKeySeedStore()
        let (bundle, keys) = try sampleBundle()
        let first = PendingKeyCreation(accountId: bundle.accountId, seed: keys.masterKeyData, bundle: bundle, recovery: .saved, startedAt: Date())
        var other = first; other.seed = KeyTest.bytes(SymmetricKey(size: .bits256))
        try store.savePending(first)
        try store.savePending(first)
        #expect(throws: CloudKeySeedStoreError.pendingConflict) { try store.savePending(other) }
        var next = first; next.bundleCreated = true
        #expect(throws: CloudKeySeedStoreError.pendingConflict) { try store.replacePending(next, expected: other) }
        try store.replacePending(next, expected: first)
        let replaced = try store.pending() == next
        #expect(replaced)
        try store.clearPending()
        #expect(throws: CloudKeySeedStoreError.pendingConflict) { try store.replacePending(next, expected: first) }
    }

    @Test func secretComparisonsAreLengthCheckedAndFull() {
        let a = Data(repeating: 7, count: 32)
        var b = a; b[31] = 8
        var c = a; c[0] = 8
        #expect(CloudKeyConstantTime.equal(a, a))
        #expect(!CloudKeyConstantTime.equal(a, b))
        #expect(!CloudKeyConstantTime.equal(a, c))
        #expect(!CloudKeyConstantTime.equal(a, a.prefix(31)))
        #expect(!CloudKeyConstantTime.equal(Data(), a))
    }

    @Test func synchronizableItemNeverSharesAName() throws {
        #expect(Set(CloudKeyNames.all).count == CloudKeyNames.all.count)
        // The other keychain items of the app: the Cloudflare sync item and the note-password vault (Mac app).
        let vaultSource = try String(contentsOf: SchemaSnapshotTests.fixtureDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/TheoNotesMac/Sources/Privacy/VaultKeyCache.swift"), encoding: .utf8)
        // The Mac app reads the service from AppIdentity; the value itself is pinned by IdentityPinsTests.
        #expect(vaultSource.contains("defaultService = AppIdentity.vaultKeychainService"))
        let others = [KeychainSyncStore.keychainService, AppIdentity.vaultKeychainService]
        for name in CloudKeyNames.all {
            for other in others {
                #expect(name != other)
                #expect(!name.hasPrefix(other) && !other.hasPrefix(name))
            }
            #expect(!name.lowercased().contains("baerchen"), "new identifiers use a neutral name")
        }
        let store = KeychainCloudKeySeedStore(namespace: "library-1", accessGroup: "TEAMID1234.example.group")
        let seed = store.seedQuery(accountId: "ck-1")
        let pending = store.pendingQuery()
        let probe = store.probeQuery(account: "probe.1")
        #expect(seed[kSecAttrService] as? String == CloudKeyNames.seedService)
        #expect(pending[kSecAttrService] as? String == CloudKeyNames.pendingService)
        #expect(probe[kSecAttrService] as? String == CloudKeyNames.probeService)
        #expect(seed[kSecAttrSynchronizable] as? Bool == true)
        #expect(probe[kSecAttrSynchronizable] as? Bool == true)
        #expect(pending[kSecAttrSynchronizable] as? Bool == false)
        #expect(seed[kSecAttrAccount] as? String == "ck-1")
        #expect(pending[kSecAttrAccount] as? String == "pending.library-1")
        let mark = store.markQuery(accountId: "ck-1")
        #expect(mark[kSecAttrService] as? String == CloudKeyNames.markService)
        #expect(mark[kSecAttrSynchronizable] as? Bool == false, "the revision mark never syncs")
        #expect(mark[kSecAttrAccount] as? String == "ck-1")
        #expect(store.namespace == "library-1")
        for query in [seed, pending, probe, mark] {
            #expect(query[kSecAttrAccessGroup] as? String == "TEAMID1234.example.group")
            #if os(macOS)
            #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
            #endif
        }
        let syncAdd = KeychainCloudKeySeedStore.addAttributes(seed, value: Data([1]), synchronizable: true)
        let localAdd = KeychainCloudKeySeedStore.addAttributes(pending, value: Data([1]), synchronizable: false)
        #expect(syncAdd[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(localAdd[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(KeychainCloudKeySeedStore(namespace: "x").accessGroup == AppIdentity.current.keychainAccessGroup)
    }

    /// (task B3): the iCloud key seed, the pending creation, the probe and the revision mark all live in the
    /// access group of the running identity (`AppIdentity.keychainAccessGroup`, which follows team and bundle id), never
    /// in a group written out in this file. A store built the default way reads whatever the identity says.
    @Test func test_every_cloud_key_item_uses_the_identitys_access_group_by_default() {
        let store = KeychainCloudKeySeedStore(namespace: "library-1")
        let group = AppIdentity.current.keychainAccessGroup
        #expect(store.accessGroup == group)
        for query in [store.seedQuery(accountId: "ck-1"), store.pendingQuery(), store.probeQuery(account: "probe.1"),
                      store.markQuery(accountId: "ck-1")] {
            #expect(query[kSecAttrAccessGroup] as? String == group)
        }
        // The group is team + "." + bundle id: for the next team it is a different string, so a seed written
        // under the old team is simply absent for a build of the new one (a normal state, not an error).
        #expect(AppIdentity.production.keychainAccessGroup(team: "AAAAAAAAAA") != AppIdentity.production.keychainAccessGroup(team: "BBBBBBBBBB"))
        #expect(KeychainCloudKeySeedStore(namespace: "x", accessGroup: AppIdentity.production.keychainAccessGroup(team: "BBBBBBBBBB"))
            .seedQuery(accountId: "ck-1")[kSecAttrAccessGroup] as? String == AppIdentity.production.keychainAccessGroup(team: "BBBBBBBBBB"))
    }

    @Test func noRecoveryWordSeedOrKeyByteInAnyRecord() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let first = try KeyTest.knownRecovery(), second = try KeyTest.knownRecovery()
        guard case .created(let account) = try await a.creation.run(first.choice) else { Issue.record("not created"); return }
        let keys = try await a.readyKeys()
        _ = try await b.readyKeys()
        #expect(try await b.rotation.createOrReplaceRecoveryKey(second.choice, keys: try await b.readyKeys()) == .replaced(revision: 2))

        var records = await a.gateway.saves.map(\.record) + b.gateway.saves.map(\.record)
        if let current = await cloud.record(named: "keybundle") { records.append(current) }
        #expect(records.count == 3)
        var needles: [Data] = []
        for recovery in [first, second] {
            needles += KeyTest.forms(of: recovery.secret)
            needles += KeyTest.forms(of: recovery.words)
            needles += KeyTest.forms(of: recovery.words.split(separator: " ").prefix(3).joined(separator: " "))
            let key = try RecoveryKey(secret: recovery.secret)
            needles += KeyTest.forms(of: try key.signingKey(accountID: account).rawRepresentation)
            needles += KeyTest.forms(of: KeyTest.bytes(try key.wrappingKey(accountID: account)))
        }
        needles += KeyTest.forms(of: keys.masterKeyData)
        needles += KeyTest.forms(of: KeyTest.bytes(keys.vaultKey))
        let leaked = KeyTest.leaks(records.flatMap(KeyTest.exposedBytes), needles)
        #expect(!leaked, "a recovery word, seed or key byte reached a record")
        // The canary content itself is sealed: the plaintext labels never appear.
        let labels = KeyTest.leaks(records.flatMap(KeyTest.exposedBytes), [Data("\"recovery\"".utf8), Data("\"saved\"".utf8)])
        #expect(!labels)
    }

    @Test func noSecretInAnyErrorOrDescription() throws {
        let recovery = try KeyTest.knownRecovery()
        let keys = try AccountKeys(accountID: "ck-1")
        let (bundle, _) = try sampleBundle()
        let pending = PendingKeyCreation(accountId: "ck-1", seed: keys.masterKeyData, bundle: bundle, recovery: .saved, startedAt: Date())
        let offer = try RecoveryKeyOffer.make()
        var texts: [String] = [String(describing: pending), String(reflecting: pending), String(describing: recovery.choice),
                               String(reflecting: recovery.choice), String(describing: offer), String(reflecting: offer)]
        let errors: [any Error] = [
            CloudKeyError.acknowledgementRequired, CloudKeyError.recoveryWordsNotConfirmed, CloudKeyError.invalidRecoveryKey,
            CloudKeyError.keychainUnavailable(.unavailable(.missingEntitlement)), CloudKeyError.bundleUnreadable("payload"),
            CloudKeyError.bundleNotWritten, CloudKeyError.noBundle, CloudKeyError.keyMismatch, CloudKeyError.creationIncomplete,
            CloudKeyError.alreadyComplete, CloudKeyError.bundleRollback, CloudKeyError.accountMismatch, CloudKeyError.seedConflict,
            CloudKeyError.seedNotStored(.unavailable(.deviceLocked)), CloudKeySeedStoreError.seedConflict(accountId: "ck-1"),
            CloudKeySeedStoreError.unavailable(.failedReadBack), CloudKeySeedStoreError.corruptItem, CloudKeySeedStoreError.pendingConflict,
        ]
        texts += errors.flatMap { [String(describing: $0), String(reflecting: $0), $0.localizedDescription] }
        // Reflection (dump, and what a test framework prints for a value) is redacted too.
        for value in [pending, recovery.choice, offer] as [Any] {
            var dumped = ""
            dump(value, to: &dumped)
            texts.append(dumped)
        }
        let needles = KeyTest.forms(of: keys.masterKeyData) + KeyTest.forms(of: recovery.secret) + KeyTest.forms(of: recovery.words)
            + KeyTest.forms(of: offer.words) + KeyTest.forms(of: String(offer.words.split(separator: " ")[0] + " " + offer.words.split(separator: " ")[1]))
        let leaked = KeyTest.leaks(texts.map { Data($0.utf8) }, needles)
        #expect(!leaked, "a secret appears in an error or description")
        #expect(texts[0].contains("<redacted>"))
    }

    @Test func theLibraryStoresItsKeyStateInCkState() throws {
        let store = CloudSyncStore(database: try AppDatabase.inMemory())
        #expect(try store.keyState().summary == "none/0")
        #expect(try store.keyState().accountId == nil)
        try store.setKeyState(CloudKeyLocalState(accountId: "ck-1", recovery: .acknowledgedSkip, bundleRevision: 3))
        #expect(try store.keyState().summary == "acknowledgedSkip/3")
        #expect(try store.keyState().accountId == "ck-1")
        // The library can still be bound to the same account afterwards (Task 3's bind).
        #expect(throws: Never.self) { try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "h") }
        try CloudRecoveryReminder.noteOfferShown(in: store)
        #expect(try store.keyState().recovery == .pending)
        try store.recordSendResult(attemptId: "kb-1", accountGeneration: store.generation(), outcome: .unknownItem)
        #expect(try store.sendOutcome(attemptId: "kb-1") == .unknownItem)
        #expect(try store.sendOutcome(attemptId: "kb-2") == nil)
    }

    @Test func recoveryRotationLostRaceIsReportedNotOverwritten() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let c = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        _ = try await a.creation.run(.acknowledgedRisk)
        let keysA = try await a.readyKeys(), keysB = try await b.readyKeys(), keysC = try await c.readyKeys()
        let wordsA = try KeyTest.knownRecovery(), wordsB = try KeyTest.knownRecovery(), wordsC = try KeyTest.knownRecovery()

        // B prepares on rev 1, A replaces first, B's change-tag-checked save loses.
        let draft = try await b.rotation.prepare(wordsB.choice, keys: keysB)
        #expect(try await a.rotation.createOrReplaceRecoveryKey(wordsA.choice, keys: keysA) == .replaced(revision: 2))
        #expect(try await b.rotation.commit(draft, keys: keysB) == .lostRace)
        let current = try #require(try await a.bundles.fetch()).bundle
        #expect(current.rev == 2)
        let opensWithA = (try? AccountKeys(recovery: RecoveryKey(words: wordsA.words), envelope: current.envelope)) != nil
        let opensWithB = (try? AccountKeys(recovery: RecoveryKey(words: wordsB.words), envelope: current.envelope)) != nil
        #expect(opensWithA)
        #expect(!opensWithB, "the losing rotation must not overwrite the winner")
        #expect(try b.state.keyState().summary == "saved/2")
        #expect(await cloud.versionCount(of: "keybundle") == 2)

        // C still knows rev 1: reported before anything is saved, then a retry on the newer bundle works.
        #expect(try await c.rotation.createOrReplaceRecoveryKey(wordsC.choice, keys: keysC) == .lostRace)
        #expect(await c.gateway.saves.isEmpty)
        #expect(try c.state.keyState().bundleRevision == 2)
        #expect(try await c.rotation.createOrReplaceRecoveryKey(wordsC.choice, keys: keysC) == .replaced(revision: 3))

        // A rotation needs the three-word check and keys that open the bundle.
        await #expect(throws: CloudKeyError.recoveryWordsNotConfirmed) { _ = try await a.rotation.prepare(.acknowledgedRisk, keys: keysA) }
        let stranger = try AccountKeys(accountID: current.accountId)
        await #expect(throws: CloudKeyError.keyMismatch) { _ = try await a.rotation.prepare(wordsA.choice, keys: stranger) }
    }

    @Test func recoveryKeyCanBeCreatedLaterAndOldDevicesKeepWorking() async throws {
        let cloud = FakeCloudKitAccount(), keychain = InMemoryCloudKeychain()
        let a = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let b = try await KeyDevice.make(cloud: cloud, keychain: keychain)
        let c = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        _ = try await a.creation.run(.acknowledgedRisk)
        let keysA = try await a.readyKeys()
        let keysB = try await b.readyKeys()
        #expect(try b.state.keyState().recovery == .acknowledgedSkip)

        let later = try KeyTest.knownRecovery()
        #expect(try await a.rotation.createOrReplaceRecoveryKey(later.choice, keys: keysA) == .replaced(revision: 2))
        #expect(try a.state.keyState().summary == "saved/2")
        let keysBAfter = try await b.readyKeys()
        do { let sameKeys = KeyTest.same(keysBAfter.vaultKey, keysB.vaultKey); #expect(sameKeys) }
        #expect(try b.state.keyState().summary == "saved/2")
        let joined = try await c.joiner().join(recoveryWords: later.words)
        do { let sameKeys = KeyTest.same(joined.keys.vaultKey, keysA.vaultKey); #expect(sameKeys) }

        let replacement = try KeyTest.knownRecovery()
        #expect(try await b.rotation.createOrReplaceRecoveryKey(replacement.choice, keys: keysBAfter) == .replaced(revision: 3))
        let d = try await KeyDevice.make(cloud: cloud, keychain: InMemoryCloudKeychain())
        await #expect(throws: CloudKeyError.invalidRecoveryKey) { _ = try await d.joiner().join(recoveryWords: later.words) }
        do { let sameKeys = KeyTest.same(try await a.readyKeys().vaultKey, keysA.vaultKey); #expect(sameKeys) }
    }
}

// MARK: - The real keychain store, only in a team-signed host (Gate G0)

/// Runs only where `THEONOTES_KEYCHAIN_HOST_TESTS=1` is set by a team-signed test host with the keychain access group
/// (Gate G0). Never in `swift test`: an unsigned process has no access group (-34018), and agents never write the login
/// keychain. Uses a unique account id and namespace and removes exactly those items.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["THEONOTES_KEYCHAIN_HOST_TESTS"] == "1"))
struct KeychainCloudKeySeedStoreHostedTests {
    @Test func seedAndPendingRoundTripInTheSignedHost() throws {
        let store = KeychainCloudKeySeedStore(namespace: "hosted-test-\(UUID().uuidString)")
        #expect(store.probeAvailability() == .usable)
        let account = "ck-hosted-test-\(UUID().uuidString)"
        defer { try? store.removeSeed(accountId: account); try? store.clearPending() }
        let seed = KeyTest.bytes(SymmetricKey(size: .bits256))
        try store.saveSeed(seed, accountId: account)
        try store.saveSeed(seed, accountId: account)
        let readBack = try store.seed(accountId: account) == seed
        #expect(readBack)
        #expect(throws: CloudKeySeedStoreError.seedConflict(accountId: account)) {
            try store.saveSeed(KeyTest.bytes(SymmetricKey(size: .bits256)), accountId: account)
        }
        let (bundle, _) = try CloudKeyBundleTests().sampleBundle()
        let pending = PendingKeyCreation(accountId: account, seed: seed, bundle: bundle, recovery: .saved, startedAt: Date())
        try store.savePending(pending)
        var updated = pending; updated.bundleCreated = true
        #expect(throws: CloudKeySeedStoreError.pendingConflict) { try store.savePending(updated) }
        try store.replacePending(updated, expected: pending)
        #expect(throws: CloudKeySeedStoreError.pendingConflict) { try store.replacePending(pending, expected: pending) }
        let pendingMatches = try store.pending() == updated
        #expect(pendingMatches)
        try store.clearPending()
        #expect(try KeyTest.noPending(store))
        try store.raiseHighWaterMark(4, accountId: account)
        try store.raiseHighWaterMark(2, accountId: account)
        #expect(try store.highWaterMark(accountId: account) == 4)
        try store.forgetAccount(accountId: account)
        #expect(try store.highWaterMark(accountId: account) == nil)
        try store.raiseHighWaterMark(1, accountId: account)
        try store.removeSeed(accountId: account)
        #expect(try KeyTest.hasSeed(store, account) == false)
        #expect(try store.highWaterMark(accountId: account) == nil)
    }
}
