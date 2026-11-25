// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// The shared title follower (spec §3.5, ruling R15) that both apps drive: a title typed in a
/// session rewrites `[[links]]` to it in other notes once the title is stable.
@Suite @MainActor struct TitleChangeMonitorTests {
    final class ManualScheduler: DebounceScheduler {
        private(set) var now: Duration = .zero
        private var items: [Int: (due: Duration, action: @MainActor () -> Void)] = [:]
        private var next = 0
        func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
            let order = next
            next += 1
            items[order] = (now + delay, action)
            return ScheduledAction { [weak self] in self?.items[order] = nil }
        }
        func advance(by duration: Duration) {
            let end = now + duration
            while let (order, item) = items.filter({ $0.value.due <= end }).min(by: { ($0.value.due, $0.key) < ($1.value.due, $1.key) }) {
                items[order] = nil
                now = item.due
                item.action()
            }
            now = end
        }
    }

    @Test func aTitleTypedInASessionRewritesLinksInOtherNotesOnly() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("title-monitor-\(UUID())"))
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase(path: paths.database)
        let store = NoteStore(db: db, notifier: nil, paths: paths)
        let target = try store.create(text: "# Old\nbody")
        let linking = try store.create(text: "See [[Old]] and [[ Old/Part | alias ]] here")
        let plain = try store.create(text: "# Plain\nNo links to Old")
        let locked = try store.create(text: "Private [[Old]]")
        try NotePrivacy(store: store).setPassword("monitor-password").lock(noteId: locked.id)
        let lockedBefore = try #require(try store.note(id: locked.id))
        let plainBefore = try #require(try store.note(id: plain.id))

        let session = try NoteSession(noteId: target.id, store: store, journalDirectory: paths.journal)
        let scheduler = ManualScheduler()
        var results: [LinkRewriteResult] = []
        let monitor = TitleChangeMonitor(
            scheduler: scheduler, read: { try? store.linkTargetState(id: $0) }, flush: { try? session.flush() },
            rewrite: { id, previous, busy in
                guard let result = try? store.rewriteWikiLinks(to: id, from: previous, deferringIfTouching: busy) else { return true }
                results.append(result)
                return !result.deferred
            })
        _ = session.addActivityListener { monitor.sessionActivity(target.id, $0) }
        monitor.watch([target.id])

        let edit = ChangeSet(sections: [.replace(deleteLength: 10, insert: "# New\nbody")])
        #expect(session.apply(txId: "rename", baseRevision: session.revision, changeSet: edit, origin: nil) == .acked(revision: 1))
        try session.flush()
        #expect(try store.note(id: linking.id)?.text == "See [[Old]] and [[ Old/Part | alias ]] here")
        scheduler.advance(by: TitleChangeMonitor.delay)

        #expect(try store.note(id: linking.id)?.text == "See [[New]] and [[ New/Part | alias ]] here")
        #expect(results.map(\.changedNoteIds) == [[linking.id]])
        let plainAfter = try #require(try store.note(id: plain.id))
        #expect(plainAfter.text == plainBefore.text && plainAfter.revision == plainBefore.revision)
        let lockedAfter = try #require(try store.note(id: locked.id))
        #expect(lockedAfter.isLocked && lockedAfter.revision == lockedBefore.revision)
        #expect(lockedAfter.encryptedPayload == lockedBefore.encryptedPayload)
        #expect(!monitor.hasPendingRewrites)
    }
}
