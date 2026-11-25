// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Synchronization
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchDraftStoreTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func draft(id: UUID = UUID(), generation: Int = 0, noteID: String = UUID().uuidString) -> MobileSketchDraftStore.Draft {
        .init(id: id, generation: generation, originalNoteID: noteID,
              drawingData: Data("PRIVATE-STROKE-ARCHIVE".utf8), canvasSize: CGSize(width: 768, height: 1024))
    }
    private func namespace(_ root: URL, libraryID: String = "fixture-library") -> URL {
        let hash = SHA256.hash(data: Data(libraryID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("SketchDrafts").appendingPathComponent(hash)
    }
    private func files(_ root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(url) }
        }
        return result
    }
    private func access(at root: URL, password: String = "fixture-password") throws -> (AppDatabase, LockedNoteAccess) {
        let paths = AppPaths(root: root.appendingPathComponent(UUID().uuidString))
        try paths.createDirectories()
        let database = try AppDatabase(path: paths.database)
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        return (database, try NotePrivacy(store: store).setPassword(password))
    }
    @Test func plainCheckpointReopensAndOldGenerationsCannotReplaceIt() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft(generation: 2)
        #expect(try await store.checkpoint(value, protection: .plain))
        #expect(try await store.load(value.id) == value)
        let old = draft(id: value.id, generation: 1, noteID: try #require(value.originalNoteID))
        #expect(try await !store.checkpoint(old, protection: .plain))
        let reopened = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        #expect(try await reopened.load(value.id) == value)
        let other = MobileSketchDraftStore(root: url, libraryID: "other-library")
        #expect(try await other.discover().isEmpty)
        #expect(try await other.load(value.id) == nil)
        let sceneA = UUID(), sceneB = UUID()
        #expect(try await reopened.claim(value.id, owner: sceneA))
        #expect(try await !reopened.claim(value.id, owner: sceneB))
        await reopened.release(value.id, owner: sceneB)
        #expect(try await !reopened.claim(value.id, owner: sceneB))
        await reopened.release(value.id, owner: sceneA)
        #expect(try await reopened.claim(value.id, owner: sceneB))
    }
    @Test func sealedCheckpointHasNoPlaintextAndMissingWrongRevokedKeyPreservesIt() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (db, key) = try access(at: url), (wrongDB, wrong) = try access(at: url)
        defer { try? db.pool.close(); try? wrongDB.pool.close() }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .sealed(key)))
        let snapshots = files(namespace(url)), before = try snapshots.map { try Data(contentsOf: $0) }
        for bytes in before {
            #expect(bytes.range(of: Data(try #require(value.originalNoteID).utf8)) == nil)
            #expect(bytes.range(of: value.drawingData) == nil)
        }
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await store.load(value.id) }
        await #expect(throws: (any Error).self) { try await store.load(value.id, access: wrong) }
        #expect(try snapshots.map { try Data(contentsOf: $0) } == before)
        let reopened = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        #expect(try await reopened.load(value.id, access: key) == value)
        #expect(try await reopened.hasProtectedDrafts())
        key.revoke()
        await #expect(throws: (any Error).self) { try await store.checkpoint(draft(id: value.id, generation: 1), protection: .sealed(key)) }
        #expect(try snapshots.map { try Data(contentsOf: $0) } == before)
    }
    @Test func deleteWinsAgainstHeldCheckpointAndSurvivesStoreReopen() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let held = DraftCheckpointHold(), store = MobileSketchDraftStore(root: url, libraryID: "fixture-library", beforeCheckpoint: { await held.waitIfArmed() })
        let value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        await held.arm()
        let pending = Task { try await store.checkpoint(draft(id: value.id, generation: 1), protection: .plain) }
        try await waitForHold(held)
        try await store.delete(value.id)
        await held.release()
        #expect(try await !pending.value)
        #expect(try await store.load(value.id) == nil)
        let reopened = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        #expect(try await !reopened.checkpoint(draft(id: value.id, generation: 10), protection: .plain))
        #expect(try await reopened.discover().isEmpty)
    }
    @Test func revokeOrCancellationBeforePublicationKeepsLastDurableGeneration() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (db, key) = try access(at: url); defer { try? db.pool.close() }
        let held = DraftCheckpointHold(), store = MobileSketchDraftStore(root: url, libraryID: "fixture-library", beforeCheckpoint: { await held.waitIfArmed() })
        let value = draft()
        #expect(try await store.checkpoint(value, protection: .sealed(key)))
        let base = try #require(files(namespace(url)).first { $0.pathExtension == "base" }), before = try Data(contentsOf: base)
        await held.arm()
        let pending = Task { try await store.checkpoint(draft(id: value.id, generation: 1), protection: .sealed(key)) }
        try await waitForHold(held)
        key.revoke()
        await held.release()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        #expect(try Data(contentsOf: base) == before)
        await held.arm()
        let cancelled = Task { try await store.checkpoint(draft(id: value.id, generation: 2), protection: .plain) }
        try await waitForHold(held)
        await store.invalidatePendingWrites()
        await held.release()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        await store.waitForWrites()
        #expect(try Data(contentsOf: base) == before)
    }
    @Test func uncertaintyCannotBeClearedByAutosaveAndProtectionCannotDowngrade() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (db, key) = try access(at: url); defer { try? db.pool.close() }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        #expect(try await store.markInsertionUnconfirmed(value.id, protection: .plain) == 1)
        #expect(try await store.checkpoint(draft(id: value.id, generation: 2), protection: .plain))
        #expect(try await store.load(value.id)?.state == .insertionUnconfirmed)
        #expect(try await store.checkpoint(draft(id: value.id, generation: 3), protection: .sealed(key)))
        #expect(try await store.hasProtectedDrafts())
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await store.checkpoint(draft(id: value.id, generation: 4), protection: .plain) }
        for file in files(namespace(url)) where file.pathExtension == "base" { #expect(try Data(contentsOf: file).starts(with: Data("BJB1:".utf8))) }
        try await store.discardAll()
        #expect(try await !store.hasProtectedDrafts())
    }
    @Test func corruptOrOversizedRecordsFailClosedWithoutDeletingRecovery() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        let base = try #require(files(namespace(url)).first { $0.pathExtension == "base" })
        let corrupted = Data("broken recovery".utf8)
        try corrupted.write(to: base)
        await #expect(throws: (any Error).self) { try await store.load(value.id) }
        #expect(try Data(contentsOf: base) == corrupted)
        let oversized = MobileSketchDraftStore.Draft(generation: 0, originalNoteID: nil,
            drawingData: Data(count: MobileSketchDraftStore.maximumDrawingBytes + 1), canvasSize: CGSize(width: 768, height: 1024))
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await store.checkpoint(oversized, protection: .plain) }
    }
    @Test func actualJournalFilesAndSnapshotDirectoryAreProtectedAndExcluded() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        let journalFiles = files(namespace(url)).filter { ["base", "jsonl"].contains($0.pathExtension) }
        #expect(journalFiles.count == 2)
        for file in journalFiles {
            for checked in [file, file.deletingLastPathComponent()] {
                let attributes = try FileManager.default.attributesOfItem(atPath: checked.path)
                let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
                #if targetEnvironment(simulator)
                #expect(protection == nil || protection == FileProtectionType.complete.rawValue)
                #else
                #expect(protection == FileProtectionType.complete.rawValue)
                #endif
                #expect(try checked.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            }
        }
        // Exact future EditJournal temp filename with the same explicit creation attributes.
        let folder = try #require(journalFiles.first).deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(value.id.uuidString + ".base.tmp")
        try #require(FileManager.default.createFile(atPath: temporary.path, contents: Data(), attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600]))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
        #if targetEnvironment(simulator)
                #expect(protection == nil || protection == FileProtectionType.complete.rawValue)
                #else
                #expect(protection == FileProtectionType.complete.rawValue)
                #endif
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    @Test func twoStoresCannotClaimSameDraftAndFreshReservationCoversFirstCheckpoint() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let first = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let second = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let value = draft(), ownerA = UUID(), ownerB = UUID()
        #expect(try await first.reserveFresh(value.id, owner: ownerA))
        #expect(try await !second.reserveFresh(value.id, owner: ownerB))
        #expect(try await first.checkpoint(value, protection: .plain))
        #expect(try await !second.claim(value.id, owner: ownerB))
        #expect(try await !second.claim(value.id, owner: ownerA), "Same owner UUID cannot bypass a different store's kernel lease")
        await first.release(value.id, owner: ownerB)
        #expect(try await !second.claim(value.id, owner: ownerB))
        await first.release(value.id, owner: ownerA)
        #expect(try await second.claim(value.id, owner: ownerB))
        await second.release(value.id, owner: ownerB)
    }
    @Test func orphanSealedCheckpointRecoversOnlyAfterUnlockWithoutRepairingCorruptPointer() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (db, key) = try access(at: url); defer { try? db.pool.close() }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft(generation: 7)
        #expect(try await store.checkpoint(value, protection: .sealed(key)))
        let folder = namespace(url).appendingPathComponent("Drafts").appendingPathComponent(value.id.uuidString)
        let pointer = folder.appendingPathComponent("current")
        try FileManager.default.removeItem(at: pointer) // Crash-equivalent complete sealed base, no published pointer.
        let orphan = try #require(try await store.discover().first)
        #expect(orphan.isProtected && orphan.insertionUnconfirmed)
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await store.load(value.id) }
        let loaded = try #require(try await store.load(value.id, access: key))
        #expect(loaded.drawingData == value.drawingData && loaded.originalNoteID == value.originalNoteID && loaded.generation == 7)
        #expect(loaded.state == .insertionUnconfirmed)
        #expect(try await !store.checkpoint(draft(id: value.id, generation: 6), protection: .sealed(key)))
        let bad = Data("corrupt current pointer".utf8)
        try bad.write(to: pointer)
        await #expect(throws: (any Error).self) { try await store.discover() }
        await #expect(throws: (any Error).self) { try await store.load(value.id, access: key) }
        await #expect(throws: (any Error).self) { try await store.claim(value.id, owner: UUID()) }
        await #expect(throws: (any Error).self) { try await store.hasProtectedDrafts() }
        #expect(try Data(contentsOf: pointer) == bad)
        #expect(files(folder).contains { $0.pathExtension == "base" })
    }
    @Test func suspensionBlocksPeerWritesAndInvalidatesQueuedWritesEvenAfterResume() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let held = DraftCheckpointHold()
        let first = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let peer = MobileSketchDraftStore(root: url, libraryID: "fixture-library", beforeCheckpoint: { await held.waitIfArmed() })
        let value = draft()
        #expect(try await first.checkpoint(value, protection: .plain))
        await held.arm()
        let queued = Task { try await peer.checkpoint(draft(id: value.id, generation: 1), protection: .plain) }
        try await waitForHold(held)
        let one = try await first.suspendWrites(), two = try await first.suspendWrites()
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await peer.checkpoint(draft(generation: 0), protection: .plain) }
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await first.checkpoint(draft(generation: 0), protection: .plain) }
        await first.resumeWrites(one)
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await peer.checkpoint(draft(generation: 0), protection: .plain) }
        await first.resumeWrites(two)
        await held.release()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        #expect(try await first.load(value.id)?.generation == 0)
        #expect(try await peer.checkpoint(draft(id: value.id, generation: 2), protection: .plain))
        try await first.delete(value.id)
        #expect(try await !peer.checkpoint(draft(id: value.id, generation: 3), protection: .plain))
    }

    @Test func externallyCapturedPlainDecisionCannotPublishAfterPeerNoteLock() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let first = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), peer = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let value = draft(), decision = first.captureAdmission(for: value.originalNoteID)
        let transition = peer.beginProtectionTransition(noteID: try #require(value.originalNoteID))
        peer.completeProtectionTransition(transition, isProtected: true)
        await #expect(throws: CancellationError.self) { try await first.checkpoint(value, protection: .plain, admission: decision) }
        #expect(try await first.discover().isEmpty)
        let (db, key) = try access(at: url); defer { try? db.pool.close() }
        let current = first.captureAdmission(for: value.originalNoteID)
        #expect(try await first.checkpoint(value, protection: .sealed(key), admission: current))
    }
    @Test func plainUpgradeRevocationRetainsLastSnapshotThenFreshAccessSealsAndRetiresPlaintext() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (db, key) = try access(at: url); defer { try? db.pool.close() }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        key.revoke()
        await #expect(throws: (any Error).self) { try await store.upgradePlainDrafts(noteID: #require(value.originalNoteID), access: key) }
        #expect(try await store.load(value.id)?.drawingData == value.drawingData)
        #expect(try await store.discover().first?.isProtected == false)
        let fresh = try NotePrivacy(store: NoteStore(db: db, notifier: nil, paths: AppPaths(root: url))).unlock(password: "fixture-password")
        _ = try await store.upgradePlainDrafts(noteID: #require(value.originalNoteID), access: fresh)
        #expect(try await store.discover().first?.isProtected == true)
        #expect(try await store.load(value.id, access: fresh)?.drawingData == value.drawingData)
        for file in files(namespace(url)) where file.pathExtension == "base" { #expect(try Data(contentsOf: file).starts(with: Data("BJB1:".utf8))) }
    }
    @Test func launchSweepRemovesOnlyMarkedNoncurrentCandidatesAndPreservesOrphanRecovery() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        let base = try #require(files(namespace(url)).first { $0.pathExtension == "base" }), current = base.deletingLastPathComponent()
        let parent = current.deletingLastPathComponent(), stale = parent.appendingPathComponent(UUID().uuidString), orphan = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: current, to: stale)
        try FileManager.default.copyItem(at: current, to: orphan)
        try Data([1]).write(to: stale.appendingPathComponent("discarded"))
        try await store.sweepDiscardedCandidates()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path) && FileManager.default.fileExists(atPath: base.path))
        try FileManager.default.removeItem(at: parent.appendingPathComponent("current"))
        try await store.sweepDiscardedCandidates()
        #expect(try await store.load(value.id)?.drawingData == value.drawingData)
    }

    @Test func relaunchDiscoverySweepsDiscardedCandidatesButPreservesClaimsCurrentAndValidOrphans() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let first = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await first.checkpoint(value, protection: .plain))
        let base = try #require(files(namespace(url)).first { $0.pathExtension == "base" })
        let current = base.deletingLastPathComponent(), parent = current.deletingLastPathComponent()
        let discarded = parent.appendingPathComponent(UUID().uuidString), orphan = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: current, to: discarded)
        try FileManager.default.copyItem(at: current, to: orphan)
        try Data([1]).write(to: discarded.appendingPathComponent("discarded"))
        // Even a marker on the current snapshot must never authorize its deletion.
        try Data([1]).write(to: current.appendingPathComponent("discarded"))
        let owner = UUID()
        #expect(try await first.claim(value.id, owner: owner))
        let relaunched = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        #expect(try await relaunched.discover().map(\.id) == [value.id])
        #expect(FileManager.default.fileExists(atPath: discarded.path), "Discovery must preserve a live cross-store claim")
        #expect(!(try await relaunched.claim(value.id, owner: UUID())))
        await first.release(value.id, owner: owner)
        // Production discovery itself performs cleanup; the test never calls sweep directly.
        #expect(try await relaunched.discover().map(\.id) == [value.id])
        #expect(!FileManager.default.fileExists(atPath: discarded.path))
        #expect(FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: orphan.path))
        #expect(try await relaunched.load(value.id)?.drawingData == value.drawingData)
        try FileManager.default.removeItem(at: parent.appendingPathComponent("current"))
        // A fresh launch must offer the unmarked orphan rather than the discarded current.
        let anotherLaunch = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        #expect(try await anotherLaunch.discover().map(\.id) == [value.id])
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(try await anotherLaunch.load(value.id)?.drawingData == value.drawingData)
    }

    @Test func discoveryDuringExclusiveAdmissionRemainsReadOnlyAndRetriesSweepAfterResume() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library"), value = draft()
        #expect(try await store.checkpoint(value, protection: .plain))
        let base = try #require(files(namespace(url)).first { $0.pathExtension == "base" })
        let current = base.deletingLastPathComponent(), stale = current.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: current, to: stale)
        try Data([1]).write(to: stale.appendingPathComponent("discarded"))
        let suspension = try await store.suspendWrites()
        #expect(try await store.discover().map(\.id) == [value.id])
        #expect(FileManager.default.fileExists(atPath: stale.path))
        await store.resumeWrites(suspension)
        #expect(try await store.discover().map(\.id) == [value.id])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try await store.load(value.id)?.drawingData == value.drawingData)
    }

    @Test func postRenameDurabilityFailurePreservesNewAndOldSnapshotsForLoadAndRetry() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let armed = Mutex(false)
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library", afterPointerRename: {
            if armed.withLock({ value in let old = value; value = false; return old }) { throw CocoaError(.fileWriteUnknown) }
        })
        let initial = draft()
        #expect(try await store.checkpoint(initial, protection: .plain))
        armed.withLock { $0 = true }
        let replacement = draft(id: initial.id, generation: 1, noteID: try #require(initial.originalNoteID))
        await #expect(throws: CocoaError.self) { try await store.checkpoint(replacement, protection: .plain) }
        #expect(try await store.load(initial.id) == replacement)
        #expect(files(namespace(url)).filter { $0.pathExtension == "base" }.count == 2)
        let reopened = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        #expect(try await reopened.load(initial.id) == replacement)
        #expect(try await reopened.checkpoint(draft(id: initial.id, generation: 2, noteID: #require(initial.originalNoteID)), protection: .plain))
        #expect(files(namespace(url)).filter { $0.pathExtension == "base" }.count == 1)
    }

    @Test func draftCapacityExplainsHowToRecoverWithoutDiscardingExistingDrafts() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        for _ in 0..<64 { #expect(try await store.checkpoint(draft(), protection: .plain)) }
        let extra = draft()
        do {
            _ = try await store.checkpoint(extra, protection: .plain)
            Issue.record("A full draft store must refuse a new draft")
        } catch MobileSketchDraftStore.Failure.tooManyDrafts {
            #expect(MobileSketchDraftStore.Failure.tooManyDrafts.localizedDescription.contains("Recovered Sketches"))
        }
        #expect(try await store.discover().count == 64)
    }

    @Test func claimedDeletionRejectsWrongOwnerAndStaleEpochWithoutDeletingDraft() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let peer = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let value = draft(), owner = UUID(), other = UUID()
        #expect(try await store.reserveFresh(value.id, owner: owner))
        #expect(try await store.checkpoint(value, protection: .plain))
        #expect(try await !store.deleteClaimed(value.id, owner: other))
        #expect(try await !peer.deleteClaimed(value.id, owner: owner))
        #expect(try await !peer.claim(value.id, owner: other))
        let suspension = try await store.suspendWrites()
        await #expect(throws: MobileSketchDraftStore.Failure.suspended) { try await store.deleteClaimed(value.id, owner: owner) }
        await store.resumeWrites(suspension)
        #expect(try await !store.deleteClaimed(value.id, owner: owner))
        #expect(try await store.load(value.id) == value)
        await store.release(value.id, owner: owner)
        #expect(try await peer.claim(value.id, owner: other))
        #expect(try await peer.deleteClaimed(value.id, owner: other))
        #expect(try await store.load(value.id) == nil)
    }

    @Test func claimedDeleteAfterOwnershipTransferFencesHeldOldCheckpoint() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let held = DraftCheckpointHold()
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library", beforeCheckpoint: { await held.waitIfArmed() })
        let peer = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let value = draft(), first = UUID(), second = UUID()
        #expect(try await store.reserveFresh(value.id, owner: first))
        #expect(try await store.checkpoint(value, protection: .plain))
        await held.arm()
        let late = draft(id: value.id, generation: 2, noteID: try #require(value.originalNoteID))
        let pending = Task { try await store.checkpoint(late, protection: .plain) }
        try await waitForHold(held)
        await store.release(value.id, owner: first)
        #expect(try await peer.claim(value.id, owner: second))
        #expect(try await !store.deleteClaimed(value.id, owner: first))
        #expect(try await peer.load(value.id) == value)
        #expect(try await peer.deleteClaimed(value.id, owner: second))
        await held.release()
        #expect(try await !pending.value)
        #expect(try await store.load(value.id) == nil)
        #expect(try await !store.checkpoint(late, protection: .plain))
    }

    @Test func heldClaimAuthenticationCannotBlockSynchronousPrivacyTransition() async throws {
        let url = try root()
        let library = try MobileLibrary(paths: AppPaths(root: url))
        defer { try? library.close(); try? FileManager.default.removeItem(at: url) }
        let note = try library.store.create(text: "# Lock while authenticating draft")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let gate = DraftClaimAuthenticationHold()
        let store = MobileSketchDraftStore(root: url, libraryID: MobileCardPublication.libraryID(for: library.paths),
            beforeClaimAuthentication: { gate.hold() })
        let value = draft(noteID: note.id), owner = UUID()
        #expect(try await store.reserveFresh(value.id, owner: owner))
        #expect(try await store.checkpoint(value, protection: .plain))
        let suspension = try await store.suspendWrites(); await store.resumeWrites(suspension)
        let admission = store.captureAdmission(for: value.originalNoteID)
        let renewal = Task { try await store.renewClaim(value.id, owner: owner, protection: .plain, admission: admission) }
        for _ in 0..<500 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)
        // Bounds the failure mode of the old implementation without hanging the
        // MainActor: it could not lock until this watchdog released authentication.
        let watchdog = Task.detached { try await Task.sleep(for: .seconds(2)); gate.release() }
        defer { watchdog.cancel(); gate.release() }
        try library.lockNote(note.id)
        let lockedBeforeDecodeRelease = !gate.released
        gate.release(); watchdog.cancel()
        _ = try? await watchdog.value
        await #expect(throws: CancellationError.self) { _ = try await renewal.value }
        #expect(lockedBeforeDecodeRelease, "Actual privacy lock must not wait for draft I/O/decode")
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        let access = try #require(library.privateAccess)
        // Actual lockNote also schedules a nonblocking plain->sealed upgrade on
        // the library's store. Wait out ONLY its legitimate per-draft lock conflict;
        // wrong keys, corrupt bytes and every other failure still fail this test.
        var durable: MobileSketchDraftStore.Draft?
        for _ in 0..<200 {
            do { durable = try await store.load(value.id, access: access); break }
            catch MobileSketchDraftStore.Failure.busy { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(durable?.drawingData == value.drawingData)
        await library.sketchDraftStore.waitForWrites()
    }

    @Test(arguments: [false, true])
    func claimRenewalRejectsPointerOrEpochReplacementDuringAuthentication(replaceEpoch: Bool) async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = DraftClaimAuthenticationHold()
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library", beforeClaimAuthentication: { gate.hold() })
        let value = draft(), owner = UUID()
        #expect(try await store.reserveFresh(value.id, owner: owner))
        #expect(try await store.checkpoint(value, protection: .plain))
        let suspension = try await store.suspendWrites(); await store.resumeWrites(suspension)
        let current = namespace(url).appendingPathComponent("Drafts").appendingPathComponent(value.id.uuidString).appendingPathComponent("current")
        let changedFile = replaceEpoch ? namespace(url).appendingPathComponent("Admission.epoch") : current
        let original = try Data(contentsOf: changedFile), admission = store.captureAdmission(for: value.originalNoteID)
        let pending = Task { try await store.renewClaim(value.id, owner: owner, protection: .plain, admission: admission) }
        for _ in 0..<500 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)
        // Even identical JSON in a replacement inode must not validate the prior read.
        try (replaceEpoch ? Data(UUID().uuidString.utf8) : original).write(to: changedFile, options: .atomic)
        gate.release()
        await #expect(throws: MobileSketchDraftStore.Failure.busy) { _ = try await pending.value }
        #expect(try await store.load(value.id) == value)
    }

    @Test(arguments: [false, true])
    func unchangedAuthenticatedClaimAvoidsPayloadDecodeButChangedEpochAuthenticatesAgain(sealed: Bool) async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let (database, key) = try access(at: url)
        defer { try? database.pool.close() }
        let strategy: MobileSketchDraftStore.Protection = sealed ? .sealed(key) : .plain
        let calls = Mutex(0)
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library", beforeClaimAuthentication: { calls.withLock { $0 += 1 } })
        let value = draft(), owner = UUID()
        #expect(try await store.reserveFresh(value.id, owner: owner))
        #expect(try await store.checkpoint(value, protection: strategy))
        for _ in 0..<3 {
            #expect(try await store.renewClaim(value.id, owner: owner, protection: strategy,
                admission: store.captureAdmission(for: value.originalNoteID)))
        }
        #expect(calls.withLock { $0 } == 0, "Own authenticated checkpoint needs no payload reread")
        let suspension = try await store.suspendWrites(); await store.resumeWrites(suspension)
        #expect(try await store.renewClaim(value.id, owner: owner, protection: strategy,
            admission: store.captureAdmission(for: value.originalNoteID)))
        #expect(calls.withLock { $0 } == 1)
        #expect(try await store.renewClaim(value.id, owner: owner, protection: strategy,
            admission: store.captureAdmission(for: value.originalNoteID)))
        #expect(calls.withLock { $0 } == 1)
        let next = draft(id: value.id, generation: 1, noteID: try #require(value.originalNoteID))
        #expect(try await store.checkpoint(next, protection: strategy))
        #expect(try await store.renewClaim(value.id, owner: owner, protection: strategy,
            admission: store.captureAdmission(for: value.originalNoteID)))
        #expect(calls.withLock { $0 } == 1, "New own checkpoint must refresh trusted file identities")
        if sealed {
            let beforeRevocation = calls.withLock { $0 }
            key.revoke()
            await #expect(throws: (any Error).self) {
                try await store.renewClaim(value.id, owner: owner, protection: strategy,
                    admission: store.captureAdmission(for: value.originalNoteID))
            }
            #expect(calls.withLock { $0 } == beforeRevocation, "Cached access still checks key revocation")
        }
    }

    @Test func staleClaimCannotBeReleasedOrTakenByAnotherSceneAfterPrivacyBarrier() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let peer = MobileSketchDraftStore(root: url, libraryID: "fixture-library")
        let value = draft(), owner = UUID(), intruder = UUID()
        #expect(try await store.reserveFresh(value.id, owner: owner))
        #expect(try await !store.claim(value.id, owner: intruder), "Missing first checkpoint must not release a fresh reservation")
        #expect(try await !store.reserveFresh(value.id, owner: intruder))
        #expect(try await !peer.reserveFresh(value.id, owner: intruder))
        #expect(try await store.checkpoint(value, protection: .plain))
        let suspension = try await store.suspendWrites(); await store.resumeWrites(suspension)
        #expect(try await !store.claim(value.id, owner: intruder))
        #expect(try await !store.claim(value.id, owner: intruder), "Repeated attempts must not release the live owner's flock")
        #expect(try await !peer.claim(value.id, owner: intruder))
        #expect(try await !store.reserveFresh(value.id, owner: intruder))
        #expect(try await store.renewClaim(value.id, owner: owner, protection: .plain,
            admission: store.captureAdmission(for: value.originalNoteID)))
        #expect(try await store.claim(value.id, owner: owner))
        await store.release(value.id, owner: owner)
        #expect(try await peer.claim(value.id, owner: intruder))
        await peer.release(value.id, owner: intruder)
    }

    private func waitForHold(_ held: DraftCheckpointHold) async throws {
        for _ in 0..<500 { if await held.started { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CancellationError()
    }
}

private actor DraftCheckpointHold {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }
    func arm() { armed = true }
    func waitIfArmed() async {
        guard armed else { return }; armed = false
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class DraftClaimAuthenticationHold: Sendable {
    private struct State { var entered = false; var released = false }
    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { state.withLock { $0.entered } }
    var released: Bool { state.withLock { $0.released } }
    func hold() { state.withLock { $0.entered = true }; _ = semaphore.wait(timeout: .now() + 10) }
    func release() { state.withLock { $0.released = true }; semaphore.signal() }
}
