// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A creating link request that is sent again because its answer never arrived gets the first
/// note back instead of a second one.
@Suite struct XCallbackRetryTests {
    private func executor(_ library: AutomationLibrary, clipboard: String? = nil) -> XCallbackExecutor {
        XCallbackExecutor(
            library: library, context: .fixed(TestLibrary.epoch), selectedNoteId: { nil }, clipboard: { clipboard })
    }

    private func create(_ library: AutomationLibrary, _ query: String, clipboard: String? = nil) throws -> XCallbackOutcome {
        executor(library, clipboard: clipboard).execute(try XCallbackTests.request("create", query))
    }

    private func identifier(_ outcome: XCallbackOutcome) -> String? {
        outcome.success?.first { $0.0 == "identifier" }?.1
    }

    private func noteCount(_ library: AutomationLibrary) throws -> Int {
        try library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note WHERE deletedAt IS NULL") ?? 0 }
    }

    @Test func sameUnansweredRequestTwiceGivesOneNoteAndTheSameAnswer() throws {
        let lib = try TestLibrary.make()
        let first = try create(lib.library, "title=Retry&text=Body&x-success=shortcuts://ok")
        let second = try create(lib.library, "title=Retry&text=Body&x-success=shortcuts://ok")
        #expect(first.failure == nil && second.failure == nil)
        let id = try #require(identifier(first))
        #expect(identifier(second) == id)
        #expect(second.ui == first.ui)
        #expect(try noteCount(lib.library) == 1)
    }

    @Test func differentRequestsGiveTwoNotes() throws {
        let lib = try TestLibrary.make()
        let first = try create(lib.library, "text=One")
        let second = try create(lib.library, "text=Two")
        #expect(identifier(first) != identifier(second))
        #expect(try noteCount(lib.library) == 2)
        // The clipboard is part of the request it was read for.
        let a = try create(lib.library, "clipboard=yes", clipboard: "first copy")
        let b = try create(lib.library, "clipboard=yes", clipboard: "second copy")
        #expect(identifier(a) != identifier(b))
        #expect(try noteCount(lib.library) == 4)
    }

    @Test func anAnsweredRequestIsCreatedAgain() throws {
        let lib = try TestLibrary.make()
        let first = try create(lib.library, "text=Water")
        let receipt = try #require(first.receipt)
        let receipts = XCallbackReceipts(database: lib.library.database)
        // The executor's clock is `TestLibrary.epoch`: settle on the same clock, or every entry
        // would already count as expired and this would pass with a broken `settle`.
        #expect(receipts.count == 1)
        receipts.settle(receipt, now: TestLibrary.epoch)
        #expect(receipts.count == 0)
        let second = try create(lib.library, "text=Water")
        #expect(identifier(second) != identifier(first))
        #expect(try noteCount(lib.library) == 2)
    }

    @Test func aFailedCreateLeavesNoReceipt() throws {
        let lib = try TestLibrary.make()
        let failed = try create(lib.library, "text=&title=")
        #expect(failed.failure != nil && failed.receipt == nil)
        #expect(XCallbackReceipts(database: lib.library.database).count == 0)
    }

    @Test func theMemoryIsBoundedInSizeAndTime() throws {
        let lib = try TestLibrary.make()
        let receipts = XCallbackReceipts(database: lib.library.database)
        let note = try lib.library.store.create(text: "Kept")
        let start = TestLibrary.epoch
        for index in 0..<(XCallbackReceipts.capacity + 8) {
            receipts.record("f\(index)", noteID: note.id, now: start.addingTimeInterval(Double(index)))
        }
        #expect(receipts.count == XCallbackReceipts.capacity)
        let late = start.addingTimeInterval(Double(XCallbackReceipts.capacity + 8))
        #expect(receipts.noteID(for: "f0", now: late) == nil)
        #expect(receipts.noteID(for: "f\(XCallbackReceipts.capacity + 7)", now: late) == note.id)
        let expired = start.addingTimeInterval(XCallbackReceipts.lifetime + Double(XCallbackReceipts.capacity + 8))
        #expect(receipts.noteID(for: "f\(XCallbackReceipts.capacity + 7)", now: expired) == nil)
        // A clock set back does not keep a receipt alive either.
        #expect(receipts.noteID(for: "f\(XCallbackReceipts.capacity + 7)", now: start.addingTimeInterval(-60)) == nil)
    }

    /// A first note in the Trash does not count; an archived one does.
    @Test func aTrashedFirstNoteCreatesAgainAndAnArchivedOneCounts() throws {
        let lib = try TestLibrary.make()
        let archived = try #require(identifier(try create(lib.library, "text=Archived")))
        try lib.library.store.archive([archived])
        #expect(identifier(try create(lib.library, "text=Archived")) == archived)
        let trashed = try #require(identifier(try create(lib.library, "text=Trashed")))
        try lib.library.store.trash([trashed])
        let again = try #require(identifier(try create(lib.library, "text=Trashed")))
        #expect(again != trashed)
    }

    /// No hash outlives the hour, whether or not another request comes.
    @Test func expiredReceiptsAreRemovedAtOpenAndBeforeEveryLookupAndWrite() throws {
        let lib = try TestLibrary.make()
        let note = try lib.library.store.create(text: "Kept")
        let receipts = XCallbackReceipts(database: lib.library.database)
        let now = Date()
        let old = now.addingTimeInterval(-XCallbackReceipts.lifetime - 60)
        receipts.record("old", noteID: note.id, now: old)
        #expect(receipts.count == 1)
        try lib.library.database.pool.close()
        let opened = try AppDatabase(path: lib.paths.database)
        #expect(XCallbackReceipts(database: opened).count == 0)
        XCallbackReceipts(database: opened).record("fresh", noteID: note.id, now: now)
        try opened.pool.close()
        let reopened = XCallbackReceipts(database: try AppDatabase(path: lib.paths.database))
        #expect(reopened.count == 1)

        let past = now.addingTimeInterval(XCallbackReceipts.lifetime + 1)
        #expect(reopened.noteID(for: "other", now: past) == nil)
        #expect(reopened.count == 0)
        reopened.record("again", noteID: note.id, now: now)
        reopened.settle("other", now: past)
        #expect(reopened.count == 0)
    }

    @Test func aReceiptOfADeletedNoteCreatesAgain() throws {
        let lib = try TestLibrary.make()
        let first = try create(lib.library, "text=Gone")
        let id = try #require(identifier(first))
        try lib.library.store.deletePermanently([id])
        let second = try create(lib.library, "text=Gone")
        #expect(identifier(second) != id)
        #expect(try noteCount(lib.library) == 1)
    }

    @Test func aRestartBetweenTheAttemptsStillGivesOneNote() throws {
        let lib = try TestLibrary.make()
        let first = try create(lib.library, "title=Restart&text=Body")
        let id = try #require(identifier(first))
        try lib.library.database.pool.close()
        let reopened = try AutomationLibrary.open(dataDir: lib.paths.root.path, environment: [:])
        let second = try create(reopened, "title=Restart&text=Body")
        #expect(identifier(second) == id)
        #expect(try noteCount(reopened) == 1)
    }

    @MainActor @Test func theMobileDispatcherSharesTheReceipts() async throws {
        let lib = try TestLibrary.make()
        let library = lib.library
        let dispatcher = MobileXCallbackDispatcher(database: library.database, paths: library.paths, store: library.store)
        func request(_ text: String) throws -> MobileXCallbackRequest {
            var url = URLComponents(string: "theonotes://x-callback-url/create")!
            url.queryItems = [URLQueryItem(name: "title", value: "Mobile"), URLQueryItem(name: "text", value: text),
                              URLQueryItem(name: "x-success", value: "shortcuts://ok")]
            return try MobileXCallbackRequest(url.url!)
        }
        let first = try await dispatcher.execute(request("Body"), token: nil)
        let second = try await dispatcher.execute(request("Body"), token: nil)
        let id = try #require(first.values["identifier"])
        #expect(second.values == first.values && second.noteID == id)
        #expect(try noteCount(library) == 1)
        let other = try await dispatcher.execute(request("Other"), token: nil)
        #expect(other.values["identifier"] != id)
        XCallbackReceipts(database: library.database).settle(try #require(second.receipt))
        let again = try await dispatcher.execute(request("Body"), token: nil)
        #expect(again.values["identifier"] != id)
        #expect(try noteCount(library) == 3)
    }
}
