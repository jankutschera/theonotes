// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CoreSpotlight
import CryptoKit
import Foundation
import GRDB
import Observation
import TheoNotesCore
import UniformTypeIdentifiers

@MainActor protocol MobileSpotlightIndex {
    func removeAll(completion: @escaping @MainActor (Error?) -> Void)
    func index(_ entries: [MobileSpotlight.Entry], completion: @escaping @MainActor (Error?) -> Void)
}

@MainActor final class MobileSystemSpotlightIndex: MobileSpotlightIndex {
    private let index = CSSearchableIndex.default()
    func removeAll(completion: @escaping @MainActor (Error?) -> Void) {
        index.deleteAllSearchableItems { error in Task { @MainActor in completion(error) } }
    }
    func index(_ entries: [MobileSpotlight.Entry], completion: @escaping @MainActor (Error?) -> Void) {
        let items = entries.map { entry in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = entry.title
            attributes.textContent = entry.text
            attributes.contentDescription = entry.text
            let item = CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: entry.libraryID, attributeSet: attributes)
            item.expirationDate = Date.now.addingTimeInterval(24 * 60 * 60)
            return item
        }
        index.indexSearchableItems(items) { error in Task { @MainActor in completion(error) } }
    }
}

/// One process-wide owner of the app's index. Clear requests are submitted synchronously;
/// Core Spotlight journals them asynchronously and controls when system UI caches disappear.
@MainActor @Observable final class MobileSpotlight {
    struct Entry: Equatable, Sendable {
        let id: String
        let libraryID: String
        let title: String
        let text: String
    }
    private struct Fingerprint: Equatable, Sendable {
        let id: String
        let revision: Int
        let locked: Bool
        let location: String
        let deletedAt: Date?
        var eligible: Bool { !locked && location != "trash" && deletedAt == nil }
    }
    private let index: any MobileSpotlightIndex
    private let debounce: Duration
    private let debounceWait: @Sendable (Duration) async throws -> Void
    private let prepareEntries: @Sendable (AppDatabase, AppPaths) async throws -> [Entry]
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var debouncePending = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<[Entry], any Error>?
    @ObservationIgnored private var metadata: [Fingerprint]?
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private var privacyGeneration = 0
    @ObservationIgnored private weak var library: MobileLibrary?
    @ObservationIgnored private var observation: (any DatabaseCancellable)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var outstanding = 0
    @ObservationIgnored private var needsRebuild = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryFailures = 0
    @ObservationIgnored private var indexRetryPending = false
    @ObservationIgnored private var indexRetryFailures = 0
    private let retryDelay: Duration?
    private(set) var scrubPending = false
    private(set) var lastError: Error?

    var lastErrorMessage: String? {
        lastError == nil ? nil : "Spotlight could not be updated or cleared. Retrying."
    }

    init(index: any MobileSpotlightIndex, retryDelay: Duration? = nil, debounce: Duration = .seconds(2),
         debounceWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         prepareEntries: @escaping @Sendable (AppDatabase, AppPaths) async throws -> [Entry] = { database, paths in
             try MobileSpotlight.loadEntries(database: database, paths: paths)
         }) {
        self.index = index
        self.retryDelay = retryDelay
        self.debounce = debounce
        self.debounceWait = debounceWait
        self.prepareEntries = prepareEntries
    }

    isolated deinit {
        retryTask?.cancel(); debounceTask?.cancel(); worker?.cancel(); observation?.cancel()
    }
    var hasPendingContentUpdate: Bool { debouncePending }
    /// Snapshot the current quiet-period task without changing its ownership.
    var pendingContentUpdateCompletion: Task<Void, Never>? { debounceTask }
    var hasBackgroundPreparations: Bool { preparationTask != nil }
    func waitForBackgroundPreparations() async {
        while let task = preparationTask { await task.value }
    }

    nonisolated static func libraryID(for paths: AppPaths) -> String {
        SHA256.hash(data: Data(paths.root.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func identifier(noteID: String, paths: AppPaths) -> String {
        "theonotes.spotlight.\(libraryID(for: paths)).\(noteID)"
    }
    nonisolated static func noteID(from identifier: String, paths: AppPaths) -> String? {
        let prefix = "theonotes.spotlight.\(libraryID(for: paths))."
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        guard UUID(uuidString: id) != nil else { return nil }
        return id
    }
    nonisolated static func entries(notes: [Note], paths: AppPaths) -> [Entry] {
        let libraryID = libraryID(for: paths)
        return notes.filter { !$0.isLocked && $0.deletedAt == nil && $0.location != .trash }
            .map { entry(note: $0, libraryID: libraryID) }
    }
    nonisolated private static func entry(note: Note, libraryID: String) -> Entry {
        Entry(id: "theonotes.spotlight.\(libraryID).\(note.id)", libraryID: libraryID,
              title: String(note.title.prefix(512)), text: String(PlainTextExport.text(note.text).prefix(100_000)))
    }
    nonisolated private static func readMetadata(_ db: Database) throws -> [Fingerprint] {
        try Row.fetchAll(db, sql: "SELECT id,revision,isLocked,location,deletedAt FROM note ORDER BY id").map {
            Fingerprint(id: $0["id"], revision: $0["revision"], locked: $0["isLocked"],
                        location: $0["location"], deletedAt: $0["deletedAt"])
        }
    }

    nonisolated private static func loadEntries(database: AppDatabase, paths: AppPaths) throws -> [Entry] {
        try Task.checkCancellation()
        let notes = try database.pool.read {
            try Note.fetchAll($0, sql: "SELECT * FROM note WHERE NOT isLocked AND deletedAt IS NULL AND location!='trash'")
        }
        // Parsing runs outside both MainActor and the database read transaction.
        let libraryID = libraryID(for: paths)
        return try notes.map {
            try Task.checkCancellation()
            return entry(note: $0, libraryID: libraryID)
        }
    }

    func connect(_ library: MobileLibrary?) {
        self.library?.spotlightDidChange = nil
        observation?.cancel(); observation = nil
        self.library = library
        connectionID = UUID()
        let token = connectionID
        metadata = nil
        library?.spotlightDidChange = { [weak self] in self?.refresh() }
        library?.spotlightPreparationBusy = { [weak self] in self?.hasBackgroundPreparations == true }
        library?.waitForSpotlightPreparation = { [weak self] in await self?.waitForBackgroundPreparations() }
        refresh() // Startup, App Lock and library switches always purge synchronously.
        guard let library else { return }
        observation = ValueObservation.tracking { db in try Self.readMetadata(db) }.start(in: library.database.pool, scheduling: .immediate,
                onError: { [weak self] error in
                    guard let self, connectionID == token else { return }
                    failClosed(error)
                }, onChange: { [weak self] value in
                    guard let self, connectionID == token else { return }
                    observed(value)
                })
    }

    private func observed(_ value: [Fingerprint]) {
        let previous = metadata
        metadata = value
        guard let previous, previous != value else { return }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let next = Dictionary(uniqueKeysWithValues: value.map { ($0.id, $0) })
        let losesOrGainsAccess = previous.contains { $0.eligible && next[$0.id]?.eligible != true }
            || value.contains { old[$0.id] != nil && old[$0.id]?.eligible != $0.eligible }
        if losesOrGainsAccess { refresh(); return }
        // Ordinary content updates never delete the index. Fence older preparations and
        // coalesce a burst into one upsert after the user has stopped editing briefly.
        generation &+= 1
        worker?.cancel()
        debounceTask?.cancel()
        debouncePending = true
        needsRebuild = true
        let scheduledGeneration = generation, wait = debounceWait
        debounceTask = Task { [weak self, debounce] in
            do { try await wait(debounce) } catch { return }
            guard !Task.isCancelled, let self, generation == scheduledGeneration else { return }
            debounceTask = nil; debouncePending = false
            pump()
        }
    }

    func refresh() {
        // Refresh the lightweight baseline so the observation of the same explicit lock
        // does not submit a second purge. No note bodies are read on MainActor.
        if let library, !library.isClosed {
            metadata = try? library.database.pool.read { try Self.readMetadata($0) }
        }
        generation &+= 1
        privacyGeneration &+= 1
        debounceTask?.cancel(); debounceTask = nil; debouncePending = false
        worker?.cancel()
        retryTask?.cancel(); retryTask = nil
        indexRetryPending = false; indexRetryFailures = 0
        scrubPending = true
        needsRebuild = true
        removeAll()
    }

    private func failClosed(_ error: Error) {
        generation &+= 1
        privacyGeneration &+= 1
        debounceTask?.cancel(); debounceTask = nil; debouncePending = false
        worker?.cancel()
        retryTask?.cancel(); retryTask = nil
        indexRetryPending = false; indexRetryFailures = 0
        needsRebuild = false
        lastError = error
        scrubPending = true
        removeAll()
    }

    /// Foreground retries cleanup first; a cleaned index whose write failed can then rebuild.
    func retryPendingPurge() {
        guard scrubPending || indexRetryPending else { return }
        retryTask?.cancel(); retryTask = nil
        if scrubPending { removeAll() }
        else { indexRetryPending = false; pump() }
    }

    private func indexWriteFailed(_ error: Error) {
        generation &+= 1
        privacyGeneration &+= 1
        retryTask?.cancel(); retryTask = nil
        needsRebuild = true
        indexRetryPending = true
        lastError = error
        removeAll() // A failed index write may have partially applied; clean it before retrying.
    }

    private func scheduleIndexRetry() {
        guard retryTask == nil, indexRetryPending, !scrubPending else { return }
        indexRetryFailures = min(indexRetryFailures + 1, 6)
        let delay = retryDelay ?? .seconds(min(60, 1 << indexRetryFailures))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            retryTask = nil
            guard indexRetryPending, !scrubPending else { return }
            indexRetryPending = false
            pump() // Rechecks the current library, App Lock and privacy/lifecycle state.
        }
    }

    private func schedulePurgeRetry() {
        guard retryTask == nil, scrubPending else { return }
        retryFailures = min(retryFailures + 1, 6)
        let delay = retryDelay ?? .seconds(min(60, 1 << retryFailures))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            retryTask = nil
            guard scrubPending else { return }
            removeAll()
        }
    }

    private func removeAll() {
        scrubPending = true
        // Ordinary edits advance content generation without invalidating this privacy purge.
        let submittedPrivacyGeneration = privacyGeneration
        outstanding += 1
        index.removeAll { [weak self] error in
            guard let self else { return }
            outstanding -= 1
            if submittedPrivacyGeneration == privacyGeneration {
                if let error {
                    lastError = error
                    scrubPending = true
                    schedulePurgeRetry()
                } else {
                    scrubPending = false
                    if !indexRetryPending && indexRetryFailures == 0 { lastError = nil }
                    retryFailures = 0
                    retryTask?.cancel(); retryTask = nil
                    if indexRetryPending { scheduleIndexRetry() }
                }
            }
            pump()
        }
    }

    private func pump() {
        guard outstanding == 0, preparationTask == nil, needsRebuild, !scrubPending,
              !indexRetryPending, !debouncePending else { return }
        guard let library, !library.appLockEnabled, !library.appLocked,
              !library.isClosed, !library.isClosing, !library.libraryOperationBusy else {
            needsRebuild = false
            return
        }
        needsRebuild = false
        let submittedGeneration = generation, submittedPrivacyGeneration = privacyGeneration
        let database = library.database, paths = library.paths, prepare = prepareEntries
        let job = Task.detached(priority: .utility) { try await prepare(database, paths) }
        worker = job
        preparationTask = Task { [weak self, weak library] in
            let result = await job.result
            guard let self else { return }
            worker = nil; preparationTask = nil
            guard submittedGeneration == generation, let library, self.library === library,
                  !library.appLockEnabled, !library.appLocked, !library.isClosed,
                  !library.isClosing, !library.libraryOperationBusy else { pump(); return }
            switch result {
            case .failure(let error):
                if error is CancellationError { pump() }
                else { failClosed(error) }
            case .success(let entries):
                guard !entries.isEmpty else { return }
                do {
                    // MainActor privacy mutations and this final ID-only validation are
                    // synchronous. A remote lock cannot slip between validation and submit.
                    let eligible = try Self.eligibleIDs(in: database)
                    guard entries.allSatisfy({ entry in
                        Self.noteID(from: entry.id, paths: paths).map(eligible.contains) == true
                    }) else { refresh(); return }
                } catch { failClosed(error); return }
                submit(entries, generation: submittedGeneration, privacy: submittedPrivacyGeneration)
            }
        }
    }

    private static func eligibleIDs(in database: AppDatabase) throws -> Set<String> {
        try database.pool.read {
            Set(try String.fetchAll($0, sql: "SELECT id FROM note WHERE NOT isLocked AND deletedAt IS NULL AND location!='trash'"))
        }
    }

    private func submit(_ entries: [Entry], generation submittedGeneration: Int, privacy submittedPrivacyGeneration: Int) {
        outstanding += 1
        index.index(entries) { [weak self] error in
            guard let self else { return }
            outstanding -= 1
            if submittedPrivacyGeneration != privacyGeneration {
                // A privacy change needs a compensating purge even if the old write failed.
                removeAll()
                return
            }
            guard submittedGeneration == generation else { pump(); return }
            if let error { indexWriteFailed(error); return }
            indexRetryFailures = 0
            lastError = nil
            pump()
        }
    }
}
