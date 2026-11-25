// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// A note-list row's VoiceOver actions (the context menu's, by name).
enum NoteAXAction: String, CaseIterable, Identifiable {
    case pin = "Pin"
    case unpin = "Unpin"
    case archive = "Archive"
    case trash = "Move to Trash"
    case restore = "Restore"
    case deletePermanently = "Delete Permanently"
    case openInNewWindow = "Open in New Window"
    case lockNote = "Lock Note"
    case removeLock = "Remove Lock from Note"

    var id: String { rawValue }
}

/// What VoiceOver says for a note-list row and what it can do there (M7 Task 12).
enum NoteListAccessibility {
    /// "<title or Untitled>[, pinned][, locked][, Captured], modified <relative date>".
    static func label(for item: NoteListItem, date: Date, now: Date) -> String {
        var parts = [item.title.isEmpty ? "Untitled" : item.title]
        if item.isPinned { parts.append("pinned") }
        if item.isLocked { parts.append("locked") }
        if NoteRow.showsCapturedMark(for: item) { parts.append(NoteRow.capturedLabel) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        parts.append("modified \(formatter.localizedString(for: date, relativeTo: now))")
        return parts.joined(separator: ", ")
    }

    /// The preview; empty for a locked note (spec §4.9: its title only).
    static func value(for item: NoteListItem) -> String {
        item.isLocked ? "" : item.subtitle
    }

    /// Pin or Unpin, Archive, Move to Trash, Open in New Window, Lock Note or Remove Lock from Note;
    /// in the Trash, Restore and Delete Permanently (a note there is neither locked nor unlocked).
    static func actions(for item: NoteListItem, inTrash: Bool) -> [NoteAXAction] {
        if inTrash { return [.restore, .deletePermanently] }
        return [item.isPinned ? .unpin : .pin, .archive, .trash, .openInNewWindow, item.isLocked ? .removeLock : .lockNote]
    }

    /// The ids of the pinned rows, in list order (the "Pinned Notes" rotor).
    static func pinnedRotor(_ items: [NoteListItem]) -> [String] {
        items.filter(\.isPinned).map(\.id)
    }
}
