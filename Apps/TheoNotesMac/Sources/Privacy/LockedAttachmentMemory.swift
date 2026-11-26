// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Decrypted attachments of locked notes, held in memory only. An unlocked session reads them
/// through `LockedNoteAccess.attachmentData`; nothing is written to disk and no thumbnail is
/// cached under `Thumbnails/`. The environment empties it on every relock, and nothing is served
/// while the vault is locked.
///
/// Memory is bounded: a file larger than `attachmentLimit` is refused from its size,
/// before anything is allocated, and the bytes held (cache plus decryptions in flight) never
/// exceed `byteLimit`: older cache entries make room, a request that still does not fit is
/// refused. Decryption runs off the main actor.
@MainActor
final class LockedAttachmentMemory: LockedAttachmentProviding {
    static let defaultAttachmentLimit = 64 * 1024 * 1024
    static let defaultByteLimit = 128 * 1024 * 1024

    typealias Decrypt = @Sendable (_ access: LockedNoteAccess, _ filename: String, _ noteId: String, _ maximumBytes: Int) throws -> Data

    private let store: NoteStore
    private let vault: NoteVault
    private let attachmentLimit: Int
    private let byteLimit: Int
    private let decrypt: Decrypt
    private var entries: [String: Data] = [:]
    /// Keys in the order they were added, oldest first.
    private var order: [String] = []
    /// Bytes reserved by decryptions that have not finished.
    private var inFlightBytes = 0
    private(set) var cachedByteCount = 0
    /// The most cache plus in-flight bytes there ever were (tests).
    private(set) var peakByteCount = 0

    init(
        store: NoteStore, vault: NoteVault, attachmentLimit: Int = LockedAttachmentMemory.defaultAttachmentLimit,
        byteLimit: Int = LockedAttachmentMemory.defaultByteLimit,
        decrypt: @escaping Decrypt = { try $0.attachmentData($1, noteId: $2, maximumBytes: $3) }
    ) {
        self.store = store
        self.vault = vault
        self.attachmentLimit = attachmentLimit
        self.byteLimit = byteLimit
        self.decrypt = decrypt
    }

    /// The access of the unlocked session, nil while the vault is locked.
    var access: LockedNoteAccess? { vault.access }

    func isLockedNote(_ noteId: String) -> Bool {
        ((try? store.note(id: noteId)) ?? nil)?.isLocked == true
    }

    func data(noteId: String, filename: String) async -> Data? {
        guard let access = vault.access else { return nil }
        let key = Self.key("data", noteId, filename)
        if let cached = entries[key] { return cached }
        let size: Int
        do {
            size = try access.attachmentSize(filename, noteId: noteId)
            guard size <= attachmentLimit else { throw NotePrivacyError.attachmentTooLarge }
        } catch {
            appLogger.error("locked attachment of note \(noteId, privacy: .public) not read: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            return nil
        }
        guard reserve(size) else {
            appLogger.error("locked attachment of note \(noteId, privacy: .public) not read: attachmentTooLarge")
            return nil
        }
        let decrypt = decrypt
        let result: Data?
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try decrypt(access, filename, noteId, size)
            }.value
        } catch {
            result = nil
            appLogger.error("locked attachment of note \(noteId, privacy: .public) not read: \(PrivacyErrorCode.code(for: error), privacy: .public)")
        }
        inFlightBytes -= size
        // A relock meanwhile revoked this access: the bytes are dropped, not served.
        guard let result, vault.access === access else { return nil }
        keep(result, as: key)
        return result
    }

    func thumbnailPNG(noteId: String, filename: String, icon: Bool) async -> Data? {
        let variant: Thumbnails.Variant = icon ? .icon : .preview
        let key = Self.key(variant.rawValue, noteId, filename)
        guard let access = vault.access else { return nil }
        if let cached = entries[key] { return cached }
        guard let source = await data(noteId: noteId, filename: filename),
              let png = await Thumbnails.memoryPNG(data: source, filename: filename, variant: variant),
              vault.access === access else { return nil }
        keep(png, as: key)
        return png
    }

    /// Forgets every decrypted byte (a relock).
    func clear() {
        entries.removeAll()
        order.removeAll()
        cachedByteCount = 0
    }

    /// Makes room for `size` more bytes (oldest cache entries go first) and counts them as held.
    private func reserve(_ size: Int) -> Bool {
        guard size <= byteLimit else { return false }
        while cachedByteCount + inFlightBytes + size > byteLimit, let oldest = order.first {
            drop(oldest)
        }
        guard cachedByteCount + inFlightBytes + size <= byteLimit else { return false }
        inFlightBytes += size
        peakByteCount = max(peakByteCount, cachedByteCount + inFlightBytes)
        return true
    }

    private func keep(_ data: Data, as key: String) {
        guard data.count <= byteLimit else { return }
        // The file's own reservation is already released: make room against what is held now.
        while cachedByteCount + inFlightBytes + data.count > byteLimit, let oldest = order.first { drop(oldest) }
        guard cachedByteCount + inFlightBytes + data.count <= byteLimit else { return }
        entries[key] = data
        order.append(key)
        cachedByteCount += data.count
        peakByteCount = max(peakByteCount, cachedByteCount + inFlightBytes)
    }

    private func drop(_ key: String) {
        order.removeAll { $0 == key }
        if let dropped = entries.removeValue(forKey: key) { cachedByteCount -= dropped.count }
    }

    private static func key(_ kind: String, _ noteId: String, _ filename: String) -> String {
        "\(kind)|\(noteId)|\(AttachmentFiles.fileSystemKey(filename))"
    }
}
