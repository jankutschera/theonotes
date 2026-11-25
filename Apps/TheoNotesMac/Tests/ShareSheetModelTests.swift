// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing

/// What the share sheet does without its window (C17 fix round 1, FOC-R342): collecting, editing, the
/// picker following the app, and the hand-over. `ShareSheetModel.swift` is compiled into this bundle.
@MainActor
@Suite struct ShareSheetModelTests {
    final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(CaptureRequest, [URL])] = []
        var failing = false
        func add(_ request: CaptureRequest, _ files: [URL]) throws {
            try lock.withLock {
                if failing { throw CocoaError(.fileWriteUnknown) }
                items.append((request, files))
            }
        }
        var requests: [CaptureRequest] { lock.withLock { items.map(\.0) } }
    }

    /// A load that finishes when the test says so.
    @MainActor
    final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    let dir: URL
    let queue = Queue()

    init() throws {
        dir = URL(fileURLWithPath: "/tmp/theo-share-model-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    private func model(container: URL? = nil) -> ShareSheetModel {
        let queue = queue
        return ShareSheetModel(container: container ?? dir, enqueue: { try queue.add($0, $1) })
    }

    private func staging() throws -> StagingArea {
        try StagingArea(directory: dir.appendingPathComponent("staging-\(UUID().uuidString.prefix(6))", isDirectory: true))
    }

    private func publish(_ ids: [String]) throws {
        try SharedContainerFiles.publish(RecentNotesFile(notes: ids.map { .init(id: $0, title: "Note \($0.prefix(4))") }), in: dir)
    }

    private func newId() -> String { UUID().uuidString.lowercased() }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Collecting

    @Test func nothingCanBeEditedOrSavedWhileItemsAreStillLoading() async throws {
        defer { cleanup() }
        try publish([newId()])
        let model = model()
        let gate = Gate()
        let area = try staging()
        let collecting = Task { @MainActor in
            await model.collect(
                texts: ["from the app"], loads: [{ _ in await gate.wait(); return .text("slow part") }], staging: area)
        }
        await Task.yield()

        #expect(model.phase == .collecting)
        #expect(!model.canEdit && !model.canSave && !model.canAppend)
        #expect(await model.submit(target: nil) == false, "Save does nothing before the items are in")
        #expect(queue.requests.isEmpty)

        gate.open()
        await collecting.value
        #expect(model.phase == .ready)
        #expect(model.canEdit && model.canSave && model.canAppend)
        #expect(model.text == "from the app\n\nslow part")
    }

    @Test func textTypedWhileLoadingIsNeverOverwritten() async throws {
        defer { cleanup() }
        let model = model()
        let gate = Gate()
        let area = try staging()
        let collecting = Task { @MainActor in
            await model.collect(texts: [], loads: [{ _ in await gate.wait(); return .text("late text") }], staging: area)
        }
        await Task.yield()
        model.userEdited("typed first")
        gate.open()
        await collecting.value

        #expect(model.text == "typed first\n\nlate text")
    }

    @Test func failedItemsAreReportedAndTheOthersStillLoad() async throws {
        defer { cleanup() }
        let model = model()
        let area = try staging()
        let file = dir.appendingPathComponent("a.txt")
        try Data([1]).write(to: file)
        await model.collect(
            texts: [], loads: [{ _ in .text("kept") }, { _ in .failed }, { _ in .file(file) }, { _ in .failed }], staging: area)

        #expect(model.text == "kept")
        #expect(model.files == [file])
        #expect(model.status.contains("1 file will be attached."))
        #expect(model.status.contains("2 shared items could not be read"))
        #expect(model.phase == .ready)
    }

    @Test func oneFailedItemIsNamedInTheSingular() async throws {
        defer { cleanup() }
        let model = model()
        await model.collect(texts: ["x"], loads: [{ _ in .failed }], staging: try staging())
        #expect(model.status == "1 shared item could not be read and is not included.")
    }

    @Test func withoutAStagingFolderEveryItemCountsAsUnread() async {
        defer { cleanup() }
        let model = model()
        await model.collect(texts: ["from the app"], loads: [{ _ in .text("never called") }], staging: nil)
        #expect(model.text == "from the app")
        #expect(model.status.contains("could not be read"))
        #expect(model.phase == .ready)
    }

    @Test func noContainerMeansNothingCanBeDone() async throws {
        let model = ShareSheetModel(container: nil)
        #expect(model.phase == .unavailable)
        #expect(!model.canSave && !model.canEdit && !model.canAppend)
        #expect(!model.status.isEmpty)
        await model.collect(texts: ["x"], loads: [], staging: nil)
        #expect(model.phase == .unavailable && model.text == "")
        #expect(await model.submit(target: nil) == false)
    }

    // MARK: - Saving

    @Test func saveIsAllowedWithNothingShared() async throws {
        defer { cleanup() }
        let model = model()
        await model.collect(texts: [], loads: [], staging: try staging())
        #expect(model.canSave)
        #expect(await model.submit(target: nil))
        let request = try #require(queue.requests.first)
        #expect(request.mode == .save && request.text == "" && request.files.isEmpty)
    }

    @Test func theTextIsHandedOverExactly() async throws {
        defer { cleanup() }
        let model = model()
        await model.collect(texts: ["  Title \n", "https://example.com", "https://example.com"], loads: [], staging: try staging())
        #expect(await model.submit(target: nil))
        #expect(queue.requests.first?.text == "  Title \n\n\nhttps://example.com\n\nhttps://example.com")

        let again = self.model()
        await again.collect(texts: [], loads: [], staging: try staging())
        again.userEdited("  typed \n\n\n  ")
        #expect(await again.submit(target: nil))
        #expect(queue.requests.last?.text == "  typed \n\n\n  ")
    }

    @Test func aRefusedHandOverCanBeTriedAgain() async throws {
        defer { cleanup() }
        let model = model()
        await model.collect(texts: ["x"], loads: [], staging: try staging())
        queue.failing = true
        #expect(await model.submit(target: nil) == false)
        #expect(model.phase == .ready && model.canSave)
        #expect(model.status.contains("could not take this"))
        queue.failing = false
        #expect(await model.submit(target: nil))
    }

    // MARK: - The picker follows the app

    @Test func anOpenSheetDropsTheNotesTheAppNoLongerOffers() async throws {
        defer { cleanup() }
        let kept = newId(), locked = newId()
        try publish([kept, locked])
        let model = model()
        await model.collect(texts: ["x"], loads: [], staging: try staging())
        #expect(model.recentNotes.map(\.id) == [kept, locked])

        try publish([kept])  // a note was locked
        model.refreshRecentNotes()
        #expect(model.recentNotes.map(\.id) == [kept])

        try SharedContainerFiles.publish(nil, in: dir)  // App Lock was turned on
        model.refreshRecentNotes()
        #expect(model.recentNotes.isEmpty && !model.canAppend)
    }

    @Test func theSheetNoticesTheFileChangingWithoutBeingAsked() async throws {
        defer { cleanup() }
        let first = newId(), second = newId()
        try publish([first, second])
        let model = model()
        var changes = 0
        model.onChange = { changes += 1 }
        model.startWatching()
        defer { model.stopWatching() }

        try SharedContainerFiles.publish(nil, in: dir)
        await waitUntil { model.recentNotes.isEmpty }
        #expect(model.recentNotes.isEmpty, "deleted file: the picker is cleared at once")
        #expect(changes >= 1)

        try publish([second])
        await waitUntil { model.recentNotes.map(\.id) == [second] }
        #expect(model.recentNotes.map(\.id) == [second])
    }

    @Test func anAppendToANoteThatVanishedIsRefusedAndNothingIsQueued() async throws {
        defer { cleanup() }
        let target = newId()
        try publish([target])
        let model = model()
        await model.collect(texts: ["x"], loads: [], staging: try staging())
        try SharedContainerFiles.publish(nil, in: dir)  // App Lock enabled while the sheet is open

        #expect(await model.submit(target: target) == false)
        #expect(queue.requests.isEmpty)
        #expect(model.status == "That note is not available any more.")
        #expect(model.phase == .ready, "Save still works")
        #expect(await model.submit(target: nil))
    }

    @Test func anAppendToAListedNoteIsQueuedAsAnAppend() async throws {
        defer { cleanup() }
        let target = newId()
        try publish([target])
        let model = model()
        await model.collect(texts: ["more"], loads: [], staging: try staging())
        #expect(await model.submit(target: target))
        let request = try #require(queue.requests.first)
        #expect(request.mode == .append && request.targetNoteId == target && request.text == "more")
    }
}
