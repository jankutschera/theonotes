// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore
@testable import TheoNotesVoice

/// Spec section 9, bullet 2 (C18): Cancel throws a voice note away, Stop keeps the transcript and
/// exactly one recording. Only the microphone and the speech model are faked.
@MainActor
@Suite struct VoiceAcceptanceTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func notesInNotes(_ library: VoiceTestLibrary) throws -> Int {
        try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note WHERE location = 'notes' AND deletedAt IS NULL") ?? -1 }
    }

    @Test func cancelTrashesAndLeavesNoAttachment() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data("spoken words".utf8))
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Something I said out loud.")
        await eventually("transcript") { capture.liveText == "Something I said out loud." }
        // The recording exists while listening.
        #expect(!library.recordingFiles().isEmpty)

        await capture.cancel()

        // The new note is in the Trash, no audio is attached, and no recording is left behind.
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .trash)
        #expect(library.attachmentNames(id).isEmpty)
        #expect(library.recordingFiles().isEmpty)
        #expect(!note.text.contains(".m4a"))
        // Nothing was left in Notes either.
        #expect(try notesInNotes(library) == 0)
    }

    @Test func stopLeavesTranscriptAndOneAudio() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data("spoken words".utf8))
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Call the dentist.")
        await eventually("transcript") { capture.liveText == "Call the dentist." }

        let heard = try await capture.stop()

        #expect(heard == "Call the dentist.")
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes)
        // The transcript is the note's text, followed by one link to the one recording.
        #expect(note.text.hasPrefix("Call the dentist."))
        let names = library.attachmentNames(id)
        #expect(names.count == 1 && names[0].hasSuffix(".m4a"))
        #expect(occurrences(of: AttachmentMarkdown.link(for: names[0]), in: note.text) == 1)
        let audio = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(names[0])
        #expect(try Data(contentsOf: audio).starts(with: Data("spoken words".utf8)))
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.store.captureSource(noteId: id) == .voice)
        #expect(try notesInNotes(library) == 1)
    }
}
