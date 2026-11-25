// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// The note-list search: debounce, stale results, paging, scope, ranking, highlighting, and the
/// library model while a search shows (M4 Task 3).
@MainActor
@Suite struct NoteSearchTests {
    @MainActor
    final class Env {
        let root: URL
        let environment: AppEnvironment
        let model: LibraryModel

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesSearch-\(UUID().uuidString)", isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            model = LibraryModel(environment: environment)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var store: NoteStore { environment.store }
        var search: NoteSearch { model.search }
    }

    /// A runner whose calls the test answers by hand, in any order.
    @MainActor
    final class ManualRunner {
        struct Call {
            let request: NoteSearch.Request
            let reply: CheckedContinuation<SearchResult, any Error>
        }

        private(set) var calls: [Call] = []
        private var gate: [(query: String, continuation: CheckedContinuation<Void, Never>)] = []

        nonisolated var runner: NoteSearch.Runner {
            { [weak self] request in
                try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in self?.calls.append(Call(request: request, reply: continuation)) }
                }
            }
        }

        func answer(_ query: String, ids: [String], terms: [String] = []) {
            guard let index = calls.firstIndex(where: { $0.request.query == query }) else {
                Issue.record("no pending search for \(query)")
                return
            }
            let call = calls.remove(at: index)
            call.reply.resume(returning: SearchResult(items: ids.map(Self.item), terms: terms))
        }

        /// Answers the pending search for `query` with an error (a busy database).
        func fail(_ query: String) {
            guard let index = calls.firstIndex(where: { $0.request.query == query }) else {
                Issue.record("no pending search for \(query)")
                return
            }
            calls.remove(at: index).reply.resume(throwing: DatabaseBusy())
        }

        struct DatabaseBusy: Error {}

        static func item(_ id: String) -> NoteListItem {
            NoteListItem(
                id: id, title: id, subtitle: "", modifiedAt: .distantPast, createdAt: .distantPast,
                isPinned: false, isLocked: false, isReadOnly: false, hasAttachments: false, firstImageFilename: nil
            )
        }
    }

    private let start = Date(timeIntervalSince1970: 1_792_670_400)

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 3 s")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - NoteSearch with a manual runner

    @Test func testTypingIsDebouncedIntoOneQuery() async throws {
        let manual = ManualRunner()
        let clock = ManualScheduler()
        let search = NoteSearch(debounce: .milliseconds(80), scheduler: clock, runner: manual.runner)
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "a"
        clock.advance(by: .milliseconds(50))
        search.query = "ap"
        clock.advance(by: .milliseconds(50))
        search.query = "app"
        clock.advance(by: .milliseconds(79))
        try await Task.sleep(for: .milliseconds(20))
        #expect(manual.calls.isEmpty, "nothing runs before 80 ms without typing")
        clock.advance(by: .milliseconds(1))
        try await waitUntil("debounced search") { manual.calls.count == 1 }
        #expect(manual.calls.map(\.request.query) == ["app"])
        #expect(manual.calls.first?.request == NoteSearch.Request(
            query: "app", scope: .notes, sort: .modifiedDescending, limit: NoteSearch.defaultPageSize, offset: 0
        ))
        manual.answer("app", ids: ["n1"], terms: ["app"])
        try await waitUntil("results") { search.resultIDs == ["n1"] }
        #expect(search.terms == ["app"])
    }

    @Test func testChangesThatKeepComingWaitAtMost300ms() async throws {
        let manual = ManualRunner()
        let clock = ManualScheduler()
        let search = NoteSearch(debounce: .milliseconds(80), maxWait: .milliseconds(300), scheduler: clock, runner: manual.runner)
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "q"
        clock.advance(by: .milliseconds(80))
        try await waitUntil("first search") { manual.calls.count == 1 }
        manual.answer("q", ids: ["a"])
        try await waitUntil("results") { search.resultIDs == ["a"] }

        // The library changes every 50 ms (typing in the shown note): each restarts the debounce.
        for _ in 0..<5 {
            search.refresh()
            clock.advance(by: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(manual.calls.isEmpty, "250 ms: still waiting")
        search.refresh()
        clock.advance(by: .milliseconds(50))
        try await waitUntil("refresh after 300 ms at most") { manual.calls.count == 1 }
    }

    @Test func testARefreshRacingLoadMoreStillLoadsTheNextPage() async throws {
        let manual = ManualRunner()
        let clock = ManualScheduler()
        let search = NoteSearch(pageSize: 2, scheduler: clock, runner: manual.runner)
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "p"
        clock.advance(by: .milliseconds(80))
        try await waitUntil("page 1") { manual.calls.count == 1 }
        manual.answer("p", ids: ["a", "b"])
        try await waitUntil("page 1 results") { search.resultIDs == ["a", "b"] }

        // The list reaches its end while a refresh is pending: the refresh reads page 2 too.
        search.refresh()
        search.loadMore()
        clock.advance(by: .milliseconds(80))
        try await waitUntil("refresh") { manual.calls.count == 1 }
        #expect(manual.calls.first?.request.limit == 4)
        manual.answer("p", ids: ["a", "b", "c", "d"])
        try await waitUntil("pages 1 and 2") { search.resultIDs == ["a", "b", "c", "d"] }
        #expect(search.hasMore)

        // The list reaches its end while a refresh is running: the next page follows it.
        search.refresh()
        clock.advance(by: .milliseconds(80))
        try await waitUntil("second refresh running") { manual.calls.count == 1 }
        search.loadMore()
        manual.answer("p", ids: ["a", "b", "c", "d"])
        try await waitUntil("page 3 requested") { manual.calls.count == 1 }
        #expect(manual.calls.first?.request.offset == 4)
        manual.answer("p", ids: ["e"])
        try await waitUntil("page 3") { search.resultIDs == ["a", "b", "c", "d", "e"] }
        #expect(!search.hasMore)

        // A refresh that replaces a running page load keeps that page.
        let more = NoteSearch(pageSize: 2, scheduler: clock, runner: manual.runner)
        more.update(scope: .notes, sort: .modifiedDescending)
        more.query = "m"
        clock.advance(by: .milliseconds(80))
        try await waitUntil("m page 1") { manual.calls.count == 1 }
        manual.answer("m", ids: ["a", "b"])
        try await waitUntil("m results") { more.resultIDs == ["a", "b"] }
        more.loadMore()
        try await waitUntil("m page 2 running") { manual.calls.count == 1 }
        more.refresh()
        clock.advance(by: .milliseconds(80))
        try await waitUntil("m refresh") { manual.calls.count == 2 }
        #expect(manual.calls.last?.request.limit == 4)
        manual.answer("m", ids: ["c"]) // the replaced page load answers late: dropped
        manual.answer("m", ids: ["a", "b", "c"])
        try await waitUntil("m pages") { more.resultIDs == ["a", "b", "c"] }
    }

    @Test func testStaleResultsNeverReplaceNewerOnes() async throws {
        let manual = ManualRunner()
        let search = NoteSearch(debounce: .zero, runner: manual.runner)
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "old"
        try await waitUntil("first search running") { manual.calls.count == 1 }
        search.query = "new"
        try await waitUntil("second search running") { manual.calls.count == 2 }

        // The newer query answers first; the older one arrives late and must be dropped.
        manual.answer("new", ids: ["fresh"], terms: ["new"])
        try await waitUntil("new results") { search.resultIDs == ["fresh"] }
        manual.answer("old", ids: ["stale"], terms: ["old"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(search.resultIDs == ["fresh"])
        #expect(search.terms == ["new"])
    }

    /// Final review M6: a failed read does not leave the list waiting for results that never come.
    /// It keeps the results it had and tells the list; they belong to the query before, so no page
    /// of the new query is appended to them, and the next run (a library change, a keystroke)
    /// searches afresh.
    @Test func testAFailedSearchStopsAwaitingResults() async throws {
        let manual = ManualRunner()
        let search = NoteSearch(pageSize: 2, debounce: .zero, runner: manual.runner)
        var newSearches = 0
        search.onResults = { if $0 { newSearches += 1 } }
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "p"
        try await waitUntil("first search") { manual.calls.count == 1 }
        manual.answer("p", ids: ["a", "b"])
        try await waitUntil("results") { search.resultIDs == ["a", "b"] }
        #expect(newSearches == 1)

        search.query = "pq"
        try await waitUntil("second search") { manual.calls.count == 1 }
        #expect(search.isAwaitingNewResults)
        manual.fail("pq")
        try await waitUntil("not awaiting") { !search.isAwaitingNewResults }
        #expect(search.resultIDs == ["a", "b"], "the results it had stay")
        #expect(newSearches == 2, "the list hears about it (selection waits no longer)")

        #expect(!search.hasMore)
        search.loadMore()
        try await Task.sleep(for: .milliseconds(30))
        #expect(manual.calls.isEmpty)

        search.refresh()
        try await waitUntil("retry") { manual.calls.count == 1 }
        #expect(manual.calls.first?.request.offset == 0)
        #expect(manual.calls.first?.request.limit == 2)
        manual.answer("pq", ids: ["b", "c"])
        try await waitUntil("new results") { search.resultIDs == ["b", "c"] }
        #expect(newSearches == 3, "the retry counts as the new search")
        #expect(search.hasMore)
    }

    @Test func testClearingIsImmediateAndDropsRunningSearches() async throws {
        let manual = ManualRunner()
        let search = NoteSearch(debounce: .zero, runner: manual.runner)
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "x"
        try await waitUntil("search running") { manual.calls.count == 1 }
        search.query = "  "
        #expect(!search.isActive)
        #expect(search.resultIDs == nil)
        #expect(search.terms.isEmpty)
        manual.answer("x", ids: ["late"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(search.resultIDs == nil)
    }

    @Test func testPagesLoadWhenScrolledToTheEnd() async throws {
        let manual = ManualRunner()
        let search = NoteSearch(pageSize: 2, debounce: .zero, runner: manual.runner)
        search.update(scope: .archive, sort: .titleAscending)
        search.query = "p"
        try await waitUntil("page 1") { manual.calls.count == 1 }
        manual.answer("p", ids: ["a", "b"])
        try await waitUntil("page 1 results") { search.resultIDs == ["a", "b"] }
        #expect(search.hasMore)

        search.loadMore()
        search.loadMore() // one page at a time
        try await waitUntil("page 2") { manual.calls.count == 1 }
        #expect(manual.calls.first?.request == NoteSearch.Request(query: "p", scope: .archive, sort: .titleAscending, limit: 2, offset: 2))
        manual.answer("p", ids: ["c"])
        try await waitUntil("page 2 results") { search.resultIDs == ["a", "b", "c"] }
        #expect(!search.hasMore)

        // A refresh (the library changed) re-reads everything loaded so far in one query.
        search.refresh()
        try await waitUntil("refresh") { manual.calls.count == 1 }
        #expect(manual.calls.first?.request.limit == 3)
        #expect(manual.calls.first?.request.offset == 0)
    }

    @Test func testScopeChangeReRunsTheSearch() async throws {
        let manual = ManualRunner()
        let search = NoteSearch(debounce: .zero, runner: manual.runner)
        var newSearches: [Bool] = []
        search.onResults = { newSearches.append($0) }
        search.update(scope: .notes, sort: .modifiedDescending)
        search.query = "q"
        try await waitUntil("search") { manual.calls.count == 1 }
        manual.answer("q", ids: ["n"])
        try await waitUntil("results") { newSearches == [true] }

        search.refresh()
        try await waitUntil("refresh") { manual.calls.count == 1 }
        manual.answer("q", ids: ["n"])
        try await waitUntil("refresh results") { newSearches == [true, false] }

        search.update(scope: .trash, sort: .modifiedDescending)
        #expect(search.resultIDs == [], "no stale rows of the old scope")
        #expect(search.isAwaitingNewResults)
        try await waitUntil("scope search") { manual.calls.count == 1 }
        #expect(manual.calls.first?.request.scope == .trash)
        search.refresh() // a refresh before the scope's results arrive keeps them "new"
        try await waitUntil("scope search again") { manual.calls.count == 2 }
        manual.answer("q", ids: ["t"])
        manual.answer("q", ids: ["t"])
        try await waitUntil("scope results") { newSearches == [true, false, true] }
    }

    @Test func testRequiredTagsOfAQuery() {
        #expect(NoteSearch.requiredTags(in: "#work") == .init(tags: ["work"], onlyTags: true))
        #expect(NoteSearch.requiredTags(in: "#work !#home #my tag#") == .init(tags: ["work", "home", "my tag"], onlyTags: true))
        #expect(NoteSearch.requiredTags(in: "#work meeting") == .init(tags: ["work"], onlyTags: false))
        #expect(NoteSearch.requiredTags(in: "#a or #b") == .init(tags: [], onlyTags: false))
        #expect(NoteSearch.requiredTags(in: "-#a") == .init(tags: [], onlyTags: false))
        #expect(NoteSearch.requiredTags(in: "#*/sub") == .init(tags: [], onlyTags: false))
        #expect(NoteSearch.requiredTags(in: "plain") == .init(tags: [], onlyTags: false))
    }

    // MARK: - Library model with the live search

    @Test func testSearchListsMatchesOfTheSelectedScopeOnly() async throws {
        let env = try Env()
        let pie = try env.store.create(text: "Apple pie #food", now: start)
        _ = try env.store.create(text: "Banana", now: start.addingTimeInterval(1))
        let archived = try env.store.create(text: "Apple archived", now: start.addingTimeInterval(2))
        try env.store.archive([archived.id])
        let trashed = try env.store.create(text: "Apple trashed", now: start.addingTimeInterval(3))
        try env.store.trash([trashed.id])
        env.model.refresh()

        env.search.query = "apple"
        try await waitUntil("results in Notes") { env.model.items.map(\.id) == [pie.id] }
        #expect(env.search.terms == ["apple"])

        env.model.selectScope(.archive)
        try await waitUntil("results in Archive") { env.model.items.map(\.id) == [archived.id] }
        env.model.selectScope(.trash)
        try await waitUntil("results in Trash") { env.model.items.map(\.id) == [trashed.id] }
        env.model.selectScope(.tag("food"))
        try await waitUntil("results in the tag") { env.search.resultIDs == [pie.id] }
        #expect(env.model.items.map(\.id) == [pie.id])

        env.search.query = ""
        #expect(env.model.items.map(\.id) == [pie.id], "clearing shows the scope list at once")
    }

    @Test func testResultsArePinnedFirstThenSorted() async throws {
        let env = try Env()
        let older = try env.store.create(text: "Note one", now: start)
        let pinned = try env.store.create(text: "Note two", now: start.addingTimeInterval(1))
        let newer = try env.store.create(text: "Note three", now: start.addingTimeInterval(2))
        _ = try env.store.create(text: "Other", now: start.addingTimeInterval(3))
        try env.store.setPinned([pinned.id], pinned: true)
        env.model.refresh()

        env.search.query = "note"
        try await waitUntil("ranked results") { env.model.items.map(\.id) == [pinned.id, newer.id, older.id] }

        Settings(db: env.environment.database).noteSort = .titleAscending
        try await waitUntil("re-sorted results") { env.model.items.map(\.id) == [pinned.id, older.id, newer.id] }
    }

    @Test func testLibraryChangesRefreshTheResults() async throws {
        let env = try Env()
        let first = try env.store.create(text: "Kiwi", now: start)
        env.model.refresh()
        env.search.query = "kiwi"
        try await waitUntil("results") { env.search.resultIDs == [first.id] }

        let second = try env.store.create(text: "Kiwi again", now: start.addingTimeInterval(1))
        try await waitUntil("new match listed") { Set(env.search.resultIDs ?? []) == [first.id, second.id] }
        #expect(env.model.items.map(\.id) == [second.id, first.id])

        // A command acts on the listed results; the trashed note leaves the list at once.
        env.model.selectNotes([second.id])
        env.model.trashSelected()
        #expect(env.model.items.map(\.id) == [first.id])
        #expect(env.model.focusedNoteID == first.id)
    }

    @Test func testANewQueryFocusesTheFirstResultUnlessTheShownNoteMatches() async throws {
        let env = try Env()
        let alpha = try env.store.create(text: "Alpha", now: start)
        let beta = try env.store.create(text: "Beta", now: start.addingTimeInterval(1))
        env.model.refresh()
        env.model.selectNotes([beta.id])

        env.search.query = "alp"
        try await waitUntil("alpha focused") { env.model.focusedNoteID == alpha.id }
        #expect(env.model.selectedNoteIDs == [alpha.id])

        env.search.query = "a" // both match: the shown note stays
        try await waitUntil("both listed") { env.search.resultIDs?.count == 2 }
        #expect(env.model.focusedNoteID == alpha.id)

        env.search.query = "zzz"
        try await waitUntil("no results") { env.model.items.isEmpty && env.search.resultIDs == [] }
        #expect(env.model.focusedNoteID == nil)

        env.search.query = ""
        #expect(env.model.focusedNoteID == beta.id, "the scope's first note")
    }

    @Test func testEditingTheShownNoteSoItNoLongerMatchesKeepsItOpen() async throws {
        let env = try Env()
        let note = try env.store.create(text: "Mango", now: start)
        _ = try env.store.create(text: "Mango two", now: start.addingTimeInterval(-1))
        env.model.refresh()
        env.search.query = "mango"
        try await waitUntil("results") { env.search.resultIDs?.count == 2 }
        env.model.selectNotes([note.id])

        _ = try env.store.updateText(id: note.id, text: "Papaya", expectedRevision: note.revision)
        try await waitUntil("note left the results") { env.model.items.count == 1 }
        #expect(env.model.focusedNoteID == note.id, "a refresh never moves the editor to another note")
    }

    @Test func testNewNoteWhileSearchingATagGetsTheTag() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Work #work", now: start)
        env.model.refresh()

        env.search.query = "#work"
        try await waitUntil("tag results") { env.search.resultIDs?.count == 1 }
        let id = try env.model.newNote()
        #expect(try env.store.note(id: id)?.text == "\n\n#work")
        #expect(env.search.query == "#work", "a tag-only search stays: the new note matches it")
        try await waitUntil("new note listed") { env.search.resultIDs?.contains(id) == true }
        #expect(env.model.items.contains { $0.id == id })
        #expect(env.model.focusedNoteID == id)
        #expect(env.model.scope == .notes)

        // With other conditions the note would not be listed: the tag is still added, the search ends.
        Settings(db: env.environment.database).tagPosition = .top
        env.search.query = "#work meeting"
        let other = try env.model.newNote()
        #expect(try env.store.note(id: other)?.text == "#work\n\n")
        #expect(env.search.query == "")
        #expect(env.model.items.contains { $0.id == other })

        // A selected tag and a searched one: both, once each.
        env.model.selectScope(.tag("work"))
        env.search.query = "#Work #home"
        let both = try env.model.newNote()
        #expect(try env.store.note(id: both)?.text == "#work #home\n\n")
    }

    // MARK: - Highlighting

    @Test func testHighlightMarksEveryMatchIgnoringCaseAndDiacritics() {
        let text = SearchHighlight.attributed("Müller meets MULLER", terms: ["muller"])
        let marked = text.runs.filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }.map { String(text[$0.range].characters) }
        #expect(marked == ["Müller", "MULLER"])
        #expect(SearchHighlight.attributed("plain", terms: []).runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] == nil })
    }
}
