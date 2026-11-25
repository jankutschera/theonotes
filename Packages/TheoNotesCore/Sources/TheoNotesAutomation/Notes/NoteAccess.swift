// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore

/// What a note allows. A locked note has no readable text anywhere in the library, so reading its
/// content fails; it is never reported as empty (a client could "repair" an empty note by
/// overwriting it).
enum NoteAccess {
    static func requireReadable(_ note: Note) throws(AutomationError) {
        if note.isLocked { throw AutomationError(code: .noteLocked, message: "Note is locked: \(note.id)") }
    }

    static func requireWritable(_ note: Note) throws(AutomationError) {
        try requireReadable(note)
        if note.isReadOnly { throw AutomationError(code: .readOnly, message: "Note is read-only: \(note.id)") }
    }
}
