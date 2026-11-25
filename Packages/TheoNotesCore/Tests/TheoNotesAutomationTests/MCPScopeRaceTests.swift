// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Scope races (M5 Task 11 fix round 1): the note changes through a second store between the
/// service resolving it and writing it, which `AutomationService.beforeCommit` lets a test do.
@Suite struct MCPScopeRaceTests {
    private static let work = NoteScope(onlyTags: ["work"], excludeTags: [])

    /// A service whose hook runs `change` once, between resolution and write.
    private func service(
        _ lib: TestLibrary, scope: NoteScope = work, change: @escaping @Sendable () -> Void = {}
    ) -> AutomationService {
        let fired = Counter()
        return AutomationService(
            library: lib.library, context: .fixed(TestLibrary.epoch), scope: scope,
            beforeCommit: { _ in if fired.next() == 1 { change() } })
    }

    private func dropWorkTag(_ lib: TestLibrary, _ id: String) -> @Sendable () -> Void {
        { _ = try? lib.library.store.removeTag("work", from: [id], now: TestLibrary.epoch) }
    }

    private func attachmentFiles(_ lib: TestLibrary, _ id: String) -> [String] {
        let dir = lib.paths.attachments.appendingPathComponent(id, isDirectory: true).path
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }
    }

    // MARK: Fix 1 and 2: every write checks the scope when it starts

    @Test func aTagWriteCannotReadmitANoteThatLeftTheScope() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work\nbody")])
        let id = try lib.firstId()
        let error = #expect(throws: AutomationError.self) {
            try service(lib, change: dropWorkTag(lib, id)).addTags(.id(id), tags: ["work"])
        }
        #expect(error?.code == .outOfScope)
        #expect(!(try lib.text(id)).contains("#work"))
    }

    @Test func removingTagsFromANoteThatLeftTheScopeIsRefusedToo() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #x\nbody")])
        let id = try lib.firstId()
        let error = #expect(throws: AutomationError.self) {
            try service(lib, change: dropWorkTag(lib, id)).removeTags(.id(id), tags: ["x"])
        }
        #expect(error?.code == .outOfScope)
        #expect(try lib.text(id).contains("#x"))
    }

    @Test func pinAndLocationWritesCheckTheScopeToo() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work\nbody")])
        let id = try lib.firstId()
        let operations: [(String, (AutomationService) throws -> Void)] = [
            ("pin", { _ = try $0.addPins(.id(id), targets: ["global"]) }),
            ("pin in tag", { _ = try $0.addPins(.id(id), targets: ["work"]) }),
            ("trash", { _ = try $0.trash(.id(id)) }),
            ("archive", { _ = try $0.archive(.id(id)) }),
        ]
        for (name, run) in operations {
            // A fresh note each time: the tag is put back before the next round.
            try lib.library.store.addTag("work", to: [id], position: .bottom, now: TestLibrary.epoch)
            let error = #expect(throws: AutomationError.self, "\(name)") {
                try run(service(lib, change: dropWorkTag(lib, id)))
            }
            #expect(error?.code == .outOfScope, "\(name)")
            let note = try lib.note(id)
            #expect(note.location == .notes && !note.isPinnedGlobal, "\(name)")
        }
    }

    @Test func aRecordOfANoteOutsideTheScopeIsNeverReturned() throws {
        let lib = try TestLibrary.make([TestNote(text: "# H\n#home")])
        let id = try lib.firstId()
        let service = service(lib)
        #expect(throws: AutomationError.self) { try service.record(id: id) }
        #expect(throws: AutomationError.self) { try service.record(of: try lib.note(id)) }
        let open = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch))
        #expect(try open.record(id: id).id == id)
    }

    // MARK: Fix 3: no stray attachment bytes

    @Test func aRefusedAttachmentWriteLeavesNoFileBehind() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work\nbody")])
        let id = try lib.firstId()
        let error = #expect(throws: AutomationError.self) {
            try service(lib, change: dropWorkTag(lib, id)).addAttachment(
                .id(id), data: Data([1, 2, 3]), filename: "pic.png", preservingModifiedDate: false)
        }
        #expect(error?.code == .outOfScope)
        #expect(attachmentFiles(lib, id).isEmpty)
        #expect(!(try lib.text(id)).contains("pic.png"))
    }

    @Test func aCommittedAttachmentKeepsItsFileAfterARetry() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work\nbody")])
        let id = try lib.firstId()
        let other = lib.library.store
        let stored = try service(lib, change: { _ = try? other.updateText(id: id, text: "# W\n#work\nbody\nmore", expectedRevision: 1) })
            .addAttachment(.id(id), data: Data([1, 2, 3]), filename: "pic.png", preservingModifiedDate: false)
        #expect(attachmentFiles(lib, id) == [stored.filename])
        #expect(try lib.text(id).contains(stored.filename))
    }

    // MARK: Fix 4: pin targets reveal nothing

    @Test func pinTargetsOnlyHiddenNotesCarryLookLikeUnknownTags() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work"), TestNote(text: "# H\n#home")])
        let id = try lib.id(titled: "W")
        let scoped = service(lib)
        let hidden = #expect(throws: AutomationError.self) { try scoped.addPins(.id(id), targets: ["home"]) }
        let unknown = #expect(throws: AutomationError.self) { try scoped.addPins(.id(id), targets: ["nowhere"]) }
        #expect(hidden?.code == .tagNotFound && unknown?.code == .tagNotFound)
        #expect(hidden?.message == "Tag not found: #home" && unknown?.message == "Tag not found: #nowhere")
        let unpin = #expect(throws: AutomationError.self) { try scoped.removePins(.id(id), targets: ["home"]) }
        #expect(unpin?.message == "Tag not found: #home")
        // A visible tag still works.
        _ = try scoped.addPins(.id(id), targets: ["work"])
    }

    // MARK: Fix 6: rename and delete

    @Test func renameIntoATagOutsideNotesCarryIsRefusedAndRevealsNothing() throws {
        let lib = try TestLibrary.make([
            TestNote(text: "# W\n#work #mine"), TestNote(text: "# P\n#work #private"), TestNote(text: "# H\n#home"),
        ])
        let scoped = service(lib, scope: NoteScope(onlyTags: ["work"], excludeTags: ["private"]))
        for target in ["home", "private"] {
            let error = #expect(throws: AutomationError.self) {
                try scoped.renameTag(old: "mine", new: target, force: false)
            }
            #expect(error?.code == .outOfScope, "\(target)")
        }
        #expect(try lib.text(try lib.id(titled: "W")) == "# W\n#work #mine")
        // A name nobody uses is a plain rename; one that in-scope notes use still needs --force.
        #expect(try scoped.renameTag(old: "mine", new: "fresh", force: false) == 1)
    }

    @Test func renameChecksTheNewNameAgainInsideTheTransaction() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #mine"), TestNote(text: "# H\n#home")])
        let h = try lib.id(titled: "H")
        let store = lib.library.store
        let scoped = service(lib, change: { _ = try? store.addTag("shared", to: [h], position: .bottom) })
        let error = #expect(throws: AutomationError.self) {
            try scoped.renameTag(old: "mine", new: "shared", force: true)
        }
        #expect(error?.code == .outOfScope)
        #expect(try lib.text(try lib.id(titled: "W")) == "# W\n#work #mine")
    }

    @Test func deleteChecksTheTagAgainInsideTheTransaction() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #mine"), TestNote(text: "# H\n#home")])
        let h = try lib.id(titled: "H")
        let store = lib.library.store
        let scoped = service(lib, change: { _ = try? store.addTag("mine", to: [h], position: .bottom) })
        let error = #expect(throws: AutomationError.self) { try scoped.deleteTag("mine") }
        #expect(error?.code == .outOfScope)
        #expect(try lib.text(try lib.id(titled: "W")) == "# W\n#work #mine")
    }

    @Test func tagExistenceForRenameAndDeleteIsJudgedOverVisibleNotesOnly() throws {
        let lib = try TestLibrary.make([TestNote(text: "# W\n#work #orphan")])
        // A tag row no note carries (a sidebar pin keeps it): it is not the caller's to rename or delete.
        try lib.library.store.setTagPinned("orphan", pinned: true)
        try lib.library.store.removeTag("orphan", from: [try lib.firstId()])
        let before = try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tag WHERE pathKey = 'orphan'") ?? 0 }
        let scoped = service(lib)
        #expect(try scoped.renameTag(old: "orphan", new: "elsewhere", force: false) == 0)
        #expect(try scoped.deleteTag("orphan") == 0)
        let after = try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tag WHERE pathKey = 'orphan'") ?? 0 }
        #expect(before == 1 && after == 1)
    }
}
