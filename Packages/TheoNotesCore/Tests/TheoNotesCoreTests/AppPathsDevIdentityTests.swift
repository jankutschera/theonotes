// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// FOC-R361, FOC-R362: a dev-identity build opens its own library (`Theo Notes Dev`) and refuses the
/// production library (`Theo Notes`, and the pre-rename `Baerchen` folder) however it is named. "Real"
/// is a temporary Application Support folder here: no test touches the real one.
#if os(macOS)
@Suite struct AppPathsDevIdentityTests {
    private struct Fixture {
        let tmp: URL
        let support: URL
        var productionFolder: URL { support.appendingPathComponent("Theo Notes", isDirectory: true) }
        var legacyFolder: URL { support.appendingPathComponent("Baerchen", isDirectory: true) }
        var devFolder: URL { support.appendingPathComponent("Theo Notes Dev", isDirectory: true) }

        init() throws {
            tmp = URL(fileURLWithPath: "/tmp/theo-dev-\(UUID().uuidString.prefix(8))", isDirectory: true)
            support = tmp.appendingPathComponent("Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: tmp) }

        func make(_ folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: folder.appendingPathComponent("marker.txt"))
        }

        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }

        func listing() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []).sorted()
        }
    }

    private static let notUnderTest: AppPaths.TestRunDetector = { false }
    private static let underTest: AppPaths.TestRunDetector = { true }
    private static let argv0 = "/x/BaerchenDev.app/Contents/MacOS/Baerchen"

    @Test func theDevDefaultLibraryIsTheDevFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dev = AppPaths.production(applicationSupport: fixture.support, identity: .dev)
        #expect(dev.root.lastPathComponent == "Theo Notes Dev")
        #expect(AppPaths.production(applicationSupport: fixture.support, identity: .production).root.lastPathComponent == "Theo Notes")

        let launch = try AppPaths.resolveLaunch(
            arguments: [Self.argv0], environment: [:], production: dev, identity: .dev,
            underTest: Self.notUnderTest, realApplicationSupport: fixture.support)
        #expect(launch.paths.root.lastPathComponent == "Theo Notes Dev")
        #expect(launch.createsLibraryFolder)
    }

    @Test func aDevLibraryThatExistsIsOpenedNotCreated() throws {
        // REN-R12 for the dev library: only a fresh start may create it; once it was seen, a vanished
        // folder fails the launch instead of silently starting an empty library.
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.make(fixture.devFolder)
        let dev = AppPaths.production(applicationSupport: fixture.support, identity: .dev)
        let launch = try AppPaths.resolveLaunch(
            arguments: [Self.argv0], environment: [:], production: dev, identity: .dev,
            underTest: Self.notUnderTest, realApplicationSupport: fixture.support)
        #expect(!launch.createsLibraryFolder)
        #expect(AppPaths.isSameDirectory(launch.paths.root, fixture.devFolder))
    }

    @Test func aDevLaunchNeverMovesTheProductionLibraries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.make(fixture.legacyFolder)
        let dev = AppPaths.production(applicationSupport: fixture.support, identity: .dev)
        #expect(AppPaths.legacyProduction(for: dev) == nil)

        _ = try AppPaths.resolveLaunch(
            arguments: [Self.argv0], environment: [:], production: dev, identity: .dev,
            underTest: Self.notUnderTest, realApplicationSupport: fixture.support)
        // The old `Baerchen` folder is production data: still there, never renamed to the dev folder.
        #expect(fixture.exists(fixture.legacyFolder.appendingPathComponent("marker.txt")))
        #expect(!fixture.exists(fixture.devFolder.appendingPathComponent("marker.txt")))
    }

    @Test func aDevBuildRefusesTheProductionFolderAsItsDefaultLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.make(fixture.productionFolder)
        try fixture.make(fixture.legacyFolder)
        let before = fixture.listing()
        for protected in [fixture.productionFolder, fixture.legacyFolder] {
            #expect(throws: AppPaths.DataDirectoryError.devBuildMayNotUseProductionLibrary(protected.path)) {
                try AppPaths.resolveLaunch(
                    arguments: [Self.argv0], environment: [:], production: AppPaths(root: protected), identity: .dev,
                    underTest: Self.notUnderTest, realApplicationSupport: fixture.support)
            }
        }
        #expect(fixture.listing() == before)
        #expect(fixture.exists(fixture.productionFolder.appendingPathComponent("marker.txt")))
        #expect(fixture.exists(fixture.legacyFolder.appendingPathComponent("marker.txt")))
    }

    @Test func aDevBuildRefusesTheProductionLibraryAsADataDirOverride() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.make(fixture.productionFolder)
        try fixture.make(fixture.legacyFolder)
        let inside = fixture.productionFolder.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let dev = AppPaths.production(applicationSupport: fixture.support, identity: .dev)
        func launch(_ path: String, viaEnvironment: Bool = false) throws -> LibraryLaunch {
            try AppPaths.resolveLaunch(
                arguments: viaEnvironment ? [Self.argv0] : [Self.argv0, "--data-dir", path],
                environment: viaEnvironment ? ["THEONOTES_DATA_DIR": path] : [:],
                production: dev, identity: .dev,
                underTest: Self.notUnderTest, realApplicationSupport: fixture.support)
        }
        for protected in [fixture.productionFolder, fixture.legacyFolder, inside] {
            #expect(throws: AppPaths.DataDirectoryError.devBuildMayNotUseProductionLibrary(protected.path)) {
                try launch(protected.path)
            }
        }
        #expect(throws: AppPaths.DataDirectoryError.devBuildMayNotUseProductionLibrary(fixture.productionFolder.path)) {
            try launch(fixture.productionFolder.path, viaEnvironment: true)
        }
        // The folder that holds the production library would share its files too.
        #expect(throws: AppPaths.DataDirectoryError.devBuildMayNotUseProductionLibrary(fixture.support.path)) {
            try launch(fixture.support.path)
        }
        // Even a path that does not exist yet is refused, before anything looks at it.
        let missing = fixture.support.appendingPathComponent("Theo Notes/Nope", isDirectory: true)
        #expect(throws: AppPaths.DataDirectoryError.devBuildMayNotUseProductionLibrary(missing.path)) {
            try launch(missing.path)
        }

        // A copy elsewhere is fine and local-only, like any other override.
        let copy = fixture.tmp.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let allowed = try launch(copy.path)
        #expect(AppPaths.isSameDirectory(allowed.paths.root, copy))
        #expect(allowed.syncPolicy == .localOnly)
    }

    @Test func theProductionIdentityKeepsOpeningItsOwnLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.make(fixture.productionFolder)
        let launch = try AppPaths.resolveLaunch(
            arguments: [Self.argv0], environment: [:],
            production: AppPaths.production(applicationSupport: fixture.support, identity: .production), identity: .production,
            underTest: Self.notUnderTest, realApplicationSupport: fixture.support)
        #expect(AppPaths.isSameDirectory(launch.paths.root, fixture.productionFolder))
        #expect(launch.syncPolicy == .enabled)
    }

    @Test func aTestRunAlsoRefusesTheDevLibraryItself() throws {
        // The tests of the dev build use a temporary folder too: the dev library is real data of its own.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dev = AppPaths.production(applicationSupport: fixture.support, identity: .dev)
        #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(fixture.devFolder.path)) {
            try AppPaths.resolveLaunch(
                arguments: [Self.argv0], environment: [:], production: dev, identity: .dev,
                underTest: Self.underTest, realApplicationSupport: fixture.support)
        }
        #expect(!fixture.exists(fixture.devFolder))
    }
}
#endif
