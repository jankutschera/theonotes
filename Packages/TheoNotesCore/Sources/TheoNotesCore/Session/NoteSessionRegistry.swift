// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Weak ownership only: normal cache eviction and session lifetimes stay with each host.
@MainActor enum NoteSessionRegistry {
    private final class Entry {
        weak var session: NoteSession?
        let directory: URL
        let noteID: String
        let registrationID = UUID()
        init(session: NoteSession, directory: URL, noteID: String) {
            self.session = session; self.directory = directory; self.noteID = noteID
        }
    }
    private static var entries: [Entry] = []
    private static func identity(_ directory: URL) -> URL { directory.standardizedFileURL.resolvingSymlinksInPath() }
    static func register(_ session: NoteSession, directory: URL, noteID: String) {
        entries.removeAll { $0.session == nil }
        entries.append(Entry(session: session, directory: identity(directory), noteID: noteID))
    }
    static func liveSessionIDs(directory: URL) -> Set<String> {
        let path = identity(directory)
        entries.removeAll { $0.session == nil }
        return Set(entries.compactMap { entry in
            guard entry.directory == path, let session = entry.session, !session.isInvalidated else { return nil }
            return entry.noteID
        })
    }
    /// S3: only protected text may ever join a reset discard.
    static func dirtyProtectedLiveSessionIDs(directory: URL) -> Set<String> {
        let path = identity(directory)
        return Set(entries.compactMap { entry in
            guard entry.directory == path, let session = entry.session, !session.isInvalidated, session.wasOriginallyLocked,
                  Data(session.text.utf8) != Data(session.committedText.utf8) else { return nil }
            return entry.noteID
        })
    }
    static func capture(directory: URL, noteIDs: Set<String>) -> NoteSessionFence {
        let path = identity(directory)
        entries.removeAll { $0.session == nil }
        let stamps = Set(entries.compactMap { entry -> NoteSessionFence.Stamp? in
            guard entry.directory == path, noteIDs.contains(entry.noteID),
                  let session = entry.session, !session.isInvalidated else { return nil }
            return .init(registrationID: entry.registrationID, noteID: entry.noteID,
                         revision: session.revision, committedStoreRevision: session.committedStoreRevision)
        })
        return NoteSessionFence(directory: path, noteIDs: noteIDs, stamps: stamps)
    }
    static func invalidate(directory: URL, noteIDs: Set<String>, matching fence: NoteSessionFence) throws {
        guard capture(directory: directory, noteIDs: noteIDs) == fence else { throw NoteSessionFenceError.stale }
        try invalidate(directory: directory, noteIDs: noteIDs)
    }
    static func invalidate(directory: URL, noteIDs: Set<String>) throws {
        let path = identity(directory)
        var failure: (any Error)?
        for entry in entries where entry.directory == path && noteIDs.contains(entry.noteID) {
            do { try entry.session?.invalidate() } catch { if failure == nil { failure = error } }
        }
        entries.removeAll { $0.session == nil }
        if let failure { throw failure }
    }
}
