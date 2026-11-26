// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Spec section 9 / the focus state (reminders, hides, history, capture source, open
/// time) is device-local and never leaves in an export. HTML and PDF are covered in C18.
@Suite struct FocusExportTests {
    /// Every file below `root` as relative path and bytes.
    private static func tree(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count))] = try Data(contentsOf: url)
        }
        return files
    }

    @Test func markdownTextBundleAndPlainTextCarryNoFocusState() throws {
        let source = try LibraryBackupTests.FocusLibrary()
        defer { source.cleanup() }
        let seeded = source.seeded
        let store = source.library.store
        func exportEveryFormat(_ folder: String) throws -> [String: Data] {
            let destination = source.library.paths.root.appendingPathComponent(folder)
            let plan = ExportPlan.selection(try store.exportCandidates(ids: [seeded.plain.id]))
            let exporter = NoteExporter(store: store, paths: source.library.paths)
            for format in FileExportFormat.allCases {
                for item in plan.items {
                    _ = try exporter.write(item, format: format, under: destination.appendingPathComponent(format.rawValue), options: ExportOptions())
                }
            }
            return try Self.tree(destination)
        }

        // The note really has all of it.
        try source.library.db.pool.read { db throws -> Void in
            for table in ["note_ping", "focus_hide", "note_snapshot"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE noteId=?", arguments: [seeded.plain.id]) ?? 0 > 0, Comment(rawValue: table))
            }
            #expect(try String.fetchOne(db, sql: "SELECT captureSource FROM note WHERE id=?", arguments: [seeded.plain.id]) == "voice")
            #expect(try Date.fetchOne(db, sql: "SELECT lastOpenedAt FROM note_ui_state WHERE noteId=?", arguments: [seeded.plain.id]) != nil)
        }
        let withFocus = try exportEveryFormat("with-focus")
        #expect(withFocus.keys.contains { $0.hasSuffix(".md") } && withFocus.keys.contains { $0.hasSuffix(".txt") }
                && withFocus.keys.contains { $0.contains(".textbundle/") })

        try source.library.db.pool.write { db in
            try db.execute(sql: "DELETE FROM note_ping")
            try db.execute(sql: "DELETE FROM focus_hide")
            try db.execute(sql: "DELETE FROM note_snapshot")
            try db.execute(sql: "UPDATE note SET captureSource=NULL")
            try db.execute(sql: "UPDATE note_ui_state SET lastOpenedAt=NULL")
        }
        let withoutFocus = try exportEveryFormat("without-focus")

        #expect(withFocus == withoutFocus)
        for (path, data) in withFocus {
            for canary in ["plain snapshot", seeded.anchoredPing.id, seeded.wholePing.id, "captureSource", "lastOpenedAt", "fireAt", "hiddenUntil"] {
                #expect(data.range(of: Data(canary.utf8)) == nil, "\(canary) in \(path)")
            }
        }
    }
}
