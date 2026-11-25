// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Help ▸ Restore Getting Started Notes (REL-R75): the title, the plain words of its notices, and
/// when the command is off.
enum GettingStartedMenu {
    static let title = "Restore Getting Started Notes"
    static let nothingTitle = "Nothing to restore"
    static let nothingText = "All the getting started notes are already in your library."
    static let failedTitle = "The getting started notes could not be added"
    static let failedText = "Your notes were not changed. Try again in a moment."

    /// Off without an app, and while App Lock is engaged (nothing reaches the library behind it).
    @MainActor
    static func isDisabled(app: AppModel?) -> Bool {
        guard let app else { return true }
        return app.isLocked
    }

    /// The small alert for a notice (a message and a line of explanation, one OK button).
    @MainActor
    static func showNotice(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// The item sits at the end of the Help menu, after the items the system puts there.
struct GettingStartedCommands: Commands {
    let app: AppModel?

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(GettingStartedMenu.title) { app?.restoreGettingStartedNotes() }
                .disabled(GettingStartedMenu.isDisabled(app: app))
        }
    }
}

extension AppModel {
    /// Adds the getting started notes that are missing, moves back the ones in the Trash and leaves
    /// all others as they are (`GettingStartedNotes.restoreMissing`). When something came back, the
    /// frontmost window shows the tag they share; when nothing was missing, a notice says so.
    /// `notice` is the test seam for the alerts. Returns nil when App Lock is engaged or the library
    /// could not be written.
    @discardableResult
    func restoreGettingStartedNotes(
        notice: @MainActor (String, String) -> Void = GettingStartedMenu.showNotice
    ) -> GettingStartedRestoration? {
        guard !isLocked else { return nil }
        do {
            let result = try GettingStartedNotes.restoreMissing(in: environment.store)
            if result.changedAnything {
                showMainWindow()
                frontmostMainWindow?.model.selectScope(.tag(GettingStartedNotes.tag))
            } else {
                notice(GettingStartedMenu.nothingTitle, GettingStartedMenu.nothingText)
            }
            return result
        } catch {
            appLogger.error("could not restore the getting started notes: \(error)")
            notice(GettingStartedMenu.failedTitle, GettingStartedMenu.failedText)
            return nil
        }
    }
}

extension AppEnvironment {
    /// First launch of a brand-new library (REL-R71): `GettingStartedNotes.seedNewLibrary`. A failure is
    /// logged and never stops the launch; the person simply starts with an empty library.
    @discardableResult
    func seedGettingStartedNotes(isNewLibrary: Bool) -> [String] {
        do {
            return try GettingStartedNotes.seedNewLibrary(in: store, isNewLibrary: isNewLibrary)
        } catch {
            appLogger.error("could not make the getting started notes: \(error)")
            return []
        }
    }

    /// First launch of a build with the new texts (STARTER-R18): `GettingStartedNotes.upgradeFirstShipped` replaces each untouched
    /// first-release starter once. A failure is logged and never stops the launch; the marker is then not set and the next launch tries again.
    @discardableResult
    func upgradeGettingStartedNotes() -> [String] {
        do {
            return try GettingStartedNotes.upgradeFirstShipped(in: store, paths: paths)
        } catch {
            appLogger.error("could not upgrade the getting started notes: \(error)")
            return []
        }
    }
}
