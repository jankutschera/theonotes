// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotesAutomation

#if os(macOS)
/// Fix round 1: a long-running CLI / MCP process keeps one library object. When
/// the app moves the library folder from `Baerchen` to `Theo Notes` underneath it, the next call
/// must open the moved library, never an empty one at the old path.
@Suite struct LibraryMoveAcrossToolsTests {
    private func makeSupport() throws -> URL {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("theo-tools-\(UUID().uuidString)/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    private func makeLegacyLibrary(in support: URL, notes: Int) throws -> AppPaths {
        let paths = AppPaths(root: support.appendingPathComponent("Baerchen", isDirectory: true))
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: ChangeNotifier(), paths: paths)
        for index in 0..<notes { _ = try store.create(text: "# Note \(index)") }
        try db.pool.close()
        return paths
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    @Test func theNextCallOpensTheMovedLibrary() async throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let legacy = try makeLegacyLibrary(in: support, notes: 3)
        let production = AppPaths.production(applicationSupport: support)
        let opens = OpenCounter()
        let provider = LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
            opens.bump()
            return try AutomationLibrary.open(dataDir: nil, environment: [:], production: production)
        }
        let tools = MCPTools(libraryProvider: provider, context: .fixed(Date(timeIntervalSince1970: 1_767_323_045)), scope: .unrestricted)

        // First call: only the old folder exists, so it is read from there.
        let first = try await tools.call("list_notes", arguments: JSONValue(parsing: Data("{}".utf8)))
        guard case .success(let before) = first else { Issue.record("first call failed"); return }
        #expect(before["total"] == 3, "\(before.serialized(sortedKeys: true))")
        #expect(opens.count == 1)

        // The app moves the folder while the server keeps running.
        #expect(rename(legacy.root.path, production.root.path) == 0)

        let second = try await tools.call("list_notes", arguments: JSONValue(parsing: Data("{}".utf8)))
        guard case .success(let after) = second else { Issue.record("second call failed"); return }
        #expect(after["total"] == 3, "\(after.serialized(sortedKeys: true))")
        #expect(opens.count == 2, "the moved library was reopened")
        #expect(!exists(legacy.root), "no library is recreated at the old path")
        #expect(exists(production.root.appendingPathComponent("Baerchen.sqlite")))
    }

    /// The new folder wins even while the old one still exists; the old library object is
    /// dropped, not closed (a request still using it finishes), and one request reopens once.
    @Test func theNewFolderIsPreferredAndTheOldLibraryIsNotClosed() throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let legacy = try makeLegacyLibrary(in: support, notes: 1)
        let production = AppPaths.production(applicationSupport: support)
        let opens = OpenCounter()
        let resolve: @Sendable () -> URL? = {
            try? AutomationLibrary.resolvePaths(dataDir: nil, environment: [:], production: production).root
        }
        let provider = LibraryProvider(currentRoot: resolve) { () throws(AutomationError) -> AutomationLibrary in
            opens.bump()
            return try AutomationLibrary.open(dataDir: nil, environment: [:], production: production)
        }
        let old = try provider.library()
        #expect(old.paths.root == legacy.root)

        // A second library appears at the new place while the old folder is still there.
        let fresh = AppPaths(root: production.root)
        try fresh.createDirectories()
        let db = try AppDatabase(path: fresh.database)
        let store = NoteStore(db: db, notifier: ChangeNotifier(), paths: fresh)
        for index in 0..<4 { _ = try store.create(text: "# New \(index)") }
        try db.pool.close()

        let reopened = try provider.library()
        #expect(reopened.paths.root == production.root)
        #expect(try reopened.store.allNotes().count == 4)
        #expect(opens.count == 2)
        _ = try provider.library()
        #expect(opens.count == 2, "one reopen per change, not one per request")
        // A request still holding the old library keeps working: nobody closed its pool.
        #expect(try old.store.allNotes().count == 1)
        #expect(exists(legacy.root))
    }

    @Test func aLibraryThatIsStillThereIsKept() throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        _ = try makeLegacyLibrary(in: support, notes: 1)
        let production = AppPaths.production(applicationSupport: support)
        let opens = OpenCounter()
        let provider = LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
            opens.bump()
            return try AutomationLibrary.open(dataDir: nil, environment: [:], production: production)
        }
        _ = try provider.library()
        _ = try provider.library()
        #expect(opens.count == 1)
    }

    @Test func aVanishedLibraryIsAnErrorNotAnEmptyOne() throws {
        let support = try makeSupport()
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let legacy = try makeLegacyLibrary(in: support, notes: 1)
        let production = AppPaths.production(applicationSupport: support)
        let provider = LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
            try AutomationLibrary.open(dataDir: nil, environment: [:], production: production)
        }
        _ = try provider.library()
        try FileManager.default.removeItem(at: legacy.root)
        #expect(throws: AutomationError.self) { try provider.library() }
        #expect(!exists(legacy.root))
        #expect(!exists(production.root))
    }
}
#endif
