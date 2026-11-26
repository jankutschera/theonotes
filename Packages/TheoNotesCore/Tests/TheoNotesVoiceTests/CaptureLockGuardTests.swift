// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore
@testable import TheoNotesVoice

@MainActor
@Suite struct CaptureLockGuardTests {
    @Test func concurrentStopsShareOneResult() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        // Enough files that two cleanups running at once would overlap.
        for index in 0..<400 {
            try Data("journal \(index)".utf8).write(to: library.paths.journal.appendingPathComponent("\(note.id).part\(index)"))
        }
        let folder = library.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("Voice Note.m4a")
        try Data("audio".utf8).write(to: recording)
        let guardian = try CaptureLockGuard.register(
            noteId: note.id, store: library.store, recording: recording, discardsJournal: true) {}
        defer { guardian.end() }

        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try guardian.lockDetected()
                outcomes.set(index, "cleaned")
            } catch {
                outcomes.set(index, "failed")
            }
        }

        #expect(outcomes.all == ["cleaned", "cleaned"])
        #expect(guardian.isCleanedUp)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path).filter { $0.contains(note.id) || $0.hasPrefix(".locking-") }
        #expect(left.isEmpty)
    }

    // MARK: - A lock that fails its own checks leaves the capture alone

    private func runningCapture(_ library: VoiceTestLibrary, noteId: String) throws -> (CaptureLockGuard, URL) {
        let folder = library.paths.recordings.appendingPathComponent(noteId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("Voice Note.m4a")
        try Data("audio".utf8).write(to: recording)
        let guardian = try CaptureLockGuard.register(
            noteId: noteId, store: library.store, recording: recording, discardsJournal: true) {}
        return (guardian, recording)
    }

    @Test func aLockThatFailsItsRetentionCheckKeepsTheCaptureAndItsRecording() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        let (guardian, recording) = try runningCapture(library, noteId: note.id)
        defer { guardian.end() }
        // An open editor session keeps the note's unsaved text: the lock refuses.
        library.store.retention.retain(note.id)
        let access = try library.access(); defer { access.revoke() }

        #expect(throws: NotePrivacyError.pendingEdits) { try access.lock(noteId: note.id) }

        #expect(!guardian.isLocked)
        #expect(FileManager.default.fileExists(atPath: recording.path))
        #expect(try library.store.note(id: note.id)?.isLocked == false)
    }

    @Test func aLockThatFailsItsStagedAttachmentCheckKeepsTheCaptureAndItsRecording() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        let (guardian, recording) = try runningCapture(library, noteId: note.id)
        defer { guardian.end() }
        // An attachment batch of the note is still staged.
        let batch = library.paths.attachments.appendingPathComponent(".staging/\(UUID().uuidString)/\(note.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let access = try library.access(); defer { access.revoke() }

        #expect(throws: NotePrivacyError.pendingAttachments) { try access.lock(noteId: note.id) }

        #expect(!guardian.isLocked)
        #expect(FileManager.default.fileExists(atPath: recording.path))
    }

    @Test func aLockThatPassesItsChecksStillStopsTheCapture() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        let (guardian, recording) = try runningCapture(library, noteId: note.id)
        defer { guardian.end() }
        let access = try library.access(); defer { access.revoke() }

        try access.lock(noteId: note.id)

        #expect(guardian.isLocked && guardian.isCleanedUp)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
    }
}

private final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var values = ["", ""]
    func set(_ index: Int, _ value: String) { lock.withLock { values[index] = value } }
    var all: [String] { lock.withLock { values } }
}
