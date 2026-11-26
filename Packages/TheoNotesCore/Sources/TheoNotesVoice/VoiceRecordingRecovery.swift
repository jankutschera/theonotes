// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import os
import AVFoundation

private let recoveryLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "voice")

/// Leftovers that had to go but could not be removed (they stay for the next launch).
public enum VoiceRecoveryError: Error {
    case notRemoved(count: Int, underlying: any Error)
}

/// Recordings a capture left behind (the app quit or crashed while recording, or the file could
/// not be attached), adopted once at launch.
public enum VoiceRecordingRecovery {
    public static func isPlayable(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.processingFormat.sampleRate > 0
    }

    /// An extended attribute on a leftover that cannot be played: `<state> <seconds> <launch>`,
    /// state `inserted` (Stop put its words in the note) or `kept` (recovery found it), the time of
    /// the mark and the launch that wrote it. Neutral name, no product name.
    private static let stateAttribute = "voice-leftover-state"
    /// How long an unplayable leftover is kept after its mark.
    static let unplayableGrace: TimeInterval = 86_400

    /// This process's launch; a mark from it never leads to a deletion.
    public static let currentLaunch = UUID().uuidString

    private struct Mark {
        let wordsInserted: Bool
        let at: Date
        let launch: String
    }

    /// Marks a recording that cannot be played. If the mark cannot be written the file stays.
    public static func mark(_ url: URL, wordsInserted: Bool, at date: Date, launch: String = currentLaunch) {
        let bytes = Array("\(wordsInserted ? "inserted" : "kept") \(Int(date.timeIntervalSince1970)) \(launch)".utf8)
        if setxattr(url.path, stateAttribute, bytes, bytes.count, 0, 0) != 0 {
            recoveryLogger.error("a voice leftover could not be marked")
        }
    }

    private static func mark(of url: URL) -> Mark? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = getxattr(url.path, stateAttribute, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return nil }
        let parts = String(decoding: buffer[..<count], as: UTF8.self).split(separator: " ")
        guard parts.count == 3, parts[0] == "inserted" || parts[0] == "kept", let seconds = TimeInterval(parts[1]) else { return nil }
        return Mark(wordsInserted: parts[0] == "inserted", at: Date(timeIntervalSince1970: seconds), launch: String(parts[2]))
    }

    /// Goes through `directory/<noteId>/<file>`:
    /// - A note that exists, is not deleted, unlocked and in Notes or Archive gets the file as an
    ///   attachment, linked on its own line at the end of its text, unless one of its linked
    ///   attachments already holds exactly these bytes (a crash after Stop linked it).
    /// - Every other file is deleted: Trash, locked, deleted or unknown notes, and loose files.
    /// - A file that cannot be played is marked; it is deleted only by a later launch than the
    ///   mark's and once `unplayableGrace` has passed since it. One that can be played by then is
    ///   adopted as above. `onUnreadableRemoved` gets how many deleted files had no words in the
    /// note.
    /// First it finishes the cleanups a capture could not finish after its note was locked
    /// (`CaptureLockGuard.finishPendingCleanups`). A file whose attaching fails stays for the next
    /// launch. A file that must be deleted but cannot be stays too, and once everything else was
    /// done the first such failure is thrown (`VoiceRecoveryError.notRemoved`, no note text), so the
    /// caller can report it; the next launch tries again. Returns how many files were attached.
    /// Run it before any capture starts (the app calls it once at launch, after journal recovery).
    public static func adoptLeftovers(store: NoteStore, attachments: AttachmentStore, directory: URL,
                                      isPlayable: (URL) -> Bool = VoiceRecordingRecovery.isPlayable,
                                      now: Date = Date(), launch: String = currentLaunch,
                                      onUnreadableRemoved: (Int) -> Void = { _ in }) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return 0 }
        var notRemoved = 0, unreadableRemoved = 0
        var firstError: (any Error)?
        @discardableResult func remove(_ url: URL) -> Bool {
            do { try fm.removeItem(at: url) } catch {
                notRemoved += 1
                if firstError == nil { firstError = error }
                return false
            }
            return true
        }
        defer { if unreadableRemoved > 0 { onUnreadableRemoved(unreadableRemoved) } }
        do {
            try CaptureLockGuard.finishPendingCleanups(store: store, recordings: directory)
        } catch {
            notRemoved += 1
            if firstError == nil { firstError = error }
        }
        var attached = 0
        for entry in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if CaptureLockGuard.isPendingCleanupMarker(entry.lastPathComponent) { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                remove(entry)
                continue
            }
            let noteId = entry.lastPathComponent
            for file in try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let fileValues = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
                      let note = try store.note(id: noteId), note.deletedAt == nil, !note.isLocked,
                      note.location == .notes || note.location == .archive
                else {
                    remove(file)
                    continue
                }
                guard isPlayable(file) else {
                    guard let existing = mark(of: file) else {
                        mark(file, wordsInserted: false, at: now, launch: launch)
                        continue
                    }
                    if existing.launch != launch, now.timeIntervalSince(existing.at) >= unplayableGrace,
                       remove(file), !existing.wordsInserted {
                        unreadableRemoved += 1
                    }
                    continue
                }
                do {
                    if try !isAlreadyLinked(file, in: note, attachments: attachments) {
                        try attach(file, to: note, store: store, attachments: attachments)
                        attached += 1
                    }
                    try fm.removeItem(at: file)
                } catch {
                    recoveryLogger.error("note \(noteId, privacy: .public): a leftover voice recording could not be attached")
                }
            }
            if (try? fm.contentsOfDirectory(atPath: entry.path))?.isEmpty == true { try? fm.removeItem(at: entry) }
        }
        if let firstError {
            recoveryLogger.error("\(notRemoved, privacy: .public) leftover voice recordings could not be removed")
            throw VoiceRecoveryError.notRemoved(count: notRemoved, underlying: firstError)
        }
        return attached
    }

    private static func isAlreadyLinked(_ file: URL, in note: Note, attachments: AttachmentStore) throws -> Bool {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        for link in NoteParser.attachmentLinks(in: note.text) {
            guard let url = attachments.url(for: link.filename, noteId: note.id),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == data.count else { continue }
            if (try? Data(contentsOf: url, options: .mappedIfSafe)) == data { return true }
        }
        return false
    }

    /// Copies the file in and links it. The copy and the text update are two transactions, so a
    /// failed update removes the copy again; should that removal fail too, the next run reuses the
    /// unlinked copy (same bytes, the same name or one of its numbered variants) instead of
    /// copying a second time.
    private static func attach(_ file: URL, to note: Note, store: NoteStore, attachments: AttachmentStore) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let reused = unlinkedCopy(of: data, named: file.lastPathComponent, in: note, attachments: attachments)
        let name = try reused ?? attachments.add(fileAt: file, to: note.id)
        let link = AttachmentMarkdown.link(for: name)
        let separator = note.text.isEmpty || note.text.hasSuffix("\n") ? "" : "\n"
        do {
            _ = try store.updateText(id: note.id, text: note.text + separator + link, expectedRevision: note.revision)
        } catch {
            if reused == nil { try? attachments.delete(name, from: note.id) }
            throw error
        }
    }

    /// An attachment of `note` that holds exactly `data` under `name` or `name 2` … `name 20`.
    private static func unlinkedCopy(of data: Data, named name: String, in note: Note, attachments: AttachmentStore) -> String? {
        let usable = AttachmentStore.usableName(name)
        let stem = (usable as NSString).deletingPathExtension, ext = (usable as NSString).pathExtension
        let candidates = [usable] + (2...20).map { ext.isEmpty ? "\(stem) \($0)" : "\(stem) \($0).\(ext)" }
        for candidate in candidates {
            guard let url = attachments.url(for: candidate, noteId: note.id),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == data.count,
                  (try? Data(contentsOf: url, options: .mappedIfSafe)) == data else { continue }
            return candidate
        }
        return nil
    }
}
