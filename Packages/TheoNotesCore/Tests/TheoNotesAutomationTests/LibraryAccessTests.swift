// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

@Suite struct LibraryAccessTests {
    @Test func openExistingRefusesFolderWithoutLibrary() throws {
        let dir = try TestLibrary.emptyFolder()
        #expect(throws: LibraryOpenError.missing(path: dir.appendingPathComponent("Baerchen.sqlite").path)) {
            try AppDatabase.openExisting(path: dir.appendingPathComponent("Baerchen.sqlite"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Baerchen.sqlite").path))
    }

    @Test func openExistingRefusesPendingMigrations() throws {
        let file = try TestLibrary.emptyFolder().appendingPathComponent("Baerchen.sqlite")
        do {
            let pool = try DatabasePool(path: file.path)
            try Migrations.migrator.migrate(pool, upTo: "v5")
        }
        #expect(throws: LibraryOpenError.needsMigration) { try AppDatabase.openExisting(path: file) }
    }

    @Test func openExistingRefusesNewerSchema() throws {
        let file = try TestLibrary.emptyFolder().appendingPathComponent("Baerchen.sqlite")
        let db = try AppDatabase(path: file)
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99')")
        }
        #expect(throws: LibraryOpenError.newerThanThisBuild) { try AppDatabase.openExisting(path: file) }
    }

    @Test func openExistingOpensMigratedLibrary() throws {
        let lib = try TestLibrary.make([TestNote(text: "# One")])
        let db = try AppDatabase.openExisting(path: lib.paths.database)
        #expect(try db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") } == 1)
    }

    @Test func libraryOpenHonorsDataDirFlagAndEnvironment() throws {
        let lib = try TestLibrary.make()
        let a = try AutomationLibrary.open(dataDir: lib.paths.root.path, environment: [:])
        let b = try AutomationLibrary.open(dataDir: nil, environment: ["BAERCHEN_DATA_DIR": lib.paths.root.path])
        #expect(a.paths.root == lib.paths.root && b.paths.root == lib.paths.root)
        #expect(throws: AutomationError.self) { try AutomationLibrary.open(dataDir: "relative/x", environment: [:]) }
    }

    @Test func flagWinsOverEnvironment() throws {
        let flagged = try TestLibrary.make()
        let other = try TestLibrary.make()
        let opened = try AutomationLibrary.open(
            dataDir: flagged.paths.root.path, environment: ["BAERCHEN_DATA_DIR": other.paths.root.path])
        #expect(opened.paths.root == flagged.paths.root)
    }

    @Test func libraryOpenErrorsAreLibraryUnavailable() throws {
        let empty = try TestLibrary.emptyFolder()
        do {
            _ = try AutomationLibrary.open(dataDir: empty.path, environment: [:])
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .libraryUnavailable)
            #expect(error.exitCode == 1)
            #expect(error.message.contains("Baerchen.sqlite"))
        }
        do {
            _ = try AutomationLibrary.open(dataDir: "relative/x", environment: [:])
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .libraryUnavailable)
        }
    }

    @Test func busyDatabaseIsBusyNotLibraryUnavailable() {
        #expect(AutomationLibrary.map(DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")).code == .busy)
        #expect(AutomationLibrary.map(DatabaseError(resultCode: .SQLITE_BUSY_SNAPSHOT, message: "x")).code == .busy)
        #expect(AutomationLibrary.map(DatabaseError(resultCode: .SQLITE_CORRUPT, message: "x")).code == .libraryUnavailable)
        #expect(AutomationLibrary.map(LibraryOpenError.needsMigration).code == .libraryUnavailable)
    }

    @Test func storeWritesPostTheChangeNotification() throws {
        let lib = try TestLibrary.make()
        let received = Mutex(0)
        let token = ChangeNotifier().observe { received.withLock { $0 += 1 } }
        defer { token.cancel() }
        _ = try lib.library.store.create(text: "# Posted")
        let deadline = Date().addingTimeInterval(5)
        while received.withLock({ $0 }) == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(received.withLock { $0 } >= 1)
    }

    /// The CLI runs from `Baerchen.app/Contents/Helpers/`, where SwiftPM's `Bundle.module` for
    /// `TheoNotesCore` (tag icons, emoji, themes) cannot be found and would trap.
    /// Forbidden in the automation sources: `Bundle.module` itself, every type declared at the top
    /// level of a core file that uses it (found by scanning, so a new one such as `ThemeCatalog` is
    /// caught without editing this list), and the core types known to reach one of those. Words
    /// match on simple boundaries: Unicode word rules would read `ThemeCatalog.self` as one word.
    @Test func automationSourcesNeverTouchResourceBundleCode() throws {
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sources.deleteLastPathComponent() }
        sources.appendPathComponent("Sources")
        func swiftFiles(_ folder: String) throws -> [(URL, String)] {
            let enumerator = try #require(
                FileManager.default.enumerator(at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            var files: [(URL, String)] = []
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                files.append((file, try String(contentsOf: file, encoding: .utf8)))
            }
            return files
        }
        let declaration = try Regex(
            #"(?m)^(?:public |internal |package |private |fileprivate )?(?:final )?(?:enum|struct|class|actor|protocol|extension) ([A-Za-z_][A-Za-z0-9_]*)"#)
        var bundleTypes = Set<String>()
        for (_, text) in try swiftFiles("TheoNotesCore") where text.contains("Bundle.module") {
            for match in text.matches(of: declaration) {
                if let name = match.output[1].substring { bundleTypes.insert(String(name)) }
            }
        }
        #expect(bundleTypes.isSuperset(of: ["TagIcons", "CompletionProvider", "ThemeCatalog"]))
        let forbidden = ["Bundle.module", "NoteTitleIndex", "ThemeResolver"] + bundleTypes.sorted()
        var checked = 0
        for folder in ["TheoNotesAutomation", "baerchen"] {
            for (file, text) in try swiftFiles(folder) {
                for word in forbidden {
                    let pattern = try Regex("\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b")
                        .wordBoundaryKind(.simple)
                    let used = text.contains(pattern)
                    #expect(!used, "\(file.lastPathComponent) uses \(word)")
                }
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    @Test func testLibraryBuildsNotesWithFlags() throws {
        let lib = try TestLibrary.make(
            [
                TestNote(text: "# A\nbody", pinned: true),
                TestNote(text: "# B", location: .trash, readOnly: true),
                TestNote(
                    text: "# C secret", locked: true, created: TestLibrary.epoch,
                    modified: TestLibrary.epoch.addingTimeInterval(60)),
            ],
            bearIds: [0: "BEAR-1"])
        let a = try lib.note(try lib.id(titled: "A"))
        #expect(a.isPinnedGlobal && a.createdAt == TestLibrary.epoch)
        let b = try lib.note(try lib.id(titled: "B"))
        #expect(b.location == .trash && b.isReadOnly)
        let c = try lib.note(try lib.id(titled: "C secret"))
        #expect(c.isLocked && c.text == "" && c.modifiedAt == TestLibrary.epoch.addingTimeInterval(60))
        #expect(try lib.firstId() == a.id)
        let ref = try lib.library.database.pool.read {
            try String.fetchOne($0, sql: "SELECT noteId FROM external_ref WHERE source = 'bear' AND externalId = 'BEAR-1'")
        }
        #expect(ref == a.id)
    }
}
