// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

@testable import TheoNotesCore
import CryptoKit
import Foundation
import Testing
import SwiftUI
import UIKit
@testable import BaerchenIOS

@Suite @MainActor
struct MobileSyncResponsivenessTests {
    actor GatedTransport: SyncTransport {
        var history: [SyncEntity] = []
        var gated = false
        var started = false
        var waiter: CheckedContinuation<Void, Never>?
        func append(_ entity: SyncEntity) {
            history.append(SyncEntity(mutation: entity.mutation, revision: entity.revision,
                sequence: Int64(history.count + 1), receivedAt: entity.receivedAt))
        }
        func gateNextPull() { gated = true; started = false }
        func waitForPull() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { gated = false }
        func pull(after cursor: Int64) async throws -> SyncPullResult {
            if gated {
                started = true; waiter?.resume(); waiter = nil
                while gated { try await Task.sleep(for: .milliseconds(5)) }
            }
            let changes = history.filter { $0.sequence > cursor }
            return SyncPullResult(changes: changes, cursor: changes.last?.sequence ?? cursor, hasMore: false)
        }
        func acknowledge(_ cursor: Int64) async throws {}
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
            let results = mutations.map { mutation in
                let entity = SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                    sequence: Int64(history.count + 1), receivedAt: 1)
                history.append(entity)
                return SyncMutationResult(mutationId: mutation.mutationId, status: .accepted, entity: entity, current: nil)
            }
            return SyncPushResult(results: results)
        }
    }
    struct NoBlobs: SyncBlobTransport {
        func ensureUploaded(_ hashes: [String]) async throws {}
        func download(hash: String) async throws -> URL { throw URLError(.fileDoesNotExist) }
    }
    struct FixtureBlobs: SyncBlobTransport {
        let file: URL
        func ensureUploaded(_ hashes: [String]) async throws {}
        func download(hash: String) async throws -> URL { file }
    }
    func temporaryLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    func engine(_ library: MobileLibrary, _ server: GatedTransport, _ key: SymmetricKey) -> SyncEngine {
        SyncEngine(database: library.database, paths: library.paths, accountID: "account", vaultKey: key,
            transport: server, blobs: NoBlobs(), coordinator: MobileSyncCommitCoordinator(library: library))
    }
    func entity(text: String, key: SymmetricKey, revision: Int64) throws -> SyncEntity {
        let note = Note(id: "remote-note", text: text, title: "Title", titleKey: "title",
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 2))
        let payload = SyncNotePayload(note: note, directTags: [], pinnedTags: [], attachmentIds: [])
        let cipher = try NoteCipher.seal(JSONEncoder().encode(payload), vaultKey: key,
            context: SyncWire.cipherContext(accountID: "account", type: .note, entityID: note.id))
        return SyncEntity(mutation: SyncMutation(mutationId: "mutation-\(revision)", entityType: .note,
            entityId: note.id, parentRevision: revision - 1, ciphertext: SyncWire.base64(cipher)),
            revision: revision, sequence: revision, receivedAt: revision)
    }

    @Test func typicalPullLeavesUnrelatedEditorFocusedAndTyping() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let queue = SyncQueue(database: library.database)
        try queue.enable(accountID: "account")
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: editor).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let source = try library.store.create(text: "Typing here")
        library.selectedID = source.id
        for _ in 0..<600 where !editor.ready || editor.session?.noteId != source.id { try await Task.sleep(for: .milliseconds(50)) }
        try #require(editor.ready && editor.session?.noteId == source.id,
            "Stage: foreground editor startup before sync; ready=\(editor.ready), editable=\(editor.editable), session=\(editor.session?.noteId ?? "nil"), expected=\(source.id), sceneSelection=\(editor.sceneNavigation?.selectedID ?? "nil"), registered=\(library.hasRegisteredSceneWindows), registryEditors=\(library.sceneRegistry.sceneCount), activeScenes=\(library.hasActiveSceneWindows), privacyClosed=\(editor.isClosedForPrivacy), libraryBusy=\(library.libraryOperationBusy), scenePending=\(library.sceneOperationPending), appLocked=\(library.appLocked), documentLoad=\(editor.documentLoadGeneration), webLoading=\(editor.webView.isLoading), webURL=\(editor.webView.url?.absoluteString ?? "nil"), libraryError=\(library.errorMessage ?? "nil")")
        editor.webView.becomeFirstResponder()
        _ = try await editor.webView.evaluateJavaScript("window.__i1cFreezeCount=0;window.__i1cReceive=window.__baerchen.receive;window.__baerchen.receive=function(m){if(m.type==='freezeForClose')window.__i1cFreezeCount++;return window.__i1cReceive(m)};document.querySelector('.cm-content').focus();true")
        #expect((try await editor.webView.evaluateJavaScript("document.activeElement === document.querySelector('.cm-content')") as? Bool) == true)
        let key = SymmetricKey(size: .bits256), server = GatedTransport()
        func remote<T: Encodable>(_ value: T, type: SyncEntityType, id: String, sequence: Int64, refs: [String] = []) throws -> SyncEntity {
            let cipher = try NoteCipher.seal(SyncPayloadCodec.encoder().encode(value), vaultKey: key, context: SyncWire.cipherContext(accountID: "account", type: type, entityID: id))
            return SyncEntity(mutation: SyncMutation(mutationId: "fixture-\(sequence)", entityType: type, entityId: id, parentRevision: 0, ciphertext: SyncWire.base64(cipher), blobRefs: refs), revision: 1, sequence: sequence, receivedAt: sequence)
        }
        let other = Note(id: "other-note", text: "Remote note", title: "Remote note", titleKey: "remote note", createdAt: .now, modifiedAt: .now)
        let note = SyncNotePayload(note: other, directTags: [], pinnedTags: [], attachmentIds: [])
        let tag = SyncTagPreferencePayload(path: "Work", iconName: nil, isPinned: false, sortIndex: nil)
        let bytes = Data("attachment".utf8), cipherURL = library.paths.root.appendingPathComponent("fixture-blob")
        try ChunkedCipher.encrypt(data: bytes, output: cipherURL, keyEncryptionKey: key, context: SyncWire.cipherContext(accountID: "account", type: .attachment, entityID: "other-asset"))
        let facts = try SyncAttachmentPreparer.hashFile(cipherURL)
        let attachment = SyncAttachmentPayload(id: "other-asset", noteId: other.id, filename: "other.txt", isLocked: false, blobHash: facts.hash, cipherBytes: facts.size, fileBytes: Int64(bytes.count), fileHash: SyncWire.hash(bytes), uti: nil, width: nil, height: nil, ocrText: nil, createdAt: 1, updatedAt: 1)
        await server.append(try remote(note, type: .note, id: other.id, sequence: 1))
        await server.append(try remote(tag, type: .tagPreference, id: "tag-work", sequence: 2))
        await server.append(try remote(attachment, type: .attachment, id: attachment.id, sequence: 3, refs: [facts.hash]))
        let sync = SyncEngine(database: library.database, paths: library.paths, accountID: "account", vaultKey: key, transport: server, blobs: FixtureBlobs(file: cipherURL), coordinator: MobileSyncCommitCoordinator(library: library))
        let run = Task { try await sync.synchronize() }
        for _ in 0..<8 {
            editor.command(.insertText, args: ["text": .string("x")])
            try await Task.sleep(for: .milliseconds(40))
        }
        _ = try await run.value
        for _ in 0..<600 where editor.session?.text.filter({ $0 == "x" }).count != 8 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.session?.text.filter { $0 == "x" }.count == 8)
        #expect(try library.store.note(id: other.id) != nil)
        #expect(FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent("other-note/other.txt").path))
        #expect((try await editor.webView.evaluateJavaScript("window.__i1cFreezeCount") as? Int) == 0)
        #expect((try await editor.webView.evaluateJavaScript("document.activeElement === document.querySelector('.cm-content')") as? Bool) == true)
        await sync.shutdown()
    }

    @Test func cancellingInitialExclusiveDownloadReleasesLibraryWithoutChangingExistingNote() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let original = try library.store.create(text: "Existing note must survive")
        let queue = SyncQueue(database: library.database)
        try queue.configure(accountID: "account")
        let server = GatedTransport(), sync = engine(library, server, SymmetricKey(size: .bits256))
        await server.gateNextPull()
        let run = Task { try await library.synchronize(using: sync, exclusive: true) }
        await server.waitForPull()
        #expect(library.libraryOperationBusy)
        #expect(try !queue.isEnabled())
        #expect(try library.store.note(id: original.id)?.text == original.text)
        await sync.cancelCurrentRun()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!library.libraryOperationBusy)
        #expect(try library.store.note(id: original.id)?.text == original.text)
        let session = try library.session(for: original.id)
        #expect(session.text == original.text)
        await sync.shutdown()
    }

    @Test func enabledNonexclusiveDownloadAllowsEditingAndRefreshesTheMergedSession() async throws {
        let library = try temporaryLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let queue = SyncQueue(database: library.database)
        try queue.enable(accountID: "account")
        let key = SymmetricKey(size: .bits256), server = GatedTransport()
        let sync = engine(library, server, key)
        await server.append(try entity(text: "Title\n\na\n\nb\n", key: key, revision: 1))
        _ = try await library.synchronize(using: sync, exclusive: false)
        let session = try library.session(for: "remote-note")
        await server.append(try entity(text: "Title\n\na\n\nREMOTE\n", key: key, revision: 2))
        await server.gateNextPull()
        let run = Task { try await library.synchronize(using: sync, exclusive: false) }
        await server.waitForPull()
        #expect(!library.libraryOperationBusy)
        #expect(session.text == "Title\n\na\n\nb\n")
        let edited = "Title\n\nLOCAL\n\nb\n"
        let change = try JSONDecoder().decode(ChangeSet.self,
            from: JSONSerialization.data(withJSONObject: [[session.text.utf16.count] + edited.components(separatedBy: "\n")]))
        _ = session.apply(txId: "edit-during-network", baseRevision: session.revision, changeSet: change, origin: nil)
        #expect(session.text == edited)
        await server.release()
        _ = try await run.value
        #expect(!library.libraryOperationBusy)
        #expect(try library.store.note(id: "remote-note")?.text == "Title\n\nLOCAL\n\nREMOTE\n")
        #expect(session.text == "Title\n\nLOCAL\n\nREMOTE\n")
        await sync.shutdown()
    }
}
