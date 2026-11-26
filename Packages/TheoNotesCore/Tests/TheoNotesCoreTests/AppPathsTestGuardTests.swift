// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// A process that runs under a test never resolves, moves or opens the real library.
/// "Real" is injected as a temporary folder here, so no test touches the real Application Support.
@Suite struct AppPathsTestGuardTests {
    private struct Fixture {
        let tmp: URL
        let support: URL
        var legacy: URL { support.appendingPathComponent("Baerchen", isDirectory: true) }
        var current: URL { support.appendingPathComponent("Theo Notes", isDirectory: true) }
        var production: AppPaths { AppPaths.production(applicationSupport: support) }

        init() throws {
            tmp = URL(fileURLWithPath: "/tmp/theo-\(UUID().uuidString.prefix(8))", isDirectory: true)
            support = tmp.appendingPathComponent("Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: tmp) }

        func makeLegacyLibrary() throws {
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: legacy.appendingPathComponent("marker.txt"))
        }

        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }

        /// The entries of the simulated Application Support folder, to prove nothing changed.
        func listing() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []).sorted()
        }
    }

    private static let underTest: AppPaths.TestRunDetector = { true }
    private static let notUnderTest: AppPaths.TestRunDetector = { false }

    #if os(macOS)
    @Test func aTestRunNeverMovesTheRealLibrary() throws {
        let real = try Fixture()
        defer { real.remove() }
        try real.makeLegacyLibrary()
        let before = real.listing()

        #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(real.current.path)) {
            try AppPaths.resolveLaunch(
                arguments: ["Theo Notes"], environment: [:], production: real.production,
                underTest: Self.underTest, realApplicationSupport: real.support)
        }
        #expect(real.listing() == before)
        #expect(real.exists(real.legacy.appendingPathComponent("marker.txt")))
        #expect(!real.exists(real.current))
    }

    @Test func aTestRunRefusesTheOldFolderAsProductionToo() throws {
        let real = try Fixture()
        defer { real.remove() }
        try real.makeLegacyLibrary()
        let before = real.listing()
        let oldAsProduction = AppPaths(root: real.legacy)

        #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(real.legacy.path)) {
            try AppPaths.resolveLaunch(
                arguments: ["Theo Notes"], environment: [:], production: oldAsProduction,
                underTest: Self.underTest, realApplicationSupport: real.support)
        }
        #expect(real.listing() == before)
    }

    @Test func theReadPathRefusesTheRealLibraryInATestRunAndCreatesNothing() throws {
        let real = try Fixture()
        defer { real.remove() }
        try real.makeLegacyLibrary()
        let before = real.listing()

        #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(real.current.path)) {
            try AppPaths.resolve(
                arguments: ["theonotes"], environment: [:], production: real.production,
                underTest: Self.underTest, realApplicationSupport: real.support)
        }
        #expect(real.listing() == before)
        #expect(!real.exists(real.current))
    }

    @Test func anInjectedTemporaryRootStillWorksInATestRun() throws {
        let real = try Fixture()
        let injected = try Fixture()
        defer { real.remove(); injected.remove() }
        try injected.makeLegacyLibrary()
        let realBefore = real.listing()

        let launch = try AppPaths.resolveLaunch(
            arguments: ["Theo Notes"], environment: [:], production: injected.production,
            underTest: Self.underTest, realApplicationSupport: real.support)
        #expect(launch.legacyMove == .moved)
        #expect(AppPaths.isSameDirectory(launch.paths.root, injected.current))
        #expect(!injected.exists(injected.legacy))

        let tool = try AppPaths.resolve(
            arguments: ["theonotes"], environment: [:], production: injected.production,
            underTest: Self.underTest, realApplicationSupport: real.support)
        #expect(AppPaths.isSameDirectory(tool.root, injected.current))
        #expect(real.listing() == realBefore)
    }

    @Test func aLaunchOverrideStillWorksInATestRun() throws {
        let real = try Fixture()
        let copy = try Fixture()
        defer { real.remove(); copy.remove() }
        let launch = try AppPaths.resolveLaunch(
            arguments: ["Theo Notes", "--data-dir", copy.support.path], environment: [:], production: real.production,
            underTest: Self.underTest, realApplicationSupport: real.support)
        #expect(AppPaths.isSameDirectory(launch.paths.root, copy.support))
    }

    @Test func anOverrideNamingTheRealLibraryIsRefusedInATestRun() throws {
        // The injected production root is a different (temp) folder, so only the real-root check can catch these.
        let real = try Fixture()
        let injected = try Fixture()
        defer { real.remove(); injected.remove() }
        let inside = real.current.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real.legacy, withIntermediateDirectories: true)
        let before = real.listing()
        let beforeInside = try FileManager.default.contentsOfDirectory(atPath: real.current.path)
        let named = [real.current, real.legacy, inside, real.support, real.tmp]

        for url in named {
            #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(url.path)) {
                try AppPaths.resolveLaunch(
                    arguments: ["Theo Notes", "--data-dir", url.path], environment: [:], production: injected.production,
                    underTest: Self.underTest, realApplicationSupport: real.support)
            }
            #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(url.path)) {
                try AppPaths.resolve(
                    arguments: ["theonotes", "--data-dir=\(url.path)"], environment: [:], production: injected.production,
                    underTest: Self.underTest, realApplicationSupport: real.support)
            }
            for key in [AppPaths.theonotesDataDirEnvironmentKey, AppPaths.dataDirEnvironmentKey] {
                #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(url.path)) {
                    try AppPaths.resolve(
                        arguments: ["theonotes"], environment: [key: url.path], production: injected.production,
                        underTest: Self.underTest, realApplicationSupport: real.support)
                }
            }
        }
        // A folder that does not exist yet inside the real one is refused before the existence check.
        let missing = real.current.appendingPathComponent("nope").path
        #expect(throws: AppPaths.DataDirectoryError.testMayNotUseRealLibrary(missing)) {
            try AppPaths.resolve(
                arguments: ["theonotes", "--data-dir", missing], environment: [:], production: injected.production,
                underTest: Self.underTest, realApplicationSupport: real.support)
        }
        #expect(real.listing() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.current.path) == beforeInside)
    }

    @Test func theSameOverridesAreNotRefusedOutsideATestRun() throws {
        let real = try Fixture()
        let injected = try Fixture()
        defer { real.remove(); injected.remove() }
        try FileManager.default.createDirectory(at: real.current, withIntermediateDirectories: true)
        // Outside a test run the existing rule is by the real production root only (injected here).
        let path = try AppPaths.resolve(
            arguments: ["theonotes", "--data-dir", real.current.path], environment: [:], production: injected.production,
            underTest: Self.notUnderTest, realApplicationSupport: real.support)
        #expect(AppPaths.isSameDirectory(path.root, real.current))
    }

    @Test func outsideATestRunTheBehaviourIsUnchanged() throws {
        let real = try Fixture()
        defer { real.remove() }
        try real.makeLegacyLibrary()

        let launch = try AppPaths.resolveLaunch(
            arguments: ["Theo Notes"], environment: [:], production: real.production,
            underTest: Self.notUnderTest, realApplicationSupport: real.support)
        #expect(launch.legacyMove == .moved)
        #expect(AppPaths.isSameDirectory(launch.paths.root, real.current))
        #expect(!real.exists(real.legacy))
        let tool = try AppPaths.resolve(
            arguments: ["theonotes"], environment: [:], production: real.production,
            underTest: Self.notUnderTest, realApplicationSupport: real.support)
        #expect(AppPaths.isSameDirectory(tool.root, real.current))
    }
    #endif

    @Test func theErrorSaysWhatToDo() {
        let text = AppPaths.DataDirectoryError.testMayNotUseRealLibrary("/x/Theo Notes").description
        #expect(text.contains("/x/Theo Notes"))
        #expect(text.contains("test"))
    }

    // MARK: detection

    private func detect(
        env: [String: String] = [:], executable: String = "Theo Notes", process: String = "Theo Notes", loaded: Bool = false
    ) -> Bool {
        AppPaths.looksLikeATestRun(environment: env, executableName: executable, processName: process, xctestLoaded: loaded)
    }

    @Test func detectsTheTestRunnerProcesses() {
        // `swift test` + XCTest runs `xctest`; Swift Testing runs `swiftpm-testing-helper`; neither sets an XCTest key.
        #expect(detect(executable: "xctest", process: "xctest"))
        #expect(detect(executable: "swiftpm-testing-helper", process: "swiftpm-testing-helper"))
        #expect(detect(executable: "xctest", process: "Foo"))
    }

    @Test func detectsAnXcodeTestHost() {
        #expect(detect(env: ["XCTestConfigurationFilePath": "/x/y.xctestconfiguration"], loaded: true))
    }

    @Test func aLoneStrayEnvironmentVariableIsNotATestRun() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(!detect(env: [key: "x"], executable: "theonotes", process: "theonotes", loaded: false))
        }
        // Even the configuration path alone, in a process that loaded no XCTest bundle, is not enough.
        #expect(!detect(env: ["XCTestConfigurationFilePath": "x"], loaded: false))
        // And a loaded XCTest without the host's configuration path is not an Xcode test host.
        #expect(!detect(loaded: true))
    }

    @Test func anOrdinaryLaunchIsNotATestRun() {
        #expect(!detect(env: ["HOME": "/Users/me"]))
        #expect(!detect(executable: "theonotes", process: "theonotes"))
    }

    #if os(macOS)
    @Test func aCommandLineWithTestLookingTextIsNeverRefused() throws {
        // Note text such as `--testing-library` or `-XCTest` in arguments, and stray XCTest variables,
        // must not lock the user out of the real library.
        let real = try Fixture()
        defer { real.remove() }
        try real.makeLegacyLibrary()
        let env = ["XCTestSessionIdentifier": "x", "XCTestBundlePath": "/x/B.xctest"]
        let detector: AppPaths.TestRunDetector = {
            AppPaths.looksLikeATestRun(
                environment: env, executableName: "theonotes", processName: "theonotes", xctestLoaded: false)
        }
        let tool = try AppPaths.resolve(
            arguments: ["theonotes", "notes", "add", "--testing-library", "-XCTest", "--test-bundle-path"],
            environment: env, production: real.production, underTest: detector, realApplicationSupport: real.support)
        #expect(AppPaths.isSameDirectory(tool.root, real.legacy))
    }
    #endif

    @Test func thisVeryTestRunIsDetected() {
        #expect(AppPaths.processRunsUnderTest())
    }
}
