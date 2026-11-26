// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// The first-contact base of a starter note is chosen from the shipped versions: the merge rules, without a coordinator.
/// v1 is the frozen first set; "v2" here is v1 with most lines rewritten, the case that makes a three-way merge over v1 conflict.
@Suite struct CloudStarterVersionsTests {
    static let id = GettingStartedNotes.ids[1]

    static func payload(_ text: String) throws -> SyncNotePayload {
        let note = try #require(GettingStartedNotes.firstShippedNotes().first { $0.id == id })
        let made = GettingStartedNote(slug: note.slug, id: note.id, title: note.title, text: text, stamp: note.stamp)
        let data = try #require(try CloudStarterBase.payloads(of: [made])[id])
        return try SyncPayloadCodec.decode(SyncNotePayload.self, from: data)
    }

    static func texts() throws -> (v1: String, v2: String) {
        let v1 = try #require(GettingStartedNotes.firstShippedNotes().first { $0.id == id }).text
        let lines = v1.split(separator: "\n", omittingEmptySubsequences: false)
        let v2 = lines.enumerated().map { $0.offset == 0 ? String($0.element) : "On the Mac and iPhone: " + $0.element }.joined(separator: "\n")
        return (v1, v2)
    }

    /// The merge a device makes on first contact, as the applier does it.
    static func merge(shipped: [SyncNotePayload], local: SyncNotePayload?, remote: SyncNotePayload?) throws -> SyncNoteMergeResult {
        let base = CloudApplier.startingBase(shipped: shipped, local: local, remote: remote)
        return try SyncNoteMerge.reconcile(base: base, local: local, remote: remote, entityID: id, rejectedMutationID: "m1", remoteRevision: 1)
    }

    static func text(_ result: SyncNoteMergeResult) -> String? {
        if case .merged(let note) = result { return note?.text }
        return "conflict"
    }

    @Test func untouchedAgainstUntouchedOfAnotherVersionTheLaterOneWins() throws {
        let (t1, t2) = try Self.texts()
        let v1 = try Self.payload(t1), v2 = try Self.payload(t2)
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: v1, remote: v2)) == t2)  // old device meets the new text
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: v2, remote: v1)) == t2)  // new device meets the old text
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: v2, remote: v2)) == t2)
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: v1, remote: v1)) == t1)
    }

    @Test func anEditedCopyAgainstAnUntouchedShippedVersionWinsWithoutACopy() throws {
        let (t1, t2) = try Self.texts()
        let v1 = try Self.payload(t1), v2 = try Self.payload(t2)
        let editedV2 = try Self.payload(t2 + "\nMy own ending.\n"), editedV1 = try Self.payload(t1 + "\nMy own ending.\n")
        for untouched in [v1, v2] {
            #expect(Self.text(try Self.merge(shipped: [v1, v2], local: editedV2, remote: untouched)) == t2 + "\nMy own ending.\n")
            #expect(Self.text(try Self.merge(shipped: [v1, v2], local: untouched, remote: editedV2)) == t2 + "\nMy own ending.\n")
            #expect(Self.text(try Self.merge(shipped: [v1, v2], local: editedV1, remote: untouched)) == t1 + "\nMy own ending.\n")
            #expect(Self.text(try Self.merge(shipped: [v1, v2], local: untouched, remote: editedV1)) == t1 + "\nMy own ending.\n")
        }
    }

    @Test func aSingleFrozenBaseWouldHaveMadeAConflictHere() throws {
        // The reason for the list: v2 edited on one device, v2 untouched on the other. Over the v1 base the merge cannot tell.
        let (t1, t2) = try Self.texts()
        let v1 = try Self.payload(t1), v2 = try Self.payload(t2)
        let editedV2 = try Self.payload(t2 + "\nMy own ending.\n")
        let overV1 = try SyncNoteMerge.reconcile(base: v1, local: editedV2, remote: v2, entityID: Self.id, rejectedMutationID: "m1", remoteRevision: 1)
        #expect(Self.text(overV1) == "conflict")
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: editedV2, remote: v2)) == t2 + "\nMy own ending.\n")
    }

    @Test func twoDifferentEditsStillMakeOneConflictCopy() throws {
        let (t1, t2) = try Self.texts()
        let v1 = try Self.payload(t1), v2 = try Self.payload(t2)
        let a = try Self.payload(t2 + "\nA's ending.\n"), b = try Self.payload(t2 + "\nB's ending.\n")
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: a, remote: b)) == "conflict")
    }

    @Test func deletionFollowsAnUntouchedCopyAndNotAnEditedOne() throws {
        let (t1, t2) = try Self.texts()
        let v1 = try Self.payload(t1), v2 = try Self.payload(t2)
        for untouched in [v1, v2] {
            if case .merged(let note) = try Self.merge(shipped: [v1, v2], local: untouched, remote: nil) { #expect(note == nil) } else { Issue.record("conflict") }
        }
        #expect(Self.text(try Self.merge(shipped: [v1, v2], local: try Self.payload(t2 + "\nMine.\n"), remote: nil)) == "conflict")
        // an untouched remote against a local deletion: the deletion stands (the applier's `locallyDeleted` branch compares with the base)
        #expect(CloudApplier.startingBase(shipped: [v1, v2], local: nil, remote: v1).map { SyncNoteMerge.identical($0, v1) } == true)
        #expect(CloudApplier.startingBase(shipped: [v1, v2], local: nil, remote: v2).map { SyncNoteMerge.identical($0, v2) } == true)
    }

    @Test func theListHoldsEachDistinctVersionOnce() throws {
        for id in GettingStartedNotes.ids {
            let list = try #require(CloudStarterBase.shippedPayloads[id])
            #expect(list.first == CloudStarterBase.firstShippedPayloads[id])
            #expect(Set(list).count == list.count)
            // a text that differs from the frozen one is a second version; one that never changed stays a single version
            let changed = try GettingStartedNotes.notes().first { $0.id == id }?.text != GettingStartedNotes.firstShippedNotes().first { $0.id == id }?.text
            #expect(list.count == (changed ? 2 : 1))
        }
    }
}
