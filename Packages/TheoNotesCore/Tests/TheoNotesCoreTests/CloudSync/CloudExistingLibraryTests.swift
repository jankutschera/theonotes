// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Libraries that already had a life before sync (CK-R13): trash, archive, deletions, protected notes, attachments, tags,
/// settings, imported notes. Real coordinator, real libraries, `FakeCloudKit`.
@Suite(.serialized) struct CloudExistingLibraryFirstSyncTests {
    @Test func libraryWithTrashedAndArchivedNotesKeepsTheirStates() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let plain = try a.noteStore.create(text: "# Plain\nbody\n"), trashed = try a.noteStore.create(text: "# Trashed\nbody\n")
            let archived = try a.noteStore.create(text: "# Archived\nbody\n"), pinned = try a.noteStore.create(text: "# Pinned\nbody\n")
            try a.noteStore.trash([trashed.id]); try a.noteStore.archive([archived.id]); try a.noteStore.setPinned([pinned.id], pinned: true)
            try await a.enable(); try await b.enable()
            try await world.converge()
            for device in world.devices {
                #expect(try device.note(plain.id)?.location == .notes)
                #expect(try device.note(trashed.id)?.location == .trash && device.note(trashed.id)?.trashedAt != nil)
                #expect(try device.note(archived.id)?.location == .archive && device.note(archived.id)?.archivedAt != nil)
                #expect(try device.note(pinned.id)?.isPinnedGlobal == true)
            }
            #expect(try a.fingerprint() == b.fingerprint())
        }
    }

    @Test func libraryWithDeletedNotes() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let kept = try a.noteStore.create(text: "# Kept\n"), gone = try a.noteStore.create(text: "# Gone before sync\n")
            let later = try a.noteStore.create(text: "# Deleted after sync\n")
            try a.hardDelete(gone.id)                      // deleted before sync existed: no record of it anywhere
            try await a.enable(); try await b.enable()
            try await world.converge()
            #expect(await world.cloud.recordNames.contains("e.note.\(gone.id)") == false)
            #expect(try b.note(gone.id) == nil && b.note(kept.id) != nil && b.note(later.id) != nil)
            // deleted after sync: the encrypted tombstone reaches B, whose copy (the last one) goes to Trash
            try a.hardDelete(later.id)
            try await world.converge()
            #expect(try a.note(later.id) == nil)
            #expect(try b.note(later.id)?.location == .trash)
            #expect(await world.cloud.versionCount(of: "e.note.\(later.id)") == 2)
        }
    }

    @Test func libraryWithLockedNotesAsksForPasswordFirstAndNeverUploadsPlaintext() async throws {
        try await withCoordWorld(1) { world in
            let a = world.devices[0]
            let canaries = ["LOCKEDCANARY-7f3a91", "PLAINCANARY-c04d22"]
            let secret = try a.noteStore.create(text: "# Secret\n\(canaries[0])\n")
            _ = try a.noteStore.create(text: "# Plain\n\(canaries[1])\n")
            try NotePrivacy(store: a.noteStore).setPassword("correct horse").lock(noteId: secret.id)
            #expect(try await a.enable() == .needsNotePassword)
            #expect(try await plaintextHits(in: world.cloud, canaries: canaries).isEmpty)
            #expect(await world.cloud.recordNames.allSatisfy { !$0.hasPrefix("e.") }, "no note data left the device before the password")
            #expect(try await a.enable(notePassword: "correct horse") == .upToDate(lastSync: a.clockValue.value))
            #expect(await world.cloud.recordNames.contains("e.note.\(secret.id)"))
            let hits = try await plaintextHits(in: world.cloud, canaries: canaries)
            #expect(hits.isEmpty, "plaintext reached the cloud: \(hits)")
            // the local copy is still locked ciphertext
            #expect(try a.note(secret.id)?.isLocked == true && a.note(secret.id)?.text.contains(canaries[0]) != true)
        }
    }

    @Test func libraryWithAttachmentsIncludingMissingSourceAndStagedFiles() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let store = AttachmentStore(paths: a.paths, database: a.db)
            let good = try a.noteStore.create(text: "# Good\n![ok](ok.png)\n"), missing = try a.noteStore.create(text: "# Missing\n![gone](gone.png)\n")
            let staged = try a.noteStore.create(text: "# Staged\n![wait](wait.png)\n")
            let goodBytes = Data((0..<600_000).map { UInt8(($0 &* 7) % 251) })
            _ = try store.add(data: goodBytes, filename: "ok.png", to: good.id)
            _ = try store.add(data: Data(repeating: 9, count: 100_000), filename: "gone.png", to: missing.id)
            let goneID = try #require(try a.string("SELECT id FROM attachment WHERE filename='gone.png'"))
            try FileManager.default.removeItem(at: a.paths.attachments.appendingPathComponent(missing.id).appendingPathComponent("gone.png"))
            _ = try store.add(data: Data(repeating: 5, count: 50_000), filename: "wait.png", to: staged.id)
            try a.sql("INSERT INTO staging_batch(id, noteId, replacing, filenames, createdAt) VALUES('batch-1', '\(staged.id)', 0, '[]', datetime('now'))")
            try await a.enable(); try await b.enable()
            try await world.converge()
            // the good note and its file arrived; the file with no source did not stop anything
            #expect(try b.note(good.id) != nil)
            #expect(try Data(contentsOf: b.paths.attachments.appendingPathComponent(good.id).appendingPathComponent("ok.png")) == goodBytes)
            #expect(try b.note(missing.id) != nil, "its note is published")
            #expect(try a.dirtyGeneration(goneID, type: "attachment") != nil, "the attachment with no file stays in the journal, reported, not hidden")
            #expect(await world.cloud.recordNames.contains("e.attachment.\(goneID)") == false)
            // the staged note waits for its batch
            #expect(try b.note(staged.id) == nil)
            try a.sql("DELETE FROM staging_batch")
            try await world.converge()
            #expect(try b.note(staged.id) != nil)
            #expect(try Data(contentsOf: b.paths.attachments.appendingPathComponent(staged.id).appendingPathComponent("wait.png")) == Data(repeating: 5, count: 50_000))
        }
    }

    @Test func libraryWithTagsSettingsAndExternalRefs() async throws {
        try await withCoordWorld(2) { world in
            let a = world.devices[0], b = world.devices[1]
            let note = try a.noteStore.create(text: "# Tagged\n#project/alpha\n")
            try a.sql("UPDATE tag SET iconName='star', isPinned=1 WHERE pathKey='project/alpha'")
            try a.sql("INSERT INTO setting(key,value) VALUES('hideMarkdown','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            try a.sql("INSERT INTO external_ref(source, externalId, noteId) VALUES('bear','EXT-1','\(note.id)')")
            try await a.enable(); try await b.enable()
            try await world.converge()
            #expect(try b.string("SELECT iconName FROM tag WHERE pathKey='project/alpha'") == "star")
            #expect(try b.string("SELECT isPinned FROM tag WHERE pathKey='project/alpha'") == "1")
            #expect(try b.string("SELECT value FROM setting WHERE key='hideMarkdown'") == "true")
            #expect(try b.string("SELECT noteId FROM external_ref WHERE source='bear' AND externalId='EXT-1'") == note.id)
            // machine-local settings did not travel
            #expect(try b.string("SELECT value FROM setting WHERE key='gettingStartedSeeded'") == nil)
        }
    }

    @Test func secondMacWithItsOwnImportedBearNotesMatchesByExternalRef() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        // the same three notes imported twice, once on each Mac: equal content and stamps, different local ids
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        var mine: [String] = [], theirs: [String] = []
        for index in 0..<3 {
            for (device, isFirst) in [(a, true), (b, false)] {
                let id = UUID().uuidString.lowercased()
                try device.noteStore.write { db in
                    _ = try NoteStore.insert(id: id, text: "# Imported \(index)\nfrom the other app #imported\n", now: stamp.addingTimeInterval(Double(index)), in: db)
                }
                try device.sql("INSERT INTO external_ref(source, externalId, noteId) VALUES('bear','BEAR-\(index)','\(id)')")
                if isFirst { mine.append(id) } else { theirs.append(id) }
            }
        }
        try await a.enable(); try await b.enable()
        try await world.converge()
        // one note per external reference on both Macs, on the first Mac's ids
        for device in world.devices {
            let count = try device.count("note")
            #expect(count == 3, "\(device.name) has \(count) notes")
            for index in 0..<3 { #expect(try device.string("SELECT noteId FROM external_ref WHERE externalId='BEAR-\(index)'") == mine[index]) }
        }
        #expect(try a.fingerprint() == b.fingerprint())
        #expect(try theirs.allSatisfy { try b.note($0) == nil })
        // different content for the same reference: nothing is merged away, both versions stay
        let other = try CoordWorld.make(2); defer { other.cleanup() }
        let c = other.devices[0], d = other.devices[1]
        for (device, text) in [(c, "# Same\nversion one\n"), (d, "# Same\nversion two\n")] {
            let id = UUID().uuidString.lowercased()
            try device.noteStore.write { db in _ = try NoteStore.insert(id: id, text: text, now: stamp, in: db) }
            try device.sql("INSERT INTO external_ref(source, externalId, noteId) VALUES('bear','BEAR-X','\(id)')")
        }
        try await c.enable(); try await d.enable()
        try await other.converge()
        for device in other.devices {
            let texts = Set(try device.notes().map(\.text))
            #expect(texts == ["# Same\nversion one\n", "# Same\nversion two\n"], "no version is lost on \(device.name)")
        }
    }

    @Test func firstSyncOfExistingLibraryUploadsAllThenSecondDeviceMatches() async throws {
        let world = try CoordWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        let store = AttachmentStore(paths: a.paths, database: a.db)
        var attachments: [(note: String, bytes: Data)] = []
        for index in 0..<300 {
            let note = try a.noteStore.create(text: "# Note \(index)\nbody of note \(index) #bulk\n" + (index < 20 ? "![f](f\(index).bin)\n" : ""))
            if index < 20 {
                let bytes = Data((0..<3000).map { UInt8(($0 &+ index) % 251) })
                _ = try store.add(data: bytes, filename: "f\(index).bin", to: note.id)
                attachments.append((note.id, bytes))
            }
        }
        try await a.enable()
        try await world.converge([a])
        #expect(await world.cloud.recordNames.filter { $0.hasPrefix("e.note.") }.count == 300)
        #expect(await world.cloud.recordNames.filter { $0.hasPrefix("e.attachment.") }.count == 20)
        try await b.enable()
        try await world.converge()
        #expect(try a.fingerprint() == b.fingerprint() && b.count("note") == 300 && b.count("attachment") == 20)
        for (index, item) in attachments.enumerated() {
            #expect(try Data(contentsOf: b.paths.attachments.appendingPathComponent(item.note).appendingPathComponent("f\(index).bin")) == item.bytes)
        }
        // E0 review point 1: the second device published none of the 300 notes and none of the 20 attachment entities
        #expect(b.gateway.savedNames.filter { $0.hasPrefix("e.note.") }.isEmpty, "B re-uploaded notes")
        #expect(b.gateway.savedNames.filter { $0.hasPrefix("e.attachment.") }.isEmpty, "B re-uploaded attachments")
        #expect(try b.dirty().isEmpty)
    }
}
