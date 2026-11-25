// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Whether this process may sync its library. Decided once, at launch, from how the library was
/// chosen, never from its contents (sync tables, saved connection flags, recovery markers).
public enum SyncLaunchPolicy: Sendable, Equatable {
    /// The default library (or the recovery library it selected): sync may run.
    case enabled
    /// A library named with `--data-dir` / `BAERCHEN_DATA_DIR`: no sync code path runs in this process.
    case localOnly
}

/// The library a launch opens and the sync policy that comes with it (INT-R14).
public struct LibraryLaunch: Sendable {
    public let paths: AppPaths
    public let syncPolicy: SyncLaunchPolicy
    /// What the launch did about a library still in the pre-rename folder (REN-R2).
    public let legacyMove: LegacyLibraryMove
    /// Whether the app may create the library folder: only for a fresh install, where neither
    /// the new nor the old folder existed at the first check of the launch (REN-R12). Any other
    /// launch opens a folder it has seen, and refuses to open one that has vanished since.
    public let createsLibraryFolder: Bool

    public init(
        paths: AppPaths, syncPolicy: SyncLaunchPolicy, legacyMove: LegacyLibraryMove = .notNeeded,
        createsLibraryFolder: Bool = false
    ) {
        self.paths = paths
        self.syncPolicy = syncPolicy
        self.legacyMove = legacyMove
        self.createsLibraryFolder = createsLibraryFolder
    }
}
