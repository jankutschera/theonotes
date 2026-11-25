// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
@testable import TheoNotesCore

/// Test double for Notes' scripting interface: a mutable listing plus bodies by id. Records
/// every `bodies(ids:)` batch; single ids or whole batches can be made to fail.
final class FakeAppleNotesClient: AppleNotesClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _listing: AppleNotesListing
    private var _bodies: [String: AppleNotesBody] = [:]
    private var _batches: [[String]] = []
    private var _failingBatches = false
    private var _timingOut: Set<String> = []
    private var _noteErrors: [String: String] = [:]

    static let account = AppleNotesAccount(id: "acc-1", name: "iCloud", defaultFolderID: "f-notes")
    static let folders = [
        AppleNotesFolder(id: "f-notes", name: "Notes", accountID: "acc-1"),
        AppleNotesFolder(id: "f-work", name: "Work", accountID: "acc-1"),
        AppleNotesFolder(id: "f-projects", name: "Big Projects", accountID: "acc-1", parentID: "f-work"),
        AppleNotesFolder(id: "f-deleted", name: "Recently Deleted", accountID: "acc-1"),
    ]

    init(accounts: [AppleNotesAccount] = [account], folders: [AppleNotesFolder] = folders) {
        _listing = AppleNotesListing(accounts: accounts, folders: folders, notes: [])
    }

    var listingValue: AppleNotesListing {
        get { lock.withLock { _listing } }
        set { lock.withLock { _listing = newValue } }
    }

    var batches: [[String]] { lock.withLock { _batches } }

    var failingBatches: Bool {
        get { lock.withLock { _failingBatches } }
        set { lock.withLock { _failingBatches = newValue } }
    }

    /// Any batch containing one of these ids throws `.timedOut` (a slow or huge note).
    var timingOut: Set<String> {
        get { lock.withLock { _timingOut } }
        set { lock.withLock { _timingOut = newValue } }
    }

    /// Per-note failures the script reports (`id → message`).
    var noteErrors: [String: String] {
        get { lock.withLock { _noteErrors } }
        set { lock.withLock { _noteErrors = newValue } }
    }

    /// Adds or replaces a note (metadata + body).
    func put(
        _ id: String, html: String, name: String = "Note", folder: String? = "f-notes", account: String = "acc-1",
        modified: TimeInterval = 1_700_000_000, locked: Bool = false, attachments: Int = 0
    ) {
        lock.withLock {
            let record = AppleNotesRecord(
                id: id, name: name, created: Date(timeIntervalSince1970: 1_600_000_000),
                modified: Date(timeIntervalSince1970: modified), accountID: account, folderID: folder,
                isPasswordProtected: locked)
            if let index = _listing.notes.firstIndex(where: { $0.id == id }) {
                _listing.notes[index] = record
            } else {
                _listing.notes.append(record)
            }
            _bodies[id] = AppleNotesBody(html: html, attachmentCount: attachments)
        }
    }

    func remove(_ id: String) {
        lock.withLock { _listing.notes.removeAll { $0.id == id } }
    }

    func dropBody(_ id: String) {
        lock.withLock { _ = _bodies.removeValue(forKey: id) }
    }

    func clearBatches() { lock.withLock { _batches = [] } }

    func listing() throws -> AppleNotesListing { listingValue }

    /// Called with each batch before it is answered (tests flip a cancel flag here).
    var onBatch: (@Sendable ([String]) -> Void)?

    func bodies(ids: [String], isCancelled: () -> Bool) throws -> AppleNotesBodies {
        onBatch?(ids)
        if isCancelled() {
            lock.withLock { _batches.append(ids) }
            throw AppleNotesError.cancelled
        }
        return try lock.withLock {
            _batches.append(ids)
            if _failingBatches || !_timingOut.isDisjoint(with: ids) { throw AppleNotesError.timedOut }
            let locked = Set(_listing.notes.filter(\.isPasswordProtected).map(\.id))
            precondition(locked.isDisjoint(with: ids), "asked for the body of a password-protected note")
            return AppleNotesBodies(
                bodies: _bodies.filter { ids.contains($0.key) && _noteErrors[$0.key] == nil },
                errors: _noteErrors.filter { ids.contains($0.key) })
        }
    }

    /// Renames a folder (a tag-only change for its notes).
    func renameFolder(_ id: String, to name: String) {
        lock.withLock {
            if let index = _listing.folders.firstIndex(where: { $0.id == id }) { _listing.folders[index].name = name }
        }
    }
}
