// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A long-running `mcp-server` keeps its library open for hours while a newer app migrates it.
/// Every tool call and every write transaction re-checks the schema, so the old binary never
/// writes into a schema it does not match.
@Suite struct SchemaUpgradeTests {
    static let restart = "The library was upgraded by a newer Theo Notes; restart the MCP server"

    /// What a newer build's migration leaves behind, written from another connection.
    private func upgrade(_ lib: TestLibrary) throws {
        let other = try DatabaseQueue(path: lib.paths.database.path)
        try other.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-a-newer-build')")
        }
    }

    private func server(_ lib: TestLibrary) -> MCPTools {
        let root = lib.paths.root.path
        return MCPTools(
            libraryProvider: LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
                try AutomationLibrary.open(dataDir: root, environment: [:])
            }, context: .fixed(TestLibrary.epoch), scope: .unrestricted)
    }

    private func call(_ tools: MCPTools, _ name: String, _ arguments: String) async throws -> Result<JSONValue, AutomationError> {
        await tools.call(name, arguments: try JSONValue(parsing: Data(arguments.utf8)))
    }

    @Test func aServerSessionRefusesEveryCallOnceTheLibraryWasUpgraded() async throws {
        let lib = try TestLibrary.make([TestNote(text: "# Inbox\nfirst")])
        let id = try lib.firstId()
        let tools = server(lib)
        let append = ###"{"id":"\###(id)","content":"second"}"###
        guard case .success = try await call(tools, "append_to_note", append) else {
            Issue.record("the first append failed")
            return
        }
        let before = try lib.text(id)
        try upgrade(lib)
        for (name, arguments) in [
            ("append_to_note", append), ("get_note", ###"{"id":"\###(id)"}"###), ("list_notes", "{}"),
            ("create_note", ###"{"title":"New"}"###),
        ] {
            guard case .failure(let error) = try await call(tools, name, arguments) else {
                Issue.record("\(name) answered after the upgrade")
                continue
            }
            #expect(error.code == .libraryUnavailable && error.message == Self.restart, "\(name)")
        }
        #expect(try lib.text(id) == before)
        let notes = try await lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") }
        #expect(notes == 1)
    }

    /// The upgrade lands between the per-call check and the write: the write transaction itself
    /// refuses, so nothing is written.
    @Test func aWriteTransactionRefusesAnUpgradedSchemaAndRollsBack() throws {
        let lib = try TestLibrary.make([TestNote(text: "# Inbox\nfirst")])
        let id = try lib.firstId()
        try upgrade(lib)
        let service = AutomationService(library: lib.library, context: .fixed(TestLibrary.epoch), scope: .unrestricted)
        #expect(throws: AutomationError(code: .libraryUnavailable, message: Self.restart)) {
            _ = try service.create(title: "New", content: "", tags: [], ifNotExists: false, template: nil)
        }
        // A new process refuses at open, as before.
        let r = cli(lib, "append", id, "--content", "second")
        #expect(r.exit == 1 && r.err.contains("written by a newer version of Theo Notes"), "\(r.err)")
        #expect(try lib.text(id) == "# Inbox\nfirst")
        let notes = try lib.library.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") }
        #expect(notes == 1)
    }
}
