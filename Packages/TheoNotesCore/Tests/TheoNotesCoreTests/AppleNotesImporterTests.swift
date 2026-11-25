// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct AppleNotesImporterTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-21T12:00:00Z

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func importer(
        _ client: FakeAppleNotesClient, batchSize: Int = 10,
        convert: @escaping @Sendable (String) -> HTMLToMarkdown.Result = { HTMLToMarkdown.convert($0) }
    ) -> AppleNotesImporter {
        AppleNotesImporter(store: store, paths: tmp.paths, client: client, batchSize: batchSize, now: { [now] in now },
                           convert: convert)
    }

    private func pull(_ client: FakeAppleNotesClient, batchSize: Int = 10) throws -> AppleNotesImportReport {
        try importer(client, batchSize: batchSize).pull(progress: { _, _ in }, isCancelled: { false })
    }

    private func note(_ notesID: String) throws -> Note {
        let id = try #require(try store.externalRefs(source: "applenotes")[notesID]?.noteId)
        return try #require(try store.note(id: id))
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0) }
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0xFF, 7])

    @Test func testCreatesNotesWithDatesFolderTagsAndImages() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div><h1>Shopping</h1></div><div>milk</div>", name: "Shopping", folder: "f-notes")
        client.put("n2", html: "<div><h1>Plan</h1></div><div>x</div>", name: "Plan", folder: "f-work")
        client.put("n3", html: "<div><h1>Big</h1></div><div><img src=\"data:image/png;base64,\(Self.png.base64EncodedString())\"></div>",
                   name: "Big", folder: "f-projects", attachments: 1)
        let report = try pull(client)
        #expect(report == AppleNotesImportReport(total: 3, created: 3, imagesCopied: 1))

        let a = try note("n1")
        #expect(a.text == "# Shopping\nmilk")
        #expect(a.createdAt == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(a.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(a.location == .notes)
        #expect(try tagRows(db, a.id).isEmpty)

        let b = try note("n2")
        #expect(b.text == "# Plan\nx\n\n#Work")
        #expect(try tagRows(db, b.id) == [TagRow(path: "Work", isDirect: true)])

        let c = try note("n3")
        #expect(c.text == "# Big\n![](image.png)\n\n#Work/Big Projects#")
        #expect(try tagRows(db, c.id).contains(TagRow(path: "Work/Big Projects", isDirect: true)))
        let file = tmp.paths.attachments.appendingPathComponent("\(c.id)/image.png")
        #expect(try Data(contentsOf: file) == Self.png)
        #expect(NoteParser.metadata(for: c.text).attachments.map(\.filename) == ["image.png"])
    }

    @Test func testSecondPullIsUnchangedWithoutFetchingBodies() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>")
        client.put("n2", html: "<div>B</div>", folder: "f-work")
        _ = try pull(client)
        let before = try allNotes()
        client.clearBatches()
        let report = try pull(client)
        #expect(report == AppleNotesImportReport(total: 2, unchanged: 2))
        #expect(client.batches.isEmpty)
        #expect(try allNotes() == before)
    }

    @Test func testNotesOnlyChangeUpdatesInPlace() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>Title</div><div>old</div>")
        _ = try pull(client)
        let original = try note("n1")
        client.put("n1", html: "<div>Title</div><div>new</div>", modified: 1_750_000_000)
        let report = try pull(client)
        #expect(report.updated == 1)
        #expect(report.created == 0)
        let updated = try note("n1")
        #expect(updated.id == original.id)
        #expect(updated.text == "# Title\nnew")
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.modifiedAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(try allNotes().count == 1)
        #expect(try pull(client).unchanged == 1)
    }

    @Test func testLocalFlagsSurviveNotesUpdate() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>Title</div><div>old</div>")
        _ = try pull(client)
        let original = try note("n1")
        try store.setPinned([original.id], pinned: true)
        try store.archive([original.id])
        client.put("n1", html: "<div>Title</div><div>new</div>", modified: 1_750_000_000)
        #expect(try pull(client).updated == 1)
        let after = try note("n1")
        #expect(after.isPinnedGlobal)
        #expect(after.location == .archive)
    }

    @Test func testBothChangedCreatesConflictCopy() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>Title</div><div>old</div>")
        _ = try pull(client)
        let original = try note("n1")
        _ = try store.updateText(id: original.id, text: "# Title\nmine", expectedRevision: original.revision)
        client.put("n1", html: "<div>Title</div><div>theirs</div>", modified: 1_750_000_000)

        let report = try pull(client)
        #expect(report.conflicts == 1)
        #expect(report.updated == 0)
        #expect(try store.note(id: original.id)?.text == "# Title\nmine")
        let copy = try note("n1")
        #expect(copy.id != original.id)
        #expect(copy.text == "# Title (Apple Notes conflict \(BearImporter.localDay(now)))\ntheirs")
        #expect(try allNotes().count == 2)
        #expect(try pull(client).unchanged == 1)

        // The ref moved to the copy: the next Notes edit updates it in place.
        client.put("n1", html: "<div>Title</div><div>theirs again</div>", modified: 1_760_000_000)
        let next = try pull(client)
        #expect(next.updated == 1)
        #expect(next.conflicts == 0)
        #expect(try note("n1").id == copy.id)
        #expect(try note("n1").text == "# Title\ntheirs again")
        #expect(try allNotes().count == 2)
    }

    @Test func testLocalEditWithUnchangedNotesTextIsKept() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>Title</div><div>old</div>", name: "Title")
        _ = try pull(client)
        let original = try note("n1")
        let edited = try store.updateText(id: original.id, text: "# Title\nmine", expectedRevision: original.revision)
        // Notes bumps the date (e.g. a touch) without changing the text.
        client.put("n1", html: "<div>Title</div><div>old</div>", name: "Title", modified: 1_750_000_000)
        let report = try pull(client)
        #expect(report.unchanged == 1)
        #expect(report.conflicts == 0)
        let after = try #require(try store.note(id: original.id))
        #expect(after.text == "# Title\nmine")
        #expect(after.modifiedAt == edited.modifiedAt)
        #expect(try pull(client).unchanged == 1)
    }

    @Test func testPermanentDeleteIsATombstone() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>")
        client.put("n2", html: "<div>B</div>")
        _ = try pull(client)
        try store.deletePermanently([try note("n2").id])
        client.put("n2", html: "<div>B changed</div>", modified: 1_750_000_000)
        let report = try pull(client)
        #expect(report.deletedInTheoNotes == 1)
        #expect(report.created == 0)
        #expect(report.unchanged == 1)
        #expect(try allNotes().count == 1)
    }

    @Test func testPasswordProtectedNotesAreSkippedAndReported() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>")
        client.put("secret", html: "", name: "Bank", locked: true)
        let report = try pull(client)
        #expect(report.created == 1)
        #expect(report.passwordProtected == 1)
        #expect(report.warnings == ["“Bank”: password-protected, skipped"])
        #expect(!client.batches.joined().contains("secret"))
        #expect(try allNotes().count == 1)
    }

    @Test func testRecentlyDeletedIsSkipped() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", folder: "f-deleted")
        let report = try pull(client)
        #expect(report == AppleNotesImportReport(total: 1, recentlyDeleted: 1))
        #expect(try allNotes().isEmpty)
    }

    static func twoAccountFolders() -> [AppleNotesFolder] {
        FakeAppleNotesClient.folders + [AppleNotesFolder(id: "g-notes", name: "Notes", accountID: "acc-2"),
                                        AppleNotesFolder(id: "h-notes", name: "Notes", accountID: "acc-3")]
    }
    static let otherAccount = AppleNotesAccount(id: "acc-2", name: "On My Mac", defaultFolderID: "g-notes")

    @Test func testAccountLevelWhenSeveralAccountsHaveNotesAtFirstImport() throws {
        let empty = AppleNotesAccount(id: "acc-3", name: "Gmail", defaultFolderID: "h-notes")
        let client = FakeAppleNotesClient(
            accounts: [FakeAppleNotesClient.account, Self.otherAccount, empty], folders: Self.twoAccountFolders())
        client.put("n1", html: "<div>A</div>", folder: "f-work")
        client.put("m1", html: "<div>M</div>", folder: "g-notes", account: "acc-2")
        let report = try pull(client)
        #expect(report.created == 2)
        #expect(try note("n1").text == "# A\n\n#iCloud/Work")
        #expect(try note("m1").text == "# M\n\n#On My Mac#")
        #expect(try Settings(db: db).value(AppleNotesImporter.accountLevelTagsKey) == "yes")
    }

    @Test func testSecondAccountGainingANoteRewritesNothing() throws {
        let empty = AppleNotesAccount(id: "acc-3", name: "Gmail", defaultFolderID: "h-notes")
        let client = FakeAppleNotesClient(
            accounts: [FakeAppleNotesClient.account, Self.otherAccount, empty], folders: Self.twoAccountFolders())
        client.put("n1", html: "<div>A</div>", folder: "f-work")
        _ = try pull(client)
        #expect(try note("n1").text == "# A\n\n#Work", "an account without notes does not count")
        #expect(try Settings(db: db).value(AppleNotesImporter.accountLevelTagsKey) == "no")
        let before = try note("n1")

        client.put("m1", html: "<div>M</div>", folder: "g-notes", account: "acc-2")
        let report = try pull(client)
        #expect(report.created == 1)
        #expect(report.unchanged == 1)
        #expect(report.updated == 0 && report.conflicts == 0)
        #expect(try note("n1") == before)
        #expect(try note("m1").text == "# M", "the decision made at the first import stays")
    }

    @Test func testFolderRenameOnEditedNoteKeepsTextAndWarns() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", name: "A", folder: "f-work")
        _ = try pull(client)
        let original = try note("n1")
        _ = try store.updateText(id: original.id, text: "# A\nmine\n\n#Work", expectedRevision: original.revision)
        client.renameFolder("f-work", to: "Job")
        let report = try pull(client)
        #expect(report.conflicts == 0)
        #expect(report.updated == 0)
        #expect(report.unchanged == 1)
        #expect(report.warnings == [
            "“A”: moved to “Job” in Notes; the folder tag was not changed because the note was edited in Theo Notes",
        ])
        #expect(try note("n1").text == "# A\nmine\n\n#Work")
        #expect(try allNotes().count == 1)
        #expect(try pull(client) == AppleNotesImportReport(total: 1, unchanged: 1), "warned once")
    }

    @Test func testFolderRenameOnUneditedNoteRewritesInPlace() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", folder: "f-projects")
        _ = try pull(client)
        let original = try note("n1")
        client.renameFolder("f-work", to: "Job")
        let report = try pull(client)
        #expect(report.updated == 1)
        let after = try note("n1")
        #expect(after.id == original.id)
        #expect(after.text == "# A\n\n#Job/Big Projects#")
        #expect(after.modifiedAt == original.modifiedAt)
    }

    @Test func testConverterChangeRewritesNothing() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div><div>b</div>")
        client.put("n2", html: "<div>C</div>")
        _ = try pull(client)
        let before = try allNotes()
        let newer: @Sendable (String) -> HTMLToMarkdown.Result = { html in
            var result = HTMLToMarkdown.convert(html)
            result.markdown += "\nconverter v2"
            return result
        }
        // Nothing changed in Notes.
        #expect(try importer(client, convert: newer).pull(progress: { _, _ in }, isCancelled: { false })
            == AppleNotesImportReport(total: 2, unchanged: 2))
        // Notes bumps a date but not the body: still no rewrite.
        client.put("n1", html: "<div>A</div><div>b</div>", modified: 1_750_000_000)
        let report = try importer(client, convert: newer).pull(progress: { _, _ in }, isCancelled: { false })
        #expect(report == AppleNotesImportReport(total: 2, unchanged: 2))
        #expect(try allNotes().map(\.text) == before.map(\.text))
    }

    @Test func testFolderMoveUpdatesTag() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", folder: "f-work")
        _ = try pull(client)
        client.put("n1", html: "<div>A</div>", folder: "f-notes")
        #expect(try pull(client).updated == 1)
        #expect(try note("n1").text == "# A")
    }

    @Test func testBodiesAreFetchedInBatches() throws {
        let client = FakeAppleNotesClient()
        for i in 1...25 { client.put("n\(i)", html: "<div>N\(i)</div>") }
        let report = try pull(client, batchSize: 10)
        #expect(report.created == 25)
        #expect(client.batches.map(\.count) == [10, 10, 5])
    }

    @Test func testCancelStopsBetweenNotesAndBatches() throws {
        let client = FakeAppleNotesClient()
        for i in 1...25 { client.put("n\(i)", html: "<div>N\(i)</div>") }
        var done = 0
        var seen: [Int] = []
        let report = try importer(client, batchSize: 10).pull(
            progress: { d, total in seen.append(d); done = d; #expect(total == 25) }, isCancelled: { done >= 12 })
        #expect(report.wasCancelled)
        #expect(report.created == 12)
        #expect(client.batches.map(\.count) == [10, 10])
        #expect(seen == Array(0...12))
        #expect(try allNotes().count == 12)
    }

    @Test func testOneSlowNoteDoesNotFailItsBatch() throws {
        let client = FakeAppleNotesClient()
        for i in 1...10 { client.put("n\(i)", html: "<div>N\(i)</div>", name: "N\(i)") }
        client.timingOut = ["n4"]
        let report = try pull(client, batchSize: 10)
        #expect(report.created == 9)
        #expect(report.errors == ["“N4”: Notes did not answer in time"])
        #expect(client.batches.first?.count == 10)
        #expect(client.batches.dropFirst().allSatisfy { $0.count == 1 })

        client.clearBatches()
        let again = try pull(client, batchSize: 10)
        #expect(again.unchanged == 9)
        #expect(again.errors == ["“N4”: Notes did not answer in time"])
        #expect(client.batches == [["n4"]])
        client.timingOut = []
        #expect(try pull(client).created == 1)
    }

    @Test func testStalledNotesStopsAskingAfterTwoSingleTimeouts() throws {
        let client = FakeAppleNotesClient()
        for i in 1...15 { client.put("n\(i)", html: "<div>N\(i)</div>", name: "N\(i)") }
        client.failingBatches = true
        let report = try pull(client, batchSize: 10)
        #expect(client.batches == [(1...10).map { "n\($0)" }, ["n1"], ["n2"], ["n3"]], "two timeouts, then one probe")
        #expect(report.errors.count == 15)
        #expect(report.errors[0] == "“N1”: Notes did not answer in time")
        #expect(report.errors[2] == "“N3”: Notes did not answer in time")
        #expect(report.errors[3] == "“N4”: \(AppleNotesImporter.stalledMessage)")
        #expect(report.errors[14] == "“N15”: \(AppleNotesImporter.stalledMessage)")
    }

    /// Review R17: two slow notes back to back must not block a new note, run after run.
    @Test func testTwoSlowNotesDoNotBlockTheNextNote() throws {
        let client = FakeAppleNotesClient()
        for i in 1...10 { client.put("n\(i)", html: "<div>N\(i)</div>", name: "N\(i)") }
        client.timingOut = ["n3", "n7"]
        let first = try pull(client)
        #expect(first.created == 8)
        #expect(first.errors == ["“N3”: Notes did not answer in time", "“N7”: Notes did not answer in time"])

        for next in ["n11", "n12"] {
            client.put(next, html: "<div>\(next)</div>", name: next)
            client.clearBatches()
            let report = try pull(client)
            #expect(report.created == 1)
            #expect(report.errors == ["“N3”: Notes did not answer in time", "“N7”: Notes did not answer in time"])
            #expect(client.batches == [["n3", "n7", next], ["n3"], ["n7"], [next]], "the probe answers, the stall clears")
            #expect(try store.externalRefs(source: "applenotes")[next]?.noteId != nil)
        }
    }

    /// A successful batch between two single-note timeouts resets the count.
    @Test func testSuccessfulBatchResetsTheTimeoutCount() throws {
        let client = FakeAppleNotesClient()
        for i in 1...40 { client.put("n\(i)", html: "<div>N\(i)</div>", name: "N\(i)") }
        // Without the reset, n10 + n21 would trip the stall and n22 (slow too) would fail the probe.
        client.timingOut = ["n10", "n21", "n22"]
        let report = try pull(client, batchSize: 10)
        #expect(report.created == 37)
        #expect(report.errors == [
            "“N10”: Notes did not answer in time", "“N21”: Notes did not answer in time",
            "“N22”: Notes did not answer in time",
        ])
        #expect(!report.errors.contains { $0.contains("stopped answering") })
    }

    @Test func testCancelStopsARunningBodyRequest() throws {
        let client = FakeAppleNotesClient()
        for i in 1...25 { client.put("n\(i)", html: "<div>N\(i)</div>") }
        let cancelled = Mutex(false)
        client.onBatch = { ids in if ids.contains("n11") { cancelled.withLock { $0 = true } } }
        let report = try importer(client, batchSize: 10).pull(
            progress: { _, _ in }, isCancelled: { cancelled.withLock { $0 } })
        #expect(report.wasCancelled)
        #expect(report.created == 10)
        #expect(report.errors.isEmpty)
        #expect(client.batches.map(\.count) == [10, 10], "the cancelled request is not retried note by note")
    }

    @Test func testProcessRunnerStopsOnCancel() throws {
        let start = ContinuousClock.now
        let deadline = Date().addingTimeInterval(0.3)
        #expect(throws: ProcessRunner.Stop.cancelled) {
            _ = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60,
                                      isCancelled: { Date() > deadline })
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(throws: ProcessRunner.Stop.timedOut) {
            _ = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        }
        let output = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], timeout: 10)
        #expect(output.status == 0)
        #expect(output.stdout == Data("hi\n".utf8))
    }

    @Test func testPerNoteScriptErrorKeepsTheNumber() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", name: "A")
        client.put("n2", html: "<div>B</div>", name: "B")
        client.noteErrors = ["n1": "Notes scripting error -1728 for this note"]
        let report = try pull(client)
        #expect(report.created == 1)
        #expect(report.errors == ["“A”: Notes scripting error -1728 for this note"])
    }

    @Test func testUnusableFolderNameIsReported() throws {
        let client = FakeAppleNotesClient(folders: FakeAppleNotesClient.folders + [
            AppleNotesFolder(id: "f-bad", name: "\u{20E3}x", accountID: "acc-1"),
            AppleNotesFolder(id: "f-badkid", name: "Sub", accountID: "acc-1", parentID: "f-bad"),
            AppleNotesFolder(id: "f-blank", name: "   ", accountID: "acc-1", parentID: "f-work"),
            AppleNotesFolder(id: "f-blankkid", name: "Deep", accountID: "acc-1", parentID: "f-blank"),
        ])
        client.put("n1", html: "<div>A</div>", folder: "f-bad")
        client.put("n2", html: "<div>B</div>", folder: "f-bad")
        client.put("n3", html: "<div>C</div>", folder: "f-badkid")
        client.put("n4", html: "<div>D</div>", folder: "f-blankkid")
        let report = try pull(client)
        #expect(report.created == 4)
        #expect(report.warnings == [
            "folder “\u{20E3}x”: “\u{20E3}x” cannot become a tag; its notes get no folder tag",
            "folder “\u{20E3}x / Sub”: “\u{20E3}x” cannot become a tag; its notes get no folder tag",
            "folder “Work /     / Deep”: “   ” cannot become a tag; its notes keep the tag #Work",
        ])
        #expect(try note("n1").text == "# A")
        #expect(try note("n3").text == "# C", "never a bare #Sub that could merge with a top-level Sub folder")
        #expect(try note("n4").text == "# D\n\n#Work")
        #expect(try pull(client).warnings.count == 3, "once per folder per run")
    }

    @Test func testFailedBatchIsReportedAndRetried() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", name: "A")
        client.put("n2", html: "<div>B</div>", name: "B")
        client.failingBatches = true
        let report = try pull(client)
        #expect(report.created == 0)
        #expect(report.errors == ["“A”: Notes did not answer in time", "“B”: Notes did not answer in time"])
        client.failingBatches = false
        #expect(try pull(client).created == 2)
    }

    @Test func testMissingBodyIsAnErrorForThatNoteOnly() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", name: "A")
        client.put("n2", html: "<div>B</div>", name: "B")
        client.dropBody("n1")
        let report = try pull(client)
        #expect(report.created == 1)
        #expect(report.errors == ["“A”: Notes returned no body"])
    }

    @Test func testAttachmentsNotInBodyAreReported() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>", name: "A", attachments: 2)
        let report = try pull(client)
        #expect(report.warnings == ["“A”: 2 attachment(s) not available through Notes scripting (only embedded images are imported)"])
    }

    @Test func testMissingInNotesIsCountedAndKept() throws {
        let client = FakeAppleNotesClient()
        client.put("n1", html: "<div>A</div>")
        _ = try pull(client)
        let kept = try note("n1")
        client.remove("n1")
        let report = try pull(client)
        #expect(report.missingInNotes == 1)
        #expect(try store.note(id: kept.id) == kept)
    }

    @Test func testListingFailureThrows() throws {
        struct Broken: AppleNotesClient {
            func listing() throws -> AppleNotesListing { throw AppleNotesError.notAuthorized }
            func bodies(ids: [String], isCancelled: () -> Bool) throws -> AppleNotesBodies { AppleNotesBodies() }
        }
        let importer = AppleNotesImporter(store: store, paths: tmp.paths, client: Broken())
        #expect(throws: AppleNotesError.notAuthorized) { _ = try importer.pull(progress: { _, _ in }, isCancelled: { false }) }
    }

    @Test func testNotesTitleIsUsedWhenTheBodyHasNone() throws {
        let png = Self.png.base64EncodedString()
        let client = FakeAppleNotesClient()
        client.put("n1", html: "", name: "Empty #1 *x* _y_ [z]", folder: "f-work")
        client.put("n2", html: "<div><img src=\"data:image/png;base64,\(png)\"></div>", name: "Photo")
        client.put("n3", html: "<div>Own title</div>", name: "Other")
        _ = try pull(client)
        #expect(try note("n1").text == "# Empty \\#1 \\*x\\* \\_y\\_ \\[z\\]\n\n#Work")
        #expect(NoteParser.metadata(for: try note("n1").text).title == "Empty #1 *x* _y_ [z]")
        #expect(NoteParser.metadata(for: try note("n1").text).tags == ["Work"])
        #expect(try note("n2").text == "# Photo\n![](image.png)")
        #expect(try note("n3").text == "# Own title")
    }

    @Test func testFolderTags() {
        #expect(AppleNotesImporter.tag(["Work"]) == "#Work")
        #expect(AppleNotesImporter.tag(["Work", "Sub"]) == "#Work/Sub")
        #expect(AppleNotesImporter.tag(["My  Folder", "Sub"]) == "#My Folder/Sub#")
        #expect(AppleNotesImporter.tag(["2026"]) == "#2026#")
        #expect(AppleNotesImporter.tag(["A/B"]) == "#A-B")
        #expect(AppleNotesImporter.tag(["Q&A", "Notes."]) == "#Q&A/Notes.#")
        #expect(AppleNotesImporter.tag(["Ünïcödé 🐻"]) == "#Ünïcödé 🐻#")
        #expect(AppleNotesImporter.tag([" "]) == nil)
        for tag in ["#My Folder/Sub#", "#2026#", "#Q&A/Notes.#"] {
            #expect(TagScanner.tags(inLine: tag).count == 1)
        }
    }

    // MARK: - Scripting client (no Notes needed)

    @Test func testScriptErrorsAreMapped() {
        func err(_ s: String) -> AppleNotesError { ScriptingAppleNotesClient.error(stderr: Data(s.utf8)) }
        #expect(err("execution error: Error: Not authorized to send Apple events to Notes. (-1743)") == .notAuthorized)
        #expect(err("execution error: Error: Application isn't running. (-600)") == .notesUnavailable)
        #expect(err("execution error: Error: AppleEvent timed out. (-1712)") == .timedOut)
        #expect(err("execution error: Error: Can't get object. (-1728)") == .scriptFailed(code: -1728, kind: "Error"))
        #expect(err("garbage") == .scriptFailed(code: nil, kind: "unknown"))
    }

    /// osascript can echo a note or folder name in its message: reports keep only the error
    /// number and class.
    @Test func testScriptErrorKeepsNoMessageText() {
        let error = ScriptingAppleNotesClient.error(stderr: Data(
            "0:120: execution error: TypeError: Secret Diary Entry is not an object (-2700)".utf8))
        #expect(error == .scriptFailed(code: -2700, kind: "TypeError"))
        #expect(!error.description.contains("Secret"))
        #expect(error.description == "Notes scripting error -2700 (TypeError)")
        let noCode = ScriptingAppleNotesClient.error(stderr: Data("execution error: “My Folder” is busy".utf8))
        #expect(noCode == .scriptFailed(code: nil, kind: "unknown"))
        #expect(!noCode.description.contains("Folder"))
    }

    @Test func testListingDecodes() throws {
        let json = """
            {"accounts":[{"id":"a","name":"iCloud","defaultFolder":"f"}],
             "folders":[{"id":"f","name":"Notes","account":"a","parent":null},{"id":"g","name":"Sub","account":"a","parent":"f"}],
             "notes":[{"id":"n","name":"T","created":"2026-01-02T03:04:05.678Z","modified":"2026-01-03T00:00:00.000Z",
                       "account":"a","folder":"g","locked":false}]}
            """
        let listing = try ScriptingAppleNotesClient.decodeListing(Data(json.utf8))
        #expect(listing.accounts == [AppleNotesAccount(id: "a", name: "iCloud", defaultFolderID: "f")])
        #expect(listing.folderPath("g").map(\.name) == ["Notes", "Sub"])
        #expect(listing.notes.first?.created == Date(timeIntervalSince1970: 1_767_323_045.678))
        #expect(throws: AppleNotesError.invalidOutput) { _ = try ScriptingAppleNotesClient.decodeListing(Data("nope".utf8)) }
        let bodies = try ScriptingAppleNotesClient.decodeBodies(Data(#"[{"id":"n","body":"<div>x</div>","attachments":2},{"id":"m","error":"-1728"},{"id":"o","error":""}]"#.utf8))
        #expect(bodies == AppleNotesBodies(
            bodies: ["n": AppleNotesBody(html: "<div>x</div>", attachmentCount: 2)],
            errors: ["m": "Notes scripting error -1728 for this note", "o": "Notes could not read this note"]))
        #expect(ScriptingAppleNotesClient().bodyTimeout(count: 10) == 360)
    }

    @Test func testBodiesRejectOptionLikeIDs() {
        #expect(throws: AppleNotesError.invalidOutput) {
            _ = try ScriptingAppleNotesClient().bodies(ids: ["-e"], isCancelled: { false })
        }
    }

    /// `BAERCHEN_LIVE_APPLENOTES=1`: imports Jan's Apple Notes into a temp data dir twice and
    /// prints counts only. Triggers the Automation prompt for Notes on first run.
    @Test func testLiveAppleNotesIntoTempDir() throws {
        guard ProcessInfo.processInfo.environment["BAERCHEN_LIVE_APPLENOTES"] == "1" else { return }
        #expect(tmp.paths.root.path != AppPaths.production.root.path)
        let fileDB = try AppDatabase(path: tmp.paths.database)
        let liveStore = NoteStore(db: fileDB, notifier: nil, paths: tmp.paths)
        let client = ScriptingAppleNotesClient()
        let listing = try client.listing()
        let importer = AppleNotesImporter(store: liveStore, paths: tmp.paths, client: client)
        let first = try importer.pull(progress: { _, _ in }, isCancelled: { false })
        let second = try importer.pull(progress: { _, _ in }, isCancelled: { false })
        let counts = try fileDB.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT noteId) FROM note_stats WHERE hasImages OR hasFiles") ?? 0)
        }
        let usedAccounts = Set(listing.notes.map(\.accountID)).count
        print("LIVE_AN_LISTING accounts=\(listing.accounts.count) accountsWithNotes=\(usedAccounts) folders=\(listing.folders.count) notes=\(listing.notes.count)")
        print("LIVE_AN_PULL1 total=\(first.total) created=\(first.created) locked=\(first.passwordProtected) recentlyDeleted=\(first.recentlyDeleted) images=\(first.imagesCopied) errors=\(first.errors.count) warnings=\(first.warnings.count)")
        print("LIVE_AN_PULL2 total=\(second.total) unchanged=\(second.unchanged) created=\(second.created) updated=\(second.updated) conflicts=\(second.conflicts)")
        for warning in first.warnings { print("LIVE_AN_WARNING \(warning.components(separatedBy: "”: ").last ?? "")") }
        print("LIVE_AN_DB notes=\(counts.0) tags=\(counts.1) notesWithAttachments=\(counts.2)")
        let texts = try fileDB.pool.read { try String.fetchAll($0, sql: "SELECT text FROM note") }
        let leftover = texts.filter { $0.contains("<div") || $0.contains("<br") || $0.contains("&nbsp;") }.count
        let untitled = texts.filter { NoteParser.metadata(for: $0).title.isEmpty }.count
        print("LIVE_AN_CHECK leftoverHTML=\(leftover) untitled=\(untitled)")
        #expect(leftover == 0)
        #expect(first.errors.isEmpty)
        #expect(second.created + second.updated + second.conflicts == 0)
    }
}
