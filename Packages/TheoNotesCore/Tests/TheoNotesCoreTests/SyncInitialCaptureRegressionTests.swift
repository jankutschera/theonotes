// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

struct SyncInitialCaptureRegressionTests {
    actor BlobStore {
        let directory: URL
        init(directory: URL) { self.directory = directory }
        func put(hash: String, bytes: Data) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appendingPathComponent(hash))
        }
        func file(_ hash: String) throws -> URL {
            let url = directory.appendingPathComponent(hash)
            guard FileManager.default.fileExists(atPath: url.path) else { throw SyncProtocolError.invalidPayload }
            return url
        }
    }
    struct Blobs: SyncBlobTransport {
        let database: AppDatabase
        let paths: AppPaths
        let remote: BlobStore
        func ensureUploaded(_ hashes: [String]) async throws {
            for hash in hashes {
                let bytes = try await database.pool.read { db -> Data in
                    let row = try #require(try Row.fetchOne(db, sql: "SELECT data,localPath FROM sync_blob_state WHERE hash=?", arguments: [hash]))
                    if let data: Data = row["data"] { return data }
                    return try Data(contentsOf: paths.root.appendingPathComponent(try SyncBlobLocation.relative(#require(row["localPath"] as String?))))
                }
                try await remote.put(hash: hash, bytes: bytes)
            }
        }
        func download(hash: String) async throws -> URL { try await remote.file(hash) }
    }
    func engine(_ library: SyncMaterializerTests.Library, server: SyncEngineTests.Server, blobs: BlobStore) -> SyncEngine {
        SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
            transport: server, blobs: Blobs(database: library.db, paths: library.paths, remote: blobs))
    }

    @Test func pausedInitialCapturePreservesAlreadyDownloadedNoteEditsAcrossReopenAndRemoteRevision() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup() }
        let first = try library.entity(library.payload("Title\n\na\n\nb\n"))
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let note = try #require(try library.store.note(id: "note"))
        _ = try library.store.updateText(id: note.id, text: "Title\n\nLOCAL\n\nb\n", expectedRevision: note.revision)
        #expect(try !library.queue.isEnabled())
        #expect(try library.queue.pendingCount() == 1)
        let reopened = try AppDatabase(path: library.paths.database)
        defer { try? reopened.pool.close() }
        #expect(try SyncQueue(database: reopened).pendingCount() == 1)
        #expect(try NoteStore(db: reopened, notifier: nil, paths: library.paths).note(id: "note")?.text.contains("LOCAL") == true)
        let next = try library.entity(library.payload("Title\n\na\n\nREMOTE\n"), revision: 2, sequence: 2)
        try library.receive([next]); _ = try await library.materializer().apply(next)
        #expect(try library.store.note(id: "note")?.text == "Title\n\nLOCAL\n\nREMOTE\n")
        #expect(try !library.queue.isEnabled())
    }

    @Test func initialDirtyAttachmentUnblocksOnlyAfterSafeEnableAndPreservesBothVersions() async throws {
        let key = SymmetricKey(size: .bits256)
        let source = try SyncMaterializerTests.Library(key: key), target = try SyncMaterializerTests.Library(key: key, enabled: false)
        defer { source.cleanup(); target.cleanup() }
        let directory = source.paths.root.appendingPathComponent("remote-blobs")
        let blobs = BlobStore(directory: directory), server = SyncEngineTests.Server()
        let sender = engine(source, server: server, blobs: blobs), receiver = engine(target, server: server, blobs: blobs)
        let note = try source.store.create(text: "# File\n" + AttachmentMarkdown.link(for: "file.txt") + "\nBase")
        _ = try AttachmentStore(paths: source.paths, database: source.db).add(data: Data("base bytes".utf8), filename: "file.txt", to: note.id)
        _ = try await sender.synchronize()
        #expect(try await receiver.synchronize().pendingDownloads == 0)
        let localBytes = Data("local paused replacement".utf8), remoteBytes = Data("remote replacement".utf8)
        try AttachmentFiles(paths: target.paths, database: target.db).write(
            [ImportedAttachment(filename: "file.txt", data: localBytes)], noteId: note.id, replacing: true) { _ in }
        try AttachmentFiles(paths: source.paths, database: source.db).write(
            [ImportedAttachment(filename: "file.txt", data: remoteBytes)], noteId: note.id, replacing: true) { _ in }
        let current = try #require(try source.store.note(id: note.id))
        _ = try source.store.updateText(id: note.id, text: "# File\n" + AttachmentMarkdown.link(for: "file.txt") + "\nRemote body", expectedRevision: current.revision)
        _ = try await sender.synchronize()
        let blocked = try await receiver.synchronize()
        #expect(blocked.pendingDownloads > 0)
        #expect(blocked.waitingForUploads > 0)
        #expect(try !target.queue.isEnabled())
        #expect(try target.queue.canEnableAfterInitialDownload(blocked))
        try target.queue.enable(accountID: "account")
        var summary = blocked
        for _ in 0..<4 {
            summary = try await receiver.synchronize()
            if summary.pendingDownloads == 0 && summary.pendingUploads == 0 { break }
        }
        #expect(summary.pendingDownloads == 0 && summary.pendingUploads == 0)
        var allBytes: [Data] = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: target.paths.attachments.path) {
            let url = target.paths.attachments.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { allBytes.append(try Data(contentsOf: url)) }
        }
        #expect(allBytes.contains(localBytes))
        #expect(allBytes.contains(remoteBytes))
        await sender.shutdown(); await receiver.shutdown()
    }

    @Test func initialEnableRefusesPendingPasswordEnvelopeAndUnlockRequirements() throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup() }
        let note = try library.store.create(text: "local\n" + AttachmentMarkdown.link(for: "file.txt"))
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("local".utf8), filename: "file.txt", to: note.id)
        var summary = SyncRunSummary(); summary.pendingDownloads = 1; summary.waitingForUploads = 1
        #expect(try library.queue.canEnableAfterInitialDownload(summary))
        summary.waitingForUnlock = 1
        #expect(try !library.queue.canEnableAfterInitialDownload(summary))
        summary.waitingForUnlock = 0
        let envelope = try library.entity(SyncLockEnvelopePayload(envelope: Data("pending".utf8)), type: .keyBundle, id: "lock-vault")
        try library.receive([envelope])
        #expect(try !library.queue.canEnableAfterInitialDownload(summary))
    }
}
