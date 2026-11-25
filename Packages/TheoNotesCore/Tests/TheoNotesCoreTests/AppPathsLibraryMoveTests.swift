// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// The Theo Notes rename (REN-R1…): the macOS library folder is `Theo Notes`, and a library that
/// still lives in `Baerchen` is moved there once. Every test works in a temporary "Application
/// Support" folder; none touches the real home folder.
@Suite struct AppPathsLibraryMoveTests {
    private struct Fixture {
        let tmp: URL
        let support: URL
        var legacy: URL { support.appendingPathComponent("Baerchen", isDirectory: true) }
        var current: URL { support.appendingPathComponent("Theo Notes", isDirectory: true) }
        var production: AppPaths { AppPaths.production(applicationSupport: support) }

        init() throws {
            // Short, under /tmp: the lock sits next to the socket, whose path must fit 103 bytes.
            tmp = URL(fileURLWithPath: "/tmp/theo-\(UUID().uuidString.prefix(8))", isDirectory: true)
            support = tmp.appendingPathComponent("Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: tmp) }

        /// A library folder holding one marker file, so a moved folder can be recognised.
        func makeLibrary(_ folder: URL, marker: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: folder.appendingPathComponent("marker.txt"))
        }

        func marker(_ folder: URL) -> String? {
            (try? Data(contentsOf: folder.appendingPathComponent("marker.txt"))).flatMap { String(data: $0, encoding: .utf8) }
        }

        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }

        func launch(
            arguments: [String] = [], environment: [String: String] = [:]
        ) throws -> LibraryLaunch {
            try AppPaths.resolveLaunch(arguments: ["Theo Notes"] + arguments, environment: environment, production: production)
        }
    }

    @Test func productionFolderIsNamedAfterThePlatform() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #if os(macOS)
        #expect(fixture.production.root.lastPathComponent == "Theo Notes")
        #expect(fixture.production.root.deletingLastPathComponent() == fixture.support)
        #expect(AppPaths.production.root.lastPathComponent == "Theo Notes")
        #else
        #expect(fixture.production.root.lastPathComponent == "Baerchen")
        #expect(AppPaths.production.root.lastPathComponent == "Baerchen")
        #endif
    }

    #if os(macOS)
    @Test func onlyTheOldFolderExistsMovesItOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "jan")

        let first = try fixture.launch()
        #expect(first.paths.root == fixture.current)
        #expect(first.syncPolicy == .enabled)
        #expect(first.legacyMove == .moved)
        #expect(fixture.marker(fixture.current) == "jan")
        #expect(!fixture.exists(fixture.legacy))

        // A second launch finds the new folder and does nothing.
        let second = try fixture.launch()
        #expect(second.paths.root == fixture.current)
        #expect(second.legacyMove == .notNeeded)
        #expect(fixture.marker(fixture.current) == "jan")
        #expect(!fixture.exists(fixture.legacy))
    }

    @Test func bothFoldersExistOpensTheNewOneAndLeavesTheOldOneAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "old")
        try fixture.makeLibrary(fixture.current, marker: "new")

        let launch = try fixture.launch()
        #expect(launch.paths.root == fixture.current)
        #expect(launch.legacyMove == .newFolderExists)
        #expect(fixture.marker(fixture.current) == "new")
        #expect(fixture.marker(fixture.legacy) == "old")
    }

    @Test func aDanglingLinkAtTheNewPathIsNotReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "old")
        try FileManager.default.createSymbolicLink(
            at: fixture.current, withDestinationURL: fixture.tmp.appendingPathComponent("nowhere"))

        let launch = try fixture.launch()
        #expect(launch.legacyMove == .newFolderExists)
        #expect(fixture.marker(fixture.legacy) == "old")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.current.path)) != nil)
    }

    @Test func noOldFolderChangesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let launch = try fixture.launch()
        #expect(launch.paths.root == fixture.current)
        #expect(launch.legacyMove == .notNeeded)
        #expect(!fixture.exists(fixture.legacy))
        #expect(!fixture.exists(fixture.current), "the move never creates the new folder")
    }

    @Test func anOverrideMovesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "old")
        let copy = fixture.tmp.appendingPathComponent("Copy", isDirectory: true)
        try fixture.makeLibrary(copy, marker: "copy")

        for launch in [
            try fixture.launch(arguments: ["--data-dir", copy.path]),
            try fixture.launch(environment: ["BAERCHEN_DATA_DIR": copy.path]),
            try fixture.launch(environment: ["THEONOTES_DATA_DIR": copy.path]),
        ] {
            #expect(launch.paths.root.path == copy.standardizedFileURL.path)
            #expect(launch.syncPolicy == .localOnly)
            #expect(launch.legacyMove == .notNeeded)
        }
        #expect(fixture.marker(fixture.legacy) == "old")
        #expect(!fixture.exists(fixture.current))
    }

    @Test func theOldRealLibraryIsNotAcceptedAsAnOverrideEither() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "old")
        #expect(throws: AppPaths.DataDirectoryError.isTheRealLibrary(fixture.legacy.path)) {
            try fixture.launch(arguments: ["--data-dir", fixture.legacy.path])
        }
        #expect(fixture.marker(fixture.legacy) == "old")
    }

    @Test func aRecoverySelectionKeepsTheOldFolder() throws {
        for selectionFile in [".active-recovery-library.json", ".prepared-recovery-library.json"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeLibrary(fixture.legacy, marker: "old")
            let id = UUID().uuidString.lowercased()
            let recovery = fixture.support.appendingPathComponent("Baerchen-Recovery-" + id, isDirectory: true)
            try fixture.makeLibrary(recovery, marker: "recovery")
            try Data(#"{"version":1,"id":"\#(id)","origin":"Baerchen"}"#.utf8)
                .write(to: recovery.appendingPathComponent(".sync-recovery-library.json"))
            try Data(#"{"version":1,"name":"\#(recovery.lastPathComponent)"}"#.utf8)
                .write(to: fixture.legacy.appendingPathComponent(selectionFile))

            let launch = try fixture.launch()
            #expect(launch.legacyMove == .keptBecauseOfRecoverySelection)
            #expect(fixture.marker(fixture.legacy) == "old")
            #expect(!fixture.exists(fixture.current), "\(selectionFile)")
            if selectionFile == ".active-recovery-library.json" {
                // The default launch still follows the active selection next to the old base.
                #expect(AppPaths.isSameDirectory(launch.paths.root, recovery))
                #expect(launch.syncPolicy == .enabled)
            } else {
                #expect(AppPaths.isSameDirectory(launch.paths.root, fixture.legacy))
            }
        }
    }

    @Test func theCommandLineReadsTheOldFolderWithoutMovingIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "old")

        let resolved = try AppPaths.resolve(arguments: ["theonotes"], environment: [:], production: fixture.production)
        #expect(resolved.root == fixture.legacy)
        #expect(fixture.marker(fixture.legacy) == "old")
        #expect(!fixture.exists(fixture.current))

        // Once the app has moved the library, the command line follows it.
        _ = try fixture.launch()
        let after = try AppPaths.resolve(arguments: ["theonotes"], environment: [:], production: fixture.production)
        #expect(after.root == fixture.current)
    }

    /// Fix round 1: a competing first launch moved the folder between our checks and our rename.
    /// The failed rename is followed by a look at the file system, never by a fall back to a path
    /// that no longer exists, and nothing is created at either path.
    @Test func aLostRaceResolvesToTheNewFolderAndCreatesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "jan")
        let competitor: AppPaths.LibraryRename = { from, to in
            // The other launch wins: it renames first, ours then fails with ENOENT.
            _ = renamex_np(from, to, UInt32(RENAME_EXCL))
            errno = ENOENT
            return -1
        }
        let launch = try AppPaths.resolveLaunch(
            arguments: ["Theo Notes"], environment: [:], production: fixture.production, renameLibrary: competitor)
        #expect(launch.paths.root == fixture.current)
        #expect(launch.legacyMove == .newFolderExists)
        #expect(launch.syncPolicy == .enabled)
        #expect(fixture.marker(fixture.current) == "jan")
        #expect(!fixture.exists(fixture.legacy), "the old path is not created again")
    }

    /// REN-R12: a library that was there at the first check of the launch and is gone afterwards
    /// is never replaced by an empty one: the launch is refused, and nothing is created.
    @Test func aLibraryThatVanishedDuringTheLaunchFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "x")
        let vanishing: AppPaths.LibraryRename = { from, _ in
            try? FileManager.default.removeItem(atPath: from)
            errno = ENOENT
            return -1
        }
        #expect(throws: AppPaths.DataDirectoryError.libraryVanished(fixture.current.path)) {
            try AppPaths.resolveLaunch(
                arguments: ["Theo Notes"], environment: [:], production: fixture.production, renameLibrary: vanishing)
        }
        #expect(!fixture.exists(fixture.legacy))
        #expect(!fixture.exists(fixture.current), "resolving creates nothing")
    }

    /// REN-R12: a fresh install (neither folder at the first check) is not an error, and the
    /// tools never hand out the old path when it does not exist.
    @Test func aFreshInstallOrAToolNeverGetsAVanishedOldPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fresh = try fixture.launch()
        #expect(fresh.paths.root == fixture.current)
        #expect(fresh.createsLibraryFolder, "a fresh install may create its library")
        let tool = try AppPaths.resolve(arguments: ["theonotes"], environment: [:], production: fixture.production)
        #expect(tool.root == fixture.current)
        #expect(!fixture.exists(fixture.legacy))
        #expect(!fixture.exists(fixture.current))
    }

    /// REN-R11: the move happens only under the single-instance lock of the old folder
    /// (`app.sock.lock`, the file the app's socket server holds). While another process holds it,
    /// this launch opens the old library and the move is left to a later launch.
    /// REN-R12: only a launch that saw no library at all may create the folder.
    @Test func onlyAFreshInstallMayCreateTheLibraryFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "jan")
        let moved = try fixture.launch()
        #expect(moved.legacyMove == .moved)
        #expect(!moved.createsLibraryFolder)
        let existing = try fixture.launch()
        #expect(!existing.createsLibraryFolder)
        let copy = fixture.tmp.appendingPathComponent("Copy", isDirectory: true)
        try fixture.makeLibrary(copy, marker: "copy")
        #expect(!(try fixture.launch(arguments: ["--data-dir", copy.path])).createsLibraryFolder)
    }

    @Test func aHeldInstanceLockPostponesTheMove() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "jan")
        let lockPath = fixture.legacy.appendingPathComponent("app.sock.lock").path
        let holder = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(holder >= 0)
        defer { close(holder) }
        try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)

        let blocked = try fixture.launch()
        #expect(blocked.legacyMove == .keptBecauseAnotherInstanceRuns)
        #expect(blocked.paths.root == fixture.legacy)
        #expect(blocked.syncPolicy == .enabled)
        #expect(fixture.marker(fixture.legacy) == "jan")
        #expect(!fixture.exists(fixture.current))

        flock(holder, LOCK_UN)
        let moved = try fixture.launch()
        #expect(moved.legacyMove == .moved)
        #expect(moved.paths.root == fixture.current)
        #expect(fixture.marker(fixture.current) == "jan")
        #expect(!fixture.exists(fixture.legacy))
        // The lock is released again: the app's own server can take it at the new place.
        let again = open(fixture.current.appendingPathComponent("app.sock.lock").path, O_RDWR | O_CLOEXEC)
        try #require(again >= 0)
        defer { close(again) }
        #expect(flock(again, LOCK_EX | LOCK_NB) == 0)
    }

    /// The socket server keeps its lock elsewhere when the folder path is too long for a socket;
    /// then the lock cannot be found and the old folder is simply kept.
    @Test func aFolderPathTooLongForTheSocketIsNeverMoved() throws {
        let long = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "x", count: 90), isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: long.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
        let production = AppPaths.production(applicationSupport: long)
        let legacy = AppPaths.legacyProduction(for: production)!.root
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let launch = try AppPaths.resolveLaunch(arguments: ["Theo Notes"], environment: [:], production: production)
        guard case .failed = launch.legacyMove else { Issue.record("\(launch.legacyMove)"); return }
        #expect(launch.paths.root == legacy)
        #expect(!FileManager.default.fileExists(atPath: production.root.path))
    }

    @Test func aRefusedRenameKeepsTheOldFolderWhileItExists() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLibrary(fixture.legacy, marker: "old")
        let refused: AppPaths.LibraryRename = { _, _ in
            errno = EACCES
            return -1
        }
        let launch = try AppPaths.resolveLaunch(
            arguments: ["Theo Notes"], environment: [:], production: fixture.production, renameLibrary: refused)
        #expect(launch.legacyMove == .failed(String(cString: strerror(EACCES))))
        #expect(launch.paths.root == fixture.legacy)
        #expect(fixture.marker(fixture.legacy) == "old")
        #expect(!fixture.exists(fixture.current))
    }

    @Test func theOldFolderCountsAsTheRealLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let production = fixture.production
        #expect(AppPaths.isRealLibrary(fixture.current, production: production))
        #expect(AppPaths.isRealLibrary(fixture.legacy, production: production))
        #expect(!AppPaths.isRealLibrary(fixture.support.appendingPathComponent("Other"), production: production))
        // A production folder with another name has no old sibling.
        let custom = AppPaths(root: fixture.support.appendingPathComponent("Real", isDirectory: true))
        #expect(!AppPaths.isRealLibrary(fixture.legacy, production: custom))
        #expect(AppPaths.legacyProduction(for: custom) == nil)
        #expect(AppPaths.legacyProduction(for: production)?.root == fixture.legacy)
    }
    #endif

    @Test func theonotesDataDirWinsOverBaerchenDataDir() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let theo = fixture.tmp.appendingPathComponent("Theo", isDirectory: true)
        let old = fixture.tmp.appendingPathComponent("Old", isDirectory: true)
        try fixture.makeLibrary(theo, marker: "theo")
        try fixture.makeLibrary(old, marker: "old")

        func resolved(_ arguments: [String], _ environment: [String: String]) throws -> URL {
            try AppPaths.resolve(arguments: ["theonotes"] + arguments, environment: environment, production: fixture.production).root
        }
        #expect(try resolved([], ["THEONOTES_DATA_DIR": theo.path]).path == theo.standardizedFileURL.path)
        #expect(try resolved([], ["BAERCHEN_DATA_DIR": old.path]).path == old.standardizedFileURL.path)
        #expect(try resolved([], ["THEONOTES_DATA_DIR": theo.path, "BAERCHEN_DATA_DIR": old.path]).path
            == theo.standardizedFileURL.path)
        // The launch argument still beats both variables.
        #expect(try resolved(["--data-dir", old.path], ["THEONOTES_DATA_DIR": theo.path]).path == old.standardizedFileURL.path)
        #expect(throws: AppPaths.DataDirectoryError.missingValue(source: "THEONOTES_DATA_DIR")) {
            try resolved([], ["THEONOTES_DATA_DIR": " ", "BAERCHEN_DATA_DIR": old.path])
        }
        #expect(AppPaths.theonotesDataDirEnvironmentKey == "THEONOTES_DATA_DIR")
        #expect(AppPaths.dataDirEnvironmentKey == "BAERCHEN_DATA_DIR")
    }
}
