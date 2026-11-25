// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

@testable import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// REL-R71 / REL-R75 on the Mac: what a launch does, and Help ▸ Restore Getting Started Notes.
/// Every library here is a temporary one; none is Jan's.
@MainActor
@Suite struct GettingStartedLaunchTests {
    @MainActor private struct Support {
        let parent = URL(fileURLWithPath: "/tmp/theo-gs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var support: URL { parent.appendingPathComponent("Application Support", isDirectory: true) }
        var production: AppPaths { AppPaths.production(applicationSupport: support) }

        init() throws { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: parent) }
        func launch(arguments: [String] = ["Theo Notes"]) throws -> AppEnvironment {
            try AppEnvironment.launching(arguments: arguments, environment: [:], production: production)
        }
    }

    private func all(_ environment: AppEnvironment) throws -> [Note] {
        try [NoteLocation.notes, .archive, .trash].flatMap { try environment.store.allNotes(location: $0) }
    }

    @Test func aFreshInstallStartsWithTheGettingStartedNotesAndNoSecondLaunchAddsMore() throws {
        let support = try Support(); defer { support.remove() }
        let first = try support.launch()
        #expect(Set(try all(first).map(\.id)) == Set(GettingStartedNotes.ids))
        #expect(try all(first).count == 12)

        // The person deletes them all; the next launch finds an existing library and leaves it empty.
        try first.store.deletePermanently(GettingStartedNotes.ids)
        let second = try support.launch()
        #expect(try all(second).isEmpty)
        let third = try support.launch()
        #expect(try all(third).isEmpty)
    }

    @Test func anExistingLibraryFolderGetsNoNotes() throws {
        let support = try Support(); defer { support.remove() }
        // The folder exists (any earlier version made it) but holds no library yet: not a fresh install.
        try FileManager.default.createDirectory(at: support.production.root, withIntermediateDirectories: true)
        let environment = try support.launch()
        #expect(try all(environment).isEmpty)
    }

    @Test func aLibraryNamedByDataDirGetsNoNotes() throws {
        let support = try Support(); defer { support.remove() }
        let copy = support.parent.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let environment = try support.launch(arguments: ["Theo Notes", "--data-dir", copy.path])
        #expect(try all(environment).isEmpty)
    }

    @Test func aDirectlyOpenedEnvironmentGetsNoNotes() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("gs-direct-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let environment = try AppEnvironment(paths: paths)
        #expect(try all(environment).isEmpty)
        #expect(environment.seedGettingStartedNotes(isNewLibrary: false).isEmpty)
    }

    // MARK: STARTER-R18: the first launch of the new texts


    /// What the first release left behind: the frozen first texts under the fixed ids and stamps, the seeded flag set.
    private static func writeFirstReleaseStarters(into store: NoteStore) throws {
        try store.write { db in
            for note in try GettingStartedNotes.firstShippedNotes() { _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db) }
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [SettingKey<Bool>.gettingStartedSeeded.name])
        }
    }

    @Test func anExistingFirstReleaseLibraryGetsTheNewTextsOnceAndKeepsEditsAndDeletions() throws {
        let support = try Support(); defer { support.remove() }
        // The first release's library: made, then the person edited note 5, deleted note 6 and trashed note 7.
        let paths = support.production
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        let old = NoteStore(db: database, notifier: nil, paths: paths)
        try Self.writeFirstReleaseStarters(into: old)
        let ids = GettingStartedNotes.ids
        let five = try #require(try old.note(id: ids[4]))
        let edited = five.text + "\nmine\n"
        _ = try old.updateText(id: ids[4], text: edited, expectedRevision: five.revision)
        try old.deletePermanently([ids[5]])
        try old.trash([ids[6]])
        try database.pool.close()

        let first = try support.launch()
        let texts = Dictionary(uniqueKeysWithValues: try GettingStartedNotes.notes().map { ($0.id, $0.text) })
        #expect(try first.store.note(id: ids[0])?.text == texts[ids[0]], "an untouched starter has the new text")
        #expect(try first.store.note(id: ids[4])?.text == edited, "an edited starter stays")
        #expect(try first.store.note(id: ids[5]) == nil, "a deleted starter is not brought back")
        #expect(try first.store.note(id: ids[6])?.location == .trash && first.store.note(id: ids[6])?.text != texts[ids[6]])
        #expect(try first.store.note(id: ids[7])?.text == texts[ids[7]])
        try first.store.updateText(id: ids[0], text: "# Mine now\n", expectedRevision: try #require(try first.store.note(id: ids[0])).revision)
        try first.database.pool.close()

        // The second launch changes nothing.
        let second = try support.launch()
        #expect(try second.store.note(id: ids[0])?.text == "# Mine now\n")
        #expect(second.upgradeGettingStartedNotes().isEmpty)
    }

    // MARK: Help ▸ Restore Getting Started Notes

    @Test func theMenuItemHasItsTitleAndIsOffWithoutAnApp() {
        #expect(GettingStartedMenu.title == "Restore Getting Started Notes")
        #expect(GettingStartedMenu.isDisabled(app: nil))
    }

    @Test func restoreAddsMissingNotesAndSaysNothingWhenNothingIsMissing() throws {
        let root = URL(fileURLWithPath: "/tmp/theo-gs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let suiteName = "TheoNotesGettingStarted-\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), appAuthenticator: FakeAppAuthenticator(), appLockLifecycle: nil,
            appIdleSeconds: { 0 })
        let app = AppModel(environment: environment, defaults: UserDefaults(suiteName: suiteName)!)
        var windowRequests: [WindowRequest] = []
        app.openWindowRequest = { windowRequests.append($0) }
        var notices: [String] = []

        let first = app.restoreGettingStartedNotes(notice: { title, _ in notices.append(title) })
        #expect(first?.added == GettingStartedNotes.ids)
        #expect(notices.isEmpty)
        #expect(try all(environment).count == 12)

        let second = app.restoreGettingStartedNotes(notice: { title, text in
            notices.append(title)
            #expect(text == GettingStartedMenu.nothingText)
        })
        #expect(second?.changedAnything == false)
        #expect(notices == [GettingStartedMenu.nothingTitle])
        #expect(try all(environment).count == 12)
    }
}
