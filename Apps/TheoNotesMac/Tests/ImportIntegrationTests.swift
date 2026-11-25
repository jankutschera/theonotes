// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// The real importers (`LiveImportService`) behind `ImportModel`, on a temp data dir, with a shell
/// script standing in for bearcli.
@MainActor
@Suite struct ImportIntegrationTests {
    @MainActor
    final class Env {
        let root: URL
        let paths: AppPaths
        let environment: AppEnvironment
        let library: LibraryModel
        let importer: ImportModel
        let bearcli: URL

        init(bearRecords: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesImport-\(UUID().uuidString)", isDirectory: true)
            paths = AppPaths(root: root)
            environment = try AppEnvironment(paths: paths)
            library = LibraryModel(environment: environment)
            bearcli = root.appendingPathComponent("bearcli")
            let script = """
                #!/bin/sh
                case "$*" in
                  "list --location all --format json --fields all,content") cat <<'JSON'
                \(bearRecords)
                JSON
                  ;;
                  "search @readonly --location all --format json --fields id") echo '[]' ;;
                  "list --location all --count --format json") echo '{"count":2}' ;;
                  "list --location trash --count --format json") echo '{"count":1}' ;;
                  *) echo "unexpected: $*" >&2; exit 9 ;;
                esac
                """
            try script.write(to: bearcli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bearcli.path)
            let environment = environment, library = library, path = bearcli.path
            importer = ImportModel(
                service: LiveImportService(store: environment.store, paths: environment.paths),
                bearCLIPath: { path }, prepare: { environment.flushAll() }, didImport: { library.refresh() })
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    static let records = """
        [{"id":"BEAR-1","title":"Hello","locked":"no","tags":["#imported"],"created":"2026-01-02T03:04:05Z",
          "modified":"2026-01-03T03:04:05Z","pins":["global"],"location":"notes","todos":0,"done":0,"attachments":[],
          "content":"# Hello\\n\\nfrom Bear #imported"},
         {"id":"BEAR-2","title":"Old","locked":"no","tags":[],"created":"2026-01-02T03:04:05Z",
          "modified":"2026-01-02T03:04:05Z","pins":[],"location":"trash","todos":0,"done":0,"attachments":[],
          "content":"# Old"}]
        """

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 5 s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finished(_ model: ImportModel) -> ImportSummary? {
        if case .finished(let summary) = model.phase { return summary }
        return nil
    }

    @Test func testImportFromBearFillsTheLibraryAndRepullIsUnchanged() async throws {
        let env = try Env(bearRecords: Self.records)
        #expect(env.library.items.isEmpty)

        env.importer.showBearImport()
        await waitUntil("preview") { env.importer.preview != .loading }
        #expect(env.importer.preview == .loaded(BearLibraryPreview(total: 2, trashed: 1)))

        env.importer.startBearImport()
        await waitUntil("import") { finished(env.importer) != nil }
        #expect(finished(env.importer)?.headline == "2 created.")
        #expect(env.library.items.map(\.title) == ["Hello"])
        #expect(env.library.counts.trash == 1)
        let note = try #require(try env.environment.store.note(id: env.library.items[0].id))
        #expect(note.isPinnedGlobal)
        #expect(note.modifiedAt == ISO8601DateFormatter().date(from: "2026-01-03T03:04:05Z"))

        env.importer.dismissSheet()
        env.importer.pullFromBear()
        await waitUntil("pull") { finished(env.importer) != nil }
        #expect(env.importer.pullAlert?.headline == "2 unchanged.")
    }

    @Test func testImportFlushesAnOpenSessionFirst() async throws {
        let env = try Env(bearRecords: "[]")
        let id = try env.environment.store.create(text: "draft").id
        let session = try env.environment.session(for: id)
        let edit = ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " kept")])
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: edit, origin: nil) == .acked(revision: 1))
        #expect(try env.environment.store.note(id: id)?.text == "draft")

        env.importer.pullFromBear()
        #expect(try env.environment.store.note(id: id)?.text == "draft kept")
        await waitUntil("pull") { finished(env.importer) != nil }
        #expect(env.importer.pullAlert?.headline == "Bear has no notes.")
    }

    @Test func testMissingBearCLIFails() async throws {
        let env = try Env(bearRecords: "[]")
        try FileManager.default.removeItem(at: env.bearcli)
        env.importer.pullFromBear()
        await waitUntil("failed") { !env.importer.isRunning }
        #expect(env.importer.phase == .failed("bearcli is not installed or not executable"))
    }

    @Test func testFileImportCreatesNotes() async throws {
        let env = try Env(bearRecords: "[]")
        let folder = env.root.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Plain text".write(to: folder.appendingPathComponent("Groceries.md"), atomically: true, encoding: .utf8)

        env.importer.showFileImport([folder])
        env.importer.fileOptions.titleFromFilename = true
        env.importer.startFileImport()
        await waitUntil("import") { finished(env.importer) != nil }
        #expect(finished(env.importer)?.rows.first?.count == 1)
        #expect(env.library.items.map(\.title) == ["Groceries"])
    }

    // MARK: - Evernote and Notion exports (synthetic fixtures)

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/import", isDirectory: true)

    private func zip(_ tree: URL, _ entries: [String], to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        process.arguments = ["-q", "-r", "-X", archive.path] + entries
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func testAnEvernoteExportImportsThroughTheModel() async throws {
        let env = try Env(bearRecords: "[]")
        let enex = Self.fixtures.appendingPathComponent("evernote/Travel.enex")

        env.importer.showFileImport([enex])
        env.importer.startFileImport()
        await waitUntil("import") { finished(env.importer) != nil }

        let summary = try #require(finished(env.importer))
        #expect(summary.errors.isEmpty, "\(summary.errors)")
        #expect(summary.rows.first { $0.label == "Created" }?.count == 2)
        #expect(summary.headline == "2 created.")
        #expect(env.library.items.count == 2)
        let packing = try #require(env.library.items.first { $0.title == "Packing list" })
        #expect(try env.environment.store.note(id: packing.id)?.text.hasSuffix("#evernote/Travel") == true)
    }

    @Test func testANotionZipAndAnEnexImportTogether() async throws {
        let env = try Env(bearRecords: "[]")
        let archive = env.root.appendingPathComponent("Export-markdown.zip")
        try zip(Self.fixtures.appendingPathComponent("notion/markdown-export"), ["Private & Shared"], to: archive)
        let enex = Self.fixtures.appendingPathComponent("evernote/Travel.enex")

        env.importer.showFileImport([archive, enex])
        env.importer.startFileImport()
        await waitUntil("import") { finished(env.importer) != nil }

        let summary = try #require(finished(env.importer))
        #expect(summary.errors.isEmpty, "\(summary.errors)")
        #expect(summary.rows.first { $0.label == "Created" }?.count == 9)
        let titles = env.library.items.map(\.title)
        #expect(titles.contains("Project Hub"))
        #expect(titles.contains("Packing list"))
        #expect(env.library.items.count == 9)
    }
}
