// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

// The Getting Started notes in the coordinator tests are the REAL ones: `GettingStartedNotes.seedNewLibrary` and
// `restoreMissing`, called on a device's library. No seed code lives here.

enum StarterFixtures {
    @discardableResult
    static func seed(_ device: CoordDevice) throws -> [String] {
        try GettingStartedNotes.seedNewLibrary(in: device.noteStore, isNewLibrary: true)
    }

    @discardableResult
    static func restore(_ device: CoordDevice) throws -> GettingStartedRestoration {
        try GettingStartedNotes.restoreMissing(in: device.noteStore)
    }

    /// The Getting Started notes of a later app version: the same ids and stamps, other texts. Made through the product's own
    /// insert, in the same shape `seedNewLibrary` would make them.
    static func seedLaterVersion(_ device: CoordDevice, addition: String = "\n\nNew in the later version.\n") throws {
        let originals = try GettingStartedNotes.notes()
        try device.noteStore.write { db in
            for note in originals { _ = try NoteStore.insert(id: note.id, text: note.text + addition, now: note.stamp, in: db) }
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [SettingKey<Bool>.gettingStartedSeeded.name])
        }
    }

    /// A library made by the FIRST release: the frozen first texts (`Resources/starter-v1-*.md`), same ids and stamps, flag set.
    static func seedFirstShipped(_ device: CoordDevice) throws {
        let originals = try GettingStartedNotes.firstShippedNotes()
        try device.noteStore.write { db in
            for note in originals { _ = try NoteStore.insert(id: note.id, text: note.text, now: note.stamp, in: db) }
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [SettingKey<Bool>.gettingStartedSeeded.name])
        }
    }

    static var ids: [String] { GettingStartedNotes.ids }

    /// Notes of the starter set that exist, by id, in the places Notes and Archive.
    static func starterNotes(_ device: CoordDevice) throws -> [Note] {
        try ids.compactMap { try device.note($0) }
    }
}
