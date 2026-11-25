// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import os
#if os(macOS)
import Darwin
#endif

private let libraryMoveLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "library")

/// What a default launch did about a library still living in the pre-rename `Baerchen` folder.
public enum LegacyLibraryMove: Equatable, Sendable {
    /// Nothing to do: no old folder, or this platform keeps its folder name.
    case notNeeded
    /// The old folder was renamed to the new one (one `renamex_np`, never copy-then-delete).
    case moved
    /// Both folders exist: the new one is opened, the old one is left exactly as it is.
    case newFolderExists
    /// Another process holds the single-instance lock of the old folder (`app.sock.lock`): an
    /// older app, a second launch or its recovery flow is running. This launch opens the old
    /// folder; the move is retried on a later launch (REN-R11).
    case keptBecauseAnotherInstanceRuns
    /// An active or prepared sync recovery selection sits next to the old base and names it:
    /// moving would orphan it, so the old folder stays the library.
    case keptBecauseOfRecoverySelection
    /// The rename was refused by the file system; the old folder stays the library.
    case failed(String)

    /// Whether the launch must keep opening the old folder.
    var keepsLegacyBase: Bool {
        switch self {
        case .keptBecauseOfRecoverySelection, .keptBecauseAnotherInstanceRuns, .failed: true
        case .notNeeded, .moved, .newFolderExists: false
        }
    }
}

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The library folder name of the PRODUCTION identity inside Application Support: `Theo Notes` on
    /// macOS. iOS keeps `Baerchen` in Stage 1 (REN-R3). Fixed: this is the folder the guards protect.
    #if os(macOS)
    public static let productionLibraryFolderName = "Theo Notes"
    #else
    public static let productionLibraryFolderName = "Baerchen"
    #endif
    /// The folder name before the rename; on macOS a library found there is moved once.
    public static let legacyLibraryFolderName = LegacyNames.libraryFolder

    public static var production: AppPaths {
        production(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// The default library of `identity` below an Application Support folder (tests pass a temporary
    /// one). Named `production` because it is the library the app opens by default; for a dev
    /// identity that is the dev library, never the production one.
    public static func production(applicationSupport: URL, identity: AppIdentity = .current) -> AppPaths {
        AppPaths(root: applicationSupport.appendingPathComponent(identity.libraryFolderName, isDirectory: true))
    }

    /// The pre-rename sibling of a production library, macOS only; nil for any other root name
    /// (a test's own folder, iOS, the dev library), so nothing next to such a root is ever treated
    /// as old data and a dev build never moves the production `Baerchen` folder.
    public static func legacyProduction(for production: AppPaths) -> AppPaths? {
        #if os(macOS)
        guard production.root.lastPathComponent == productionLibraryFolderName else { return nil }
        return AppPaths(root: production.root.deletingLastPathComponent()
            .appendingPathComponent(legacyLibraryFolderName, isDirectory: true))
        #else
        return nil
        #endif
    }

    /// Whether `root` is the real library: the production folder or, on macOS, the old folder
    /// it may still be waiting in. Tools that must never touch real data refuse both.
    public static func isRealLibrary(_ root: URL, production: AppPaths = .production) -> Bool {
        if isSameDirectory(root, production.root) { return true }
        guard let legacy = legacyProduction(for: production) else { return false }
        return isSameDirectory(root, legacy.root)
    }

    /// A launch override of the library folder that cannot be used. The app refuses to launch
    /// with it rather than open the real library.
    public enum DataDirectoryError: Error, Equatable, CustomStringConvertible {
        /// `--data-dir` without a path, or `BAERCHEN_DATA_DIR` set to nothing.
        case missingValue(source: String)
        case notAbsolute(String)
        /// Missing, or not a folder.
        case notADirectory(String)
        /// The override names the real library (`production`): launch without it instead.
        case isTheRealLibrary(String)
        /// A library seen at the start of the launch is gone (another copy of the app moved or
        /// removed it): the launch is refused instead of creating an empty library (REN-R12).
        case libraryVanished(String)
        /// A process running under a test (XCTest, Swift Testing) was asked for the real library
        /// (REN-R14): tests inject a temporary production root or a `--data-dir` instead.
        case testMayNotUseRealLibrary(String)
        /// A dev-identity build was asked for the production library (FOC-R362), by default or by an
        /// override: the folder `Theo Notes`, the old `Baerchen` folder, anything inside or holding them.
        case devBuildMayNotUseProductionLibrary(String)

        public var description: String {
            switch self {
            case .missingValue(let source): "\(source) is set but names no folder."
            case .notAbsolute(let path): "“\(path)” is not an absolute path (start it with / or ~/)."
            case .notADirectory(let path): "“\(path)” is not an existing folder."
            case .isTheRealLibrary(let path): "“\(path)” is the real library; launch without an override to open it."
            case .libraryVanished(let path):
                "The library folder “\(path)” disappeared while Theo Notes was starting. Quit every copy of Theo Notes and open it again."
            case .testMayNotUseRealLibrary(let path):
                "A test run asked for the real library “\(path)” and was refused. Tests must use a temporary library folder."
            case .devBuildMayNotUseProductionLibrary(let path):
                "This is a development build; it never opens the library of the installed app, so “\(path)” was refused. Use a copy and --data-dir."
            }
        }
    }

    public static let dataDirArgument = "--data-dir"
    /// The older variable name, still honoured (REN-R4).
    public static let dataDirEnvironmentKey = LegacyNames.dataDirEnvironment
    /// The variable of the renamed product; wins over `BAERCHEN_DATA_DIR` when both are set.
    public static let theonotesDataDirEnvironmentKey = "THEONOTES_DATA_DIR"

    /// The library folder the app opens: the launch argument `--data-dir <path>` (or
    /// `--data-dir=<path>`), else the environment variable `THEONOTES_DATA_DIR`, else
    /// `BAERCHEN_DATA_DIR`, else `production`.
    /// An override must be an existing folder given as an absolute or `~/` path, and not the real
    /// library; otherwise this throws, and the caller must not fall back to `production`.
    /// For tools (CLI, MCP): never moves a library. While the library still lives in the old
    /// `Baerchen` folder it is read from there, until the app has moved it.
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        production: AppPaths = .production,
        identity: AppIdentity = .current,
        underTest: TestRunDetector = AppPaths.processRunsUnderTest,
        realApplicationSupport: URL = AppPaths.userApplicationSupport
    ) throws -> AppPaths {
        try resolveLaunch(
            arguments: arguments, environment: environment, production: production, movesLegacyLibrary: false,
            identity: identity, underTest: underTest, realApplicationSupport: realApplicationSupport).paths
    }

    /// Whether this process runs under a test. Injectable so tests can simulate both cases.
    public typealias TestRunDetector = @Sendable () -> Bool

    /// The user's real Application Support folder, the parent of the real library.
    public static var userApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `looksLikeATestRun` for this very process.
    public static let processRunsUnderTest: TestRunDetector = {
        looksLikeATestRun(
            environment: ProcessInfo.processInfo.environment,
            executableName: (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? "",
            processName: ProcessInfo.processInfo.processName,
            xctestLoaded: NSClassFromString("XCTestCase") != nil
                || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") })
    }

    /// Whether a process is a test run, decided from the process itself and never from its
    /// arguments (a command-line argument can be note text). Two shapes count:
    /// - the runner: the executable is `xctest` (`swift test` with XCTest) or `swiftpm-testing-helper`
    ///   (`swift test` with Swift Testing); neither sets any XCTest environment variable;
    /// - an Xcode test host (`xcodebuild test`): the app, with `XCTestConfigurationFilePath` set
    ///   and an XCTest bundle really loaded. The variable alone, or a loaded bundle alone, is not enough.
    static func looksLikeATestRun(
        environment: [String: String], executableName: String, processName: String, xctestLoaded: Bool
    ) -> Bool {
        let runners = ["xctest", "swiftpm-testing-helper"]
        if runners.contains(executableName) || runners.contains(processName) { return true }
        return environment["XCTestConfigurationFilePath"] != nil && xctestLoaded
    }

    /// The library folders of the PRODUCTION identity in an Application Support folder, whatever the
    /// identity of this process: `Theo Notes` and, on macOS, the old `Baerchen` one.
    private static func productionLibraryRoots(in applicationSupport: URL) -> [URL] {
        let real = production(applicationSupport: applicationSupport, identity: .production)
        return [real.root] + [legacyProduction(for: real)?.root].compactMap { $0 }
    }

    /// Every real library of an Application Support folder, of both identities: the production
    /// ones and the dev one. A test run uses none of them.
    private static func realLibraryRoots(in applicationSupport: URL) -> [URL] {
        productionLibraryRoots(in: applicationSupport)
            + [production(applicationSupport: applicationSupport, identity: .dev).root]
    }

    /// FOC-R362: throws when a dev-identity build is pointed at the production library: as its default
    /// (`url` is the folder it would open) or as an override. Checked before anything is looked at,
    /// moved or created, and whether or not the folder exists.
    private static func refuseProductionLibraryForDev(
        _ url: URL, value: String, identity: AppIdentity, realApplicationSupport: URL
    ) throws {
        guard identity == .dev else { return }
        guard productionLibraryRoots(in: realApplicationSupport).contains(where: { isSameDirectory(url, $0) || nests(url, $0) })
        else { return }
        libraryMoveLogger.fault("refusing: a dev build asked for the production library")
        throw DataDirectoryError.devBuildMayNotUseProductionLibrary(value)
    }

    /// REN-R14: throws when a test run would use the real library through `production` (or the old
    /// folder next to it). Tests inject a temporary production root, which stays valid.
    private static func refuseRealLibraryInATestRun(
        production: AppPaths, underTest: TestRunDetector, realApplicationSupport: URL
    ) throws {
        guard underTest() else { return }
        let realRoots = realLibraryRoots(in: realApplicationSupport)
        let askedRoots = [production.root] + [legacyProduction(for: production)?.root].compactMap { $0 }
        for asked in askedRoots where realRoots.contains(where: { isSameDirectory(asked, $0) }) {
            libraryMoveLogger.fault("refusing: a test run asked for the real library")
            throw DataDirectoryError.testMayNotUseRealLibrary(asked.path)
        }
    }

    /// REN-R14 for an override: under a test run, a folder that is, lies inside or holds the real
    /// library (`Theo Notes` or `Baerchen` in `realApplicationSupport`) is refused, whether or not it exists.
    private static func refuseRealLibraryOverrideInATestRun(
        _ url: URL, value: String, underTest: TestRunDetector, realApplicationSupport: URL
    ) throws {
        guard underTest() else { return }
        guard realLibraryRoots(in: realApplicationSupport).contains(where: { isSameDirectory(url, $0) || nests(url, $0) })
        else { return }
        libraryMoveLogger.fault("refusing: a test run named the real library as its override")
        throw DataDirectoryError.testMayNotUseRealLibrary(value)
    }

    /// `resolve` plus the sync policy of the launch (INT-R14). An override is opened exactly as
    /// given, never redirected by recovery files inside or next to it, and is `localOnly`.
    /// Without one, the active recovery selection of `production` is followed and sync may run.
    ///
    /// On macOS a default launch also finishes the rename (REN-R2): when `Theo Notes` does not
    /// exist and `Baerchen` does, the old folder is renamed to the new name, once, atomically and
    /// without ever replacing anything. It stays where it is when both exist (the new one is
    /// opened) or when a sync recovery selection sits next to it (the selection names the old
    /// folder, so the app keeps opening that one). `movesLegacyLibrary: false` only reads.
    ///
    /// REN-R14: under a test run (`underTest`), a default launch whose `production` is the real
    /// library of `realApplicationSupport` (or the old folder next to it) throws
    /// `testMayNotUseRealLibrary` before it looks at, moves or creates anything.
    public static func resolveLaunch(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        production: AppPaths = .production,
        movesLegacyLibrary: Bool = true,
        renameLibrary: LibraryRename = AppPaths.exclusiveRename,
        identity: AppIdentity = .current,
        underTest: TestRunDetector = AppPaths.processRunsUnderTest,
        realApplicationSupport: URL = AppPaths.userApplicationSupport
    ) throws -> LibraryLaunch {
        var override: (value: String, source: String)?
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            if argument == dataDirArgument {
                guard let value = rest.first, !value.hasPrefix("--") else {
                    throw DataDirectoryError.missingValue(source: dataDirArgument)
                }
                override = (value, dataDirArgument)
                rest = rest.dropFirst()
            } else if argument.hasPrefix(dataDirArgument + "=") {
                override = (String(argument.dropFirst(dataDirArgument.count + 1)), dataDirArgument)
            }
        }
        if override == nil {
            for key in [theonotesDataDirEnvironmentKey, dataDirEnvironmentKey] {
                if let value = environment[key] {
                    override = (value, key)
                    break
                }
            }
        }
        guard let (value, source) = override else {
            try refuseProductionLibraryForDev(
                production.root, value: production.root.path, identity: identity, realApplicationSupport: realApplicationSupport)
            // REN-R14: before anything can move, create or hand out the real library.
            try refuseRealLibraryInATestRun(
                production: production, underTest: underTest, realApplicationSupport: realApplicationSupport)
            // REN-R12: only a fresh install (neither folder at the first check) may get a new library.
            let legacy = legacyProduction(for: production)
            // The dev library has no old folder to move, but REN-R12 holds for it all the same.
            let isDevLibrary = identity == .dev && production.root.lastPathComponent == AppIdentity.dev.libraryFolderName
            let observed = isDevLibrary
                ? entryExists(production.root)
                : legacy != nil && (entryExists(production.root) || isDirectory(legacy!.root))
            let move = movesLegacyLibrary ? moveLegacyLibraryIfNeeded(production: production, rename: renameLibrary) : LegacyLibraryMove.notNeeded
            let base = defaultBase(production: production, move: move)
            let paths = try SyncRecoveryLibrary.activePaths(base: base)
            guard !observed || entryExists(paths.root) else {
                libraryMoveLogger.fault("refusing to launch: the library folder vanished during the launch")
                throw DataDirectoryError.libraryVanished(production.root.path)
            }
            return LibraryLaunch(paths: paths, syncPolicy: .enabled, legacyMove: move, createsLibraryFolder: !observed)
        }
        guard let url = try dataDirectory(from: value) else { throw DataDirectoryError.missingValue(source: source) }
        try refuseProductionLibraryForDev(url, value: value, identity: identity, realApplicationSupport: realApplicationSupport)
        try refuseRealLibraryOverrideInATestRun(
            url, value: value, underTest: underTest, realApplicationSupport: realApplicationSupport)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DataDirectoryError.notADirectory(value)
        }
        // Not the real library, nor a folder inside it or holding it: both would share its files.
        // The old `Baerchen` folder is the real library too until it has been moved.
        let realRoots = [production.root] + [legacyProduction(for: production)?.root].compactMap { $0 }
        guard !realRoots.contains(where: { isSameDirectory(url, $0) || nests(url, $0) }) else {
            throw DataDirectoryError.isTheRealLibrary(value)
        }
        return LibraryLaunch(paths: AppPaths(root: url), syncPolicy: .localOnly)
    }

    /// The base of a default launch: `production`, or the old folder when the move did not (or
    /// could not) happen and the library still lives there.
    private static func defaultBase(production: AppPaths, move: LegacyLibraryMove) -> AppPaths {
        guard let legacy = legacyProduction(for: production) else { return production }
        // Only a folder that is still there can stay the library: after a lost race it is gone,
        // and a path that no longer exists is never handed out (nothing may recreate it).
        if move.keepsLegacyBase, isDirectory(legacy.root), !entryExists(production.root) { return legacy }
        if move.keepsLegacyBase { return production }
        // A read-only caller (the command line) before the app has moved the library.
        if move == .notNeeded, !entryExists(production.root), isDirectory(legacy.root) { return legacy }
        return production
    }

    /// The one-time move of the old macOS library folder, as described at `resolveLaunch`.
    /// Never creates, merges, copies or deletes anything: it either renames the old folder or
    /// leaves both folders alone.
    public static func moveLegacyLibraryIfNeeded(
        production: AppPaths, rename: LibraryRename = AppPaths.exclusiveRename
    ) -> LegacyLibraryMove {
        #if os(macOS)
        guard let legacy = legacyProduction(for: production), isDirectory(legacy.root) else { return .notNeeded }
        if entryExists(production.root) {
            libraryMoveLogger.notice("library move skipped: both the old and the new library folder exist; opening the new one")
            return .newFolderExists
        }
        // REN-R11: decide and rename only under the old folder's single-instance lock, the file the
        // app's socket server holds. It also covers a recovery flow of another instance.
        let lock: Int32
        switch acquireInstanceLock(in: legacy.root) {
        case .acquired(let descriptor): lock = descriptor
        case .held:
            libraryMoveLogger.notice("library move postponed: another instance holds the old folder's lock")
            return .keptBecauseAnotherInstanceRuns
        case .unavailable(let reason):
            libraryMoveLogger.error("library move skipped: the old folder's lock is unusable (\(reason, privacy: .public))")
            return .failed(reason)
        }
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        // Looked at again now that nobody else can move it.
        guard isDirectory(legacy.root) else { return .notNeeded }
        if entryExists(production.root) { return .newFolderExists }
        for name in [".active-recovery-library.json", ".prepared-recovery-library.json"]
        where entryExists(legacy.root.appendingPathComponent(name)) {
            libraryMoveLogger.notice("library move skipped: a sync recovery selection sits next to the old folder; keeping it")
            return .keptBecauseOfRecoverySelection
        }
        // RENAME_EXCL: the file system refuses instead of replacing anything at the new path.
        guard rename(legacy.root.path, production.root.path) == 0 else {
            let code = errno
            // Whatever the error, the file system decides what is true now (a competing launch may
            // have moved the folder between our checks and our rename): the new folder wins, and
            // a vanished old folder is never kept as the library.
            if entryExists(production.root) {
                libraryMoveLogger.notice("library move skipped: the new library folder appeared first")
                return .newFolderExists
            }
            guard isDirectory(legacy.root) else {
                libraryMoveLogger.notice("library move skipped: the old library folder is gone")
                return .notNeeded
            }
            let reason = String(cString: strerror(code))
            libraryMoveLogger.error("library move failed (\(reason, privacy: .public)); keeping the old folder")
            return .failed(reason)
        }
        libraryMoveLogger.notice("library folder moved from the old name to the new one")
        return .moved
        #else
        return .notNeeded
        #endif
    }

    /// The rename of the one-time move: 0 on success, -1 with `errno` set otherwise. Tests replace
    /// it to simulate a competing launch.
    public typealias LibraryRename = @Sendable (_ from: String, _ to: String) -> Int32

    /// `renamex_np` with `RENAME_EXCL`: the file system refuses instead of replacing anything.
    public static let exclusiveRename: LibraryRename = { from, to in
        #if os(macOS)
        renamex_np(from, to, UInt32(RENAME_EXCL))
        #else
        -1
        #endif
    }

    private enum InstanceLock {
        case acquired(Int32)
        case held
        case unavailable(String)
    }

    /// `flock(LOCK_EX | LOCK_NB)` on `<folder>/app.sock.lock`, the file `AppSocketServer` holds for
    /// the life of the app. Same rules as the server: a regular file of ours with mode 0600, made
    /// exclusively when missing; a client's brief shared lock is waited out.
    private static func acquireInstanceLock(in folder: URL) -> InstanceLock {
        let socket = folder.appendingPathComponent("app.sock").path
        // The server puts a longer socket path elsewhere (and its lock with it): do not guess.
        guard socket.utf8.count <= 103 else { return .unavailable("the socket path is too long to find the lock") }
        let path = socket + ".lock"
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open(path, flags)
        if descriptor < 0, errno == ENOENT {
            descriptor = open(path, flags | O_CREAT | O_EXCL, 0o600)
            if descriptor >= 0 {
                fchmod(descriptor, 0o600)
            } else if errno == EEXIST {
                descriptor = open(path, flags)
            }
        }
        guard descriptor >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600
        else {
            close(descriptor)
            return .unavailable("the lock file is not a regular file of this user with mode 0600")
        }
        for attempt in 0..<6 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return .acquired(descriptor) }
            let code = errno
            guard code == EWOULDBLOCK else {
                close(descriptor)
                return .unavailable(String(cString: strerror(code)))
            }
            if attempt < 5 { usleep(40_000) }
        }
        close(descriptor)
        return .held
    }

    /// Whether anything, even a dangling link, is at `url` (`lstat`: links are not followed).
    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `value` as a folder URL: nil when blank; `~` is `home`. Throws for a relative path.
    static func dataDirectory(
        from value: String, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) throws -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true).standardizedFileURL
        }
        guard trimmed.hasPrefix("/") else { throw DataDirectoryError.notAbsolute(value) }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }

    public var database: URL { root.appendingPathComponent(LegacyNames.databaseFile) }
    public var attachments: URL { root.appendingPathComponent("Attachments", isDirectory: true) }
    public var journal: URL { root.appendingPathComponent("Journal", isDirectory: true) }
    /// Cached attachment previews (`Thumbnails/<noteId>/…`), regenerated when missing.
    public var thumbnails: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    /// Voice recordings while they are made (`Recordings/<noteId>/`); a file left here is adopted
    /// or deleted at the next launch (FOC-R9).
    public var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }

    /// Whether two folder URLs name the same folder: the file system's identity when both exist
    /// (symlinks resolved, so case, `..` and links do not matter), otherwise the standardized
    /// paths compared case- and normalization-insensitively (APFS default).
    /// Whether one folder lies inside the other (symlinks resolved; case- and normalization-
    /// insensitive like the default macOS volume).
    static func nests(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }
        let (pa, pb) = (key(a), key(b))
        return pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/")
    }

    public static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        let a = a.standardizedFileURL.resolvingSymlinksInPath(), b = b.standardizedFileURL.resolvingSymlinksInPath()
        func identity(_ url: URL) -> (any NSObjectProtocol)? {
            try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        }
        if let ia = identity(a), let ib = identity(b) { return ia.isEqual(ib) }
        func key(_ url: URL) -> String {
            var path = url.path.precomposedStringWithCanonicalMapping.lowercased()
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return key(a) == key(b)
    }

    public func createDirectories() throws {
        for dir in [attachments, journal, backups, logs, recordings] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

extension AppPaths {
    /// Edits of note `noteId` that are not in the library: a non-empty `Journal/<id>.jsonl`, or a journal set aside for recovery
    /// (`<id>.….unreplayed…`, any size). The rule of the import merge (`CloudApplier+Metadata`, `SyncMaterializer+Imports`) and of the
    /// backup's pending-edit check (`LibraryBackup`).
    public func hasPendingJournal(noteId: String) throws -> Bool {
        let file = journal.appendingPathComponent(noteId + ".jsonl")
        if FileManager.default.fileExists(atPath: file.path), (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 { return true }
        return try FileManager.default.contentsOfDirectory(atPath: journal.path).contains { $0.hasPrefix(noteId + ".") && $0.contains(".unreplayed") }
    }
}
