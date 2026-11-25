// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import TheoNotesCore
import Testing
@testable import BaerchenIOS

@MainActor struct MobileWidgetConfigurationsTests {
    @Test func acceptsOnlyConfiguredItemsFromActiveLibrary() {
        var selected = MobileWidgetSelections()
        selected.addNote(library: "current", id: "pin", activeLibrary: "current")
        selected.addNote(library: "old", id: "stale", activeLibrary: "current")
        selected.addTag(library: "current", tag: "work", activeLibrary: "current")
        selected.addTag(library: "current", tag: nil, activeLibrary: "current")
        selected.addTag(library: "old", tag: "private", activeLibrary: "current")
        #expect(selected.notes == ["pin"])
        #expect(selected.tags == ["work"])
    }
}

/// Intentionally ignores task cancellation until the test releases the response. This models
/// WidgetCenter completing a request after a newer refresh or a privacy boundary superseded it.
@MainActor private final class HeldWidgetConfigurations {
    private(set) var requests = 0
    private var replies: [Int: CheckedContinuation<MobileWidgetSelections, any Error>] = [:]
    func fetch() async throws -> MobileWidgetSelections {
        requests += 1
        let request = requests
        return try await withCheckedThrowingContinuation { replies[request] = $0 }
    }
    func release(_ request: Int, selections: MobileWidgetSelections) {
        replies.removeValue(forKey: request)?.resume(returning: selections)
    }
    func cancelRemaining() {
        let pending = replies.values
        replies.removeAll()
        for reply in pending { reply.resume(throwing: CancellationError()) }
    }
}

extension MobileWidgetConfigurationsTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Widget host publication did not reach the expected state")
        throw CocoaError(.fileReadUnknown)
    }

    @Test func ordinaryPublicationBurstPerformsOneFetchAndOneWidgetReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer {
            library.widgetPublicationTask?.cancel()
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        _ = try library.store.create(text: "# Coalesced widget fixture")
        try await wait { library.snapshot.items.count == 1 }
        library.widgetPublisher = try MobileCardPublicationPublisher(library: library, container: container)
        library.widgetPublicationDebounce = .milliseconds(100)
        var requests = 0, reloads = 0
        library.widgetConfigurations = { _ in requests += 1; return MobileWidgetSelections() }
        library.reloadWidgetTimelines = { reloads += 1 }
        library.publishRecentNotes(); library.publishRecentNotes(); library.publishRecentNotes()
        try await Task.sleep(for: .milliseconds(20))
        #expect(requests == 0 && reloads == 0)
        await library.widgetPublicationTask?.value
        #expect(requests == 1 && reloads == 1)
        #expect(WidgetSnapshot.read(container: container)?.redacted == false)
    }

    @Test(arguments: [false, true])
    func privacyScrubNeverWaitsForOrdinaryPublicationDebounce(enableAppLock: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer {
            library.widgetPublicationTask?.cancel()
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        _ = try library.store.create(text: "# Must disappear immediately")
        try await wait { library.snapshot.items.count == 1 }
        let publisher = try MobileCardPublicationPublisher(library: library, container: container)
        library.widgetPublisher = publisher
        #expect(try publisher.refresh())
        library.widgetPublicationDebounce = .seconds(3600)
        var requests = 0, reloads = 0
        library.widgetConfigurations = { _ in requests += 1; return MobileWidgetSelections() }
        library.reloadWidgetTimelines = { reloads += 1 }
        library.publishRecentNotes()
        let pending = try #require(library.widgetPublicationTask)
        if enableAppLock { try await library.setAppLock(true, authenticate: {}) }
        else { try library.clearSharePublication() }
        #expect(WidgetSnapshot.read(container: container)?.redacted == true)
        #expect(reloads == 1 && requests == 0)
        await pending.value
        #expect(WidgetSnapshot.read(container: container)?.redacted == true)
    }

    @Test func lateOldConfigurationCannotReplaceNewerConfiguredPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        library.widgetPublicationDebounce = .zero
        let held = HeldWidgetConfigurations()
        defer {
            library.widgetPublicationTask?.cancel(); held.cancelRemaining()
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        let old = try library.store.create(text: "# Old configured fixture")
        let current = try library.store.create(text: "# Current configured fixture")
        try library.store.setPinned([old.id, current.id], pinned: true)
        // Finish the note observation before installing the held configuration provider.
        try await wait { library.snapshot.items.count == 2 && library.snapshot.items.allSatisfy(\.isPinned) }
        library.widgetPublisher = try MobileCardPublicationPublisher(library: library, container: container)
        library.widgetConfigurations = { _ in try await held.fetch() }
        library.publishRecentNotes()
        let oldTask = try #require(library.widgetPublicationTask)
        try await wait { held.requests == 1 }
        library.publishRecentNotes()
        let currentTask = try #require(library.widgetPublicationTask)
        try await wait { held.requests == 2 }
        held.release(2, selections: MobileWidgetSelections(notes: [current.id]))
        await currentTask.value
        let published = try #require(WidgetSnapshot.read(container: container))
        #expect(published.configuredPins.map(\.id) == [current.id])
        let file = container.appendingPathComponent(WidgetSnapshot.relativePath)
        let currentBytes = try Data(contentsOf: file)
        held.release(1, selections: MobileWidgetSelections(notes: [old.id]))
        await oldTask.value
        #expect(try Data(contentsOf: file) == currentBytes)
        #expect(WidgetSnapshot.read(container: container)?.configuredPins.map(\.id) == [current.id])
    }

    @Test(arguments: [false, true])
    func scrubOrAppLockDuringFetchCannotRepublishReadableText(enableAppLock: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        library.widgetPublicationDebounce = .zero
        let held = HeldWidgetConfigurations()
        defer {
            library.widgetPublicationTask?.cancel(); held.cancelRemaining()
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        let note = try library.store.create(text: "# Text must remain redacted\nWidget-private fixture")
        try await wait { library.snapshot.items.count == 1 }
        let publisher = try MobileCardPublicationPublisher(library: library, container: container)
        library.widgetPublisher = publisher
        #expect(try publisher.refresh())
        #expect(WidgetSnapshot.read(container: container)?.redacted == false)
        library.widgetConfigurations = { _ in try await held.fetch() }
        library.publishRecentNotes()
        let oldTask = try #require(library.widgetPublicationTask)
        try await wait { held.requests == 1 }
        if enableAppLock { try await library.setAppLock(true, authenticate: {}) }
        else { try library.clearSharePublication() }
        #expect(WidgetSnapshot.read(container: container)?.redacted == true)
        held.release(1, selections: MobileWidgetSelections(notes: [note.id], tags: ["private"]))
        await oldTask.value
        #expect(WidgetSnapshot.read(container: container)?.redacted == true)
        if enableAppLock {
            // The replacement request also must honor enabled App Lock while authenticated.
            try await wait { held.requests == 2 }
            let replacement = try #require(library.widgetPublicationTask)
            held.release(2, selections: MobileWidgetSelections(notes: [note.id]))
            await replacement.value
            #expect(library.appLockEnabled && !library.appLocked)
        }
        let snapshot = try #require(WidgetSnapshot.read(container: container))
        let wire = String(decoding: try snapshot.encoded(), as: UTF8.self)
        #expect(snapshot.redacted)
        #expect(!wire.contains(note.id) && !wire.contains("Widget-private fixture"))
    }

    @Test func successfulPendingScrubRecoverySchedulesReplacementPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")), shareContainer: container)
        defer {
            library.widgetPublicationTask?.cancel()
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        let note = try library.store.create(text: "# Recovered publication\n\n#fixture")
        try library.store.setPinned([note.id], pinned: true)
        try await wait { library.snapshot.items.count == 1 && library.snapshot.items.first?.isPinned == true }
        _ = try #require(library.widgetPublisher)
        library.widgetPublicationDebounce = .zero
        var requests = 0
        library.widgetConfigurations = { _ in
            requests += 1
            return MobileWidgetSelections(notes: [note.id], tags: ["fixture"])
        }
        library.sharePublicationScrubPending = true
        library.publishRecentNotes()
        #expect(!library.sharePublicationScrubPending)
        let replacement = try #require(library.widgetPublicationTask,
            "Successful pending cleanup must leave a replacement widget publication task")
        #expect(!replacement.isCancelled)
        await replacement.value
        #expect(requests == 1)
        let published = try #require(WidgetSnapshot.read(container: container))
        #expect(!published.redacted)
        #expect(published.configuredPins.map(\.id) == [note.id])
        #expect(published.configuredTags.map(\.id) == ["fixture"])
    }

    @Test func recordingEditorOpenRefreshesLastOpenedAndNextUpOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer {
            library.widgetPublicationTask?.cancel()
            try? library.close(); try? FileManager.default.removeItem(at: root)
        }
        let first = try library.store.create(text: "# First task\n- [ ] First fixture", now: .now.addingTimeInterval(-200))
        let second = try library.store.create(text: "# Second task\n- [ ] Second fixture", now: .now.addingTimeInterval(-100))
        try await wait { library.snapshot.items.count == 2 }
        library.widgetPublisher = try MobileCardPublicationPublisher(library: library, container: container)
        library.widgetPublicationDebounce = .zero
        var requests = 0
        library.widgetConfigurations = { _ in requests += 1; return MobileWidgetSelections() }
        library.publishRecentNotes()
        await library.widgetPublicationTask?.value
        let before = try #require(WidgetSnapshot.read(container: container))
        #expect(before.lastOpened == nil && before.nextUp.first?.noteId == first.id)
        let priorRequests = requests
        library.recordEditorOpen(noteId: first.id)
        await library.widgetPublicationTask?.value
        try await wait { WidgetSnapshot.read(container: container)?.lastOpened?.id == first.id }
        let after = try #require(WidgetSnapshot.read(container: container))
        #expect(requests > priorRequests)
        #expect(after.lastOpened?.id == first.id)
        #expect(after.nextUp.first?.noteId == second.id)
    }
}
