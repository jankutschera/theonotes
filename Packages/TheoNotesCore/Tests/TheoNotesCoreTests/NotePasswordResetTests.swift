// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct NotePasswordResetTests {
    @Test(arguments: [false, true]) func lockedNotesIncludingTrashRefuseReset(trashed: Bool) throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "protected")
        let privacy = NotePrivacy(store: library.store), access = try privacy.setPassword("old password")
        defer { access.revoke() }
        try access.lock(noteId: note.id)
        if trashed { try library.store.trash([note.id]) }
        let envelope = try privacy.envelope(), before = try library.store.note(id: note.id)
        #expect(throws: NotePasswordResetError.lockedNotesRemain) { try privacy.deletePassword() }
        #expect(try privacy.envelope() == envelope)
        #expect(try library.store.note(id: note.id) == before)
        #expect(try privacy.passwordResetStatus().lockedNotes == 1)
    }

    @Test func plainTrashMustBeEmptiedByTheUserAndPlainNotesStayUntouched() throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let privacy = NotePrivacy(store: library.store), access = try privacy.setPassword("old password")
        access.revoke()
        let kept = try library.store.create(text: "exact e\u{301}\r\nkept"), trashed = try library.store.create(text: "trash")
        try library.store.trash([trashed.id])
        #expect(throws: NotePasswordResetError.trashNotEmpty) { try privacy.deletePassword() }
        #expect(try library.store.note(id: trashed.id) != nil)
        #expect(try library.store.emptyTrash() == 1)
        try privacy.deletePassword()
        #expect(try !privacy.hasPassword)
        #expect(try library.store.note(id: kept.id) == kept)
        let fresh = try privacy.setPassword("replacement password"); defer { fresh.revoke() }
        try fresh.lock(noteId: kept.id)
        #expect(try fresh.note(id: kept.id)?.text == kept.text)
        #expect(throws: CryptoError.wrongPassword) { try privacy.unlock(password: "old password") }
    }

    @Test func resetCapturesATombstoneAfterTheImmutableEnvelopeMutationIsAcknowledged() throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let privacy = NotePrivacy(store: library.store), access = try privacy.setPassword("old password")
        access.revoke()
        let initial = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(initial.entityType == .keyBundle && !initial.tombstone)
        try privacy.deletePassword()
        #expect(try library.queue.pendingMutations() == [initial])
        try library.queue.accept(SyncEntity(mutation: initial, revision: 1, sequence: 1, receivedAt: 1))
        let reset = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(reset.entityType == .keyBundle && reset.tombstone && reset.parentRevision == 1)
        #expect(reset.ciphertext == nil && reset.payloadRef == nil)
    }
}
