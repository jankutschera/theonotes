// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct NoteExportTests {
    @Test func textBundleRoundTripPreservesAttachmentsAndCodeExamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("source"))
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close() }
        let store = NoteStore(db: db, notifier: nil, paths: paths)
        let attachments = AttachmentStore(paths: paths, database: db)
        let text = "\u{FEFF}# Export 🐻\n![](photo%20one.png)\n[file](<résumé.pdf>)<!-- {\"embed\":\"true\"} -->\n`![](photo%20one.png)`\n```md\n![](photo%20one.png)\n```"
        let note = try store.create(text: text)
        let image = Data([0, 1, 2, 3])
        _ = try attachments.add(data: image, filename: "photo one.png", to: note.id)
        _ = try attachments.add(data: Data("pdf bytes".utf8), filename: "résumé.pdf", to: note.id)
        let wrapper = try NoteExport.textBundle(note: note, attachments: attachments)
        let url = root.appendingPathComponent("Export.textbundle")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let exported = try String(contentsOf: url.appendingPathComponent("text.md"), encoding: .utf8)
        #expect(exported.contains("![](assets/photo%20one.png)"))
        #expect(exported.contains("`![](photo%20one.png)`"))
        #expect(exported.contains("```md\n![](photo%20one.png)\n```"))
        #expect(try Data(contentsOf: url.appendingPathComponent("assets/photo one.png")) == image)
        let destination = AppPaths(root: root.appendingPathComponent("destination"))
        try destination.createDirectories()
        let targetDB = try AppDatabase(path: destination.database)
        defer { try? targetDB.pool.close() }
        let target = NoteStore(db: targetDB, notifier: nil, paths: destination)
        let report = try FileImporter(store: target, paths: destination).importItems([url])
        #expect(report.created == 1)
        #expect(report.errors.isEmpty)
        let restored = try #require(try target.allNotes().first)
        #expect(NoteParser.metadata(for: restored.text).attachments.map(\.filename).sorted() == ["photo one.png", "résumé.pdf"])
        #expect(try Data(contentsOf: destination.attachments.appendingPathComponent(restored.id).appendingPathComponent("photo one.png")) == image)
    }
}
