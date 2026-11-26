// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import Foundation
import Testing
@testable import TheoNotesCore
@testable import TheoNotesVoice

@MainActor
@Suite struct VoiceRecordingRecoveryTests {
    private static let name = "Voice Note 2027-01-15 08.00.m4a"

    private func leave(_ bytes: String, for noteId: String, in library: VoiceTestLibrary, name: String = name) throws {
        let dir = library.paths.recordings.appendingPathComponent(noteId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func bytes(of name: String, in noteId: String, _ library: VoiceTestLibrary) throws -> String {
        let url = library.paths.attachments.appendingPathComponent(noteId).appendingPathComponent(name)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func leftoverIsAttachedOnceAndOnlyToALiveUnlockedNote() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        // The library folder has Recordings/ next to Attachments/.
        #expect(library.paths.recordings.standardizedFileURL.path
            == library.paths.root.appendingPathComponent("Recordings").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: library.paths.recordings.path))

        let live = try library.store.create(text: "# Live")
        let archived = try library.store.create(text: "# Archived\n")
        try library.store.archive([archived.id])
        let trashed = try library.store.create(text: "# Trashed")
        try library.store.trash([trashed.id])
        let locked = try library.store.create(text: "# Locked")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: locked.id)
        // A crash after Stop linked the file but before the recording was removed.
        let adopted = try library.store.create(text: "# Adopted")
        let stored = try library.attachments.add(data: Data("adopted audio".utf8), filename: Self.name, to: adopted.id)
        let current = try #require(try library.store.note(id: adopted.id))
        _ = try library.store.updateText(id: adopted.id, text: current.text + "\n" + AttachmentMarkdown.link(for: stored),
                                         expectedRevision: current.revision)
        let adoptedText = try #require(try library.store.note(id: adopted.id)).text

        try leave("live audio", for: live.id, in: library)
        try leave("archived audio", for: archived.id, in: library)
        try leave("trashed audio", for: trashed.id, in: library)
        try leave("locked audio", for: locked.id, in: library)
        try leave("adopted audio", for: adopted.id, in: library)
        try leave("orphan audio", for: UUID().uuidString.lowercased(), in: library)
        try Data("stray".utf8).write(to: library.paths.recordings.appendingPathComponent("stray.m4a"))

        let attached = try VoiceRecordingRecovery.adoptLeftovers(
            store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true })

        #expect(attached == 2)
        let link = AttachmentMarkdown.link(for: Self.name)
        #expect(try library.store.note(id: live.id)?.text == "# Live\n" + link)
        #expect(library.attachmentNames(live.id) == [Self.name])
        #expect(try bytes(of: Self.name, in: live.id, library) == "live audio")
        let archivedNote = try #require(try library.store.note(id: archived.id))
        #expect(archivedNote.text == "# Archived\n" + link)
        #expect(archivedNote.location == .archive)
        #expect(try bytes(of: Self.name, in: archived.id, library) == "archived audio")
        // Trash, a locked note and an unknown id get nothing; their recordings are deleted.
        #expect(try library.store.note(id: trashed.id)?.text == "# Trashed")
        #expect(library.attachmentNames(trashed.id).isEmpty)
        #expect(try library.store.note(id: locked.id)?.isLocked == true)
        #expect(library.attachmentNames(locked.id).isEmpty)
        // Already attached: not a second time.
        #expect(try library.store.note(id: adopted.id)?.text == adoptedText)
        #expect(library.attachmentNames(adopted.id) == [Self.name])
        #expect(library.recordingFiles().isEmpty)

        // A second launch finds nothing.
        let liveText = try library.store.note(id: live.id)?.text
        #expect(try VoiceRecordingRecovery.adoptLeftovers(
            store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true }) == 0)
        #expect(try library.store.note(id: live.id)?.text == liveText)
        #expect(library.attachmentNames(live.id) == [Self.name])
    }

    @Test func aFailedLinkIsRetriedWithoutASecondCopy() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Live")
        try leave("live audio", for: note.id, in: library)
        struct LinkFault: Error {}
        let failing = library.store.guarded { _, _ in throw LinkFault() }

        // The text update fails after the file was copied in.
        let first = try VoiceRecordingRecovery.adoptLeftovers(
            store: failing, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true })

        #expect(first == 0)
        #expect(try library.store.note(id: note.id)?.text == "# Live")
        #expect(library.attachmentNames(note.id).isEmpty)
        #expect(library.recordingFiles().count == 1)

        let second = try VoiceRecordingRecovery.adoptLeftovers(
            store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true })

        #expect(second == 1)
        #expect(library.attachmentNames(note.id) == [Self.name])
        let text = try #require(try library.store.note(id: note.id)).text
        #expect(text == "# Live\n" + AttachmentMarkdown.link(for: Self.name))
        #expect(occurrences(of: AttachmentMarkdown.link(for: Self.name), in: text) == 1)
        #expect(library.recordingFiles().isEmpty)
    }

    @Test func anUndeletableLockedLeftoverIsReportedAndRetried() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Locked")
        let access = try library.access(); defer { access.revoke() }
        try access.lock(noteId: note.id)
        try leave("locked audio", for: note.id, in: library)
        let folder = library.paths.recordings.appendingPathComponent(note.id)

        library.withPermissions(0o555, on: folder) {
            #expect(throws: (any Error).self) {
                _ = try VoiceRecordingRecovery.adoptLeftovers(
                    store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true })
            }
        }
        #expect(library.recordingFiles().count == 1)

        // The next launch removes it.
        #expect(try VoiceRecordingRecovery.adoptLeftovers(
            store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true }) == 0)
        #expect(library.recordingFiles().isEmpty)
    }

    private static let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    /// 1.1 A2 (d), a leftover that cannot be played and whose words were never inserted
    /// is marked; it goes only in a later launch and a day after the mark, reported once.
    @Test func anUnplayableLeftoverGoesOnlyInALaterLaunchADayAfterItsMark() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Live")
        try leave("not audio", for: note.id, in: library)
        var removed: [Int] = []
        func launch(_ id: String, after seconds: TimeInterval) throws -> Int {
            try VoiceRecordingRecovery.adoptLeftovers(store: library.store, attachments: library.attachments,
                directory: library.paths.recordings, now: Self.t0.addingTimeInterval(seconds), launch: id,
                onUnreadableRemoved: { removed.append($0) })
        }

        #expect(try launch("A", after: 0) == 0)
        #expect(try launch("A", after: 5 * 86_400) == 0)
        #expect(library.recordingFiles().count == 1, "two runs in one launch never delete")
        #expect(try launch("B", after: 86_399) == 0)
        #expect(library.recordingFiles().count == 1, "not before a day has passed")
        #expect(removed.isEmpty)

        #expect(try launch("B", after: 86_400) == 0)
        #expect(library.recordingFiles().isEmpty)
        #expect(removed == [1])
        #expect(!FileManager.default.fileExists(atPath: library.paths.recordings.appendingPathComponent(note.id).path))

        #expect(try launch("C", after: 9 * 86_400) == 0)
        #expect(removed == [1])
        #expect(try library.store.note(id: note.id)?.text == "# Live")
        #expect(library.attachmentNames(note.id).isEmpty)
    }

    /// A marked leftover that can be played by now is adopted like any other.
    @Test func aMarkedLeftoverThatBecomesPlayableIsAdopted() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Live")
        try leave("not audio", for: note.id, in: library)
        let file = library.paths.recordings.appendingPathComponent(note.id).appendingPathComponent(Self.name)
        var removed: [Int] = []
        func launch(_ id: String, after seconds: TimeInterval) throws -> Int {
            try VoiceRecordingRecovery.adoptLeftovers(store: library.store, attachments: library.attachments,
                directory: library.paths.recordings, now: Self.t0.addingTimeInterval(seconds), launch: id,
                onUnreadableRemoved: { removed.append($0) })
        }
        #expect(try launch("A", after: 0) == 0)
        #expect(try launch("B", after: 3_600) == 0)
        #expect(library.recordingFiles().count == 1)
        // Written in place, so the mark stays on the file.
        try playableAudio(in: library).write(to: file)

        #expect(try launch("C", after: 2 * 86_400) == 1)
        #expect(library.attachmentNames(note.id) == [Self.name])
        #expect(try library.store.note(id: note.id)?.text == "# Live\n" + AttachmentMarkdown.link(for: Self.name))
        #expect(removed.isEmpty)
    }

    private func playableAudio(in library: VoiceTestLibrary) throws -> Data {
        let url = library.paths.root.appendingPathComponent("fixture.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            try file.write(from: buffer)
            file.close()
        }
        return try Data(contentsOf: url)
    }

    @Test func aFileLeftMovedAsideIsRemovedAtLaunch() throws {
        let library = try VoiceTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Live")
        let aside = ".locking-\(note.id)-\(UUID().uuidString)"
        try Data("journal text".utf8).write(to: library.paths.journal.appendingPathComponent(aside))
        try leave("half removed audio", for: note.id, in: library, name: aside)

        _ = try VoiceRecordingRecovery.adoptLeftovers(
            store: library.store, attachments: library.attachments, directory: library.paths.recordings, isPlayable: { _ in true })

        #expect(!FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(aside).path))
        #expect(library.recordingFiles().isEmpty)
        #expect(library.attachmentNames(note.id).isEmpty)
        #expect(try library.store.note(id: note.id)?.text == "# Live")
    }
}
