// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncInboxTests {
    private func entity(sequence: Int64, revision: Int64 = 1) -> SyncEntity {
        SyncEntity(mutation: SyncMutation(mutationId: "mutation-\(sequence)", entityType: .note, entityId: "note", parentRevision: revision - 1,
                                         ciphertext: "YWJj"), revision: revision, sequence: sequence, receivedAt: 1)
    }

    @Test func encryptedPageAndCursorSurviveRestartAndLockedRecordsStayQueued() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-inbox-\(UUID())"))
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let first = try AppDatabase(path: paths.database)
        try SyncQueue(database: first).enable(accountID: "account")
        let inbox = SyncInbox(database: first)
        let one = entity(sequence: 3), two = entity(sequence: 5, revision: 2)
        try inbox.persist(SyncPullResult(changes: [one, two], cursor: 5, hasMore: true), requestedAfter: 0)
        try inbox.waitForUnlock(one)
        try first.pool.close()
        let reopened = try AppDatabase(path: paths.database)
        defer { try? reopened.pool.close() }
        let resumed = SyncInbox(database: reopened)
        #expect(try resumed.cursor() == 5)
        #expect(try resumed.pending() == [one, two])
        #expect(try resumed.pending(includingLocked: false) == [two])
        #expect(try resumed.waitingForUnlockCount() == 1)
        #expect(try SyncQueue(database: reopened).pendingCount() == 0)
        #expect(throws: SyncInboxError.cursorChanged) {
            try resumed.persist(SyncPullResult(changes: [one, two], cursor: 5, hasMore: true), requestedAfter: 0)
        }
        try resumed.persist(SyncPullResult(changes: [], cursor: 5, hasMore: false), requestedAfter: 5)
    }

    @Test func invalidOrContradictoryPagesCannotAdvanceCursorOrDropCiphertext() throws {
        let db = try AppDatabase.inMemory()
        try SyncQueue(database: db).enable(accountID: "account")
        let inbox = SyncInbox(database: db)
        let one = entity(sequence: 1), two = entity(sequence: 2, revision: 2)
        for page in [SyncPullResult(changes: [two, one], cursor: 2, hasMore: false),
                     SyncPullResult(changes: [one], cursor: 3, hasMore: false),
                     SyncPullResult(changes: [], cursor: 0, hasMore: true)] {
            #expect(throws: SyncInboxError.invalidPage) { try inbox.persist(page, requestedAfter: 0) }
        }
        #expect(try inbox.cursor() == 0 && inbox.pending().isEmpty)
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO sync_inbox(sequence,entityType,entityId,serverRevision,wireEntity) VALUES(1,'note','note',2,?)",
                           arguments: [try JSONEncoder().encode(entity(sequence: 1, revision: 2))])
        }
        #expect(throws: SyncInboxError.sequenceCollision) {
            try inbox.persist(SyncPullResult(changes: [one, two], cursor: 2, hasMore: false), requestedAfter: 0)
        }
        #expect(try inbox.cursor() == 0)
        #expect(try inbox.pending().count == 1)
    }
}
