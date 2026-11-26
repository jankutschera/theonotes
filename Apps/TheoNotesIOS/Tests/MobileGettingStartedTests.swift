// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

@testable import TheoNotesCore
import Foundation
import Testing
@testable import BaerchenIOS

/// on iPhone and iPad: the one decision "is this a brand-new library" for every way a library
/// comes to exist or is opened, and Settings ▸ Restore Getting Started Notes. Temporary libraries only.
@Suite @MainActor
struct MobileGettingStartedTests {
    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mobile-gs-\(name)-" + UUID().uuidString)
    }
    private func all(_ library: MobileLibrary) throws -> [Note] {
        try [NoteLocation.notes, .archive, .trash].flatMap { try library.store.allNotes(location: $0) }
    }
    private func launch(_ root: URL, seeds: Bool = true) throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: root), seedsGettingStarted: seeds)
    }

    // MARK: the first launch of the new texts

    /// What the first release left behind: the frozen first texts under the fixed ids and stamps, the seeded flag set.
    private static func writeFirstReleaseStarters(into store: NoteStore) throws {
        try store.write { db in
            for note in try GettingStartedNotes.firstShippedNotes() { _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db) }
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [SettingKey<Bool>.gettingStartedSeeded.name])
        }
    }

    @Test func anExistingFirstReleaseLibraryGetsTheNewTextsOnceAndKeepsEditsAndDeletions() throws {
        let root = temporaryRoot("upgrade"); defer { try? FileManager.default.removeItem(at: root) }
        let old = try launch(root, seeds: false)
        try Self.writeFirstReleaseStarters(into: old.store)
        let ids = GettingStartedNotes.ids
        let five = try #require(try old.store.note(id: ids[4]))
        let edited = five.text + "\nmine\n"
        _ = try old.store.updateText(id: ids[4], text: edited, expectedRevision: five.revision)
        try old.store.deletePermanently([ids[5]])
        try old.store.setPinned([ids[6]], pinned: true)
        try old.close()

        let first = try launch(root); defer { try? first.close() }
        let texts = Dictionary(uniqueKeysWithValues: try GettingStartedNotes.notes().map { ($0.id, $0.text) })
        #expect(try first.store.note(id: ids[0])?.text == texts[ids[0]], "an untouched starter has the new text")
        #expect(try first.store.note(id: ids[4])?.text == edited, "an edited starter stays")
        #expect(try first.store.note(id: ids[5]) == nil, "a deleted starter is not brought back")
        #expect(try first.store.note(id: ids[6])?.text != texts[ids[6]], "a pinned starter stays")
        #expect(try first.store.note(id: ids[7])?.text == texts[ids[7]])
        let marker = try Settings(db: first.database).value(.gettingStartedUpgraded)
        #expect(marker)
        try first.close()

        // The next launch, and a launch that must not seed (a recovery copy), change nothing.
        let again = try launch(root); defer { try? again.close() }
        #expect(try all(again).count == 11)
        #expect(try GettingStartedNotes.upgradeFirstShipped(in: again.store, paths: again.paths).isEmpty)
    }

    // MARK: the decision, path by path

    @Test func aFreshInstallStartsWithTheTwelveNotesAndTheTag() throws {
        let root = temporaryRoot("fresh"); defer { try? FileManager.default.removeItem(at: root) }
        #expect(MobileGettingStarted.createsNewLibrary(at: AppPaths(root: root)))
        let library = try launch(root); defer { try? library.close() }
        #expect(Set(try all(library).map(\.id)) == Set(GettingStartedNotes.ids))
        #expect(try all(library).count == 12)
        #expect(try library.store.allNotes().allSatisfy { NoteParser.metadata(for: $0.text).tags.contains(GettingStartedNotes.tag) })
    }

    @Test func aFolderWithoutADatabaseIsNewBecauseTheLaunchCreatesTheDatabase() throws {
        let root = temporaryRoot("folder-only"); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(MobileGettingStarted.createsNewLibrary(at: AppPaths(root: root)))
        let library = try launch(root); defer { try? library.close() }
        #expect(try all(library).count == 12)
    }

    @Test func anExistingEmptyLibraryAnUpdateOrADeviceRestoreGetsNothing() throws {
        // 1.0.0 had no seeding: an existing container, an update and a restored device all hand the
        // launch a database file, here an empty one.
        let root = temporaryRoot("existing"); defer { try? FileManager.default.removeItem(at: root) }
        try launch(root, seeds: false).close()
        #expect(!MobileGettingStarted.createsNewLibrary(at: AppPaths(root: root)))
        let library = try launch(root); defer { try? library.close() }
        #expect(try all(library).isEmpty)
    }

    @Test func anExistingLibraryWithNotesKeepsOnlyItsNotes() throws {
        let root = temporaryRoot("notes"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try launch(root, seeds: false)
        _ = try first.store.create(text: "# Mine\nA note from 1.0.0")
        try first.close()
        let library = try launch(root); defer { try? library.close() }
        #expect(try all(library).map(\.text) == ["# Mine\nA note from 1.0.0"])
    }

    @Test func aRecoveryCopyAndALibraryJoinedThroughSyncAreExistingDatabases() async throws {
        let root = temporaryRoot("recovery"); defer { try? FileManager.default.removeItem(at: root) }
        let library = try launch(root, seeds: false)
        _ = try library.store.create(text: "# Synced from another device")
        let archive = try await library.makeBackup()
        let prepared = try SyncRecoveryLibrary.prepare(source: library.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        try library.close()
        // The library switch (TheoNotesIOSApp) opens the copy through the same initializer.
        #expect(!MobileGettingStarted.createsNewLibrary(at: prepared.paths))
        let copy = try MobileLibrary(paths: prepared.paths, seedsGettingStarted: true); defer { try? copy.close() }
        #expect(try all(copy).map(\.text) == ["# Synced from another device"])
        // A library that sync filled later is the same file: the launch that made it has long passed.
        let reopened = try launch(root); defer { try? reopened.close() }
        #expect(try all(reopened).count == 1)
    }

    @Test func aLibraryOpenedByATestOrToolIsNeverSeeded() throws {
        let root = temporaryRoot("tool"); defer { try? FileManager.default.removeItem(at: root) }
        let library = try MobileLibrary(paths: AppPaths(root: root)); defer { try? library.close() }
        #expect(try all(library).isEmpty)
    }

    @Test func theUITestLibraryStaysEmptyUnlessTheTestAsksForTheNotes() {
        #expect(MobileGettingStarted.seedsInThisLaunch(arguments: []))
        #expect(MobileGettingStarted.seedsInThisLaunch(arguments: ["Theo Notes"]))
        #expect(!MobileGettingStarted.seedsInThisLaunch(arguments: ["--ui-testing", "--reset-library"]))
        #expect(MobileGettingStarted.seedsInThisLaunch(arguments: ["--ui-testing", "--seed-getting-started"]))
        #expect(!MobileGettingStarted.seedsInThisLaunch(arguments: [], shortcutsUITesting: true))
        #expect(MobileGettingStarted.seedsInThisLaunch(arguments: ["--ui-testing", "--seed-getting-started"], shortcutsUITesting: true))
    }

    // MARK: second launch, deletion

    @Test func aSecondLaunchSeedsNothingAndDeletedNotesDoNotComeBack() throws {
        let root = temporaryRoot("second"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try launch(root)
        #expect(try all(first).count == 12)
        let second1 = try launch(root)
        #expect(try all(second1).count == 12)
        try second1.close()
        try first.store.deletePermanently(Array(GettingStartedNotes.ids.prefix(5)))
        try first.close()
        let third = try launch(root)
        #expect(try all(third).count == 7)
        try third.store.deletePermanently(Array(GettingStartedNotes.ids.dropFirst(5)))
        try third.close()
        let fourth = try launch(root); defer { try? fourth.close() }
        #expect(try all(fourth).isEmpty)
    }

    // MARK: Settings ▸ Restore Getting Started Notes

    @Test func restoreBringsBackATrashedNoteAndThenSaysNothingIsMissing() throws {
        let root = temporaryRoot("restore"); defer { try? FileManager.default.removeItem(at: root) }
        let library = try launch(root); defer { try? library.close() }
        let id = GettingStartedNotes.ids[2]
        try library.store.trash([id])
        let back = try #require(try #require(library.restoreGettingStarted()).get())
        #expect(back.changedAnything && back.movedBackFromTrash == [id])
        #expect(try library.store.note(id: id)?.location == .notes)
        let again = try #require(try #require(library.restoreGettingStarted()).get())
        #expect(!again.changedAnything)
    }

    @Test func restoreMakesAPermanentlyDeletedNoteAgain() throws {
        let root = temporaryRoot("restore-gone"); defer { try? FileManager.default.removeItem(at: root) }
        let library = try launch(root); defer { try? library.close() }
        try library.store.deletePermanently([GettingStartedNotes.ids[0]])
        let result = try #require(try #require(library.restoreGettingStarted()).get())
        #expect(result.added == [GettingStartedNotes.ids[0]])
        #expect(try all(library).count == 12)
    }

    @Test func restoreIsOffWhileAppLockIsEngaged() throws {
        let root = temporaryRoot("restore-locked"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try launch(root)
        try first.store.deletePermanently([GettingStartedNotes.ids[0]])
        try first.settings.set(.mobileAppLock, to: true)
        try first.close()
        let library = try launch(root); defer { try? library.close() }
        #expect(library.appLocked)
        #expect(library.restoreGettingStarted() == nil)
        #expect(try all(library).count == 11)
    }

    @Test func restoreIsOffWhileTheLibraryIsBusyOrClosing() async throws {
        let root = temporaryRoot("restore-closing"); defer { try? FileManager.default.removeItem(at: root) }
        let library = try launch(root)
        #expect(library.canRestoreGettingStarted)
        try library.close()
        #expect(!library.canRestoreGettingStarted)
        #expect(library.restoreGettingStarted() == nil)
    }

    @Test func aWriteFailureComesBackToTheSettingsPageAndChangesNothing() throws {
        let root = temporaryRoot("restore-fails"); defer { try? FileManager.default.removeItem(at: root) }
        let library = try launch(root); defer { try? library.close() }
        try library.database.pool.write { try $0.execute(sql: "CREATE TRIGGER no_more_notes BEFORE INSERT ON note BEGIN SELECT RAISE(ABORT, 'no'); END") }
        try library.store.deletePermanently([GettingStartedNotes.ids[0]])
        let outcome = try #require(library.restoreGettingStarted())
        #expect({ if case .failure = outcome { true } else { false } }())
        #expect(try all(library).count == 11)
    }

    /// The words are the Mac's: they are read from the Mac source, so the two cannot drift apart.
    @Test func theWordsAreTheMacCommandsWords() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }  // …/Apps/TheoNotesIOS/Tests/<file> -> …/Apps
        let mac = try String(contentsOf: url.appendingPathComponent("TheoNotesMac/Sources/Help/GettingStartedMenu.swift"), encoding: .utf8)
        for text in [MobileGettingStarted.title, MobileGettingStarted.nothingTitle, MobileGettingStarted.nothingText,
                     MobileGettingStarted.failedTitle, MobileGettingStarted.failedText] {
            #expect(mac.contains("\"" + text + "\""), "\(text) is not the Mac's wording")
        }
    }
}
