// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncMaterializerTests {
    struct Library {
        let paths: AppPaths
        let db: AppDatabase
        let key: SymmetricKey
        var store: NoteStore { NoteStore(db: db, notifier: nil, paths: paths) }
        var queue: SyncQueue { SyncQueue(database: db) }
        var inbox: SyncInbox { SyncInbox(database: db) }
        func materializer(_ blobs: SyncPayloadReaderTests.Blobs = .init()) -> SyncMaterializer {
            SyncMaterializer(database: db, paths: paths, accountID: "account", vaultKey: key, blobs: blobs)
        }
        init(key: SymmetricKey = SymmetricKey(size: .bits256), enabled: Bool = true) throws {
            self.key = key
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-apply-\(UUID())"))
            try paths.createDirectories(); db = try AppDatabase(path: paths.database)
            if enabled { try SyncQueue(database: db).enable(accountID: "account") }
            else { try SyncQueue(database: db).configure(accountID: "account") }
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        func entity<T: Encodable>(_ value: T, type: SyncEntityType = .note, id: String = "note", revision: Int64 = 1,
                                   sequence: Int64 = 1, refs: [String] = []) throws -> SyncEntity {
            let cipher = try NoteCipher.seal(SyncPayloadCodec.encoder().encode(value), vaultKey: key,
                                            context: SyncWire.cipherContext(accountID: "account", type: type, entityID: id))
            return SyncEntity(mutation: SyncMutation(mutationId: "mutation-\(sequence)", entityType: type, entityId: id,
                parentRevision: revision - 1, ciphertext: SyncWire.base64(cipher), blobRefs: refs), revision: revision, sequence: sequence, receivedAt: sequence)
        }
        func receive(_ entities: [SyncEntity]) throws {
            try inbox.persist(SyncPullResult(changes: entities, cursor: entities.last!.sequence, hasMore: false), requestedAfter: inbox.cursor())
        }
        func payload(_ text: String, id: String = "note", attachments: [String] = []) -> SyncNotePayload {
            let title = NoteParser.metadata(for: text).title
            return SyncNotePayload(note: Note(id: id, text: text, title: title, titleKey: CanonicalKey.make(title),
                createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 2)),
                directTags: NoteParser.metadata(for: text).tags, pinnedTags: [], attachmentIds: attachments)
        }
    }

    @Test func appliesExactMarkdownAndPreferencesWithoutEchoAndRejectsOldReplays() async throws {
        let library = try Library(); defer { library.cleanup() }
        let first = try library.entity(library.payload("# Café\r\ne\u{301}\n#Work\n"))
        let setting = try library.entity(SyncSettingPayload(key: "hideMarkdown", value: "false"), type: .setting, id: "setting", sequence: 2)
        try library.receive([first, setting])
        #expect(try await library.materializer().apply(first) == .applied)
        #expect(try await library.materializer().apply(setting) == .applied)
        #expect(try library.store.note(id: "note").map { Data($0.text.utf8) } == Data("# Café\r\ne\u{301}\n#Work\n".utf8))
        #expect(try library.queue.pendingCount() == 0)
        #expect(try library.inbox.pending().isEmpty)
        let second = try library.entity(library.payload("# New\nbody"), revision: 2, sequence: 3)
        try library.receive([second])
        #expect(try await library.materializer().apply(second) == .applied)
        #expect(try await library.materializer().apply(first) == .unchanged)
        #expect(try library.store.note(id: "note")?.text == "# New\nbody")
    }

    @Test func mergesDisjointEditsAndRebasesTheUnsentGeneration() async throws {
        let library = try Library(); defer { library.cleanup() }
        let first = try library.entity(library.payload("Title\n\na\n\nb\n"))
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let local = try #require(try library.store.note(id: "note"))
        _ = try library.store.updateText(id: "note", text: "Title\n\nLOCAL\n\nb\n", expectedRevision: local.revision)
        let next = try library.entity(library.payload("Title\n\na\n\nREMOTE\n"), revision: 2, sequence: 2)
        try library.receive([next])
        #expect(try await library.materializer().apply(next) == .applied)
        #expect(try library.store.note(id: "note")?.text == "Title\n\nLOCAL\n\nREMOTE\n")
        let mutation = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(mutation.parentRevision == 2)
        #expect(try library.queue.pendingCount() == 1)
    }

    @Test func explicitRejectionPreservesBothConflictingBodiesAndReplayMakesNoExtraCopy() async throws {
        let library = try Library(); defer { library.cleanup() }
        let first = try library.entity(library.payload("Original"))
        try library.receive([first]); _ = try await library.materializer().apply(first)
        let note = try #require(try library.store.note(id: "note"))
        _ = try library.store.updateText(id: note.id, text: "Local version", expectedRevision: note.revision)
        let pending = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let remote = try library.entity(library.payload("Remote version"), revision: 2, sequence: 2)
        try library.receive([remote])
        #expect(try await library.materializer().apply(remote) == .waitingForUpload)
        #expect(try await library.materializer().apply(remote, rejectedMutationID: pending.mutationId) == .applied)
        let copyID = SyncNoteMerge.conflictID(entityID: note.id, mutationID: pending.mutationId, remoteRevision: 2)
        #expect(try library.store.note(id: note.id)?.text == "Local version")
        #expect(try library.store.note(id: copyID)?.text == "Remote version")
        #expect(try await library.materializer().apply(remote) == .unchanged)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 2)
        #expect(try library.queue.pendingMutations().isEmpty)
        #expect(try library.queue.pendingCount() == 2)
    }

    @Test func preservesLocalSettingWhileResolvingAnExplicitCASRejection() async throws {
        let library = try Library(); defer { library.cleanup() }
        try Settings(db: library.db).set(.hideMarkdown, to: false)
        let pending = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let remote = try library.entity(SyncSettingPayload(key: "hideMarkdown", value: "true"), type: .setting, id: pending.entityId)
        try library.receive([remote])
        #expect(try await library.materializer().apply(remote) == .waitingForUpload)
        #expect(try await library.materializer().apply(remote, rejectedMutationID: pending.mutationId) == .applied)
        #expect(Settings(db: library.db).hideMarkdown == false)
        let rebased = try #require(try library.queue.prepareNext(vaultKey: library.key))
        #expect(rebased.parentRevision == 1 && rebased.mutationId != pending.mutationId)
    }

    @Test func waitsForAttachmentThenCommitsStableIdentityAndVerifiedBytesTogether() async throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.entity(library.payload("Picture\n![](picture.png)", attachments: ["asset"]))
        try library.receive([note])
        #expect(try await library.materializer().apply(note) == .waitingForDependencies)
        #expect(try library.store.note(id: "note") == nil)
        let content = Data("file content".utf8), cipher = library.paths.root.appendingPathComponent("download.bch")
        try ChunkedCipher.encrypt(data: content, output: cipher, keyEncryptionKey: library.key,
                                  context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: "asset"))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let payload = SyncAttachmentPayload(id: "asset", noteId: "note", filename: "picture.png", isLocked: false,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(content.count), fileHash: SyncWire.hash(content),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        let attachment = try library.entity(payload, type: .attachment, id: "asset", sequence: 2, refs: [facts.hash])
        try library.receive([attachment])
        #expect(try await library.materializer(.init(files: [facts.hash: cipher])).apply(note) == .applied)
        #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent("note/picture.png")) == content)
        #expect(try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId='note'") } == "asset")
        #expect(try library.inbox.pending().isEmpty)
        #expect(try library.queue.pendingCount() == 0)
    }

    @Test func filenamePlaceholderShowsTheNoteBeforeAFileArrivesAndKeepsItsStableID() async throws {
        let library = try Library(); defer { library.cleanup() }
        var payload = library.payload("Text is available now\n![](later.png)", attachments: ["asset"])
        payload.attachmentNames = ["asset": "later.png"]
        let note = try library.entity(payload)
        try library.receive([note])
        #expect(try await library.materializer().apply(note) == .applied)
        #expect(try library.store.note(id: "note")?.text == payload.text)
        #expect(try library.inbox.pending().isEmpty)
        #expect(try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId='note'") } == "asset")
        let content = Data("arrived later".utf8), cipher = library.paths.root.appendingPathComponent("later.bch")
        try ChunkedCipher.encrypt(data: content, output: cipher, keyEncryptionKey: library.key,
                                  context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: "asset"))
        let facts = try SyncAttachmentPreparer.hashFile(cipher)
        let descriptor = SyncAttachmentPayload(id: "asset", noteId: "note", filename: "later.png", isLocked: false,
            blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(content.count), fileHash: SyncWire.hash(content),
            uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 2)
        let file = try library.entity(descriptor, type: .attachment, id: "asset", sequence: 2, refs: [facts.hash])
        try library.receive([file])
        #expect(try await library.materializer(.init(files: [facts.hash: cipher])).apply(file) == .applied)
        #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent("note/later.png")) == content)
        #expect(try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId='note'") } == "asset")
        #expect(try library.queue.pendingCount() == 0)
    }
}
