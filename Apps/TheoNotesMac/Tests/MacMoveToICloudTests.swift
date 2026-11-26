// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import GRDB
import Security
import Testing
@testable import TheoNotes

/// The real glue of "Move This Library to iCloud" on the Mac: `MacSyncController.leaveForICloud` with a real
/// Keychain item in a namespace of its own, a real `HTTPSyncTransport` whose key-bundle request a URL stub answers, and a real
/// `SyncEngine` on an in-memory server. Nothing reaches the network or the real library.
@MainActor @Suite(.serialized) struct MacMoveToICloudTests {
    /// Answers the private server's key-bundle request; counts every request.
    final class KeysStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bundle = Data()
        nonisolated(unsafe) static var requests = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests += 1
            let found = request.url?.path == "/v1/keys"
            let response = HTTPURLResponse(url: request.url!, statusCode: found ? 200 : 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: found ? Self.bundle : Data(#"{"error":"not_found"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// The private server's change log, enough for one device: accepts every push, returns what it has.
    actor Server: SyncTransport, SyncBlobTransport {
        var history: [SyncEntity] = []
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
            var results: [Any] = []
            for mutation in mutations {
                let entity = SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1, sequence: Int64(history.count + 1), receivedAt: 1)
                history.append(entity)
                results.append(["mutationId": mutation.mutationId, "status": "accepted", "entity": try Self.json(entity)])
            }
            return try JSONDecoder().decode(SyncPushResult.self, from: JSONSerialization.data(withJSONObject: ["results": results]))
        }
        func pull(after cursor: Int64) async throws -> SyncPullResult {
            let changes = history.filter { $0.sequence > cursor }
            let page: [String: Any] = ["changes": try changes.map(Self.json), "cursor": changes.last?.sequence ?? cursor, "hasMore": false]
            return try JSONDecoder().decode(SyncPullResult.self, from: JSONSerialization.data(withJSONObject: page))
        }
        static func json(_ entity: SyncEntity) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(entity)) }
        func acknowledge(_ cursor: Int64) async throws {}
        func ensureUploaded(_ hashes: [String]) async throws {}
        func download(hash: String) async throws -> URL { throw CancellationError() }
        func count() -> Int { history.count }
    }

    final class World {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MacMove-\(UUID().uuidString)", isDirectory: true)
        let namespace = "move-test." + UUID().uuidString
        let suite = "MacMoveToICloudTests." + UUID().uuidString
        let accountID = UUID().uuidString.lowercased()
        let server = Server()
        var store: KeychainSyncStore { KeychainSyncStore(namespace: namespace) }

        @MainActor func environment() throws -> AppEnvironment {
            let store = self.store, server = self.server
            let session: URLSession = {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [KeysStub.self]
                return URLSession(configuration: configuration)
            }()
            let services = MacSyncServices(
                defaults: UserDefaults(suiteName: suite)!,
                credentials: { _ in store },
                transport: { identity, credentials in
                    try HTTPSyncTransport(endpoint: URL(string: "https://move-test.invalid")!, signingKey: identity.signingKey, credentials: credentials, session: session)
                },
                enrollment: { _, _ in throw CancellationError() },
                engine: { library, account, transport in
                    (SyncBlobTransfer(database: library.database, paths: library.paths, transport: transport),
                     SyncEngine(database: library.database, paths: library.paths, accountID: account.keys.accountID, vaultKey: account.keys.vaultKey,
                                transport: server, blobs: server, coordinator: MacSyncCommitCoordinator(environment: library)))
                },
                scheduler: { _, _ in nil })
            return try AppEnvironment(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true)), syncPolicy: .enabled,
                                      syncSetup: true, syncServices: services, cloudSync: false)
        }

        /// A signed-in device with the account keys, as after pairing; the stub serves the same envelope.
        func signIn() async throws {
            let identity = try await store.identity()
            let far = Int64(Date.now.addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
            try await store.save(SyncCredentials(accountId: accountID, deviceId: identity.id, accessToken: SyncWire.base64(Data(repeating: 1, count: 32)), refreshToken: SyncWire.base64(Data(repeating: 2, count: 32)),
                                                 accessExpiresAt: far, refreshExpiresAt: far + 1))
            let keys = try AccountKeys(accountID: accountID)
            let envelope = try keys.envelope(recovery: RecoveryKey())
            try await store.saveAccount(keys, envelope: envelope)
            struct Bundle: Encodable { let envelope: AccountKeyEnvelope; let revision: Int64 }
            KeysStub.bundle = try JSONEncoder().encode(Bundle(envelope: envelope, revision: 1))
            KeysStub.requests = 0
        }

        func cleanup() {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: KeychainSyncStore.keychainService,
                                          kSecAttrAccount: namespace, kSecAttrSynchronizable: false, kSecUseDataProtectionKeychain: true]
            SecItemDelete(query as CFDictionary)
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: parent)
        }
    }

    @Test(.enabled(if: HostEntitlements.hasKeychainAccessGroup, HostEntitlements.keychainSkipReason))
    func theRealGlueSyncsOnceBacksUpLetsGoAndSignsOut() async throws {
        let world = World(); defer { world.cleanup() }
        try await world.signIn()
        let environment = try world.environment()
        let note = try environment.store.create(text: "# Written before the move\nkept")
        try SyncQueue(database: environment.database).configure(accountID: world.accountID)
        try SyncQueue(database: environment.database).enable(accountID: world.accountID)
        let backups = try LibraryBackup(database: environment.database, paths: environment.paths).localBackups().count

        try await environment.sync.leaveForICloud()

        #expect(await world.server.count() > 0, "the final sync sent the note through the app's own synchronize")
        #expect(try PrivateServerMove.hasLeft(environment.database))
        #expect(try CloudSyncStore(database: environment.database).backend() == SyncBackend.none)
        #expect(try LibraryBackup(database: environment.database, paths: environment.paths).localBackups().count == backups + 1)
        #expect(try await world.store.load() == nil, "signed out: no sign-in")
        #expect(try await world.store.account() == nil, "and no account keys")
        #expect(environment.sync.status == MacSyncController.movedStatus && !environment.sync.busy && !environment.sync.ready)
        #expect(try environment.store.note(id: note.id)?.text == "# Written before the move\nkept")
        await environment.sync.shutdown()
    }

    @Test(.enabled(if: HostEntitlements.hasKeychainAccessGroup, HostEntitlements.keychainSkipReason))
    func aMoveThatStoppedBeforeTheSignOutIsFinishedAtLoadWithoutTheNetwork() async throws {
        let world = World(); defer { world.cleanup() }
        try await world.signIn()
        let environment = try world.environment()
        try SyncQueue(database: environment.database).enable(accountID: world.accountID)
        let backup = LibraryBackup(database: environment.database, paths: environment.paths)
        _ = try backup.createRolling()
        // The detach committed, then the app stopped: the sign-in is still in the Keychain.
        try PrivateServerMove.leave(database: environment.database, verifiedBackupID: try #require(try backup.localBackups().first).id)
        #expect(try await world.store.load() != nil)

        await environment.sync.load()

        #expect(try await world.store.load() == nil, "the sign-out is finished")
        #expect(KeysStub.requests == 0, "before any network call")
        #expect(try CloudSyncStore(database: environment.database).backend() == SyncBackend.none, "never bound again")
        #expect(environment.sync.status == MacSyncController.movedStatus)
        await environment.sync.shutdown()
    }

    @Test(.enabled(if: HostEntitlements.hasKeychainAccessGroup, HostEntitlements.keychainSkipReason))
    func aRefusalAfterTheFinalSyncLeavesTheSignInAndTheBinding() async throws {
        let world = World(); defer { world.cleanup() }
        try await world.signIn()
        let environment = try world.environment()
        try SyncQueue(database: environment.database).configure(accountID: world.accountID)
        try SyncQueue(database: environment.database).enable(accountID: world.accountID)
        _ = try environment.store.create(text: "# Lost file\n" + AttachmentMarkdown.link(for: "gone.txt"))

        await #expect(throws: PrivateServerMoveRefusal.self) { try await environment.sync.leaveForICloud() }

        #expect(try CloudSyncStore(database: environment.database).backend() == SyncBackend.cloudflare)
        #expect(try await world.store.load() != nil, "still signed in")
        #expect(!environment.sync.busy && environment.sync.ready)
        await environment.sync.shutdown()
    }

    @Test(.enabled(if: HostEntitlements.hasKeychainAccessGroup, HostEntitlements.keychainSkipReason))
    func theRealGlueMovesWithoutAFileNoDeviceEverHad() async throws {
        let world = World(); defer { world.cleanup() }
        try await world.signIn()
        let environment = try world.environment()
        try SyncQueue(database: environment.database).configure(accountID: world.accountID)
        try SyncQueue(database: environment.database).enable(accountID: world.accountID)
        let note = try environment.store.create(text: "# Imported cover\n" + AttachmentMarkdown.link(for: "cover-001.jpg"))

        await #expect(throws: PrivateServerMoveRefusal.unavailableAttachments(notes: ["Imported cover"], moreNotes: 0, canMoveWithout: true)) {
            try await environment.sync.leaveForICloud()
        }
        try await environment.sync.leaveForICloud(withoutMissingFiles: true)

        #expect(try CloudSyncStore(database: environment.database).backend() == SyncBackend.none)
        #expect(try await world.store.load() == nil, "signed out")
        #expect(try environment.store.note(id: note.id)?.text.contains("cover-001.jpg") == true, "the note keeps its reference")
        await environment.sync.shutdown()
    }
}
