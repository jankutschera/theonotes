// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A write that committed and then could not read its result back (`busy`, `internal`) says that
/// it committed (`details.committed: true`), as the scope refusal after a commit does: an
/// agent that retried an ordinary-looking failure would append twice (final review M3).
@Suite struct CommittedReadBackTests {
    private static let committed: JSONValue = .object([("committed", .bool(true))])

    /// A service whose result read-back fails after the commit (the `note_pin` table it reads is gone).
    private func service(_ lib: TestLibrary) -> AutomationService {
        let db = lib.library.database
        return AutomationService(
            library: lib.library, context: .fixed(TestLibrary.epoch),
            afterCommit: { try? db.pool.write { try $0.execute(sql: "DROP TABLE note_pin") } })
    }

    @Test func aFailedReadBackAfterTheCommitIsMarkedCommitted() throws {
        let operations: [(String, (AutomationService, String) throws -> Void, (TestLibrary, String) throws -> Bool)] = [
            (
                "append",
                { _ = try $0.append(.id($1), content: "more", position: .end, address: nil, preservingModifiedDate: false) },
                { try $0.text($1).contains("more") }
            ),
            ("add tags", { _ = try $0.addTags(.id($1), tags: ["extra"]) }, { try $0.text($1).contains("#extra") }),
            ("trash", { _ = try $0.trash(.id($1)) }, { try $0.note($1).location == .trash }),
            (
                "create",
                { service, _ in _ = try service.create(title: "New", content: "", tags: [], ifNotExists: false, template: nil) },
                { lib, _ in try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 2 }
            ),
        ]
        for (name, run, persisted) in operations {
            let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody")])
            let id = try lib.firstId()
            let error = #expect(throws: AutomationError.self, "\(name)") { try run(service(lib), id) }
            #expect(error?.code == .internal, "\(name)")
            #expect(error?.details == Self.committed, "\(name): \(String(describing: error))")
            #expect(try persisted(lib, id), "\(name): the change is stored")
        }
    }

    @Test func aFailureBeforeTheCommitIsNotMarked() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Doc\nbody", locked: true)])
        let error = #expect(throws: AutomationError.self) {
            _ = try service(lib).append(.id(try lib.firstId()), content: "x", position: .end, address: nil, preservingModifiedDate: false)
        }
        #expect(error?.code == .noteLocked && error?.details == nil)
    }
}
