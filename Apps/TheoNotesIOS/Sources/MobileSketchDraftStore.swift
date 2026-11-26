// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Darwin
import Foundation
import TheoNotesCore
import Synchronization

/// Local recovery only, deliberately separate from the note Journal replay directory.
/// Callers gate restore UI on App Lock and obtain sealed access through normal vault unlock.
actor MobileSketchDraftStore {
    static let maximumDrawingBytes = 8 * 1024 * 1024
    private static let maximumRecordBytes = 24 * 1024 * 1024
    private static let maximumDrafts = 64
    enum Failure: LocalizedError, Equatable {
        case invalid, corrupt, tooLarge, tooManyDrafts, keyRequired, revoked, busy, suspended, protectionDowngrade, cleanupFailed, journalProtectionUnavailable(String?)
        var errorDescription: String? {
            switch self {
            case .tooManyDrafts: "There are too many saved sketch drafts. Open Recovered Sketches and restore or discard a draft, then try again."
            case .tooLarge: "This sketch is too large to save as a draft."
            case .keyRequired, .revoked: "Unlock locked notes to save this sketch draft."
            case .busy, .suspended: "Sketch drafts are busy. Try again shortly."
            case .protectionDowngrade: "This protected sketch draft cannot be saved without its notes password."
            case .cleanupFailed: "The sketch draft was kept, but older files could not be removed. Try again."
            case .journalProtectionUnavailable: "This device could not protect the sketch draft. Your drawing remains open."
            case .invalid, .corrupt: "This sketch draft cannot be read safely. It has been kept."
            }
        }
    }
    enum Protection: Sendable { case plain, sealed(LockedNoteAccess) }
    enum State: String, Codable, Sendable { case editing, insertionUnconfirmed }
    struct Draft: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        var generation: Int
        let originalNoteID: String?
        let sourceFilename: String?
        let sourceSHA256: String?
        let drawingData: Data
        let canvasSize: CGSize
        var state: State
        init(id: UUID = UUID(), generation: Int, originalNoteID: String?, sourceFilename: String? = nil,
             sourceSHA256: String? = nil, drawingData: Data, canvasSize: CGSize, state: State = .editing) {
            self.id = id; self.generation = generation; self.originalNoteID = originalNoteID
            self.sourceFilename = sourceFilename; self.sourceSHA256 = sourceSHA256
            self.drawingData = drawingData; self.canvasSize = canvasSize; self.state = state
        }
    }
    struct Summary: Sendable { let id: UUID; let generation: Int; let isProtected: Bool; let insertionUnconfirmed: Bool }
    struct AdmissionToken: Sendable {
        fileprivate let namespace: String
        fileprivate let noteID: String?
        fileprivate let epoch: UUID
    }
    struct ProtectionTransition: Sendable { fileprivate let noteID: String; fileprivate let id: UUID }
    private final class NoteFence: Sendable {
        struct State: Sendable { var epoch = UUID(); var transitions: [String: UUID] = [:]; var protectedNotes: Set<String> = [] }
        let state = Mutex(State())
    }
    private final class WeakFence: @unchecked Sendable {
        weak var value: NoteFence?
        init(_ value: NoteFence) { self.value = value }
    }
    private nonisolated static let fences = Mutex<[String: WeakFence]>([:])
    private nonisolated let fence: NoteFence
    private nonisolated let namespaceID: String
    nonisolated func captureAdmission(for noteID: String?) -> AdmissionToken {
        fence.state.withLock { AdmissionToken(namespace: namespaceID, noteID: noteID, epoch: $0.epoch) }
    }
    /// Synchronous: call BEFORE changing note privacy, never enqueue this behind the actor hop.
    nonisolated func beginProtectionTransition(noteID: String) -> ProtectionTransition {
        fence.state.withLock {
            $0.epoch = UUID()
            let id = UUID(); $0.transitions[noteID] = id
            return ProtectionTransition(noteID: noteID, id: id)
        }
    }
    nonisolated func completeProtectionTransition(_ token: ProtectionTransition, isProtected: Bool) {
        fence.state.withLock {
            guard $0.transitions[token.noteID] == token.id else { return }
            $0.transitions.removeValue(forKey: token.noteID)
            if isProtected { $0.protectedNotes.insert(token.noteID) } else { $0.protectedNotes.remove(token.noteID) }
        }
    }
    nonisolated private func validateAdmission<Value>(_ token: AdmissionToken?, draft: Draft, sealed: Bool,
                                                      _ action: () throws -> Value) throws -> Value {
        try fence.state.withLock { state in
            if let token {
                guard token.namespace == namespaceID, token.noteID == draft.originalNoteID, token.epoch == state.epoch else { throw CancellationError() }
            }
            if let noteID = draft.originalNoteID {
                guard state.transitions[noteID] == nil,
                      !state.protectedNotes.contains(noteID) || sealed else { throw CancellationError() }
            }
            return try action()
        }
    }
    private struct Record: Codable { let version: Int; let libraryID: String; let draft: Draft }
    private struct Pointer: Codable { let version: Int; let generation: Int; let snapshot: UUID; let isProtected: Bool; let insertionUnconfirmed: Bool }
    private let directory: URL
    private let libraryID: String
    private let beforeCheckpoint: (@Sendable () async throws -> Void)?
    private let afterPointerRename: (@Sendable () throws -> Void)?
    private let beforeClaimAuthentication: (@Sendable () throws -> Void)?
    private var epoch = 0
    private var pendingWrites = 0
    private var pendingIDs: [UUID: Int] = [:]
    private struct ClaimAuthentication: Sendable {
        let noteID: String?
        let fenceEpoch: UUID
        let access: ObjectIdentifier?
        let identities: [(URL, FileIdentity?)]
    }
    private struct Claim: Sendable {
        let owner: UUID
        let descriptor: Int32
        let admissionEpoch: String
        var authentication: ClaimAuthentication? = nil
    }
    private var claims: [UUID: Claim] = [:]
    private var suspensions: Set<UUID> = []
    private var admissionDescriptor: Int32?
    deinit {
        if let fd = admissionDescriptor { _ = flock(fd, LOCK_UN); close(fd) }
        for value in claims.values { _ = flock(value.descriptor, LOCK_UN); close(value.descriptor) }
    }
    var hasPendingWrites: Bool { pendingWrites > 0 }
    func waitForWrites() async { while pendingWrites > 0 { await Task.yield() } }
    func claim(_ id: UUID, owner: UUID) throws -> Bool {
        try writerAdmission {
            try locked(id) {
                guard !isDeleted(id), try pointer(id) != nil || orphanSummary(id) != nil else { return false }
                return try acquireClaim(id, owner: owner)
            }
        }
    }
    /// Reserve before displaying a fresh canvas or launching its first checkpoint.
    func reserveFresh(_ id: UUID, owner: UUID) throws -> Bool {
        try writerAdmission {
            try locked(id) {
                guard !isDeleted(id) else { return false }
                if claims[id] != nil { return try acquireClaim(id, owner: owner) }
                guard try pointer(id) == nil, try orphanSummary(id) == nil else { return false }
                return try acquireClaim(id, owner: owner)
            }
        }
    }
    private func acquireClaim(_ id: UUID, owner: UUID) throws -> Bool {
        if let existing = claims[id] {
            // Stale admission is not abandoned ownership. Never drop the owner's
            // exclusive flock on another scene's claim attempt; only explicit release
            // or authenticated renewal may change it.
            guard existing.owner == owner, existing.admissionEpoch == (try readAdmissionEpoch()) else { return false }
            return true
        }
        let claimEpoch = try readAdmissionEpoch()
        let fd = open(directory.appendingPathComponent("Claims").appendingPathComponent(id.uuidString).path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw Failure.corrupt }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        claims[id] = Claim(owner: owner, descriptor: fd, admissionEpoch: claimEpoch)
        return true
    }
    /// A NEW host checkpoint may renew its own held lease after a completed vault
    /// admission barrier. The host must supply freshly authorized protection and the
    /// token captured before that checkpoint's policy decision, never retry an old job.
    func renewClaim(_ id: UUID, owner: UUID, protection: Protection, admission: AdmissionToken) throws -> Bool {
        try writerAdmission {
            try locked(id) {
                guard !isDeleted(id), let existing = claims[id], existing.owner == owner else { return false }
                let access: LockedNoteAccess?
                switch protection { case .plain: access = nil; case .sealed(let value): access = value }
                if let access { _ = try access.journalKey() }
                let stub = Draft(id: id, generation: 0, originalNoteID: admission.noteID,
                    drawingData: Data([1]), canvasSize: CGSize(width: 1, height: 1))
                try validateAdmission(admission, draft: stub, sealed: access != nil) { () }
                let diskEpoch = try readAdmissionEpoch()
                if let authenticated = existing.authentication,
                   existing.admissionEpoch == diskEpoch,
                   authenticated.noteID == admission.noteID, authenticated.fenceEpoch == admission.epoch,
                   authenticated.access == access.map(ObjectIdentifier.init),
                   try identitiesMatch(authenticated.identities) {
                    return try validateAdmission(admission, draft: stub, sealed: access != nil) {
                        if let access { _ = try access.journalKey() }
                        guard try identitiesMatch(authenticated.identities) else { throw Failure.busy }
                        return true
                    }
                }
                // Admission/per-draft flocks serialize cooperating writers throughout the
                // read, but the synchronous note privacy fence MUST remain available.
                let folder = draftDirectory(id)
                var identities: [(URL, FileIdentity?)] = []
                func remember(_ url: URL) throws { identities.append((url, try fileIdentity(url))) }
                try remember(directory.appendingPathComponent("Admission.epoch"))
                guard diskEpoch == (try readAdmissionEpoch()) else { throw Failure.busy }
                try remember(folder)
                try remember(folder.appendingPathComponent("current"))
                let current = try pointer(id)
                let snapshots: [(URL, Bool)]
                if let current {
                    snapshots = [(folder.appendingPathComponent(current.snapshot.uuidString), current.isProtected)]
                } else if FileManager.default.fileExists(atPath: folder.path) {
                    snapshots = try snapshotFolders(id).map { snapshot in
                        let bytes = try boundedData(snapshot.appendingPathComponent(id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
                        return (snapshot, bytes.starts(with: Data("BJB1:".utf8)))
                    }
                } else { snapshots = [] }
                for (snapshot, _) in snapshots {
                    try remember(snapshot)
                    try remember(snapshot.appendingPathComponent(id.uuidString + ".base"))
                    try remember(snapshot.appendingPathComponent(id.uuidString + ".jsonl"))
                }
                try beforeClaimAuthentication?()
                for (snapshot, sealed) in snapshots {
                    guard !sealed || access != nil else { throw Failure.protectionDowngrade }
                    let saved = try loadSnapshot(snapshot, id: id, isProtected: sealed, access: access)
                    guard saved.originalNoteID == admission.noteID else { throw Failure.invalid }
                }
                // Only bounded metadata/key checks occur under the note fence. No
                // payload reads, decryption, JSON decode, or directory scans live here.
                return try validateAdmission(admission, draft: stub, sealed: access != nil) {
                    if let access { _ = try access.journalKey() }
                    for (url, identity) in identities {
                        guard try fileIdentity(url) == identity else { throw Failure.busy }
                    }
                    claims[id] = Claim(owner: owner, descriptor: existing.descriptor, admissionEpoch: diskEpoch,
                        authentication: ClaimAuthentication(noteID: admission.noteID, fenceEpoch: admission.epoch,
                            access: access.map(ObjectIdentifier.init), identities: identities))
                    return true
                }
            }
        }
    }
    func release(_ id: UUID, owner: UUID) { if claims[id]?.owner == owner { releaseClaim(id) } }
    private func releaseClaim(_ id: UUID) {
        guard let value = claims.removeValue(forKey: id) else { return }
        _ = flock(value.descriptor, LOCK_UN); close(value.descriptor)
    }
    func suspendWrites() throws -> UUID {
        epoch += 1
        fence.state.withLock { $0.epoch = UUID() }
        if admissionDescriptor == nil {
            try prepareDirectories()
            let fd = try admissionFile()
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
            admissionDescriptor = fd
        }
        do {
            // Persist invalidation across store instances/processes, including queued jobs
            // which resume only AFTER this suspension has ended.
            try atomic(Data(UUID().uuidString.utf8), to: directory.appendingPathComponent("Admission.epoch"))
        } catch {
            if suspensions.isEmpty, let fd = admissionDescriptor {
                admissionDescriptor = nil; _ = flock(fd, LOCK_UN); close(fd)
            }
            throw error
        }
        let token = UUID(); suspensions.insert(token); return token
    }
    func resumeWrites(_ token: UUID) {
        guard suspensions.remove(token) != nil, suspensions.isEmpty, let fd = admissionDescriptor else { return }
        admissionDescriptor = nil; _ = flock(fd, LOCK_UN); close(fd)
    }

    init(root: URL, libraryID: String, beforeCheckpoint: (@Sendable () async throws -> Void)? = nil,
         afterPointerRename: (@Sendable () throws -> Void)? = nil,
         beforeClaimAuthentication: (@Sendable () throws -> Void)? = nil) {
        let namespace = SHA256.hash(data: Data(libraryID.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent("SketchDrafts", isDirectory: true).appendingPathComponent(namespace, isDirectory: true)
        let identity = root.standardizedFileURL.resolvingSymlinksInPath().path + "/SketchDrafts/" + namespace
        namespaceID = identity
        fence = Self.fences.withLock { registry in
            if let existing = registry[identity]?.value { return existing }
            if registry.count > 64 { registry = registry.filter { $0.value.value != nil } }
            let value = NoteFence(); registry[identity] = WeakFence(value); return value
        }
        self.libraryID = libraryID
        self.beforeCheckpoint = beforeCheckpoint
        self.afterPointerRename = afterPointerRename
        self.beforeClaimAuthentication = beforeClaimAuthentication
    }
    func invalidatePendingWrites() { epoch += 1; fence.state.withLock { $0.epoch = UUID() } }

    /// False means a stale generation/deleted draft. No stale operation can resurrect a tombstone.
    @discardableResult func checkpoint(_ draft: Draft, protection: Protection, admission: AdmissionToken? = nil) async throws -> Bool {
        try validate(draft)
        let isSealed: Bool
        switch protection { case .plain: isSealed = false; case .sealed: isSealed = true }
        try validateAdmission(admission, draft: draft, sealed: isSealed) { () }
        let admissionEpoch = try writerAdmission { try readAdmissionEpoch() }
        pendingWrites += 1; pendingIDs[draft.id, default: 0] += 1
        defer {
            pendingWrites -= 1
            pendingIDs[draft.id, default: 0] -= 1
            if pendingIDs[draft.id] == 0 { pendingIDs.removeValue(forKey: draft.id) }
        }
        let token = epoch
        try await beforeCheckpoint?()
        try Task.checkCancellation()
        guard token == epoch else { throw CancellationError() }
        return try writerAdmission {
            guard admissionEpoch == (try readAdmissionEpoch()),
                  claims[draft.id].map({ $0.admissionEpoch == admissionEpoch }) ?? true else { throw CancellationError() }
            return try locked(draft.id) {
            guard !isDeleted(draft.id) else { return false }
            try validateAdmission(admission, draft: draft, sealed: isSealed) { () }
            let old = try pointer(draft.id)
            if let old, draft.generation <= old.generation { return false }
            var savedDraft = draft
            if old?.insertionUnconfirmed == true { savedDraft.state = .insertionUnconfirmed }
            let access: LockedNoteAccess?
            switch protection { case .plain: access = nil; case .sealed(let value): access = value }
            if old == nil, FileManager.default.fileExists(atPath: draftDirectory(draft.id).path) {
                for folder in try snapshotFolders(draft.id) {
                    let raw = try boundedData(folder.appendingPathComponent(draft.id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
                    let orphan = try loadSnapshot(folder, id: draft.id, isProtected: raw.starts(with: Data("BJB1:".utf8)), access: access)
                    guard draft.generation > orphan.generation else { return false }
                    savedDraft.state = .insertionUnconfirmed
                }
            }
            let encoded = try JSONEncoder().encode(Record(version: 1, libraryID: libraryID, draft: savedDraft))
            guard encoded.count <= Self.maximumRecordBytes / 2 else { throw Failure.tooLarge }
            guard old?.isProtected != true || access != nil else { throw Failure.protectionDowngrade }
            let key = try access?.journalKey() // Operation lifetime only; never cached by this store.
            let folder = draftDirectory(draft.id), snapshotID = UUID()
            if !FileManager.default.fileExists(atPath: folder.path) {
                guard try boundedChildren(directory.appendingPathComponent("Drafts"), maximum: Self.maximumDrafts).count < Self.maximumDrafts else { throw Failure.tooManyDrafts }
            }
            try makeDirectory(folder)
            let snapshots = try boundedChildren(folder, maximum: 32).filter { UUID(uuidString: $0.lastPathComponent) != nil }
            let snapshot = folder.appendingPathComponent(snapshotID.uuidString, isDirectory: true)
            try makeDirectory(snapshot)
            var published = false
            defer {
                if !published {
                    // An already-started Complete/excluded candidate may finish
                    // after lock. It cannot publish; a durable marker allows safe launch cleanup.
                    try? atomic(Data([1]), to: snapshot.appendingPathComponent("discarded"))
                    try? FileManager.default.removeItem(at: snapshot)
                }
            }
            // Prove the directory's inherited protection before journal code creates its
            // default-attribute .jsonl/.base.tmp; never stage plaintext in an unprotected folder.
            try verifyJournalCreationProtection(snapshot, id: draft.id)
            let journal = try EditJournal(directory: snapshot, noteId: draft.id.uuidString, encryptionKey: key,
                creationAttributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600])
            try journal.writeBase(JournalBase(storeRevision: draft.generation,
                baseText: String(decoding: encoded, as: UTF8.self)))
            try protectFiles(snapshot)
            try Task.checkCancellation()
            // Revoked during encryption: leave the previous durable pointer untouched.
            if let access { _ = try access.journalKey() }
            guard token == epoch else { throw CancellationError() }
            let next = Pointer(version: 1, generation: draft.generation, snapshot: snapshotID, isProtected: access != nil, insertionUnconfirmed: savedDraft.state == .insertionUnconfirmed)
            let pointerData = try JSONEncoder().encode(next)
            try validateAdmission(admission, draft: draft, sealed: isSealed) {
                try atomic(pointerData, to: folder.appendingPathComponent("current"), afterRename: {
                    // Rename is the irreversible visibility boundary, even if directory fsync
                    // fails afterward. Preserve both this candidate AND prior generations.
                    published = true
                    try self.afterPointerRename?()
                })
            }
            // Successful plain->sealed upgrade must retire ALL earlier plaintext generations.
            // If cleanup fails callers must not acknowledge a note protection transition.
            for previous in snapshots {
                do { try FileManager.default.removeItem(at: previous) }
                catch { throw Failure.cleanupFailed }
            }
            if var claim = claims[draft.id] {
                let cacheAdmission = admission ?? captureAdmission(for: draft.originalNoteID)
                let urls = [directory.appendingPathComponent("Admission.epoch"), folder,
                    folder.appendingPathComponent("current"), snapshot,
                    snapshot.appendingPathComponent(draft.id.uuidString + ".base"),
                    snapshot.appendingPathComponent(draft.id.uuidString + ".jsonl")]
                if let identities = try? urls.map({ ($0, try fileIdentity($0)) }) {
                    claim.authentication = ClaimAuthentication(noteID: draft.originalNoteID, fenceEpoch: cacheAdmission.epoch,
                        access: access.map(ObjectIdentifier.init), identities: identities)
                    claims[draft.id] = claim
                }
            }
            return true
        } }
    }

    func discover() throws -> [Summary] {
        // App startup and every recovery entry point discover through this method. Cleanup
        // must precede orphan selection so a known discarded candidate is never offered.
        do { try sweepDiscardedCandidates() }
        catch Failure.suspended {
            // Destructive-transition guards also discover while holding exclusive admission.
            // Keep that inspection read-only; the next admitted recovery retries cleanup.
        }
        try prepareDirectories()
        return try boundedChildren(directory.appendingPathComponent("Drafts"), maximum: Self.maximumDrafts).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { throw Failure.corrupt }
            return try locked(id) {
                guard !isDeleted(id) else { return nil }
                guard let pointer = try pointer(id) else { return try orphanSummary(id) }
                return Summary(id: id, generation: pointer.generation, isProtected: pointer.isProtected, insertionUnconfirmed: pointer.insertionUnconfirmed)
            }
        }
    }

    /// Missing/wrong/revoked keys and corrupt records leave recovery files exactly in place.
    func load(_ id: UUID, access: LockedNoteAccess? = nil) throws -> Draft? {
        try locked(id) {
            guard !isDeleted(id) else { return nil }
            if let current = try pointer(id) {
                let draft = try loadSnapshot(draftDirectory(id).appendingPathComponent(current.snapshot.uuidString), id: id,
                                             isProtected: current.isProtected, access: access)
                guard draft.generation == current.generation,
                      (draft.state == .insertionUnconfirmed) == current.insertionUnconfirmed else { throw Failure.corrupt }
                return draft
            }
            // No pointer ever published (e.g. crash after sealed base fsync). Recover only after
            // authenticating all candidates; a CORRUPT existing pointer never takes this path.
            guard FileManager.default.fileExists(atPath: draftDirectory(id).path) else { return nil }
            var candidates: [Draft] = []
            for folder in try snapshotFolders(id) {
                let bytes = try boundedData(folder.appendingPathComponent(id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
                candidates.append(try loadSnapshot(folder, id: id, isProtected: bytes.starts(with: Data("BJB1:".utf8)), access: access))
            }
            guard var newest = candidates.max(by: { $0.generation < $1.generation }) else { return nil }
            guard candidates.filter({ $0.generation == newest.generation }).allSatisfy({ $0 == newest }) else { throw Failure.corrupt }
            newest.state = .insertionUnconfirmed
            return newest
        }
    }
    private func loadSnapshot(_ snapshot: URL, id: UUID, isProtected: Bool, access: LockedNoteAccess?) throws -> Draft {
        if isProtected, access == nil { throw Failure.keyRequired }
        let key = isProtected ? try access?.journalKey() : nil
        try requireDirectory(snapshot)
        _ = try boundedData(snapshot.appendingPathComponent(id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
        guard try boundedData(snapshot.appendingPathComponent(id.uuidString + ".jsonl"), maximum: 0).isEmpty else { throw Failure.corrupt }
        let journal = try EditJournal(directory: snapshot, noteId: id.uuidString, encryptionKey: key)
        guard let saved = try journal.base(), saved.baseText.utf8.count <= Self.maximumRecordBytes / 2 else { throw Failure.corrupt }
        let record = try JSONDecoder().decode(Record.self, from: Data(saved.baseText.utf8))
        guard record.version == 1, record.libraryID == libraryID, record.draft.id == id,
              saved.storeRevision == record.draft.generation else { throw Failure.corrupt }
        try validate(record.draft)
        if isProtected { _ = try access?.journalKey() }
        return record.draft
    }
    private func snapshotFolders(_ id: UUID) throws -> [URL] {
        try boundedChildren(draftDirectory(id), maximum: 32).filter { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil else { return false }
            return try !isDiscarded(folder)
        }
    }
    private func orphanSummary(_ id: UUID) throws -> Summary? {
        guard FileManager.default.fileExists(atPath: draftDirectory(id).path) else { return nil }
        let folders = try snapshotFolders(id)
        guard !folders.isEmpty else { return nil }
        var protected = false
        for folder in folders {
            try requireDirectory(folder)
            let bytes = try boundedData(folder.appendingPathComponent(id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
            protected = protected || bytes.starts(with: Data("BJB1:".utf8))
        }
        // Generation is opaque until vault unlock. Recovery is always uncertain, never autosaved
        // back over existing records or silently reinserted from this placeholder generation.
        return Summary(id: id, generation: 0, isProtected: protected, insertionUnconfirmed: true)
    }

    /// Call and await BEFORE a writer/bridge attempt. Later ordinary autosaves cannot clear it.
    @discardableResult func markInsertionUnconfirmed(_ id: UUID, protection: Protection, admission: AdmissionToken? = nil) async throws -> Int? {
        let access: LockedNoteAccess?
        switch protection { case .plain: access = nil; case .sealed(let value): access = value }
        guard var draft = try load(id, access: access) else { return nil }
        guard draft.generation < Int.max else { throw Failure.tooLarge }
        draft.generation += 1; draft.state = .insertionUnconfirmed
        return try await checkpoint(draft, protection: protection, admission: admission) ? draft.generation : nil
    }

    /// Durable opaque tombstone is published BEFORE removing files. A failed cleanup never
    /// makes an old queued checkpoint current again, including another store/process instance.
    /// Recovery UI must own the current lease at the actual deletion boundary.
    /// False means ownership/admission changed; no bytes or tombstone were touched.
    @discardableResult func deleteClaimed(_ id: UUID, owner: UUID) throws -> Bool {
        try writerAdmission {
            try locked(id) {
                guard !isDeleted(id), let claim = claims[id], claim.owner == owner,
                      claim.admissionEpoch == (try readAdmissionEpoch()) else { return false }
                try deleteLocked(id)
                return true
            }
        }
    }
    func delete(_ id: UUID) throws {
        try locked(id) { try deleteLocked(id) }
    }
    private func deleteLocked(_ id: UUID) throws {
        try atomic(Data([1]), to: tombstone(id))
        releaseClaim(id)
        let folder = draftDirectory(id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// Includes sealed orphan checkpoints after failed cleanup; password removal must fail closed.
    func hasProtectedDrafts() throws -> Bool {
        try prepareDirectories()
        for folder in try boundedChildren(directory.appendingPathComponent("Drafts"), maximum: Self.maximumDrafts) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { throw Failure.corrupt }
            let found = try locked(id) {
                if try pointer(id)?.isProtected == true { return true }
                for snapshot in try boundedChildren(folder, maximum: 32) where UUID(uuidString: snapshot.lastPathComponent) != nil {
                    try requireDirectory(snapshot)
                    let bytes = try boundedData(snapshot.appendingPathComponent(id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
                    if bytes.starts(with: Data("BJB1:".utf8)) { return true }
                }
                return false
            }
            if found { return true }
        }
        return false
    }
    func discardAll() throws {
        epoch += 1
        try prepareDirectories()
        var ids = Set(pendingIDs.keys)
        for folder in try boundedChildren(directory.appendingPathComponent("Drafts"), maximum: Self.maximumDrafts) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { throw Failure.corrupt }
            ids.insert(id)
        }
        for id in ids { try delete(id) }
        for id in Array(claims.keys) { releaseClaim(id) }
    }

    /// Only KNOWN discarded candidates are removed. Unmarked orphan journals are recovery,
    /// not garbage; a current or corrupt pointer is never silently removed/repaired.
    func sweepDiscardedCandidates() throws {
        try writerAdmission {
            for folder in try boundedChildren(directory.appendingPathComponent("Drafts"), maximum: Self.maximumDrafts) {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { throw Failure.corrupt }
                try locked(id) {
                    // Preserve live claims, including other scenes/store instances/processes.
                    guard claims[id] == nil else { return }
                    let cleanupOwner = UUID()
                    guard try acquireClaim(id, owner: cleanupOwner) else { return }
                    defer { release(id, owner: cleanupOwner) }
                    let current = try pointer(id)
                    for snapshot in try boundedChildren(folder, maximum: 32) where UUID(uuidString: snapshot.lastPathComponent) != nil {
                        guard current?.snapshot.uuidString != snapshot.lastPathComponent else { continue }
                        if try isDiscarded(snapshot) { try FileManager.default.removeItem(at: snapshot) }
                    }
                }
            }
        }
    }
    private func isDiscarded(_ snapshot: URL) throws -> Bool {
        let marker = snapshot.appendingPathComponent("discarded")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        guard try boundedData(marker, maximum: 1) == Data([1]) else { throw Failure.corrupt }
        return true
    }

    /// Best effort AFTER note lock (or at next unlock). Never block the privacy transition.
    /// A failed checkpoint leaves the old Complete-protected plain draft hidden for later retry.
    @discardableResult func upgradePlainDrafts(noteID originalNoteID: String, access: LockedNoteAccess,
                           admission: AdmissionToken? = nil) async throws -> Int {
        if let admission {
            try fence.state.withLock { state in
                guard admission.namespace == namespaceID, admission.noteID == originalNoteID,
                      admission.epoch == state.epoch, state.transitions[originalNoteID] == nil else { throw CancellationError() }
            }
        }
        // The caller owns authoritative note-state fencing. An upgrade queued after a later
        // unlock must never mark that now-ordinary note protected again.
        var upgraded = 0
        for item in try discover() {
            // Authenticate sealed orphan candidates too before retiring any older plaintext.
            guard var draft = try load(item.id, access: item.isProtected ? access : nil), draft.originalNoteID == originalNoteID else { continue }
            guard draft.generation < Int.max else { throw Failure.tooLarge }
            draft.generation += 1
            let checkpointAdmission = admission ?? captureAdmission(for: originalNoteID)
            if try await checkpoint(draft, protection: .sealed(access), admission: checkpointAdmission) { upgraded += 1 }
            else if let current = try discover().first(where: { $0.id == item.id }), !current.isProtected { throw Failure.busy }
        }
        // Remove plaintext older generations only after each current draft has a durable sealed copy.
        if let admission {
            try fence.state.withLock { state in
                guard admission.epoch == state.epoch, state.transitions[originalNoteID] == nil else { throw CancellationError() }
                try deletePlainDrafts(originalNoteID: originalNoteID)
            }
        } else { try deletePlainDrafts(originalNoteID: originalNoteID) }
        return upgraded
    }

    /// Host invokes before a note protection transition, after invalidating its UI jobs.
    /// Failure must be surfaced; leaving a plaintext draft cannot count as successful protection.
    func deletePlainDrafts(originalNoteID: String) throws {
        try prepareDirectories()
        for folder in try boundedChildren(directory.appendingPathComponent("Drafts"), maximum: Self.maximumDrafts) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { throw Failure.corrupt }
            try locked(id) {
                let current = try pointer(id)
                for snapshot in try boundedChildren(folder, maximum: 32) where UUID(uuidString: snapshot.lastPathComponent) != nil {
                    try requireDirectory(snapshot)
                    let bytes = try boundedData(snapshot.appendingPathComponent(id.uuidString + ".base"), maximum: Self.maximumRecordBytes)
                    if bytes.starts(with: Data("BJB1:".utf8)) { continue }
                    let base = try JSONDecoder().decode(JournalBase.self, from: bytes)
                    guard base.v == EditJournal.formatVersion else { throw Failure.corrupt }
                    let record = try JSONDecoder().decode(Record.self, from: Data(base.baseText.utf8))
                    guard record.version == 1, record.libraryID == libraryID, record.draft.id == id else { throw Failure.corrupt }
                    if record.draft.originalNoteID == originalNoteID {
                        if current?.snapshot.uuidString == snapshot.lastPathComponent {
                            try atomic(Data([1]), to: tombstone(id))
                            try FileManager.default.removeItem(at: folder)
                            break
                        }
                        try FileManager.default.removeItem(at: snapshot)
                    }
                }
            }
        }
    }

    private func validate(_ draft: Draft) throws {
        guard draft.generation >= 0, !draft.drawingData.isEmpty,
              draft.drawingData.count <= Self.maximumDrawingBytes,
              draft.canvasSize.width.isFinite, draft.canvasSize.height.isFinite,
              draft.canvasSize.width >= 1, draft.canvasSize.height >= 1,
              draft.canvasSize.width <= 4096, draft.canvasSize.height <= 4096 else { throw Failure.tooLarge }
        guard libraryID.utf8.count <= 256, !libraryID.isEmpty,
              draft.originalNoteID.map({ UUID(uuidString: $0) != nil }) ?? true else { throw Failure.invalid }
        if let name = draft.sourceFilename {
            // Same single-component boundary as Core's internal AttachmentFiles.validate.
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  !name.unicodeScalars.contains("\u{0}"), name.utf8.count <= 255 else { throw Failure.invalid }
        }
        if let hash = draft.sourceSHA256 { guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalid } }
    }
    private func draftDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("Drafts").appendingPathComponent(id.uuidString) }
    private func tombstone(_ id: UUID) -> URL { directory.appendingPathComponent("Deleted").appendingPathComponent(id.uuidString) }
    private func isDeleted(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: tombstone(id).path) }
    private func pointer(_ id: UUID) throws -> Pointer? {
        let url = draftDirectory(id).appendingPathComponent("current")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try requireDirectory(draftDirectory(id))
        let value = try JSONDecoder().decode(Pointer.self, from: boundedData(url, maximum: 4096))
        guard value.version == 1, value.generation >= 0 else { throw Failure.corrupt }
        return value
    }
    private func prepareDirectories() throws {
        try makeDirectory(directory.deletingLastPathComponent())
        try makeDirectory(directory)
        for name in ["Drafts", "Deleted", "Locks", "Claims"] { try makeDirectory(directory.appendingPathComponent(name)) }
    }
    private func makeDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        }
        try requireDirectory(url)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var value = url, flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try value.setResourceValues(flags)
    }
    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.corrupt }
    }
    private func verifyJournalCreationProtection(_ folder: URL, id: UUID) throws {
        let probe = folder.appendingPathComponent(id.uuidString + ".base.tmp")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data(),
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600]) else { throw Failure.corrupt }
        defer { try? FileManager.default.removeItem(at: probe) }
        let attributes = try FileManager.default.attributesOfItem(atPath: probe.path)
        let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
        #if targetEnvironment(simulator)
        // Simulator may omit Data Protection metadata; physical devices must report Complete.
        guard protection == nil || protection == FileProtectionType.complete.rawValue else { throw Failure.journalProtectionUnavailable(protection) }
        #else
        guard protection == FileProtectionType.complete.rawValue else { throw Failure.journalProtectionUnavailable(protection) }
        #endif
        // EditJournal creates this exact payload-bearing filename with explicit Complete
        // attributes too; neither path relies on parent-directory inheritance.
    }
    private func protectFiles(_ folder: URL) throws {
        for file in try boundedChildren(folder, maximum: 4) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600], ofItemAtPath: file.path)
            var url = file, flags = URLResourceValues(); flags.isExcludedFromBackup = true; try url.setResourceValues(flags)
        }
    }
    private func boundedChildren(_ folder: URL, maximum: Int) throws -> [URL] {
        try requireDirectory(folder)
        let failed = Mutex(false)
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in
                failed.withLock { $0 = true }; return false
            }) else { throw Failure.corrupt }
        var result: [URL] = []
        while let url = iterator.nextObject() as? URL {
            guard result.count < maximum else { throw Failure.tooLarge }
            result.append(url)
        }
        guard !failed.withLock({ $0 }) else { throw Failure.corrupt }
        return result
    }
    private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    private func identitiesMatch(_ identities: [(URL, FileIdentity?)]) throws -> Bool {
        for (url, identity) in identities where try fileIdentity(url) != identity { return false }
        return true
    }
    private func fileIdentity(_ url: URL) throws -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.corrupt
        }
        let kind = value.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw Failure.corrupt }
        return FileIdentity(device: value.st_dev, inode: value.st_ino, size: value.st_size, mode: value.st_mode,
            modifiedSeconds: Int(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int(value.st_mtimespec.tv_nsec),
            changedSeconds: Int(value.st_ctimespec.tv_sec), changedNanoseconds: Int(value.st_ctimespec.tv_nsec))
    }
    private func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.corrupt }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximum else { throw Failure.tooLarge }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, maximum - result.count + 1)) }
            if count == 0 { break }
            guard count > 0, count <= maximum - result.count else { throw Failure.corrupt }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    private func readAdmissionEpoch() throws -> String {
        let url = directory.appendingPathComponent("Admission.epoch")
        guard FileManager.default.fileExists(atPath: url.path) else { return "initial" }
        let value = String(decoding: try boundedData(url, maximum: 64), as: UTF8.self)
        guard UUID(uuidString: value) != nil else { throw Failure.corrupt }
        return value
    }
    private func admissionFile() throws -> Int32 {
        let fd = open(directory.appendingPathComponent("Admission.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw Failure.corrupt }
        return fd
    }
    private func writerAdmission<Value>(_ body: () throws -> Value) throws -> Value {
        guard suspensions.isEmpty else { throw Failure.suspended }
        try prepareDirectories()
        let fd = try admissionFile()
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw Failure.suspended }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func locked<Value>(_ id: UUID, _ body: () throws -> Value) throws -> Value {
        try prepareDirectories()
        let fd = open(directory.appendingPathComponent("Locks").appendingPathComponent(id.uuidString).path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.busy }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func atomic(_ bytes: Data, to url: URL, afterRename: (() throws -> Void)? = nil) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600]) else { throw Failure.corrupt }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: bytes); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        try afterRename?()
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}
