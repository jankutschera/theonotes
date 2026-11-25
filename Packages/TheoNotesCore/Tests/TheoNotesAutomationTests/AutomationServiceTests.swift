// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// The write service: retrying mutation, section results, gate modes.
@Suite struct AutomationServiceTests {
    private func service(_ lib: TestLibrary) -> AutomationService {
        AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch))
    }

    @Test func retryReappliesTransformOnRevisionConflict() throws {
        let lib = try TestLibrary.make([TestNote(text: "base")])
        let id = try lib.firstId()
        let calls = Counter()
        let result = try service(lib).mutate(.id(id), preservingModifiedDate: false) { note, _ in
            if calls.next() == 1 {
                // Another writer commits between our read and our write.
                _ = try? lib.library.store.updateText(
                    id: id, text: note.text + "\nother", expectedRevision: note.revision)
            }
            return note.text + "\nmine"
        }
        #expect(calls.value == 2)
        #expect(try lib.text(id) == "base\nother\nmine")
        #expect(result.before.content == "base\nother" && result.after.content == "base\nother\nmine")
    }

    @Test func givesUpAfterEightAttemptsWithBusy() throws {
        let lib = try TestLibrary.make([TestNote(text: "base")])
        let id = try lib.firstId()
        let calls = Counter()
        let error = #expect(throws: AutomationError.self) {
            try service(lib).mutate(.id(id), preservingModifiedDate: false) { note, _ in
                _ = calls.next()
                _ = try? lib.library.store.updateText(
                    id: id, text: note.text + "x", expectedRevision: note.revision)
                return note.text + "mine"
            }
        }
        #expect(calls.value == 8)
        #expect(error?.code == .busy && error?.message == "The note kept changing; try again")
    }

    @Test func unchangedTextWritesNothing() throws {
        let lib = try TestLibrary.make([TestNote(text: "same")])
        let id = try lib.firstId()
        let result = try service(lib).mutate(.id(id), preservingModifiedDate: false) { note, _ in note.text }
        #expect(result.before == result.after)
        #expect(try lib.note(id).revision == 1)
        // Content that only differs in line endings is the same text once stored.
        let crlf = try service(lib).mutate(.id(id), preservingModifiedDate: false) { _, _ in "same\r" }
        #expect(crlf.before.length == 4 && crlf.after.length == 5)
    }

    @Test func mutateRefusesLockedAndReadOnlyBeforeTheTransformRuns() throws {
        let lib = try TestLibrary.make([TestNote(text: "a", locked: true), TestNote(text: "b", readOnly: true)])
        let ran = Counter()
        for index in 0..<2 {
            let id = try lib.library.database.pool.read {
                try String.fetchOne($0, sql: "SELECT id FROM note ORDER BY rowid LIMIT 1 OFFSET ?", arguments: [index])
            }
            let error = #expect(throws: AutomationError.self) {
                try service(lib).mutate(.id(try #require(id)), preservingModifiedDate: false) { note, _ in
                    _ = ran.next()
                    return note.text
                }
            }
            #expect(error?.code == (index == 0 ? .noteLocked : .readOnly))
        }
        #expect(ran.value == 0)
    }

    @Test func baseMismatchIsCaughtOnTheRetryAfterARacingWrite() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n## B\nb\n")])
        let id = try lib.firstId()
        let base = ContentHash.of("# T\n## A\na\n## B\nb\n")
        let store = lib.library.store
        let racing = Service(lib) { attempt in
            // Between the service's read and its commit, another writer changes the note.
            if attempt == 0, let note = try? store.note(id: id) {
                _ = try? store.updateText(id: id, text: note.text + "c\n", expectedRevision: note.revision)
            }
        }
        let error = #expect(throws: AutomationError.self) {
            try racing.overwrite(
                .id(id), content: "# T", base: base, address: nil, gate: .cli(force: false), preservingModifiedDate: false)
        }
        #expect(error?.code == .staleHash)
        #expect(try lib.text(id) == "# T\n## A\na\n## B\nb\nc\n")  // nothing of ours was written
        // The same race on another section does not matter for a section hash.
        let sectionHash = ContentHash.of("## A\na\n")
        let fine = Service(lib) { attempt in
            if attempt == 0, let note = try? store.note(id: id) {
                _ = try? store.updateText(id: id, text: note.text + "d\n", expectedRevision: note.revision)
            }
        }
        _ = try fine.overwrite(
            .id(id), content: "## A\nnew", base: sectionHash, address: "## A", gate: .cli(force: false),
            preservingModifiedDate: false)
        #expect(try lib.text(id) == "# T\n## A\nnew\n## B\nb\nc\nd\n")
    }

    @Test func aTitleSelectorStaysOnTheSameNoteAcrossRetries() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Target\nx"), TestNote(text: "# Other\ny")])
        let id = try lib.id(titled: "Target")
        let otherId = try lib.id(titled: "Other")
        let store = lib.library.store
        let racing = Service(lib) { attempt in
            // The target is renamed by another writer and a new note takes its title.
            if attempt == 0, let note = try? store.note(id: id) {
                _ = try? store.updateText(id: id, text: "# Renamed\nx", expectedRevision: note.revision)
                _ = try? store.create(text: "# Target\nimpostor")
            }
        }
        _ = try racing.append(.title("Target"), content: "added", position: .end, address: nil, preservingModifiedDate: false)
        #expect(try lib.text(id) == "# Renamed\nx\nadded\n")
        #expect(try lib.text(otherId) == "# Other\ny")
    }

    @Test func createTitleKeepsABOMFirst() {
        #expect(AutomationService.addingTitle("Hi", to: "\u{FEFF}body") == "\u{FEFF}# Hi\nbody")
        #expect(AutomationService.addingTitle("Hi", to: "\u{FEFF}Hi\nbody") == "\u{FEFF}Hi\nbody")
        #expect(NoteParser.metadata(for: AutomationService.addingTitle("Hi", to: "\u{FEFF}body")).title == "Hi")
    }

    @Test func appendReturnsTheGrownSection() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n## B\nb\n")])
        let id = try lib.firstId()
        let (result, section) = try service(lib).append(
            .id(id), content: "a2", position: .end, address: "## A", preservingModifiedDate: false)
        #expect(result.after.content == "# T\n## A\na\na2\n## B\nb\n")
        #expect(section == OutlineEntry(address: "## A", offset: 4, length: 10))
        let (whole, none) = try service(lib).append(
            .id(id), content: "z", position: .end, address: nil, preservingModifiedDate: false)
        #expect(none == nil && whole.after.content?.hasSuffix("b\nz\n") == true)
    }

    @Test func editReturnsTheSectionOfEachFirstMatch() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\nx\n## A\ny\n")])
        let id = try lib.firstId()
        let (result, ops) = try service(lib).edit(
            .id(id), edits: [EditSpec(find: "x", action: .replace("X")), EditSpec(find: "y", action: .replace("Y"))],
            address: nil, gate: .cli(force: false), preservingModifiedDate: false)
        #expect(result.after.content == "# T\nX\n## A\nY\n")
        #expect(ops.map(\.index) == [0, 1])
        #expect(ops[0].section?.address == "# T\npreamble")  // the lead above the first subheading
        #expect(ops[1].section?.address == "## A")
        let empty = #expect(throws: AutomationError.self) {
            try service(lib).edit(
                .id(id), edits: [], address: nil, gate: .cli(force: false), preservingModifiedDate: false)
        }
        #expect(empty?.code == .usage)
    }

    @Test func overwriteSectionResultAndDeletion() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n## A\na\n## B\nb\n")])
        let id = try lib.firstId()
        let (result, section) = try service(lib).overwrite(
            .id(id), content: "## A2\nnew", base: nil, address: "## A", gate: .cli(force: false),
            preservingModifiedDate: false)
        #expect(result.after.content == "# T\n## A2\nnew\n## B\nb\n")
        #expect(section?.address == "## A2")
        let (_, gone) = try service(lib).overwrite(
            .id(id), content: "", base: nil, address: "## A2", gate: .cli(force: false), preservingModifiedDate: false)
        #expect(gone == nil)
        #expect(try lib.text(id) == "# T\n## B\nb\n")
    }

    @Test func mcpGateNeedsTheDeclaredSetToMatch() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n![](a.jpg)\n")])
        let id = try lib.firstId()
        let attachments = AttachmentStore(paths: lib.paths, database: lib.library.database)
        _ = try attachments.add(data: Data("x".utf8), filename: "a.jpg", to: id)
        let undeclared = #expect(throws: AutomationError.self) {
            try service(lib).overwrite(
                .id(id), content: "# T\n", base: nil, address: nil, gate: .mcp(expected: nil),
                preservingModifiedDate: false)
        }
        #expect(undeclared?.code == .attachmentsRemoved)
        #expect(undeclared?.details == .object([("removed", .array([.string("a.jpg")]))]))
        _ = try service(lib).overwrite(
            .id(id), content: "# T\n", base: nil, address: nil, gate: .mcp(expected: ["a.jpg"]),
            preservingModifiedDate: false)
        #expect(try lib.text(id) == "# T\n")
    }

    @Test func createRules() throws {
        let lib = try TestLibrary.make()
        let s = service(lib)
        #expect(AutomationService.addingTitle("Hi", to: "") == "# Hi")
        #expect(AutomationService.addingTitle("Hi", to: "---\nk: v\n---") == "---\nk: v\n---\n# Hi")
        #expect(AutomationService.addingTitle("Hi", to: "hi\nbody") == "hi\nbody")
        #expect(AutomationService.addingTitle("Hi", to: "body") == "# Hi\nbody")
        let record = try s.create(title: "  A\nB ", content: "", tags: ["x", "#X#", " "].filter { $0 != " " }, ifNotExists: false, template: nil)
        #expect(record.title == "A B" && record.tags == ["x"])
        let invalid = #expect(throws: AutomationError.self) {
            try s.create(title: nil, content: "x", tags: ["#"], ifNotExists: false, template: nil)
        }
        #expect(invalid?.code == .usage)
        let both = #expect(throws: AutomationError.self) {
            try s.create(title: "t", content: "x", tags: [], ifNotExists: false, template: "Daily")
        }
        #expect(both?.message == "Provide content or a template, not both")
    }

    @Test func tagOperationsReturnBeforeAndAfter() throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\n#a")])
        let id = try lib.firstId()
        let result = try service(lib).addTags(.id(id), tags: ["b"])
        #expect(result.before.tags == ["a"] && result.after.tags == ["a", "b"])
        let noop = try service(lib).addTags(.id(id), tags: ["B"])  // already there under another spelling
        #expect(noop.before.tags == noop.after.tags)
    }
}

private func Service(_ lib: TestLibrary, beforeCommit: @escaping @Sendable (Int) -> Void) -> AutomationService {
    AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch), beforeCommit: beforeCommit)
}

/// Counts calls from non-Sendable-free closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
