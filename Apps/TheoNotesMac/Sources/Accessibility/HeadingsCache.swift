// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore

/// The shown note's headings for the Headings rotor, parsed once per session revision (M7 final review I3).
/// VoiceOver searches through every rotor entry to build its menu, so parsing the whole note per search
/// would cost (headings + 1) parses on the main thread. The list is computed on first use and recomputed
/// only when the session's text changes (`NoteSession.revision` goes up with every applied edit and every
/// adopted external change) or when another session is shown.
@MainActor
final class HeadingsCache {
    /// How many times the note was parsed (tests pin this).
    private(set) var parseCount = 0
    private weak var session: NoteSession?
    private var noteId: String?
    private var revision = -1
    private var entries: [EditorHeadingsRotor.Entry] = []

    /// Forgets the parsed headings (the shown note went away; a locked note's must not linger).
    func reset() {
        session = nil
        noteId = nil
        revision = -1
        entries = []
    }

    func entries(for session: NoteSession?) -> [EditorHeadingsRotor.Entry] {
        guard let session else { return [] }
        if self.session === session, noteId == session.noteId, revision == session.revision { return entries }
        parseCount += 1
        entries = NoteParser.metadata(for: session.text).headings.map {
            EditorHeadingsRotor.Entry(level: $0.level, text: $0.text)
        }
        self.session = session
        noteId = session.noteId
        revision = session.revision
        return entries
    }
}
