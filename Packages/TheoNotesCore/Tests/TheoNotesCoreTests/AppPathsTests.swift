// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct AppPathsTests {
    @Test func testLayoutUnderRoot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(root: tmp)
        #expect(paths.database.path == tmp.path + "/Baerchen.sqlite")
        #expect(paths.attachments.path == tmp.path + "/Attachments")
        #expect(paths.journal.path == tmp.path + "/Journal")
        #expect(paths.backups.path == tmp.path + "/Backups")
        #expect(paths.logs.path == tmp.path + "/Logs")

        try paths.createDirectories()
        for dir in [paths.attachments, paths.journal, paths.backups, paths.logs] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    /// Final fix wave (T11 carry): the app opens `--data-dir <path>` or `BAERCHEN_DATA_DIR`, and
    /// never falls back to the real library when the override is unusable. The "real" library
    /// here is a temp folder: the test never touches Application Support.
    @Test func testDataDirOverrideResolution() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("baerchen-override-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let real = AppPaths(root: tmp.appendingPathComponent("Real", isDirectory: true))
        let copy = tmp.appendingPathComponent("Copy", isDirectory: true)
        let other = tmp.appendingPathComponent("Other", isDirectory: true)
        try fm.createDirectory(at: real.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        func resolve(_ arguments: [String], _ environment: [String: String] = [:]) throws -> URL {
            try AppPaths.resolve(arguments: ["/Applications/Baerchen.app/Contents/MacOS/Baerchen"] + arguments,
                                 environment: environment, production: real).root
        }

        // No override: the production folder.
        #expect(try resolve([]) == real.root)
        #expect(try resolve(["-NSDocumentRevisionsDebugMode", "YES"]) == real.root)
        // The argument (both spellings), the variable, and the argument winning over the variable.
        #expect(AppPaths.isSameDirectory(try resolve(["--data-dir", copy.path]), copy))
        #expect(AppPaths.isSameDirectory(try resolve(["--data-dir=" + copy.path]), copy))
        #expect(AppPaths.isSameDirectory(try resolve([], ["BAERCHEN_DATA_DIR": copy.path]), copy))
        #expect(AppPaths.isSameDirectory(try resolve(["--data-dir", other.path], ["BAERCHEN_DATA_DIR": copy.path]), other))
        // `~` is the home folder.
        #expect(try AppPaths.dataDirectory(from: "~/x", home: tmp)?.path == tmp.appendingPathComponent("x").path)

        // Unusable overrides throw; none of them opens the real library.
        #expect(throws: AppPaths.DataDirectoryError.missingValue(source: "--data-dir")) { try resolve(["--data-dir"]) }
        #expect(throws: AppPaths.DataDirectoryError.missingValue(source: "--data-dir")) { try resolve(["--data-dir", "--other"]) }
        #expect(throws: AppPaths.DataDirectoryError.missingValue(source: "BAERCHEN_DATA_DIR")) {
            try resolve([], ["BAERCHEN_DATA_DIR": "  "])
        }
        #expect(throws: AppPaths.DataDirectoryError.notAbsolute("relative/dir")) { try resolve(["--data-dir", "relative/dir"]) }
        let missing = tmp.appendingPathComponent("Missing").path
        #expect(throws: AppPaths.DataDirectoryError.notADirectory(missing)) { try resolve(["--data-dir", missing]) }
        #expect(throws: AppPaths.DataDirectoryError.notADirectory(file.path)) { try resolve([], ["BAERCHEN_DATA_DIR": file.path]) }
        #expect(throws: AppPaths.DataDirectoryError.isTheRealLibrary(real.root.path)) {
            try resolve(["--data-dir", real.root.path])
        }
        #expect(throws: AppPaths.DataDirectoryError.isTheRealLibrary(real.root.path.uppercased())) {
            try resolve(["--data-dir", real.root.path.uppercased()])
        }
        // A folder inside the real library (or holding it) is refused too.
        let inside = real.root.appendingPathComponent("Attachments", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(throws: AppPaths.DataDirectoryError.isTheRealLibrary(inside.path)) { try resolve(["--data-dir", inside.path]) }
        let holding = real.root.deletingLastPathComponent().path
        #expect(throws: AppPaths.DataDirectoryError.isTheRealLibrary(holding)) { try resolve(["--data-dir", holding]) }
        #expect(!fm.fileExists(atPath: missing), "an unusable path is never created")
        #expect(AppPaths.DataDirectoryError.notADirectory(missing).description.contains(missing))
    }

    /// Phase 2 sync hard-off: a library named at launch is opened exactly as given and
    /// is local-only for the process. Recovery files copied along with it cannot redirect it.
    @Test func testExplicitOverrideOpensExactlyThatFolderAndIsLocalOnly() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("baerchen-launch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let real = AppPaths(root: tmp.appendingPathComponent("Real", isDirectory: true))
        try fm.createDirectory(at: real.root, withIntermediateDirectories: true)
        // A copy that carries a recovery selection naming a valid sibling recovery library.
        let copy = tmp.appendingPathComponent("Copy", isDirectory: true)
        let copyRecovery = try Self.makeRecoverySibling(of: copy)
        try Self.select(copyRecovery, in: copy)
        // A copy of a recovery library itself: its marker names an original next to it.
        let id = UUID().uuidString.lowercased()
        let origin = tmp.appendingPathComponent("Orig", isDirectory: true)
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        let recoveryCopy = tmp.appendingPathComponent("Orig-Recovery-" + id, isDirectory: true)
        try fm.createDirectory(at: recoveryCopy, withIntermediateDirectories: true)
        try Self.writeMarker(id: id, origin: "Orig", in: recoveryCopy)
        // Sanity: the recovery files are valid, so the default-library rule would follow them.
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: AppPaths(root: copy)).root, copyRecovery))
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: AppPaths(root: recoveryCopy)).root, origin))

        func launch(_ arguments: [String], _ environment: [String: String] = [:]) throws -> LibraryLaunch {
            try AppPaths.resolveLaunch(arguments: ["Baerchen"] + arguments, environment: environment, production: real)
        }
        for launched in [
            try launch(["--data-dir", copy.path]),
            try launch(["--data-dir=" + copy.path]),
            try launch([], ["BAERCHEN_DATA_DIR": copy.path]),
        ] {
            #expect(launched.paths.root.path == copy.standardizedFileURL.path)
            #expect(launched.syncPolicy == .localOnly)
        }
        let exact = try launch(["--data-dir", recoveryCopy.path])
        #expect(exact.paths.root.path == recoveryCopy.standardizedFileURL.path)
        #expect(exact.syncPolicy == .localOnly)
        // Opening the copy changed none of its recovery files.
        #expect(fm.fileExists(atPath: copy.appendingPathComponent(".active-recovery-library.json").path))
        #expect(fm.fileExists(atPath: recoveryCopy.appendingPathComponent(".sync-recovery-library.json").path))

        // Unusable overrides still fail closed, symlink aliases of the real library included.
        let alias = tmp.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real.root)
        #expect(throws: AppPaths.DataDirectoryError.isTheRealLibrary(alias.path)) { try launch(["--data-dir", alias.path]) }
        #expect(throws: AppPaths.DataDirectoryError.missingValue(source: "--data-dir")) { try launch(["--data-dir"]) }
        #expect(throws: AppPaths.DataDirectoryError.notAbsolute("rel")) { try launch([], ["BAERCHEN_DATA_DIR": "rel"]) }
        // `resolve` (CLI, MCP, oracle) returns the same exact folder.
        #expect(try AppPaths.resolve(arguments: ["baerchen", "--data-dir", copy.path], environment: [:], production: real).root.path
            == copy.standardizedFileURL.path)
    }

    /// The default library keeps the deliberate recovery workflow: it follows the active recovery
    /// selection, and sync stays available there.
    @Test func testDefaultLaunchFollowsRecoverySelectionAndMaySync() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("baerchen-default-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let real = AppPaths(root: tmp.appendingPathComponent("Real", isDirectory: true))
        let plain = try AppPaths.resolveLaunch(arguments: ["Baerchen"], environment: [:], production: real)
        #expect(plain.paths.root == real.root)
        #expect(plain.syncPolicy == .enabled)
        let recovery = try Self.makeRecoverySibling(of: real.root)
        try Self.select(recovery, in: real.root)
        let followed = try AppPaths.resolveLaunch(arguments: ["Baerchen"], environment: [:], production: real)
        #expect(AppPaths.isSameDirectory(followed.paths.root, recovery))
        #expect(followed.syncPolicy == .enabled)
    }

    private static func writeMarker(id: String, origin: String, in folder: URL) throws {
        try Data(#"{"version":1,"id":"\#(id)","origin":"\#(origin)"}"#.utf8)
            .write(to: folder.appendingPathComponent(".sync-recovery-library.json"))
    }

    /// A valid `<base>-Recovery-<id>` sibling of `base` (both created).
    private static func makeRecoverySibling(of base: URL) throws -> URL {
        let id = UUID().uuidString.lowercased()
        let sibling = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-Recovery-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try writeMarker(id: id, origin: base.lastPathComponent, in: sibling)
        return sibling
    }

    private static func select(_ recovery: URL, in base: URL) throws {
        try Data(#"{"version":1,"name":"\#(recovery.lastPathComponent)"}"#.utf8)
            .write(to: base.appendingPathComponent(".active-recovery-library.json"))
    }

    /// The bear-oracle guard against the app's real data folder: APFS is case-insensitive by
    /// default and the folder can be reached through a symlink.
    @Test func testSameDirectoryIgnoresCaseSymlinksAndDots() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("baerchen-same-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("Baerchen", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)

        #expect(AppPaths.isSameDirectory(dir, dir))
        #expect(AppPaths.isSameDirectory(URL(fileURLWithPath: dir.path.uppercased()), dir))
        #expect(AppPaths.isSameDirectory(tmp.appendingPathComponent("BAERCHEN"), dir))
        #expect(AppPaths.isSameDirectory(link, dir))
        #expect(AppPaths.isSameDirectory(URL(fileURLWithPath: dir.path + "/../Baerchen/"), dir))
        #expect(!AppPaths.isSameDirectory(tmp, dir))
        #expect(!AppPaths.isSameDirectory(tmp.appendingPathComponent("Other"), dir))
        // A folder that does not exist yet compares by its spelled-out path, case-insensitively.
        let missing = tmp.appendingPathComponent("Missing/Baerchen")
        #expect(AppPaths.isSameDirectory(tmp.appendingPathComponent("missing/BAERCHEN"), missing))
        #expect(!AppPaths.isSameDirectory(missing, dir))
    }
}
