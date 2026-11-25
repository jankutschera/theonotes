// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Scope fix round 2: what a caller is told when the change committed and the note then left the
/// scope, hidden descendant tag rows, and the cleanup report.
@Suite struct MCPScopeCommittedTests {
    private static let work = NoteScope(onlyTags: ["work"], excludeTags: [])
    private static let saved = AutomationError(
        code: .outOfScope, message: "The change was saved, but the note is now outside this server's scope",
        details: .object([("committed", .bool(true))]))

    private func service(
        _ lib: TestLibrary, before: @escaping @Sendable () -> Void = {}, after: @escaping @Sendable () -> Void = {}
    ) -> AutomationService {
        let beforeFired = Counter()
        let afterFired = Counter()
        return AutomationService(
            library: lib.library, context: .fixed(TestLibrary.epoch), scope: Self.work,
            beforeCommit: { _ in if beforeFired.next() == 1 { before() } },
            afterCommit: { if afterFired.next() == 1 { after() } })
    }

    /// Takes `#work` off every note, as the app would between the commit and the readback.
    private func dropWorkTags(_ lib: TestLibrary) -> @Sendable () -> Void {
        {
            let ids = (try? lib.library.database.pool.read { try String.fetchAll($0, sql: "SELECT id FROM note") }) ?? []
            _ = try? lib.library.store.removeTag("work", from: ids, now: TestLibrary.epoch)
        }
    }

    // MARK: Committed, then out of scope

    @Test func aCommittedChangeSaysSoWhenTheNoteLeftTheScope() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work\nbody")])
        let id = try lib.firstId()
        let operations: [(String, (AutomationService) throws -> Void, () throws -> Bool)] = [
            (
                "append",
                { _ = try $0.append(.id(id), content: "more", position: .end, address: nil, preservingModifiedDate: false) },
                { try lib.text(id).contains("more") }
            ),
            ("add tags", { _ = try $0.addTags(.id(id), tags: ["extra"]) }, { try lib.text(id).contains("#extra") }),
            ("pin", { _ = try $0.addPins(.id(id), targets: ["global"]) }, { try lib.note(id).isPinnedGlobal }),
            ("trash", { _ = try $0.trash(.id(id)) }, { try lib.note(id).location == .trash }),
        ]
        for (name, run, persisted) in operations {
            try lib.library.store.addTag("work", to: [id], position: .bottom, now: TestLibrary.epoch)
            let error = #expect(throws: AutomationError.self, "\(name)") {
                try run(service(lib, after: dropWorkTags(lib)))
            }
            #expect(error == Self.saved, "\(name)")
            #expect(try persisted(), "\(name): the change is stored")
        }
    }

    @Test func aCommittedCreateSaysSoWhenTheNoteLeftTheScope() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work")])
        let error = #expect(throws: AutomationError.self) {
            try service(lib, after: dropWorkTags(lib)).create(
                title: "New", content: "", tags: [], ifNotExists: false, template: nil)
        }
        #expect(error == Self.saved)
        #expect(try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 2)
    }

    @Test func refusalsBeforeTheCommitCarryNoCommittedDetail() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work\nbody")])
        let id = try lib.firstId()
        let start = #expect(throws: AutomationError.self) {
            try service(lib, before: dropWorkTags(lib)).addTags(.id(id), tags: ["work"])
        }
        #expect(start?.code == .outOfScope && start?.details == nil)
        #expect(start?.message == "Note is outside this server's scope: \(id)")
        try lib.library.store.addTag("work", to: [id], position: .bottom, now: TestLibrary.epoch)
        let end = #expect(throws: AutomationError.self) {
            try service(lib).overwrite(
                .id(id), content: "# W\nno tag", base: nil, address: nil, gate: .mcp(expected: nil),
                preservingModifiedDate: false)
        }
        #expect(end?.code == .outOfScope && end?.details == nil)
        #expect(end?.message == "The change would move the note out of this server's scope")
    }

    // MARK: Pins in one transaction

    @Test func severalPinTargetsAreOneTransaction() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work")])
        let id = try lib.firstId()
        let refuse = lib.library.store.guarded { _, stage in
            if stage == .beforeCommit { throw AutomationError(code: .outOfScope, message: "no") }
        }
        #expect(throws: AutomationError.self) {
            try refuse.setPins([id], pinned: true, inTags: ["work"], global: true)
        }
        #expect(try lib.note(id).isPinnedGlobal == false)
        let pins = try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_pin") }
        #expect(pins == 0)
        // And through the service: the tag pin and the global pin land together.
        let result = try service(lib).addPins(.id(id), targets: ["work", "global"])
        #expect(result.after.pins.count == 2)
    }

    // MARK: Hidden descendant tag rows

    private func insertHiddenRow(_ lib: TestLibrary, _ key: String) throws {
        try lib.library.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO tag (id, pathKey, displayPath, isPinned) VALUES (?, ?, ?, 1)",
                arguments: [UUID().uuidString, key, key])
        }
    }

    @Test func renameAndDeleteRefuseASubtreeWithRowsNoVisibleNoteCarries() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #proj")])
        try insertHiddenRow(lib, "proj/orphan")
        let scoped = service(lib)
        let rename = #expect(throws: AutomationError.self) { try scoped.renameTag(old: "proj", new: "plan", force: false) }
        let delete = #expect(throws: AutomationError.self) { try scoped.deleteTag("proj") }
        #expect(rename?.code == .outOfScope && delete?.code == .outOfScope)
        #expect(rename?.message == "The tag #proj is used by notes outside this server's scope")
        #expect(try lib.text(try lib.firstId()) == "# W\n#work #proj")
        // Unrestricted callers are unchanged.
        let open = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch))
        #expect(try open.renameTag(old: "proj", new: "plan", force: false) == 1)
    }

    @Test func theHiddenRowCheckRunsAgainInsideTheTransaction() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #proj")])
        let scoped = service(lib, before: { try? self.insertHiddenRow(lib, "proj/orphan") })
        let error = #expect(throws: AutomationError.self) { try scoped.deleteTag("proj") }
        #expect(error?.code == .outOfScope)
        #expect(try lib.text(try lib.firstId()) == "# W\n#work #proj")
    }

    @Test func descendantsCarriedByVisibleNotesStillRename() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #proj/child")])
        #expect(try service(lib).renameTag(old: "proj", new: "plan", force: false) == 1)
        #expect(try lib.text(try lib.firstId()) == "# W\n#work #plan/child")
    }

    // MARK: Cleanup report

    @Test func aFailedCleanupIsReportedWithFileAndNoteOnly() {
        struct Boom: Error {}
        let reported = Reports()
        AutomationService.discard(
            "pic.png", of: "note-1", remove: { _, _ in throw Boom() }, report: { name, note, _ in reported.add("\(name)|\(note)") })
        AutomationService.discard("ok.png", of: "note-2", remove: { _, _ in }, report: { _, _, _ in reported.add("unexpected") })
        #expect(reported.values == ["pic.png|note-1"])
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var values: [String] { lock.withLock { items } }
}
