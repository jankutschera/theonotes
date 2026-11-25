// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// A locked note's attachment decrypted into memory only (the Mac note window serves it from
/// there): same authentication as `decryptAttachment`, no file written anywhere.
@Suite struct LockedAttachmentDataTests {
    private struct Library {
        let paths: AppPaths
        let db: AppDatabase
        let store: NoteStore
        init() throws {
            paths = AppPaths(root: URL(fileURLWithPath: "/tmp/locked-data-\(UUID().uuidString.prefix(8))", isDirectory: true))
            try paths.createDirectories()
            db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        func cleanup() {
            try? db.pool.close()
            try? FileManager.default.removeItem(at: paths.root)
        }
        func files() -> Set<String> {
            let enumerator = FileManager.default.enumerator(at: paths.root, includingPropertiesForKeys: [.isRegularFileKey])
            var found: Set<String> = []
            while let url = enumerator?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { found.insert(url.path) }
            }
            return found
        }
    }

    private func lockedNote(_ library: Library, bytes: Data) throws -> (Note, LockedNoteAccess) {
        let note = try library.store.create(text: "# Title\n![](photo.png)")
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "photo.png", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("correct horse")
        try access.lock(noteId: note.id)
        return (note, access)
    }

    @Test func returnsTheRealBytesUnderTheRealNameAndWritesNoFile() throws {
        let library = try Library()
        defer { library.cleanup() }
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let (note, access) = try lockedNote(library, bytes: bytes)
        let before = library.files()
        #expect(try access.attachmentData("photo.png", noteId: note.id, maximumBytes: 1 << 20) == bytes)
        #expect(try access.attachmentData("PHOTO.png", noteId: note.id, maximumBytes: 1 << 20) == bytes)
        #expect(library.files() == before)
    }

    @Test func anUnknownNameOrARevokedAccessThrows() throws {
        let library = try Library()
        defer { library.cleanup() }
        let (note, access) = try lockedNote(library, bytes: Data("x".utf8))
        #expect(throws: NotePrivacyError.attachmentMissing("other.png")) {
            try access.attachmentData("other.png", noteId: note.id, maximumBytes: 1 << 20)
        }
        access.revoke()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.attachmentData("photo.png", noteId: note.id, maximumBytes: 1 << 20) }
    }

    @Test func aTamperedFileIsRefused() throws {
        let library = try Library()
        defer { library.cleanup() }
        let (note, access) = try lockedNote(library, bytes: Data(repeating: 7, count: 1000))
        let blob = try #require(library.files().first { $0.hasSuffix(".bch") })
        var raw = try Data(contentsOf: URL(fileURLWithPath: blob))
        raw[raw.count - 1] ^= 1
        try raw.write(to: URL(fileURLWithPath: blob))
        #expect(throws: CryptoError.tampered) { try access.attachmentData("photo.png", noteId: note.id, maximumBytes: 1 << 20) }
    }

    @Test func theSizeIsKnownBeforeAnythingIsDecrypted() throws {
        let library = try Library()
        defer { library.cleanup() }
        let access = try NotePrivacy(store: library.store).setPassword("correct horse")
        for count in [0, 1, 65_536, 65_537, 200_000] {
            let bytes = Data((0..<count).map { UInt8($0 % 251) })
            let note = try library.store.create(text: "![](f\(count).bin)")
            _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "f\(count).bin", to: note.id)
            try access.lock(noteId: note.id)
            #expect(try access.attachmentSize("f\(count).bin", noteId: note.id) == count)
            #expect(try access.attachmentData("f\(count).bin", noteId: note.id, maximumBytes: count) == bytes)
        }
    }

    @Test func aLimitBelowTheSizeRefusesBeforeAllocatingAndTheExactSizePasses() throws {
        let library = try Library()
        defer { library.cleanup() }
        let bytes = Data(repeating: 9, count: 100_000)
        let (note, access) = try lockedNote(library, bytes: bytes)
        #expect(throws: NotePrivacyError.attachmentTooLarge) {
            try access.attachmentData("photo.png", noteId: note.id, maximumBytes: 99_999)
        }
        #expect(try access.attachmentData("photo.png", noteId: note.id, maximumBytes: 100_000) == bytes)
        let blob = try #require(library.files().first { $0.hasSuffix(".bch") })
        #expect(throws: NotePrivacyError.attachmentTooLarge) {
            try ChunkedCipher.decrypt(input: URL(fileURLWithPath: blob), keyEncryptionKey: .init(size: .bits256),
                                      context: "x", maximumBytes: 10)
        }
    }
}
