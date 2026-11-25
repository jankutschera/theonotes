// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct SyncNoteMergeTests {
    private func payload(_ text: String) -> SyncNotePayload {
        let meta = NoteParser.metadata(for: text)
        return SyncNotePayload(note: Note(id: "note", text: text, title: meta.title, titleKey: "", createdAt: Date(timeIntervalSince1970: 10), modifiedAt: Date(timeIntervalSince1970: 20)), directTags: meta.tags, pinnedTags: [], attachmentIds: [])
    }
    private func merge(_ base: SyncNotePayload?, _ local: SyncNotePayload?, _ remote: SyncNotePayload?) throws -> SyncNoteMergeResult {
        try SyncNoteMerge.reconcile(base: base, local: local, remote: remote, entityID: "note", rejectedMutationID: "mutation", remoteRevision: 2)
    }
    @Test func disjointTextAndMetadataChangesMergeWithoutChangingOriginalID() throws {
        let base = payload("# Original\none\nseparator\ntwo\n#work")
        var local = payload("# Local title\none\nseparator\ntwo\n#work")
        var remote = payload("# Original\none\nseparator\nremote two\n#work")
        local.isPinnedGlobal = true; remote.location = .archive; remote.archivedAt = 50_000
        local.pinnedTags = ["work"]; remote.isReadOnly = true
        guard case .merged(let value) = try merge(base, local, remote), let value else { Issue.record("expected clean merge"); return }
        #expect(value.id == "note")
        #expect(value.text == "# Local title\none\nseparator\nremote two\n#work")
        #expect(value.title == "Local title" && value.isPinnedGlobal && value.isReadOnly)
        #expect(value.location == .archive && value.archivedAt == 50_000 && value.pinnedTags == ["work"])
    }
    @Test func overlappingEditsKeepLocalAndCreateOneDeterministicRemoteCopy() throws {
        let base = payload("# Title\noriginal"), local = payload("# Title\nlocal"), remote = payload("# Title\nremote")
        let result = try merge(base, local, remote)
        #expect(try merge(base, local, remote) == result)
        guard case .conflict(let kept, let copy) = result else { Issue.record("expected conflict"); return }
        #expect(kept?.id == "note" && kept?.text == local.text)
        #expect(copy?.id != "note" && copy?.text == remote.text)
        #expect(copy?.conflict?.originalNoteId == "note" && kept?.conflict != nil)
        #expect(UUID(uuidString: try #require(copy?.id)) != nil)
        #expect(copy?.id != SyncNoteMerge.conflictID(entityID: "note", mutationID: "mutation", remoteRevision: 3))
    }
    @Test func deleteEditRacesPreserveEditedContentAndMarkConflict() throws {
        let base = payload("base"), edited = payload("edited")
        #expect(try merge(base, base, nil) == .merged(nil))
        guard case .conflict(let local, let remoteCopy) = try merge(base, edited, nil) else { Issue.record("expected delete/edit conflict"); return }
        #expect(local?.text == "edited" && local?.conflict != nil && remoteCopy == nil)
        guard case .conflict(let deleted, let keptRemote) = try merge(base, nil, edited) else { Issue.record("expected edit/delete conflict"); return }
        #expect(deleted == nil && keptRemote?.text == "edited" && keptRemote?.conflict != nil)
    }
    @Test func lockedBodiesWaitForPasswordInsteadOfCopyingCiphertextToWrongID() throws {
        var base = payload(""); base.isLocked = true; base.encryptedPayload = Data([1])
        var local = base, remote = base
        local.encryptedPayload = Data([2]); remote.encryptedPayload = Data([3])
        #expect(try merge(base, local, remote) == .needsUnlock)
        local = base; local.isPinnedGlobal = true
        guard case .merged(let value) = try merge(base, local, remote) else { Issue.record("expected metadata merge"); return }
        #expect(value?.encryptedPayload == Data([3]) && value?.isPinnedGlobal == true)
        local = base; remote = base; local.location = .archive; remote.location = .trash
        #expect(try merge(base, local, remote) == .needsUnlock)
    }
    @Test func exactUnicodeAndNoCommonAncestorAreConservative() throws {
        let base = payload("base"), local = payload("é"), remote = payload("e\u{301}")
        guard case .conflict = try merge(base, local, remote) else { Issue.record("different Markdown bytes must conflict"); return }
        guard case .conflict = try merge(nil, payload("one"), payload("two")) else { Issue.record("no base must not overwrite"); return }
        #expect(try merge(nil, local, local) == .merged(local))
        var invalid = base; invalid.createdAt = .min
        #expect(throws: SyncProtocolError.invalidPayload) { try merge(base, invalid, remote) }
    }
}
