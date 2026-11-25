// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// CK-R19: the sealed payload, the reader and the applier are transport-neutral. A second transport (our own server, the user's
/// own storage) brings its own gateway and tables and reuses these files as they are.
@Suite struct CloudSyncNeutralityTests {
    static let neutralFiles = ["CloudPayloadSealer", "CloudRemoteReader", "CloudApplier", "CloudApplier+Notes", "CloudApplier+Metadata"]

    @Test func theNeutralFilesMentionNoTransportOrStateTable() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TheoNotesCore/CloudSync")
        for name in Self.neutralFiles {
            let source = try String(contentsOf: sources.appendingPathComponent(name + ".swift"), encoding: .utf8)
            for banned in ["CloudKit", "CKRecord", "ck_", "CloudRecord", "CloudSyncStore", "systemFields", "CloudGateway", "import CloudKit"] {
                #expect(!source.contains(banned), "\(name).swift must stay neutral but contains \(banned)")
            }
        }
    }

    @Test func aSealedPayloadOpensAndAppliesWithNoGatewayNoStoreAndNoChangeTag() async throws {
        let key = SymmetricKey(data: Data(repeating: 5, count: 32)), account = "neutral-account"
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ck-neutral-\(UUID())"))
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase(path: paths.database)
        try SyncQueue(database: db).configure(accountID: account)
        // The sender: any code that can produce the sealed bytes of the spec.
        var payload = SyncNotePayload(note: Note(id: "neutral-1", text: "# Neutral\nbody\n", title: "Neutral", titleKey: "neutral", createdAt: .now, modifiedAt: .now),
                                      directTags: [], pinnedTags: [], attachmentIds: [])
        payload.attachmentNames = [:]
        let sealer = CloudPayloadSealer(accountID: account, vaultKey: key)
        let sealed = try sealer.sealLive(SyncPayloadCodec.encoder().encode(payload), type: .note, entityID: "neutral-1")
        let version = RemoteVersion(entityType: .note, entityId: "neutral-1", ver: 1, sid: "sid-1", sealed: sealed, blobRefs: [], lineage: "any-opaque-token")
        // The receiver: only plain values and a commit that is a plain transaction.
        let value = try CloudRemoteReader(sealer: sealer).read(sealed: version.sealed, type: version.entityType, entityId: version.entityId, blobRefs: version.blobRefs)
        let input = CloudApplyInput(version: version, value: value, base: nil, hasBase: false, mergeIdentity: (version.sid, version.ver), mergingInflight: false,
                                    siblings: { _, _ in nil }, precondition: { _ in }, siblingStillCurrent: { _, _, _, _ in true }, lockEnvelopeWaiting: false,
                                    independent: false, consumeSiblings: { _, _ in },
                                    requireUnpublishedProtectedLibrary: { _ in }, isUnpublishedNote: { _, _ in true }, noteAccess: nil, remoteNotePassword: nil)
        let applier = CloudApplier(database: db, paths: paths, accountID: account, vaultKey: key, blobs: NoBlobTransport())
        let outcome = try await applier.apply(input, commit: { write in try db.pool.write { try write($0) } })
        #expect(outcome == .applied(consumed: []))
        let text = try await db.pool.read { try Note.fetchOne($0, key: "neutral-1")?.text }
        let dirty = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty") }
        #expect(text == "# Neutral\nbody\n")
        #expect(dirty == 0, "applying is not an edit")
    }
}
