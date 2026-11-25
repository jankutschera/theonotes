// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import TheoNotesCore

/// Scene-local read projection over the shared database. It owns no session, WebView,
/// writer, publication or OCR work. MobileLibrary's shared observer remains the sole owner
/// of publishRecentNotes/startBacklog side effects until that responsibility is migrated.
///
/// The root starts one instance per scene and stops it BEFORE closing/replacing its database.
/// isCurrent must read the library's generation/closed/busy/App-Lock state (capture the
/// expected generation), so old callbacks cannot expose another library's or locked results.
@MainActor @Observable final class MobileSceneLibraryObservation {
    struct SearchRequest: Sendable {
        let query: String
        let scope: SidebarScope
        let workspace: Workspace?
        let sort: NoteSort
        let now: Date
        let calendar: Calendar
    }
    typealias SearchOperation = @Sendable (SearchRequest, AppDatabase) async throws -> SearchResult
    private struct Context: Equatable {
        let scope: SidebarScope
        let workspace: Workspace?
        let query: String
        let generation: Int
    }
    private struct SearchContext: Equatable {
        let navigation: Context
        let snapshotVersion: Int
    }
    private struct SnapshotContext: Equatable {
        let scope: SidebarScope
        let workspace: Workspace?
    }

    let navigation: MobileSceneNavigation
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let searchOperation: SearchOperation
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var observation: ObservationToken?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    // Replaced/canceled workers stay owned until they actually finish: cancellation alone
    // does not prove a GRDB read or injected platform operation has released its database.
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var drainingCount = 0
    @ObservationIgnored private var requestedSearch: SearchContext?
    @ObservationIgnored private var snapshotVersion = 0
    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var trackingArmed = false
    private var running = false
    private var observedContext: SnapshotContext?
    private var visibleContext: Context?
    private var storedSnapshot = LibrarySnapshot()
    private var storedItems: [NoteListItem] = []
    private var storedTerms: [String] = []
    private var storedError: String?

    /// Gate getters as well as callbacks: a lock invalidates cached display values without
    /// waiting for the observation onChange task to reach the main actor.
    var items: [NoteListItem] { canExpose && visibleContext == context ? storedItems : [] }
    var searchTerms: [String] { canExpose && visibleContext == context ? storedTerms : [] }
    var snapshot: LibrarySnapshot {
        canExpose && observedContext == snapshotContext ? storedSnapshot : LibrarySnapshot()
    }
    var errorMessage: String? { canExpose ? storedError : nil }
    private var canExpose: Bool { running && isCurrent() }
    private var context: Context {
        Context(scope: navigation.scope, workspace: navigation.workspace, query: navigation.query,
            generation: navigation.queryContextGeneration)
    }
    private var snapshotContext: SnapshotContext {
        SnapshotContext(scope: navigation.scope, workspace: navigation.workspace)
    }

    init(navigation: MobileSceneNavigation, database: AppDatabase,
         isCurrent: @escaping @MainActor () -> Bool,
         debounce: Duration = .milliseconds(150), calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { .now },
         searchOperation: @escaping SearchOperation = { request, database in
             try await database.pool.read { db in
                 try LibraryQueries.search(request.query, in: request.scope, sort: request.sort,
                     workspace: request.workspace, now: request.now, calendar: request.calendar, db: db)
             }
         }) {
        self.navigation = navigation; self.database = database; self.isCurrent = isCurrent
        self.debounce = debounce; self.calendar = calendar; self.now = now
        self.searchOperation = searchOperation
    }

    deinit { observation?.cancel(); for task in workers.values { task.cancel() } }

    func start() {
        guard drainingCount == 0 else { return }
        running = true
        synchronize()
    }
    func stop() {
        running = false
        invalidate()
    }

    /// Stop ALL scene observers first, then await each before the shared database closes.
    /// A held native read can delay this async operation but cannot block the main actor.
    /// A cancellation/error is not permission to close the database early.
    func stopAndWait() async throws {
        drainingCount += 1
        defer { drainingCount -= 1 }
        stop()
        while !workers.isEmpty {
            let pending = Array(workers.values)
            for task in pending { await task.value }
        }
        // ValueObservation cancellation has no awaitable completion. The pool barrier also
        // drains its already-admitted fetches. Use GRDB's callback API so caller cancellation
        // cannot skip this safety barrier (it never mutates the database).
        let pool = database.pool
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pool.asyncBarrierWriteWithoutTransaction { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    /// Usually automatic; the host can call synchronously at a routing/privacy boundary.
    /// forceSearch retries an unchanged failed search; ordinary repeated calls are idempotent.
    func synchronize(forceSearch: Bool = false) {
        guard running else { return }
        defer { trackNavigationAndBoundary() }
        guard isCurrent() else { invalidate(); return }
        let next = snapshotContext
        if observation == nil || observedContext != next {
            invalidate()
            observedContext = next
            let id = observationID
            // Core delivers the initial snapshot synchronously. Install the identity BEFORE
            // subscribing, then reject any callback from a canceled subscription afterward.
            observation = LibraryQueries.observeSnapshot(scope: next.scope, workspace: next.workspace,
                database: database, calendar: calendar, now: now,
                onError: { [weak self] error in
                    guard let self, self.acceptsSnapshot(id, context: next) else { return }
                    self.storedError = error.localizedDescription
                }, onChange: { [weak self] value in
                    guard let self, self.acceptsSnapshot(id, context: next) else { return }
                    if !value.workspaceExists {
                        self.navigation.workspace = nil
                        // Do not recursively subscribe during Core's synchronous delivery.
                        Task { @MainActor [weak self] in self?.synchronize() }
                        return
                    }
                    self.storedSnapshot = value
                    self.snapshotVersion &+= 1
                    self.storedError = nil
                    self.beginSearch()
                })
        } else {
            beginSearch(force: forceSearch)
        }
    }

    private func acceptsSnapshot(_ id: UUID, context: SnapshotContext) -> Bool {
        canExpose && observationID == id && observedContext == context && snapshotContext == context
    }
    private func invalidate() {
        observationID = UUID(); searchID = UUID()
        observation?.cancel(); observation = nil
        for task in workers.values { task.cancel() }
        searchTask = nil; requestedSearch = nil
        observedContext = nil; visibleContext = nil
        storedSnapshot = LibrarySnapshot(); storedItems = []; storedTerms = []; storedError = nil
    }
    private func beginSearch(force: Bool = false) {
        let expected = context
        guard canExpose, observedContext == snapshotContext, drainingCount == 0 else { return }
        let next = SearchContext(navigation: expected, snapshotVersion: snapshotVersion)
        guard force || requestedSearch != next else { return }
        requestedSearch = next
        searchTask?.cancel(); searchTask = nil; searchID = UUID()
        let id = searchID, observer = observationID
        if expected.query.isEmpty {
            storedItems = storedSnapshot.items; storedTerms = []; visibleContext = expected
            return
        }
        visibleContext = nil; storedItems = []; storedTerms = []
        let request = SearchRequest(query: expected.query, scope: expected.scope, workspace: expected.workspace,
            sort: storedSnapshot.sort, now: now(), calendar: calendar)
        let search = searchOperation, database = database, pause = debounce
        let task = Task { [weak self] in
            defer { self?.workers.removeValue(forKey: id) }
            do {
                try await Task.sleep(for: pause)
                try Task.checkCancellation()
                let result = try await search(request, database)
                try Task.checkCancellation()
                guard let self, self.acceptsSearch(id, observer: observer, context: expected) else { return }
                self.storedItems = result.items; self.storedTerms = result.terms
                self.visibleContext = expected; self.storedError = nil
            } catch is CancellationError {
                // A newer request, lock, stop or database boundary owns the display.
            } catch {
                guard let self, self.acceptsSearch(id, observer: observer, context: expected) else { return }
                self.storedError = error.localizedDescription
            }
        }
        workers[id] = task
        searchTask = task
    }
    private func acceptsSearch(_ id: UUID, observer: UUID, context: Context) -> Bool {
        canExpose && searchID == id && observationID == observer && self.context == context
    }
    private func trackNavigationAndBoundary() {
        // withObservationTracking is one-shot and has no public cancellation token. Keep at
        // most ONE weak registration across stop/start rather than accumulating dormant ones.
        guard !trackingArmed else { return }
        trackingArmed = true
        withObservationTracking {
            _ = navigation.queryContextGeneration
            _ = isCurrent()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackingArmed = false
                if self.running { self.synchronize() }
            }
        }
    }
}
