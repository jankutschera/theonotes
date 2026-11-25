// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// REL-R79 on iPhone and iPad: when the getting started notes are made, and Settings ▸ Restore Getting
/// Started Notes. The wording matches the Mac's Help command (`GettingStartedMenu`).
enum MobileGettingStarted {
    static let title = "Restore Getting Started Notes"
    static let nothingTitle = "Nothing to restore"
    static let nothingText = "All the getting started notes are already in your library."
    static let failedTitle = "The getting started notes could not be added"
    static let failedText = "Your notes were not changed. Try again in a moment."

    /// A library is brand new only when its database file does not exist yet, so the launch itself is
    /// about to create it. An existing container, an update, a device restore or migration (all carry
    /// the file), a recovery copy and a library joined through sync (a later change to the same file)
    /// are never new. Must be read before the database is opened, which creates the file.
    static func createsNewLibrary(at paths: AppPaths) -> Bool {
        !FileManager.default.fileExists(atPath: paths.database.path)
    }

    /// Whether this launch may seed. Always true in a release build; the debug UI-test library stays
    /// empty (many UI tests assume it) unless the test passes `--seed-getting-started`, and so does a
    /// debug Shortcuts test launch, which comes without arguments.
    static func seedsInThisLaunch(arguments: [String] = ProcessInfo.processInfo.arguments, shortcutsUITesting: Bool = false) -> Bool {
        #if DEBUG
        if arguments.contains("--ui-testing") { return arguments.contains("--seed-getting-started") }
        if shortcutsUITesting { return false }
        #endif
        return true
    }
}

extension MobileLibrary {
    /// Whether Settings ▸ Restore Getting Started Notes may run: not under App Lock, and not while a library operation, a
    /// closing library, a scene operation or an attachment write holds the library (`sceneEditorAdmissionBlocked`).
    var canRestoreGettingStarted: Bool { !appLocked && !sceneEditorAdmissionBlocked }

    /// Settings ▸ Restore Getting Started Notes: `GettingStartedNotes.restoreMissing`. A failure is returned to the Settings page,
    /// which shows it; the library-view alert sits under the open sheet and would not be seen.
    func restoreGettingStarted() -> Result<GettingStartedRestoration, any Error>? {
        guard canRestoreGettingStarted else { return nil }
        return Result { try GettingStartedNotes.restoreMissing(in: store) }
    }
}
