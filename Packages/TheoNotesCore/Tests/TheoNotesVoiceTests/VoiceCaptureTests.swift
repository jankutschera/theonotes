// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import AVFoundation
import Testing
@testable import TheoNotesCore
@testable import TheoNotesVoice

@MainActor
@Suite struct VoiceCaptureTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// FOC-R9's name, formatted here independently of the implementation.
    private static var expectedName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Voice Note \(formatter.string(from: now)).m4a"
    }

    private static var expectedLink: String { AttachmentMarkdown.link(for: expectedName) }
    private static var recordingName: String { VoiceCapture.recordingName(at: Date(timeIntervalSince1970: 1_800_000_000)) }

    @Test func provisionalRevisionsSurviveWithoutStopAndFinalDoesNotDuplicate() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.partial("First words")
        await eventually("first provisional journaled") { (try? journaledText(library, id)) == "First words" }
        engine.partial("First words revised")
        await eventually("latest provisional journaled") { (try? journaledText(library, id)) == "First words revised" }
        // Replaying the journal here models a process dying before Stop can run.
        #expect(try journaledText(library, id) == "First words revised")
        engine.final("First words final")
        await eventually("final replaces provisional") { (try? journaledText(library, id)) == "First words final" }
        _ = try await capture.stop()
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.hasPrefix("First words final\n"))
        #expect(!note.text.contains("revised"))
    }

    /// 1.1 A2 (b), FOC-R396: the draft follows another editor's change, so the final replaces it
    /// and no stale copy of the provisional words stays in the note.
    @Test func provisionalFollowsAnotherEditorsChangesAndLeavesNoStaleDraft() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.partial("Draft words")
        await eventually("draft journaled") { (try? journaledText(library, id)) == "Draft words" }
        let session = try #require(library.sessions[id])
        _ = session.apply(txId: "other-editor", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "Manual: "), .retain(session.text.utf16.count)]), origin: nil)
        engine.partial("Draft words revised")
        await eventually("draft moved") { (try? journaledText(library, id)) == "Manual: Draft words revised" }
        engine.final("Final words")
        await eventually("final journaled") { (try? journaledText(library, id)) == "Manual: Final words" }
        _ = try await capture.stop()
        let text = try #require(try library.store.note(id: id)).text
        #expect(text.hasPrefix("Manual: Final words\n"), "\(text)")
        #expect(!text.contains("Draft"))
    }

    /// FOC-R396: words someone typed into the draft are theirs now; the final goes after them.
    @Test func anEditInsideTheDraftKeepsItAsTheEditorsText() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.partial("Draft words")
        await eventually("draft journaled") { (try? journaledText(library, id)) == "Draft words" }
        let session = try #require(library.sessions[id])
        _ = session.apply(txId: "inside", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!"), .retain(6)]), origin: nil)
        engine.final("Final words")
        await eventually("final journaled") { (try? journaledText(library, id))?.contains("Final words") == true }
        _ = try await capture.stop()
        #expect(try #require(try library.store.note(id: id)).text.hasPrefix("Draft! words Final words\n"))
    }

    /// 1.1 A2 (a), FOC-R395: words still being recognised are journaled (they survive a crash) but
    /// no store write takes them, so sync, Spotlight and widgets never see them before Stop.
    @Test func provisionalWordsStayOutOfTheStoreUntilStop() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        let session = try #require(library.sessions[id])
        engine.final("Buy oat milk.")
        engine.partial("and bread")
        await eventually("final + partial") { capture.liveText == "Buy oat milk. and bread" }
        // A host flush (the app resigning active, a sync pass) commits the final words only.
        try session.flush()
        #expect(try library.store.note(id: id)?.text == "Buy oat milk.")
        #expect(try journaledText(library, id) == "Buy oat milk. and bread")
        engine.partial("and bread rolls")
        await eventually("revised partial") { capture.liveText == "Buy oat milk. and bread rolls" }
        try session.flush()
        #expect(try library.store.note(id: id)?.text == "Buy oat milk.")
        #expect(try journaledText(library, id) == "Buy oat milk. and bread rolls")
        _ = try await capture.stop()
        #expect(try library.store.note(id: id)?.text.hasPrefix("Buy oat milk. and bread rolls\n") == true)
    }

    /// FOC-R395 (fix round): pinning or archiving the note while words are still being recognised
    /// moves its revision only; re-basing on that commits the final words but not the others.
    @Test(arguments: ["pin", "archive"]) func aRevisionOnlyChangeMidCaptureLeavesUnfinishedWordsOut(change: String) async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        let session = try #require(library.sessions[id])
        engine.final("Buy milk.")
        engine.partial("and bread")
        await eventually("journaled") { (try? journaledText(library, id)) == "Buy milk. and bread" }
        if change == "pin" { try library.store.setPinned([id], pinned: true) } else { try library.store.archive([id]) }
        _ = try session.handleExternalChange()
        #expect(try library.store.note(id: id)?.text == "Buy milk.")
        #expect(try journaledText(library, id) == "Buy milk. and bread")
        try session.flush()
        #expect(try library.store.note(id: id)?.text == "Buy milk.")
        _ = try await capture.stop()
        #expect(try library.store.note(id: id)?.text.hasPrefix("Buy milk. and bread\n") == true)
    }

    /// FOC-R395 (fix round): an external edit before the draft (two lines above, with an emoji
    /// of two UTF-16 units before the draft) is merged; the store gets it without the unfinished
    /// words, which move with it. An edit on the draft's own line is a conflict: the remote text
    /// becomes a copy and the store still gets no unfinished words.
    @Test(arguments: [true, false]) func anExternalEditMidCaptureKeepsUnfinishedWordsOut(otherLine: Bool) async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        let session = try #require(library.sessions[id])
        engine.final("😀 Start.")
        engine.partial("unfinished")
        await eventually("journaled") { (try? journaledText(library, id)) == "😀 Start. unfinished" }
        _ = session.apply(txId: "title", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "Title\nKept\n"), .retain(session.text.utf16.count)]), origin: nil)
        try session.flush()
        let stored = try #require(try library.store.note(id: id))
        #expect(stored.text == "Title\nKept\n😀 Start.")
        let remote = otherLine ? "Title X\nKept\n😀 Start." : "Title\nKept\n😀 Start!"
        _ = try library.store.updateText(id: id, text: remote, expectedRevision: stored.revision)
        _ = try session.handleExternalChange()
        let expected = otherLine ? "Title X\nKept\n😀 Start." : "Title\nKept\n😀 Start."
        #expect(try library.store.note(id: id)?.text == expected)
        #expect(session.text == expected + " unfinished")
        #expect(try journaledText(library, id) == expected + " unfinished")
        engine.final("unfinished words")
        await eventually("final") { session.text == expected + " unfinished words" }
        _ = try await capture.stop()
        #expect(try library.store.note(id: id)?.text.hasPrefix(expected + " unfinished words\n") == true)
    }

    /// FOC-R395: the process dies after a flush that left the unfinished words out; a new session
    /// replays the journal and they are back.
    @Test func aRelaunchRecoversTheUnfinishedWordsFromTheJournal() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        let session = try #require(library.sessions[id])
        engine.final("Buy milk.")
        engine.partial("and bread")
        await eventually("journaled") { (try? journaledText(library, id)) == "Buy milk. and bread" }
        try session.flush()
        #expect(try library.store.note(id: id)?.text == "Buy milk.")
        try session.invalidate()
        let reopened = try NoteSession(noteId: id, store: library.store, journalDirectory: library.paths.journal)
        #expect(reopened.text == "Buy milk. and bread")
        try reopened.flush()
        #expect(try library.store.note(id: id)?.text == "Buy milk. and bread")
        try reopened.invalidate()
    }

    /// 1.1 A2, FOC-R397: an empty final retracts the provisional words it replaces.
    @Test func anEmptyFinalRemovesTheWordsItRetracted() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Keep this.")
        engine.partial("uh noise")
        await eventually("partial journaled") { (try? journaledText(library, id)) == "Keep this. uh noise" }
        engine.final("")
        await eventually("retracted") { (try? journaledText(library, id)) == "Keep this." }
        _ = try await capture.stop()
        let text = try #require(try library.store.note(id: id)).text
        #expect(text.hasPrefix("Keep this.\n") && !text.contains("noise"), "\(text)")
    }

    /// 1.1 A2 (c), FOC-R398: no recognised words and no recording that can be played: nothing is
    /// kept. A new note goes to the Trash, an insert target is untouched, the file is removed.
    @Test(arguments: [false, true]) func aCaptureWithNoWordsAndNoUsableAudioKeepsNothing(insert: Bool) async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data(), writesCloseMarker: false)
        let existing = try library.store.create(text: "Shopping")
        let capture = library.capture(insert ? .insert(noteId: existing.id, utf16Offset: 8) : .newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.partial("hm")
        engine.final("")
        let heard = try await capture.stop()
        #expect(heard.isEmpty)
        #expect(capture.phase == .cancelled)
        #expect(library.recordingFiles().isEmpty)
        if insert {
            #expect(try library.store.note(id: id)?.text == "Shopping")
        } else {
            #expect(try library.store.note(id: id)?.location == .trash)
        }
    }

    @Test func cancelStillDiscardsAnUneditedProvisionalCapture() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.partial("Temporary words")
        await eventually("draft journaled") { (try? journaledText(library, id)) == "Temporary words" }
        await capture.cancel()
        #expect(try library.store.note(id: id)?.location == .trash)
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func provisionalJournalFailureStopsAndKeepsRecording() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        try #require(library.sessions[id]).invalidate()
        engine.partial("Cannot be journaled")
        await eventually("capture reports failure") { capture.phase == .failed }
        #expect(library.recordingFiles().count == 1)
    }

    @Test(arguments: [false, true]) func interruptionKeepsProvisionalTextAndAudio(streamFails: Bool) async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data("spoken audio".utf8))
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.partial("Words before interruption")
        await eventually("provisional words") { capture.liveText == "Words before interruption" }
        if streamFails { engine.fail(FakeEngineFailure()) } else { engine.send(.interrupted) }
        await eventually("capture stopped") { capture.phase == .failed || capture.phase == .stoppedByInput(noteId: id) }
        let note = try #require(try library.store.note(id: id))
        #expect(note.text.contains("Words before interruption"))
        #expect(note.text.contains(Self.expectedLink))
        let audio = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(Self.expectedName)
        #expect(try Data(contentsOf: audio) == engine.audio + FakeVoiceEngine.closeMarker)
    }

    /// 1.1 A2 (d), FOC-R399: the words are in the note, so the unplayable file goes in a later
    /// launch a day after Stop, without a notice.
    @Test func emptyRecordingKeepsTheTextAndGoesAtTheNextLaunch() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data(), writesCloseMarker: false)
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Keep the text")
        await eventually("final text") { capture.liveText == "Keep the text" }
        await #expect(throws: VoiceCaptureError.recordingUnreadable) { _ = try await capture.stop() }
        #expect(try library.store.note(id: id)?.text == "Keep the text")
        #expect(library.recordingFiles().count == 1)
        var removed: [Int] = []
        func launch(_ id: String, after seconds: TimeInterval) throws {
            _ = try VoiceRecordingRecovery.adoptLeftovers(
                store: library.store, attachments: library.attachments, directory: library.paths.recordings,
                now: Self.now.addingTimeInterval(seconds), launch: id, onUnreadableRemoved: { removed.append($0) })
        }
        try launch(VoiceRecordingRecovery.currentLaunch, after: 3 * 86_400)
        #expect(library.recordingFiles().count == 1, "never in the launch that marked it")
        try launch("later", after: 86_399)
        #expect(library.recordingFiles().count == 1, "not before a day has passed")
        try launch("later", after: 86_400)
        #expect(library.recordingFiles().isEmpty)
        #expect(removed.isEmpty)
        #expect(library.attachmentNames(id).isEmpty)
        #expect(try library.store.note(id: id)?.text == "Keep the text")
    }

    @Test func interruptedAudioIsKeptOnlyWhenItCanBePlayed() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let fixture = library.paths.root.appendingPathComponent("valid.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        do {
            let file = try AVAudioFile(forWriting: fixture, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            try file.write(from: buffer)
            file.close()
        }
        let audio = try Data(contentsOf: fixture)
        for (bytes, valid) in [(audio, true), (Data("invalid audio".utf8), false)] {
            let engine = FakeVoiceEngine(audio: bytes, writesCloseMarker: false, validatesRealAudio: true)
            let capture = library.capture(.newNote, engine: engine, now: Self.now)
            try await capture.start()
            let id = try #require(capture.noteId)
            engine.send(.interrupted)
            await eventually("interruption finished") { capture.phase == .cancelled || capture.phase == .stoppedByInput(noteId: id) }
            if valid {
                let url = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(Self.expectedName)
                let file = try AVAudioFile(forReading: url)
                #expect(file.length > 0)
            } else {
                // No words and nothing that plays: nothing is kept (FOC-R398).
                #expect(capture.phase == .cancelled && library.attachmentNames(id).isEmpty)
                #expect(library.recordingFiles().isEmpty)
                #expect(try library.store.note(id: id)?.location == .trash)
            }
        }
    }

    /// What the journal of `noteId` reproduces: its base text plus every entry (what recovery replays).
    private func journaledText(_ library: VoiceTestLibrary, _ noteId: String) throws -> String? {
        let journal = try EditJournal(directory: library.paths.journal, noteId: noteId)
        guard let base = try journal.base() else { return nil }
        return try journal.entries().reduce(base.baseText) { try $1.changeSet.apply(to: $0) }
    }

    @Test func startCreatesTheNoteWithSourceVoice() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        #expect(capture.phase == .idle)

        try await capture.start()

        let id = try #require(capture.noteId)
        #expect(capture.phase == .listening)
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "")
        #expect(note.createdAt == Self.now)
        #expect(try library.store.captureSource(noteId: id) == .voice)
        // The recording goes to Recordings/<noteId>/ under FOC-R9's name.
        guard case .start(let url) = try #require(engine.calls.first) else { Issue.record("no start"); return }
        #expect(url.lastPathComponent == Self.expectedName)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path
            == library.paths.recordings.appendingPathComponent(id).standardizedFileURL.path)
        await capture.cancel()
    }

    @Test func finalResultsAreJournaledBeforeStop() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)

        engine.partial("Buy")
        await eventually("partial") { capture.liveText == "Buy" }
        #expect(try journaledText(library, id) == "Buy")

        engine.final("Buy oat milk.")
        engine.partial("and")
        await eventually("final + partial") { capture.liveText == "Buy oat milk. and" }
        // Both final and provisional results are recoverable before Stop.
        #expect(try journaledText(library, id) == "Buy oat milk. and")
        #expect(library.sessions[id]?.text == "Buy oat milk. and")
        // Nothing waited for Stop: it is journaled, not yet committed.
        #expect(try library.store.note(id: id)?.text == "")

        engine.final("Call the bank.")
        await eventually("second final") { (try? journaledText(library, id)) == "Buy oat milk. Call the bank." }
        await capture.cancel()
    }

    @Test func stopAttachesExactlyOneAudioFileAndLinksIt() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data("spoken audio".utf8))
        engine.setRemainingOnFinish([.transcript(TranscriptUpdate(text: "last words", isFinal: true))])
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("First thought.")
        await eventually("final") { capture.liveText == "First thought." }

        let heard = try await capture.stop()

        #expect(heard == "First thought. last words")
        #expect(capture.phase == .finished(noteId: id))
        #expect(engine.calls.contains(.finish))
        // Exactly one audio file, with the recorded bytes, linked once from the committed text.
        #expect(library.attachmentNames(id) == [Self.expectedName])
        let file = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(Self.expectedName)
        #expect(try Data(contentsOf: file) == Data("spoken audio".utf8) + FakeVoiceEngine.closeMarker)
        let text = try #require(try library.store.note(id: id)).text
        #expect(text == "First thought. last words\n" + Self.expectedLink)
        #expect(occurrences(of: Self.expectedLink, in: text) == 1)
        // The recording left Recordings/.
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func cancelTrashesTheNewNoteAndLeavesNoAttachment() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Never mind.")
        await eventually("final") { capture.liveText == "Never mind." }

        await capture.cancel()

        #expect(capture.phase == .cancelled)
        #expect(engine.calls.contains(.cancel))
        #expect(!engine.calls.contains(.finish))
        #expect(try library.store.note(id: id)?.location == .trash)
        #expect(library.attachmentNames(id).isEmpty)
        #expect(library.recordingFiles().isEmpty)
        // Stop after Cancel does nothing.
        await #expect(throws: VoiceCaptureError.self) { _ = try await capture.stop() }
        #expect(library.attachmentNames(id).isEmpty)
    }

    @Test func insertModeChangesNothingUntilStop() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let original = "# Groceries\n- eggs\n"
        let note = try library.store.create(text: original)
        let before = try #require(try library.store.note(id: note.id))
        let engine = FakeVoiceEngine()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 12), engine: engine)
        try await capture.start()
        #expect(capture.noteId == note.id)

        engine.final("bread")
        engine.partial("and")
        await eventually("final + partial") { capture.liveText == "bread and" }
        #expect(library.sessions[note.id]?.text ?? original == original)
        #expect(try journaledText(library, note.id) ?? original == original)
        #expect(try library.store.note(id: note.id) == before)

        await capture.cancel()

        // Cancel leaves the note byte-identical, and no file.
        #expect(capture.phase == .cancelled)
        #expect(try library.store.note(id: note.id) == before)
        #expect(library.sessions[note.id]?.text ?? original == original)
        #expect(library.attachmentNames(note.id).isEmpty)
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.store.allNotes(location: .notes).count == 1)
    }

    @Test func insertModeStopInsertsAtTheCaretAndAttachesToThatNote() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let original = "# Groceries\n- eggs\n"
        let note = try library.store.create(text: original)
        let engine = FakeVoiceEngine()
        // The caret sits after "# Groceries\n" (UTF-16 offset 12).
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 12), engine: engine, now: Self.now)
        try await capture.start()
        engine.final("Ask about bread.")
        await eventually("final") { capture.liveText == "Ask about bread." }

        let heard = try await capture.stop()

        #expect(heard == "Ask about bread.")
        #expect(capture.phase == .finished(noteId: note.id))
        let text = try #require(try library.store.note(id: note.id)).text
        // The link gets its own line; text after the caret starts on the next one.
        #expect(text == "# Groceries\nAsk about bread.\n" + Self.expectedLink + "\n- eggs\n")
        #expect(library.attachmentNames(note.id) == [Self.expectedName])
        #expect(library.recordingFiles().isEmpty)
        // No new note was made.
        #expect(try library.store.allNotes(location: .notes).map(\.id) == [note.id])
    }

    @Test func interruptionEndsLikeStopAndKeepsTextAndAudio() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        engine.setRemainingOnFinish([.transcript(TranscriptUpdate(text: "cut short", isFinal: true))])
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("A call came in,")

        engine.send(.interrupted)

        await eventually("stopped by input") { capture.phase == .stoppedByInput(noteId: id) }
        #expect(engine.calls.contains(.finish))
        #expect(!engine.calls.contains(.cancel))
        let text = try #require(try library.store.note(id: id)).text
        #expect(text == "A call came in, cut short\n" + Self.expectedLink)
        #expect(library.attachmentNames(id) == [Self.expectedName])
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.store.note(id: id)?.location == .notes)
    }

    @Test func routeChangeEndsLikeStopAndKeepsTextAndAudio() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Headphones out.")
        await eventually("final") { capture.liveText == "Headphones out." }

        engine.send(.inputChanged)
        // A second change while it is already ending changes nothing.
        engine.send(.inputChanged)

        await eventually("stopped by input") { capture.phase == .stoppedByInput(noteId: id) }
        #expect(engine.calls.filter { $0 == .finish }.count == 1)
        let text = try #require(try library.store.note(id: id)).text
        #expect(text == "Headphones out.\n" + Self.expectedLink)
        #expect(library.attachmentNames(id) == [Self.expectedName])
        #expect(library.recordingFiles().isEmpty)
        // Stop after the input change returns what was heard.
        #expect(try await capture.stop() == "Headphones out.")
    }

    @Test func interruptionInInsertModeInsertsWhatWasHeard() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Call notes\n")
        let engine = FakeVoiceEngine()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 100), engine: engine, now: Self.now)
        try await capture.start()
        engine.final("They agreed.")
        await eventually("final") { capture.liveText == "They agreed." }

        engine.send(.interrupted)

        await eventually("stopped by input") { capture.phase == .stoppedByInput(noteId: note.id) }
        // A caret past the end inserts at the end.
        let text = try #require(try library.store.note(id: note.id)).text
        #expect(text == "# Call notes\nThey agreed.\n" + Self.expectedLink)
        #expect(library.attachmentNames(note.id) == [Self.expectedName])
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func engineFailureMidwayKeepsTextAndTrashesNothing() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine, now: Self.now)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Half a thought")
        await eventually("final") { capture.liveText == "Half a thought" }

        engine.fail(FakeEngineFailure())

        await eventually("failed") { capture.phase == .failed }
        // The engine was torn down (tap removed, file closed) before the recording was attached.
        #expect(engine.calls.contains(.cancel))
        #expect(engine.isClosed)
        let note = try #require(try library.store.note(id: id))
        #expect(note.location == .notes)
        #expect(note.text == "Half a thought\n" + Self.expectedLink)
        #expect(library.attachmentNames(id) == [Self.expectedName])
        let attached = library.paths.attachments.appendingPathComponent(id).appendingPathComponent(Self.expectedName)
        #expect(try Data(contentsOf: attached) == engine.audio + FakeVoiceEngine.closeMarker)
        #expect(library.recordingFiles().isEmpty)
        // Stop now reports the failure; Cancel no longer trashes anything.
        await #expect(throws: FakeEngineFailure.self) { _ = try await capture.stop() }
        await capture.cancel()
        #expect(try library.store.note(id: id)?.location == .notes)
        #expect(capture.phase == .failed)
    }

    @Test func engineThatCannotStartLeavesNoNote() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        engine.setStartError(FakeEngineFailure())
        let capture = library.capture(.newNote, engine: engine)

        await #expect(throws: FakeEngineFailure.self) { try await capture.start() }

        #expect(capture.phase == .failed)
        #expect(try library.store.allNotes(location: .notes).isEmpty)
        #expect(library.recordingFiles().isEmpty)
    }

    // MARK: - Fix round 1

    @Test func secondStartWhileTheFirstIsStartingIsRefused() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let opener = engine.holdNextStart()
        let capture = library.capture(.newNote, engine: engine)
        let first = Task { try await capture.start() }
        await eventually("first start reached the engine") { engine.calls.count == 1 }

        await #expect(throws: VoiceCaptureError.self) { try await capture.start() }

        opener.finish()
        try await first.value
        #expect(capture.phase == .listening)
        #expect(engine.calls.count == 1)
        #expect(try library.store.allNotes(location: .notes).count == 1)
        await capture.cancel()
    }

    @Test func localLockMidCaptureStopsItAndLeavesNoPlaintext() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["after": "after" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Shopping list")
        await eventually("final") { capture.liveText == "Shopping list" }
        // NotePrivacy.lock's precondition: the app flushes and detaches the session first.
        try #require(library.sessions[id]).flush()
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: id)
        engine.final(canaries["after"]!)

        await eventually("stopped by the lock") { capture.phase == .failed }
        #expect(engine.calls.contains(.cancel))
        #expect(capture.liveText.isEmpty)
        await #expect(throws: VoiceCaptureError.self) { _ = try await capture.stop() }
        await capture.cancel()
        // Nothing reached the note after the lock, nothing is left in Recordings/.
        #expect(try access.note(id: id)?.text == "Shopping list")
        #expect(try library.store.note(id: id)?.isLocked == true)
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    @Test func remoteLockMidCaptureDiscardsTheJournaledFinals() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["spoken": "spoken" + token, "after": "after" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final(canaries["spoken"]!)
        await eventually("journaled") { (try? journaledText(library, id)) == canaries["spoken"] }
        #expect(try library.canaryHits(canaries) == ["spoken", "audio"])

        // The note arrives locked through sync (the materializer's lock branch).
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), id])
            try FocusPurge.purgeRemoteLock(noteId: id, in: db)
        }
        engine.final(canaries["after"]!)

        await eventually("stopped by the lock") { capture.phase == .failed }
        #expect(engine.calls.contains(.cancel))
        #expect(try library.store.note(id: id)?.text == "")
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    @Test func aLockSeenOnlyInTheStoreStopsTheNextWrite() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["spoken": "spoken" + token, "after": "after" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final(canaries["spoken"]!)
        await eventually("journaled") { (try? journaledText(library, id)) == canaries["spoken"] }

        // Locked without this process's lock path (no hook ran).
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), id])
        }
        engine.final(canaries["after"]!)

        await eventually("stopped by the lock") { capture.phase == .failed }
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    // MARK: - Fix round 2

    @Test func lockFailsAndRollsBackWhenTheRecordingCannotBeDeleted() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine(audio: Data("kept audio".utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Shopping list")
        await eventually("final") { capture.liveText == "Shopping list" }
        try #require(library.sessions[id]).flush()
        let access = try library.access(); defer { access.revoke() }
        let folder = library.paths.recordings.appendingPathComponent(id)

        // The recording cannot be removed: the lock fails and nothing is half done.
        library.withPermissions(0o555, on: folder) {
            #expect(throws: (any Error).self) { try access.lock(noteId: id) }
        }

        await eventually("capture stopped") { capture.phase == .failed }
        let note = try #require(try library.store.note(id: id))
        #expect(!note.isLocked)
        #expect(note.text == "Shopping list")
        #expect(library.recordingFiles().count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(Self.recordingName)) == Data("kept audio".utf8) + FakeVoiceEngine.closeMarker)

        // Once the folder is writable again, locking succeeds and removes the recording.
        try access.lock(noteId: id)
        #expect(try library.store.note(id: id)?.isLocked == true)
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func lockFailsAndRollsBackWhenTheJournalCannotBeListed() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["spoken": "spoken" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final(canaries["spoken"]!)
        await eventually("journaled") { (try? journaledText(library, id)) == canaries["spoken"] }

        // Sync brings the lock while the journal folder cannot be listed: the lock is not applied.
        library.withPermissions(0o000, on: library.paths.journal) {
            #expect(throws: (any Error).self) { try library.remoteLock(id) }
        }

        await eventually("capture stopped") { capture.phase == .failed }
        #expect(try library.store.note(id: id)?.isLocked == false)
        #expect(try journaledText(library, id) == canaries["spoken"])
        #expect(library.recordingFiles().count == 1)

        // The next sync pass applies it and removes the plaintext.
        try library.remoteLock(id)
        #expect(try library.store.note(id: id)?.isLocked == true)
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    @Test func aLockWhileTheSessionOpensStopsTheStart() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n")
        let access = try library.access(); defer { access.revoke() }
        let engine = FakeVoiceEngine()
        // The note is locked after the start's first check, before the guard exists.
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 0), engine: engine) { id in
            let session = try library.session(id)
            try access.lock(noteId: id)
            return session
        }

        await #expect(throws: VoiceCaptureError.self) { try await capture.start() }

        #expect(capture.phase == .failed)
        #expect(engine.calls.isEmpty)
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.store.note(id: note.id)?.isLocked == true)
    }

    @Test func cancelWhileFinishingTearsTheEngineDownOnce() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Never mind.")
        await eventually("final") { capture.liveText == "Never mind." }
        let opener = engine.holdNextFinish()
        let stopping = Task { try await capture.stop() }
        await eventually("finishing") { engine.calls.contains(.finish) }

        let cancelling = Task { await capture.cancel() }
        opener.finish()
        await cancelling.value
        _ = try? await stopping.value

        #expect(engine.teardownCalls == 1)
        #expect(capture.phase == .cancelled)
        #expect(try library.store.note(id: id)?.location == .trash)
        #expect(library.attachmentNames(id).isEmpty)
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func lockWhileFinishingTearsTheEngineDownOnce() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["spoken": "spoken" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final(canaries["spoken"]!)
        await eventually("final") { capture.liveText == canaries["spoken"] }
        let opener = engine.holdNextFinish()
        let stopping = Task { try await capture.stop() }
        await eventually("finishing") { engine.calls.contains(.finish) }

        try library.remoteLock(id)
        opener.finish()
        _ = try? await stopping.value
        await eventually("stopped by the lock") { capture.phase == .failed }

        #expect(engine.teardownCalls == 1)
        #expect(library.attachmentNames(id).isEmpty)
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    @Test func aLockWhileTheEngineStartsTearsItDownOnce() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let opener = engine.holdNextStart()
        let capture = library.capture(.newNote, engine: engine)
        let starting = Task { try await capture.start() }
        await eventually("engine starting") { engine.calls.count == 1 }
        let id = try #require(capture.noteId)

        try library.remoteLock(id)
        opener.finish()

        await #expect(throws: VoiceCaptureError.self) { try await starting.value }
        #expect(capture.phase == .failed)
        #expect(engine.teardownCalls == 1)
        #expect(library.recordingFiles().isEmpty)
    }

    // MARK: - Controller round 3

    @Test func aLockCommittedBetweenRegistrationAndRecheckNeverRecords() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n")
        let engine = FakeVoiceEngine()
        let opener = engine.holdNextStart()
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 0), engine: engine)
        // The editor already has the note open (its session needs no write at Start).
        _ = try library.session(note.id)
        let database = library.db
        let insideLock = TestFlag()
        let commit = DispatchSemaphore(value: 0)
        // The lock takes its look at the registered captures, then stays uncommitted.
        let locking = Task.detached {
            try VoiceTestLibrary.remoteLock(note.id, in: database) {
                insideLock.set()
                _ = commit.wait(timeout: .now() + 0.5)
            }
        }
        while !insideLock.isSet { try await Task.sleep(for: .milliseconds(5)) }

        // The capture registers and re-checks while the lock is open; the lock commits only once the
        // capture went on to start its engine (or after half a second, if the start waits for it).
        let starting = Task { try await capture.start() }
        for _ in 0..<100 where engine.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        commit.signal()
        try await locking.value
        opener.finish()

        await #expect(throws: VoiceCaptureError.self) { try await starting.value }
        #expect(capture.phase == .failed)
        #expect(engine.calls.isEmpty)
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func externalLockCleanupFailureSurfacesAndTheNextSyncPassFinishesIt() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["spoken": "spoken" + token, "after": "after" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final(canaries["spoken"]!)
        await eventually("journaled") { (try? journaledText(library, id)) == canaries["spoken"] }
        // Locked by another process (no hook here); the journal folder cannot be listed.
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), id])
        }
        await library.withPermissionsAsync(0o000, on: library.paths.journal) {
            engine.final(canaries["after"]!)
            await eventually("stopped by the lock") { capture.phase == .failed }
        }

        // The cleanup failure is the capture's error, not a plain "locked".
        await #expect(throws: CocoaError.self) { _ = try await capture.stop() }

        // The next sync pass of the locked note finishes the cleanup.
        try library.remoteLock(id)
        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    @Test func externalLockCleanupFailureIsFinishedAtTheNextLaunch() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let canaries = ["spoken": "spoken" + token, "after": "after" + token, "audio": "audio" + token]
        let engine = FakeVoiceEngine(audio: Data(canaries["audio"]!.utf8))
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final(canaries["spoken"]!)
        await eventually("journaled") { (try? journaledText(library, id)) == canaries["spoken"] }
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), id])
        }
        await library.withPermissionsAsync(0o000, on: library.paths.journal) {
            engine.final(canaries["after"]!)
            await eventually("stopped by the lock") { capture.phase == .failed }
        }
        await #expect(throws: CocoaError.self) { _ = try await capture.stop() }

        // The next launch's recovery finishes the cleanup.
        _ = try VoiceRecordingRecovery.adoptLeftovers(
            store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true })

        #expect(library.recordingFiles().isEmpty)
        #expect(try library.canaryHits(canaries).isEmpty)
    }

    // MARK: - Round 4

    @Test func anUnusableJournalNeverWritesToTheDatabaseDuringCapture() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let writes = TestCounter()
        let counted = library.store.guarded { _, stage in
            if case .begin = stage { writes.increment() }
        }
        var opened: NoteSession?
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine) { id in
            let session = try NoteSession(noteId: id, store: counted, journalDirectory: library.paths.journal,
                                          commitDelay: .seconds(3600))
            opened = session
            return session
        }
        try await capture.start()
        engine.final("First.")
        await eventually("first") { capture.liveText == "First." }
        // The journal breaks: a failed append whose rollback fails too poisons it.
        struct DiskFault: Error {}
        let session = try #require(opened)
        session.journal.faultInjector = { operation, _ in
            switch operation {
            case .write, .truncate: throw DiskFault()
            default: break
            }
        }
        engine.final("Second.")
        await eventually("second") { capture.liveText == "First. Second." }
        let before = writes.value

        // A result arriving now must not make the session flush to the database while the capture
        // holds its lock guard (a lock holding the writer would wait for that guard).
        engine.final("Third.")
        await eventually("third") { capture.liveText == "First. Second. Third." }

        #expect(writes.value == before)
        session.journal.faultInjector = nil
        await capture.cancel()
    }

    @Test func aMarkerThatCannotBeWrittenIsPartOfTheError() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        let capture = library.capture(.newNote, engine: engine)
        try await capture.start()
        let id = try #require(capture.noteId)
        engine.final("Before.")
        await eventually("journaled") { (try? journaledText(library, id)) == "Before." }
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), id])
        }
        // Neither the journal can be listed nor the marker written.
        await library.withPermissionsAsync(0o555, on: library.paths.recordings) {
            await library.withPermissionsAsync(0o000, on: library.paths.journal) {
                engine.final("After.")
                await eventually("stopped by the lock") { capture.phase == .failed }
            }
        }

        var thrown: (any Error)?
        do { _ = try await capture.stop() } catch { thrown = error }
        let description = String(reflecting: try #require(thrown))
        #expect(description.contains("markerNotWritten"))
    }

    @Test func aReleasedCaptureNoLongerGuardsItsNote() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        var capture: VoiceCapture? = library.capture(.newNote, engine: engine)
        try await capture!.start()
        let id = try #require(capture?.noteId)
        weak let released = capture
        capture = nil
        await eventually("capture released") { released == nil }

        // Later an editor has unsaved text in the note's journal, and the note is locked by sync.
        let journal = try EditJournal(directory: library.paths.journal, noteId: id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: ""))
        try journal.append(JournalEntry(txId: "editor", baseRevision: 0,
                                        changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "typed")])))
        try? library.remoteLock(id)

        // No capture guard is left to delete the editor's journal.
        #expect(try journal.entries().count == 1)
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }

    // MARK: - Follow-ups (FOC-R301, FOC-R302)

    @Test func aCaptureThatNeverJournaledDoesNotBlockAndLeavesNothingWhenTheNoteIsLockedElsewhere() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n")
        // An empty recording: Stop has no link to attach (a locked note would refuse it) and goes
        // straight to the insertion, which finds the note locked.
        let engine = FakeVoiceEngine(audio: Data(), writesCloseMarker: false)
        let capture = library.capture(.insert(noteId: note.id, utf16Offset: 7), engine: engine)
        try await capture.start()
        // The editor's own unsaved text sits in the note's journal (same session); the capture
        // wrote none of it.
        let session = try library.session(note.id)
        let typed = session.applyJournaled(
            txId: "editor", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.retain(7), .replace(deleteLength: 0, insert: "typed")]), origin: nil)
        guard case .acked = typed.0 else { Issue.record("the editor's text was not journaled"); return }
        let journalSize = try FileManager.default.attributesOfItem(
            atPath: library.paths.journal.appendingPathComponent(note.id + ".jsonl").path)[.size] as? Int ?? 0
        #expect(journalSize > 0)
        engine.final("heard")
        await eventually("heard") { capture.liveText == "heard" }
        // Another process locks the note: no lock path ran the guard.
        try await library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET text = '', isLocked = 1, encryptedPayload = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [Data([1, 2, 3]), note.id])
        }
        // The recording is there, and the editor's non-empty journal is not the capture's.
        #expect(library.recordingFiles().count == 1)

        // `lockDetected` must remove the recording and must not fail over the editor's journal.
        await #expect(throws: VoiceCaptureError.noteLocked(noteId: note.id)) { try await capture.stop() }

        #expect(library.recordingFiles().isEmpty)
                #expect(capture.phase == .failed)
    }

    @Test func droppingARunningCaptureCancelsTheEngineOnceAndRemovesTheRecording() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        var capture: VoiceCapture? = library.capture(.newNote, engine: engine)
        try await capture!.start()
        #expect(library.recordingFiles().count == 1)
        weak let released = capture
        capture = nil
        await eventually("capture released") { released == nil }

        await eventually("engine cancelled and recording removed") {
            engine.calls.contains(.cancel) && library.recordingFiles().isEmpty
        }
        #expect(engine.teardownCalls == 1)
        #expect(!engine.calls.contains(.finish))
    }

    /// A dropped capture whose engine is slow to cancel still guards its note: a lock that comes
    /// meanwhile removes the recording itself (FOC-R307), and the cancel finds nothing left to do.
    @Test func aLockWhileADroppedCaptureIsStillCancellingRemovesTheRecording() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        var capture: VoiceCapture? = library.capture(.newNote, engine: engine)
        try await capture!.start()
        let id = try #require(capture?.noteId)
        let release = engine.holdNextCancel()
        weak let released = capture
        capture = nil
        await eventually("capture released") { released == nil }
        await eventually("cancel requested") { engine.calls.contains(.cancel) }
        #expect(library.recordingFiles().count == 1)
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: id)

        #expect(try library.store.note(id: id)?.isLocked == true)
        #expect(library.recordingFiles().isEmpty)
        release.finish()
        await eventually("engine torn down") { engine.isClosed }
        #expect(engine.teardownCalls == 1)
    }

    /// A removal that fails after the cancel keeps the obligation: the recording and a marker
    /// stay, the guard stays registered, and the next lock removes the recording.
    @Test func aDroppedCapturesFailedRemovalKeepsTheObligationUntilALockRetriesIt() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        var capture: VoiceCapture? = library.capture(.newNote, engine: engine)
        try await capture!.start()
        let id = try #require(capture?.noteId)
        let folder = library.paths.recordings.appendingPathComponent(id)
        let release = engine.holdNextCancel()
        weak let released = capture
        let marker = library.paths.recordings.appendingPathComponent(".pending-cleanup-" + id)
        await library.withPermissionsAsync(0o555, on: folder) {
            capture = nil
            await eventually("capture released") { released == nil }
            release.finish()
            await eventually("the obligation is recorded") { FileManager.default.fileExists(atPath: marker.path) }
        }

        #expect(library.recordingFiles().filter { !$0.hasPrefix(".pending-cleanup-") }.count == 1)
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: id)
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func droppingAFinishedCaptureTouchesNeitherTheEngineNorTheLibrary() async throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let engine = FakeVoiceEngine()
        var capture: VoiceCapture? = library.capture(.newNote, engine: engine)
        try await capture!.start()
        engine.final("Done.")
        await eventually("heard") { capture?.liveText == "Done." }
        _ = try await capture!.stop()
        let id = try #require(capture?.noteId)
        weak let released = capture
        capture = nil
        await eventually("capture released") { released == nil }

        #expect(engine.teardownCalls == 1)
        #expect(library.attachmentNames(id).count == 1)
    }
}
