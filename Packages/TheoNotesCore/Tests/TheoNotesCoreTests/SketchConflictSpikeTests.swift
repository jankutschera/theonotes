// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Real PencilKit baseline and two independently edited drawings rendered by the iOS spike.
/// The padded multipart variant below additionally tests opaque ancillary byte preservation.
enum SketchSyncPNGFixture {
    static var directory: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("Fixtures/sketch")
    }
    static func baseline() throws -> Data {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("one-stroke.png"))
        #expect(SyncWire.hash(bytes) == "b230e42019b40ffab7c458df722d7f01dc16da14ff8fd17afc84264ef83525bb")
        #expect(try archive(in: bytes) == Data(contentsOf: directory.appendingPathComponent("one-stroke.drawing")))
        return bytes
    }
    static func conflictEdits(baseline: Data) throws -> (Data, Data) {
        let left = try Data(contentsOf: directory.appendingPathComponent("conflict-left.png"))
        let right = try Data(contentsOf: directory.appendingPathComponent("conflict-right.png"))
        #expect(SyncWire.hash(left) == "d5877abeccac9049b0faeb5071492ceeac0595694e30f0804261993b1af3f03c")
        #expect(SyncWire.hash(right) == "ea78c52567e2cf42dca506b8e640e326a013d7f8c44a82059477704399e1b0ea")
        let leftDrawing = try archive(in: left), rightDrawing = try archive(in: right)
        #expect(leftDrawing == (try Data(contentsOf: directory.appendingPathComponent("conflict-left.drawing"))))
        #expect(rightDrawing == (try Data(contentsOf: directory.appendingPathComponent("conflict-right.drawing"))))
        #expect(leftDrawing != rightDrawing)
        #expect(leftDrawing != (try archive(in: baseline)))
        #expect(rightDrawing != (try archive(in: baseline)))
        #expect(left != right && left != baseline && right != baseline)
        return (left, right)
    }
    static func variant(_ baseline: Data, marker: String, padding: Int = 0) throws -> Data {
        var payload = Data(marker.utf8)
        payload.append(Data(repeating: 0xa5, count: padding))
        let type = Data("skEt".utf8), body = type + payload
        func word(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                  UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        let chunk = word(UInt32(payload.count)) + body + word(SketchOpaquePNGFixture.crc32(body))
        try #require(baseline.suffix(8).prefix(4) == Data("IEND".utf8))
        let result = Data(baseline.dropLast(12)) + chunk + baseline.suffix(12)
        #expect(try archive(in: result) == archive(in: baseline))
        return result
    }
    static func archive(in bytes: Data) throws -> Data {
        var offset = 8
        func word(_ position: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(bytes[position + $1]) } }
        while offset + 12 <= bytes.count {
            let count = word(offset)
            try #require(count <= bytes.count - offset - 12)
            let type = bytes.subdata(in: (offset + 4)..<(offset + 8))
            if type == Data("thND".utf8) {
                let payload = bytes.subdata(in: (offset + 8)..<(offset + 8 + count))
                try #require(payload.starts(with: Data([84, 78, 80, 75, 1])))
                return Data(payload.dropFirst(5))
            }
            offset += count + 12
        }
        throw CocoaError(.fileReadCorruptFile)
    }
    struct Reachable {
        let noteID: String
        let bytes: Data
    }
    static func reachable(store: NoteStore, paths: AppPaths, database: AppDatabase) throws -> [Reachable] {
        var result: [Reachable] = []
        for note in try store.allNotes() where note.deletedAt == nil && !note.isLocked {
            for link in NoteParser.attachmentLinks(in: note.text) {
                let exists = try database.pool.read {
                    try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE noteId=? AND filename=? AND deletedAt IS NULL)",
                                      arguments: [note.id, link.filename]) == true
                }
                try #require(exists, "Recovery bytes must have a live attachment row AND a readable Markdown link")
                result.append(Reachable(noteID: note.id,
                    bytes: try Data(contentsOf: paths.attachments.appendingPathComponent(note.id).appendingPathComponent(link.filename))))
            }
        }
        return result
    }
    // Bounded fixture-only diagnostics: no payload/plaintext or credentials are logged.
    static func cloudState(_ device: PublisherDevice, stage: String, noteID: String) throws {
        let rows = try device.db.pool.read { db in
            try ["sync_control", "sync_dirty", "ck_inflight", "ck_remote", "attachment", "note"].map { table in
                let columns: String
                switch table {
                case "sync_control": columns = "applying, enabled, backend"
                case "sync_dirty": columns = "entityType, localId, generation, tombstone"
                case "ck_inflight": columns = "entityType, entityId, generation, state"
                case "ck_remote": columns = "entityType, entityId, ver"
                case "attachment": columns = "id, noteId, filename, sha256, byteSize, deletedAt"
                default: columns = "id, location, isLocked, deletedAt"
                }
                return table + "=" + (try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) LIMIT 12")).map { $0.description }.joined(separator: ";")
            }
        }
        let file = device.installed(noteID: noteID, filename: "sketch.png")
        let hash = (try? Data(contentsOf: file)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
        print("SKETCH-CLOUD \(stage) file=\(hash) " + rows.joined(separator: " | "))
    }
    static func replace(_ bytes: Data, noteID: String, paths: AppPaths, database: AppDatabase) throws {
        try AttachmentFiles(paths: paths, database: database).write(
            [ImportedAttachment(filename: "sketch.png", data: bytes)], noteId: noteID, replacing: true) { _ in }
    }
}

@Suite struct SketchConflictSpikeTests {
    @Test(arguments: [false, true])
    func privateServerPreservesBothOfflinePNGAttachmentEdits(firstDeviceWins: Bool) async throws {
        let key = SymmetricKey(size: .bits256)
        let left = try SyncMaterializerTests.Library(key: key), right = try SyncMaterializerTests.Library(key: key)
        let observer = try SyncMaterializerTests.Library(key: key)
        defer { left.cleanup(); right.cleanup(); observer.cleanup() }
        let fixtures = SyncInitialCaptureRegressionTests()
        let blobs = SyncInitialCaptureRegressionTests.BlobStore(directory: left.paths.root.appendingPathComponent("sketch-shared-blobs"))
        let server = SyncEngineTests.Server()
        let engines = [fixtures.engine(left, server: server, blobs: blobs), fixtures.engine(right, server: server, blobs: blobs),
                       fixtures.engine(observer, server: server, blobs: blobs)]
        let baseline = try SketchSyncPNGFixture.baseline()
        let note = try left.store.create(text: "# Sketch\n![Sketch](sketch.png)\n")
        _ = try AttachmentStore(paths: left.paths, database: left.db).add(data: baseline, filename: "sketch.png", to: note.id)
        for engine in engines { _ = try await engine.synchronize() }
        for library in [left, right, observer] {
            #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("sketch.png")) == baseline)
        }
        let id = try #require(try await left.db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=? AND filename='sketch.png'", arguments: [note.id])
        })
        let ancestor = try #require(await server.entities["attachment:" + id])
        let (a, b) = try SketchSyncPNGFixture.conflictEdits(baseline: baseline)
        try SketchSyncPNGFixture.replace(a, noteID: note.id, paths: left.paths, database: left.db)
        try SketchSyncPNGFixture.replace(b, noteID: note.id, paths: right.paths, database: right.db)
        let loser = firstDeviceWins ? right : left
        let winnerEngine = engines[firstDeviceWins ? 0 : 1]
        let preparer = SyncAttachmentPreparer(database: loser.db, paths: loser.paths, accountID: "account", vaultKey: key)
        _ = try await preparer.preparePending()
        let queued = try #require(try loser.queue.prepareNext(vaultKey: key))
        #expect(queued.entityType == .attachment && queued.entityId == id)
        #expect(queued.parentRevision == ancestor.revision)
        _ = try await winnerEngine.synchronize()
        let rejection = try #require(try await server.push([queued]).results.first)
        #expect(rejection.status == .conflict && rejection.current?.mutation.entityId == id)
        #expect(await server.receipts[queued.mutationId] == nil)
        for _ in 0..<6 { for engine in engines { _ = try await engine.synchronize() } }
        for library in [left, right, observer] {
            let versions = try SketchSyncPNGFixture.reachable(store: library.store, paths: library.paths, database: library.db)
            #expect(Set(versions.map(\.bytes)) == Set([a, b]))
            #expect(Set(versions.map(\.noteID)).count >= 2, "Both versions must be recoverable through readable notes")
            for version in versions { #expect(try [SketchSyncPNGFixture.archive(in: a), SketchSyncPNGFixture.archive(in: b)].contains(SketchSyncPNGFixture.archive(in: version.bytes))) }
            #expect(try library.inbox.pending().isEmpty)
            #expect(try library.queue.pendingMutations().isEmpty)
        }
        for engine in engines { await engine.shutdown() }
    }

    @Test(arguments: [false, true])
    func cloudKitBlobFlowPreservesBothOfflinePNGAttachmentEdits(firstDeviceWins: Bool) async throws {
        try await withBlobWorld(3) { world in
            let devices = world.devices, rigs = devices.map { BlobRig($0) }
            for (device, rig) in zip(devices, rigs) { device.publishThrough(rig) }
            let baseline = try SketchSyncPNGFixture.baseline()
            let note = try devices[0].noteStore.create(text: "# Sketch\n![Sketch](sketch.png)\n")
            _ = try AttachmentStore(paths: devices[0].paths, database: devices[0].db)
                .add(data: baseline, filename: "sketch.png", to: note.id)
            try await devices[0].publish()
            for index in 1..<3 { try await devices[index].fetchEntities(); _ = try await devices[index].receiver(rigs[index]).applyPending() }
            for device in devices {
                #expect(try Data(contentsOf: device.installed(noteID: note.id, filename: "sketch.png")) == baseline)
            }
            let id = try devices[0].attachmentID(of: note.id)
            #expect(try devices[1].attachmentID(of: note.id) == id)
            let (a, b) = try SketchSyncPNGFixture.conflictEdits(baseline: baseline)
            try SketchSyncPNGFixture.replace(a, noteID: note.id, paths: devices[0].paths, database: devices[0].db)
            try SketchSyncPNGFixture.replace(b, noteID: note.id, paths: devices[1].paths, database: devices[1].db)
            let winner = firstDeviceWins ? 0 : 1, loser = firstDeviceWins ? 1 : 0
            try SketchSyncPNGFixture.cloudState(devices[loser], stage: "before-winner win=\(winner) loser=\(loser)", noteID: note.id)
            try await devices[winner].publish()
            let rejected = try await devices[loser].publish()
            #expect(rejected.needsMerge.contains { $0.entityType == "attachment" && $0.entityId == id })
            try SketchSyncPNGFixture.cloudState(devices[loser], stage: "after-rejected win=\(winner) loser=\(loser)", noteID: note.id)
            for round in 0..<6 {
                for index in devices.indices {
                    try await devices[index].fetchEntities()
                    if round < 2 { try SketchSyncPNGFixture.cloudState(devices[index], stage: "before-apply win=\(winner) round=\(round) device=\(index)", noteID: note.id) }
                    _ = try await devices[index].receiver(rigs[index]).applyPending()
                    if round == 0, index == loser {
                        // The conflict must already be a readable, live attachment before any
                        // later publisher/fetch cycle. A copied file with a tombstoned row is not recovery.
                        let immediate = try SketchSyncPNGFixture.reachable(store: devices[index].noteStore,
                            paths: devices[index].paths, database: devices[index].db)
                        #expect(Set(immediate.map(\.bytes)) == Set([a, b]))
                        #expect(Set(immediate.map(\.noteID)).count == 2)
                    }
                    if round < 2 { try SketchSyncPNGFixture.cloudState(devices[index], stage: "after-apply win=\(winner) round=\(round) device=\(index)", noteID: note.id) }
                    try await devices[index].publish()
                    if round < 2 { try SketchSyncPNGFixture.cloudState(devices[index], stage: "after-publish win=\(winner) round=\(round) device=\(index)", noteID: note.id) }
                }
            }
            for device in devices {
                let versions = try SketchSyncPNGFixture.reachable(store: device.noteStore, paths: device.paths, database: device.db)
                #expect(Set(versions.map(\.bytes)) == Set([a, b]))
                #expect(Set(versions.map(\.noteID)).count >= 2)
                #expect(try device.store.allRemote().isEmpty)
                #expect(try device.rowCount("ck_inflight") == 0)
            }
        }
    }

    @Test func realPencilKitPNGBytesSurviveMultipartCloudBlobTransferAndInstall() async throws {
        try await withBlobWorld(2) { world in
            let a = world.devices[0], b = world.devices[1], rigA = BlobRig(a), rigB = BlobRig(b)
            a.publishThrough(rigA)
            let baseline = try SketchSyncPNGFixture.baseline()
            let bytes = try SketchSyncPNGFixture.variant(baseline, marker: "multipart-sketch-fixture", padding: blobMiB + 37)
            let note = try a.noteStore.create(text: "# Multipart sketch\n![Sketch](sketch.png)")
            _ = try AttachmentStore(paths: a.paths, database: a.db).add(data: bytes, filename: "sketch.png", to: note.id)
            try await a.publish()
            try await b.fetchEntities(); _ = try await b.receiver(rigB).applyPending()
            #expect(try Data(contentsOf: b.installed(noteID: note.id, filename: "sketch.png")) == bytes)
            #expect(try SketchSyncPNGFixture.archive(in: bytes) == SketchSyncPNGFixture.archive(in: baseline))
            let parts = await world.account.recordNames.filter { $0.hasPrefix("b.") }
            #expect(parts.count >= 2)
            #expect(!rigB.gateway.assetFetches.isEmpty)
        }
    }
}
