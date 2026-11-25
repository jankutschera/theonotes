// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Only ciphertext reaches CloudKit (Global Constraints): canaries planted in note text, titles, tags, attachment names, OCR text,
/// protected bodies, deletions and recovery words must appear nowhere in any field or asset of any record, in plain, UTF-8, UTF-16
/// or base64 form; and a deletion is not recognisable as one.
@Suite struct CloudKitCiphertextOnlyTests {
    static let canaries = ["CANARYTEXT7f3a", "CANARYTITLE91bc", "canarytag5d2e", "canaryfile3c4d.txt", "CANARYOCR8e1f", "CANARYLOCKED2a9b",
                           "CANARYFILEBYTES6b7c", "CANARYWORDS correct horse battery staple", "CANARYSETTING4e5f"]

    /// Every byte pattern a canary could show up as.
    static func patterns(_ canary: String) -> [Data] {
        let utf8 = Data(canary.utf8)
        var out = [utf8, Data(canary.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), Data(canary.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })]
        // Base64 of the canary at each of the three alignments: keep the characters that do not depend on the neighbours.
        for shift in 0..<3 {
            let encoded = Array((Data(repeating: 0x41, count: shift) + utf8).base64EncodedString().utf8)
            let lead = (shift * 8 + 5) / 6 + (shift == 0 ? 0 : 1)
            if encoded.count > lead + 4 { out.append(Data(encoded[lead..<(encoded.count - 3)])) }
        }
        out.append(Data(utf8.base64EncodedString().utf8.prefix(max(4, utf8.count * 4 / 3 - 4))))
        return out
    }

    static func contains(_ haystack: Data, _ needle: Data) -> Bool { !needle.isEmpty && haystack.range(of: needle) != nil }

    /// Every field and asset of every record in the account, as raw bytes.
    func everything(_ world: PublisherWorld) async throws -> [(name: String, bytes: Data)] {
        var out: [(String, Data)] = []
        for name in await world.account.recordNames {
            let record = try #require(await world.account.record(named: name))
            out.append(("name:" + name, Data(name.utf8)))
            for (field, value) in record.fields.sorted(by: { $0.key < $1.key }) {
                switch value {
                case .int(let i): out.append(("\(name).\(field)", Data(String(i).utf8)))
                case .string(let s): out.append(("\(name).\(field)", Data(s.utf8)))
                case .strings(let list): out.append(("\(name).\(field)", Data(list.joined(separator: "\u{0}").utf8)))
                case .bytes(let data): out.append(("\(name).\(field)", data))
                case .asset(let url): out.append(("\(name).\(field)", try Data(contentsOf: url)))
                }
            }
            if let tag = record.systemFields { out.append(("\(name).systemFields", tag)) }
        }
        return out
    }

    @Test func noCanaryInAnyFieldOrAsset() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let c = Self.canaries
        let plain = try a.noteStore.create(text: "# \(c[1])\n\(c[0]) #\(c[2])\n![f](\(c[3]))\n")
        _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: Data(c[6].utf8), filename: c[3], to: plain.id)
        try a.edit(plain.id, "# \(c[1])\n\(c[0]) #\(c[2])\n![f](\(c[3]))\n")
        try a.edit(plain.id, "# \(c[1])\n\(c[0]) #\(c[2])\n![f](\(c[3])) and \(c[7])\n")
        try a.sql("UPDATE attachment SET ocrText=?, ocrState='done' WHERE noteId=?", [c[4], plain.id])
        try a.sql("INSERT INTO setting(key,value) VALUES('startNoteTemplate',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", ["\"\(plain.id)\""])
        // a big note: its payload travels as an asset
        _ = try a.noteStore.create(text: "# Big \(c[0])\n" + String(repeating: "\(c[0]) filler text ", count: 12_000))
        let access = try NotePrivacy(store: a.noteStore).setPassword("pw"); defer { access.revoke() }
        let locked = try a.noteStore.create(text: "# Locked\n\(c[5])\n")
        try access.lock(noteId: locked.id)
        let doomed = try a.noteStore.create(text: "# Doomed \(c[0])\nbye\n")
        try a.publishAttachments(of: plain.id)
        try await a.sync()
        try a.noteStore.deletePermanently([doomed.id])
        try await a.sync()
        let names = await world.account.recordNames
        #expect(names.contains { $0.hasPrefix("e.note.") } && names.contains { $0.hasPrefix("e.attachment.") } && names.contains { $0.hasPrefix("e.keyBundle.") })
        let records = try await everything(world)
        #expect(records.contains { $0.name.hasSuffix(".cipherAsset") && $0.bytes.count > 200 * 1024 }, "the scan includes an asset")
        for canary in c {
            for pattern in Self.patterns(canary) {
                for (place, bytes) in records {
                    #expect(!Self.contains(bytes, pattern), "canary \(canary) found in \(place)")
                }
            }
        }
        // Positive controls: the scan sees a canary that was not sealed, in every encoding it looks for.
        for canary in c {
            let found = Self.patterns(canary)
            #expect(found.contains { Self.contains(Data("x\(canary)x".utf8), $0) })
            #expect(found.contains { Self.contains(Data("x".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + canary.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), $0) })
            for shift in 0..<3 {
                let wrapped = Data(repeating: 0x7A, count: shift) + Data(canary.utf8) + Data([0x7A])
                let encoded = Data(wrapped.base64EncodedString().utf8)
                #expect(found.contains { Self.contains(encoded, $0) }, "base64 at alignment \(shift) of \(canary) is recognised")
            }
        }
    }

    @Test func aDeletionLooksLikeAnyOtherRecord() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let a = world.devices[0]
        let kept = try a.noteStore.create(text: "# Keep\nstays\n"), gone = try a.noteStore.create(text: "# Gone\nsame size text\n")
        try await a.sync()
        let before = try #require(await world.account.record(named: "e.note.\(gone.id)"))
        try a.noteStore.deletePermanently([gone.id])
        try await a.sync()
        let after = try #require(await world.account.record(named: "e.note.\(gone.id)"))
        let live = try #require(await world.account.record(named: "e.note.\(kept.id)"))
        #expect(Set(after.fields.keys) == Set(before.fields.keys) && Set(after.fields.keys) == Set(live.fields.keys), "same field names as a live record")
        guard case .bytes(let cipher)? = after.fields["cipher"] else { Issue.record("a deletion carries a cipher field"); return }
        #expect(!Self.contains(cipher, Data("\"at\"".utf8)) && !Self.contains(cipher, Data([0x02]) + Data("{".utf8)), "no plaintext marker")
        #expect(try a.openedText(of: after) == nil, "only the key can tell it is a deletion")
        let header = try decodedEntity(after)
        #expect(header.ver == 2, "a deletion is an ordinary next version")
    }

    // MARK: size

    @Test("libraryOfFiveThousandNotesPushesAndPullsInBatchesWithinTime", .tags(.perf), PerfGate.onlyInPerfPass)
    func testPerfLibraryOfFiveThousandNotesPushesAndPullsInBatchesWithinTime() async throws {
        let world = try await PublisherWorld.make(2); defer { world.cleanup() }
        let a = world.devices[0], b = world.devices[1]
        try await a.db.pool.write { db in
            for i in 0..<5_000 {
                let note = Note(id: UUIDv7.make(), text: "# Note \(i)\nbody \(i)\n", title: "Note \(i)", titleKey: "note \(i)", createdAt: .now, modifiedAt: .now)
                try note.save(db)
                try NoteIndexer.index(noteId: note.id, text: note.text, in: db)
            }
        }
        let start = Date()
        var cycles = 0, largestBatch = 0
        while try a.dirtyCount() > 0 || a.store.allInflight().count > 0, cycles < 200 {
            let report = try await a.publish()
            largestBatch = max(largestBatch, report.submitted)
            cycles += 1
        }
        let pushed = Date().timeIntervalSince(start)
        #expect(try a.dirtyCount() == 0)
        #expect(largestBatch <= 100, "pushes go in batches")
        let pullStart = Date()
        try await b.fetch()
        let applied = try await b.reconciler.applyPending(maxPasses: 2)
        let pulled = Date().timeIntervalSince(pullStart)
        #expect(applied.applied.count >= 5_000)
        #expect(try b.notes().count == 5_000)
        #expect(pushed < 600 && pulled < 600, "pushed in \(pushed) s, pulled in \(pulled) s")
    }
}
