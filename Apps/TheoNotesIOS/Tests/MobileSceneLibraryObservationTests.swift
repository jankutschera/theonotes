// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation
import Synchronization
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileSceneLibraryObservationTests {
    private func fixture() throws -> (AppPaths, AppDatabase, NoteStore) {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        return (paths, db, NoteStore(db: db, notifier: nil, paths: paths))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func twoScenesObserveIndependentScopesWorkspacesAndLiveWrites() async throws {
        let (paths, db, store) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let work = try store.create(text: "# Work alpha\n#Work"), home = try store.create(text: "# Home beta\n#Home")
        let leftNav = MobileSceneNavigation(), rightNav = MobileSceneNavigation()
        leftNav.workspace = Workspace(path: "Work")
        rightNav.scope = .tag("Home")
        let left = MobileSceneLibraryObservation(navigation: leftNav, database: db, isCurrent: { true }, debounce: .zero)
        let right = MobileSceneLibraryObservation(navigation: rightNav, database: db, isCurrent: { true }, debounce: .zero)
        defer { left.stop(); right.stop() }
        left.start(); right.start()
        #expect(left.items.map(\.id) == [work.id] && right.items.map(\.id) == [home.id])
        leftNav.query = "alpha" // Automatic observation: no shared MobileLibrary.query mutation.
        try await waitUntil { left.searchTerms == ["alpha"] }
        #expect(left.items.map(\.id) == [work.id] && right.items.map(\.id) == [home.id])
        let another = try store.create(text: "# Another home\n#Home")
        try await waitUntil { Set(right.items.map(\.id)) == [home.id, another.id] }
        #expect(left.items.map(\.id) == [work.id] && rightNav.query.isEmpty)
        right.stop()
        _ = try store.create(text: "# Third home\n#Home")
        try await Task.sleep(for: .milliseconds(30))
        #expect(right.items.isEmpty && right.snapshot.items.isEmpty)
        #expect(leftNav.workspace == Workspace(path: "Work"))
    }

    @Test func staleUncooperativeSearchCannotWinAfterQueryABAOrStop() async throws {
        let (paths, db, _) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let held = HeldSceneSearch(), nav = MobileSceneNavigation()
        let model = MobileSceneLibraryObservation(navigation: nav, database: db, isCurrent: { true }, debounce: .zero,
            searchOperation: { request, _ in await held.run(request) })
        defer { model.stop(); held.finishAll() }
        model.start()
        nav.query = "alpha"; model.synchronize()
        try await waitUntil { held.requests.count == 1 }
        nav.query = "beta"; model.synchronize()
        try await waitUntil { held.requests.count == 2 }
        nav.query = "alpha"; model.synchronize()
        try await waitUntil { held.requests.count == 3 }
        held.finish(2, title: "current")
        try await waitUntil { model.items.first?.title == "current" }
        held.finish(0, title: "stale alpha"); held.finish(1, title: "stale beta")
        await Task.yield()
        #expect(model.items.first?.title == "current")
        nav.query = "late"; model.synchronize()
        try await waitUntil { held.requests.count == 4 }
        model.stop()
        held.finish(3, title: "after stop")
        await Task.yield()
        #expect(model.items.isEmpty && model.searchTerms.isEmpty && model.snapshot.items.isEmpty)
    }

    @Test func repeatedSynchronizeDoesNotDuplicateAnUnchangedSearch() async throws {
        let (paths, db, _) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let held = HeldSceneSearch(), nav = MobileSceneNavigation()
        let model = MobileSceneLibraryObservation(navigation: nav, database: db, isCurrent: { true }, debounce: .zero,
            searchOperation: { request, _ in await held.run(request) })
        defer { model.stop(); held.finishAll() }
        nav.query = "one"
        model.start()
        try await waitUntil { held.requests.count == 1 }
        for _ in 0..<20 { model.synchronize(); model.start() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(held.requests.count == 1)
        held.finish(0, title: "one result")
        try await waitUntil { model.items.first?.title == "one result" }
        model.synchronize()
        await Task.yield()
        #expect(held.requests.count == 1)
    }

    @Test func stopAndWaitDrainsReplacedNoncooperativeActualDatabaseReadsBeforeClose() async throws {
        let (paths, db, _) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let old = HeldScenePoolRead(), current = HeldScenePoolRead(), nav = MobileSceneNavigation()
        let model = MobileSceneLibraryObservation(navigation: nav, database: db, isCurrent: { true }, debounce: .zero,
            searchOperation: { request, database in
                try await database.pool.read { _ in
                    (request.query == "old" ? old : current).hold()
                    return SearchResult(items: [], terms: [request.query])
                }
            })
        defer { old.release(); current.release(); model.stop() }
        nav.query = "old"; model.start()
        try await waitUntil { old.started }
        nav.query = "current"; model.synchronize()
        try await waitUntil { current.started }
        var drained = false
        let drain = Task { try await model.stopAndWait(); drained = true }
        await Task.yield()
        #expect(model.items.isEmpty && !drained)
        model.start() // Admission is closed until ALL replaced workers have ended.
        current.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!drained && model.snapshot.items.isEmpty)
        old.release()
        try await drain.value
        #expect(drained && model.items.isEmpty)
        try db.pool.close() // No reader is held and no model can admit a late query.
    }

    @Test func privacyBoundaryHidesResultsSynchronouslyAndCanRestartCleanly() async throws {
        let (paths, db, store) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try store.create(text: "# Visible while unlocked")
        let gate = SceneObservationGate(), nav = MobileSceneNavigation()
        let model = MobileSceneLibraryObservation(navigation: nav, database: db, isCurrent: { gate.allowed }, debounce: .zero)
        defer { model.stop() }
        model.start()
        #expect(model.items.map(\.id) == [note.id])
        gate.allowed = false
        // No run-loop hop: cached results must already be inaccessible.
        #expect(model.items.isEmpty && model.snapshot.items.isEmpty && model.errorMessage == nil)
        model.synchronize()
        gate.allowed = true
        model.synchronize()
        #expect(model.items.map(\.id) == [note.id])
        for _ in 0..<10 { model.stop(); model.start() }
        #expect(model.items.map(\.id) == [note.id])
        model.stop()
        gate.allowed = false; gate.allowed = true
        await Task.yield()
        #expect(model.items.isEmpty)
    }

    @Test func heldPrelockResultCannotReappearOnUnlock() async throws {
        let (paths, db, _) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let held = HeldSceneSearch(), gate = SceneObservationGate(), nav = MobileSceneNavigation()
        let model = MobileSceneLibraryObservation(navigation: nav, database: db,
            isCurrent: { gate.allowed }, debounce: .zero,
            searchOperation: { request, _ in await held.run(request) })
        defer { model.stop(); held.finishAll() }
        nav.query = "private"; model.start()
        try await waitUntil { held.requests.count == 1 }
        gate.allowed = false
        #expect(model.items.isEmpty && model.snapshot.items.isEmpty)
        model.synchronize()
        held.finish(0, title: "old private result")
        await Task.yield()
        #expect(model.items.isEmpty)
        gate.allowed = true
        model.synchronize()
        try await waitUntil { held.requests.count == 2 }
        #expect(model.items.isEmpty) // A new read, not the prelock completion, owns unlock.
        held.finish(1, title: "fresh unlocked result")
        try await waitUntil { model.items.first?.title == "fresh unlocked result" }
        try await model.stopAndWait()
    }

    @Test func disappearingWorkspaceFallsBackOnlyInItsOwnScene() async throws {
        let (paths, db, store) = try fixture()
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try store.create(text: "# Ordinary note")
        let leftNav = MobileSceneNavigation(), rightNav = MobileSceneNavigation()
        leftNav.workspace = Workspace(path: "Missing")
        rightNav.scope = .archive
        let left = MobileSceneLibraryObservation(navigation: leftNav, database: db, isCurrent: { true }, debounce: .zero)
        let right = MobileSceneLibraryObservation(navigation: rightNav, database: db, isCurrent: { true }, debounce: .zero)
        defer { left.stop(); right.stop() }
        right.start(); left.start()
        try await waitUntil { leftNav.workspace == nil && left.items.map(\.id) == [note.id] }
        #expect(rightNav.scope == .archive && right.items.isEmpty)
    }
}

@MainActor @Observable private final class SceneObservationGate { var allowed = true }

@MainActor private final class HeldSceneSearch {
    var requests: [MobileSceneLibraryObservation.SearchRequest] = []
    private var continuations: [Int: CheckedContinuation<SearchResult, Never>] = [:]
    func run(_ request: MobileSceneLibraryObservation.SearchRequest) async -> SearchResult {
        let index = requests.count; requests.append(request)
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func finishAll() {
        for continuation in continuations.values { continuation.resume(returning: SearchResult(items: [], terms: [])) }
        continuations.removeAll()
    }
    func finish(_ index: Int, title: String) {
        let now = Date(timeIntervalSince1970: 0)
        let item = NoteListItem(id: title, title: title, subtitle: "", modifiedAt: now, createdAt: now,
            isPinned: false, isLocked: false, isReadOnly: false, hasAttachments: false, firstImageFilename: nil)
        continuations.removeValue(forKey: index)?.resume(returning: SearchResult(items: [item], terms: [requests[index].query]))
    }
}

private final class HeldScenePoolRead: Sendable {
    private let didStart = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)
    var started: Bool { didStart.withLock { $0 } }
    func hold() { didStart.withLock { $0 = true }; semaphore.wait() }
    func release() { semaphore.signal() }
}
