// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Observation

/// The note-list search (spec §6, inventory §2.5): Bear's query language over the selected
/// sidebar scope within the window's workspace, as you type. Queries run off the main actor after an 80 ms debounce (300 ms at
/// most while changes keep coming). A new query or scope drops every reply of the search before;
/// a refresh (the library changed) re-reads the same search. Results come in pages (ruling R8):
/// the first `pageSize`, more when the list scrolls to its end.
@MainActor
@Observable
final class NoteSearch {
    /// One search: the query over `scope` ∩ `workspace`, in the list order, rows
    /// `offset..<offset + limit`.
    struct Request: Equatable, Sendable {
        var query: String
        var scope: SidebarScope
        var sort: NoteSort
        var limit: Int
        var offset: Int
        var workspace: Workspace? = nil
    }

    typealias Runner = @Sendable (Request) async throws -> SearchResult

    nonisolated static let defaultPageSize = 200
    nonisolated static let defaultDebounce: Duration = .milliseconds(80)
    /// The longest a search waits while the debounce keeps being restarted.
    nonisolated static let defaultMaxWait: Duration = .milliseconds(300)

    /// The search field's text.
    var query = "" {
        didSet { if query != oldValue { start(isNewSearch: true) } }
    }
    /// What to highlight in the listed notes and the opened one (`SearchResult.terms`).
    private(set) var terms: [String] = []
    /// The matching notes loaded so far, in list order; nil while no search shows results. Empty
    /// while the first results of a new scope are on their way.
    private(set) var resultIDs: [String]?
    /// More results than loaded may exist (the last page was full).
    private(set) var hasMore = false
    /// A changed query or scope has not got its results yet: the listed ones are stale.
    private(set) var isAwaitingNewResults = false
    /// Called after results are applied or cleared: `true` for a changed query or scope, `false`
    /// for a refresh of the same search or a further page.
    @ObservationIgnored var onResults: ((_ isNewSearch: Bool) -> Void)?

    var isActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let maxWait: Duration
    @ObservationIgnored private let scheduler: any DebounceScheduler
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var scope: SidebarScope = .notes
    @ObservationIgnored private var sort = SettingKey<NoteSort>.noteSort.defaultValue
    @ObservationIgnored private var workspace: Workspace?
    @ObservationIgnored private var debounceAction: ScheduledAction?
    @ObservationIgnored private var maxWaitAction: ScheduledAction?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Bumped by every new query or scope (and clearing); replies of an older search are dropped.
    @ObservationIgnored private var generation = 0
    /// Bumped by every query sent; only the latest one's reply is applied.
    @ObservationIgnored private var sendCount = 0
    /// The search to send next is a new one (a refresh started meanwhile keeps it new).
    @ObservationIgnored private var pendingNewSearch = false
    /// The list reached its end while a search was pending or running: load the next page after it.
    @ObservationIgnored private var wantsMore = false
    /// The query in flight is a further page (a refresh replacing it loads that page too).
    @ObservationIgnored private var inFlightIsPage = false

    init(
        pageSize: Int = NoteSearch.defaultPageSize, debounce: Duration = NoteSearch.defaultDebounce,
        maxWait: Duration = NoteSearch.defaultMaxWait, scheduler: any DebounceScheduler = TaskDebounceScheduler(),
        runner: @escaping Runner
    ) {
        self.pageSize = pageSize
        self.debounce = debounce
        self.maxWait = maxWait
        self.scheduler = scheduler
        self.runner = runner
    }

    /// Runs searches against the library.
    nonisolated static func live(
        database: AppDatabase, calendar: Calendar, now: @escaping @Sendable () -> Date
    ) -> Runner {
        { request in
            try await database.pool.read { db in
                try LibraryQueries.search(
                    request.query, in: request.scope, sort: request.sort, workspace: request.workspace, now: now(),
                    calendar: calendar, limit: request.limit, offset: request.offset, db: db
                )
            }
        }
    }

    /// The sidebar scope, workspace and list order the search runs in. A changed scope or
    /// workspace searches again and lists nothing until its results arrive (no stale rows).
    func update(scope: SidebarScope, sort: NoteSort, workspace: Workspace? = nil) {
        let scopeChanged = scope != self.scope || workspace != self.workspace
        guard scopeChanged || sort != self.sort else { return }
        self.scope = scope
        self.sort = sort
        self.workspace = workspace
        guard isActive else { return }
        if scopeChanged, resultIDs != nil { resultIDs = [] }
        start(isNewSearch: scopeChanged)
    }

    /// The library changed: re-reads the loaded results (same query, debounced).
    func refresh() {
        if isActive { start(isNewSearch: false) }
    }

    func clear() {
        query = ""
    }

    /// The next page, when the list reached the end of the loaded results. While a search is
    /// pending or running it follows that search.
    func loadMore() {
        guard isActive, hasMore, !isAwaitingNewResults, let loaded = resultIDs else { return }
        guard debounceAction == nil, inFlight == nil else {
            wantsMore = true
            return
        }
        let request = Request(
            query: query, scope: scope, sort: sort, limit: pageSize, offset: loaded.count, workspace: workspace
        )
        send(request, isPage: true) { [weak self] result in
            guard let self, let loaded = self.resultIDs else { return }
            let known = Set(loaded)
            self.resultIDs = loaded + result.items.map(\.id).filter { !known.contains($0) }
            self.hasMore = result.items.count == request.limit
            self.onResults?(false)
        }
    }

    private func start(isNewSearch: Bool) {
        guard isActive else {
            cancelAll()
            generation += 1
            pendingNewSearch = false
            wantsMore = false
            isAwaitingNewResults = false
            guard resultIDs != nil || !terms.isEmpty else { return }
            resultIDs = nil
            terms = []
            hasMore = false
            onResults?(true)
            return
        }
        if isNewSearch {
            generation += 1
            pendingNewSearch = true
            wantsMore = false
            isAwaitingNewResults = true
            inFlight?.cancel()
            inFlight = nil
        }
        debounceAction?.cancel()
        debounceAction = scheduler.schedule(after: debounce) { [weak self] in self?.fire() }
        if maxWaitAction == nil {
            maxWaitAction = scheduler.schedule(after: maxWait) { [weak self] in self?.fire() }
        }
    }

    private func fire() {
        debounceAction?.cancel()
        debounceAction = nil
        maxWaitAction?.cancel()
        maxWaitAction = nil
        let isNew = pendingNewSearch || isAwaitingNewResults
        pendingNewSearch = false
        // A refresh re-reads everything loaded so far (plus a page the list asked for meanwhile),
        // so the list does not shrink while scrolled.
        let loaded = isNew ? 0 : resultIDs?.count ?? 0
        let more = (wantsMore || (inFlight != nil && inFlightIsPage)) && hasMore && !isNew
        wantsMore = false
        let request = Request(
            query: query, scope: scope, sort: sort, limit: max(pageSize, loaded + (more ? pageSize : 0)), offset: 0,
            workspace: workspace
        )
        send(request, isPage: false, apply: { [weak self] result in
            guard let self else { return }
            self.resultIDs = result.items.map(\.id)
            if self.terms != result.terms { self.terms = result.terms }
            self.hasMore = result.items.count == request.limit
            if isNew { self.isAwaitingNewResults = false }
            self.onResults?(isNew)
        }, failed: { [weak self] in
            // A failed read (busy database) of a new search: stop waiting, keep the results shown
            // (of the search before, so no page of this one is appended to them) and search
            // afresh on the next run (a library change, a keystroke).
            guard let self, isNew else { return }
            self.isAwaitingNewResults = false
            self.pendingNewSearch = true
            self.hasMore = false
            self.onResults?(true)
        })
    }

    private func cancelAll() {
        debounceAction?.cancel()
        debounceAction = nil
        maxWaitAction?.cancel()
        maxWaitAction = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Runs `request` off the main actor; `apply` gets the reply (`failed` an error other than
    /// cancellation) unless a newer query was sent or a new search started meanwhile. A page the
    /// list asked for meanwhile loads next.
    private func send(
        _ request: Request, isPage: Bool, apply: @escaping @MainActor (SearchResult) -> Void,
        failed: @escaping @MainActor () -> Void = {}
    ) {
        inFlight?.cancel()
        inFlightIsPage = isPage
        sendCount += 1
        let sent = sendCount, generation = generation, runner = runner
        inFlight = Task { [weak self] in
            let result: SearchResult
            do {
                result = try await runner(request)
            } catch {
                guard !(error is CancellationError) else {
                    if let self, self.sendCount == sent { self.inFlight = nil }
                    return
                }
                appLogger.error("search failed: \(error)")
                guard let self, self.sendCount == sent else { return }
                self.inFlight = nil
                if self.generation == generation, !Task.isCancelled { failed() }
                return
            }
            guard let self, self.sendCount == sent, self.generation == generation, !Task.isCancelled else { return }
            self.inFlight = nil
            apply(result)
            if self.wantsMore, self.debounceAction == nil {
                self.wantsMore = false
                self.loadMore()
            }
        }
    }

    // MARK: - Tags of a query

    struct RequiredTags: Equatable {
        /// Tags every result has (`#a`, `!#a` at the top level of the query), as typed.
        var tags: [String]
        /// The query is nothing but such tags, so a note with them matches it.
        var onlyTags: Bool
    }

    /// A new note made while searching gets these tags (Bear: searching a tag pre-fills it).
    static func requiredTags(in query: String, locale: Locale = .current) -> RequiredTags {
        let expr = SearchParser.parse(query, locale: locale)
        let parts: [SearchExpr]
        if case .and(let list) = expr { parts = list } else { parts = [expr] }
        var tags: [String] = []
        for part in parts {
            if case .tag(let name, let mode) = part, mode != .subtagsOnly { tags.append(name) }
        }
        return RequiredTags(tags: tags, onlyTags: !parts.isEmpty && tags.count == parts.count)
    }
}
