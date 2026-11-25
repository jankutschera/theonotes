// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import BaerchenIOS

/// Renaming a note on iPhone and iPad keeps the wiki links to it, through the same
/// `TitleChangeMonitor` and `NoteStore.rewriteWikiLinks` the Mac uses (spec §3.5).
@Suite @MainActor struct MobileLinkRewriteTests {
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

    @Test func aTitleChangeInASessionRewritesLinksInOtherNotes() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let scheduler = ManualScheduler()
        library.linkScheduler = scheduler
        let target = try library.store.create(text: "# Old\nbody")
        let linking = try library.store.create(text: "See [[Old]] and [[Old/Part|alias]]")
        let plain = try library.store.create(text: "# Plain\nNo link to Old")
        let locked = try library.store.create(text: "Private [[Old]]")
        try await library.unlockNotes(password: "link-rewrite-password", createPassword: true)
        try library.lockNote(locked.id)
        let plainBefore = try #require(try library.store.note(id: plain.id))
        let lockedBefore = try #require(try library.store.note(id: locked.id))

        let session = try library.session(for: target.id)
        let linkingSession = try library.session(for: linking.id)
        let edit = ChangeSet(sections: [.replace(deleteLength: 10, insert: "# New\nbody")])
        let revision = session.revision
        #expect(session.apply(txId: "rename", baseRevision: revision, changeSet: edit, origin: nil) == .acked(revision: revision + 1))
        try library.flush()
        scheduler.advance(by: TitleChangeMonitor.delay)

        #expect(try library.store.note(id: linking.id)?.text == "See [[New]] and [[New/Part|alias]]")
        #expect(linkingSession.text == "See [[New]] and [[New/Part|alias]]")
        let plainAfter = try #require(try library.store.note(id: plain.id))
        #expect(plainAfter.text == plainBefore.text && plainAfter.revision == plainBefore.revision)
        let lockedAfter = try #require(try library.store.note(id: locked.id))
        #expect(lockedAfter.isLocked && lockedAfter.revision == lockedBefore.revision)
        #expect(lockedAfter.encryptedPayload == lockedBefore.encryptedPayload)
    }

    private func makeLibrary() throws -> (MobileLibrary, ManualScheduler) {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let scheduler = ManualScheduler()
        library.linkScheduler = scheduler
        return (library, scheduler)
    }

    private func type(_ text: String, replacing length: Int, at offset: Int = 0, in session: NoteSession, id: String) {
        let rest = session.text.utf16.count - offset - length
        var sections: [ChangeSet.Section] = []
        if offset > 0 { sections.append(.retain(offset)) }
        sections.append(.replace(deleteLength: length, insert: text))
        if rest > 0 { sections.append(.retain(rest)) }
        let revision = session.revision
        #expect(session.apply(txId: id, baseRevision: revision, changeSet: ChangeSet(sections: sections), origin: nil) == .acked(revision: revision + 1))
    }

    /// IOS-LINKS-R4: a rename still in its pause is followed when the app leaves the front.
    @Test func goingToTheBackgroundRunsAPendingRewrite() throws {
        let (library, _) = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let target = try library.store.create(text: "# Old\nbody")
        let linking = try library.store.create(text: "See [[Old]]")
        let session = try library.session(for: target.id)
        type("# New", replacing: 5, in: session, id: "rename")
        try session.flush()
        #expect(try library.store.note(id: linking.id)?.text == "See [[Old]]")
        library.setActive(false)
        #expect(try library.store.note(id: linking.id)?.text == "See [[New]]")
    }

    /// IOS-LINKS-R4: closing the library runs a pending rewrite before the sessions go.
    @Test func closingTheLibraryRunsAPendingRewrite() throws {
        let (library, _) = try makeLibrary()
        let paths = library.paths
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let target = try library.store.create(text: "# Old\nbody")
        let linking = try library.store.create(text: "See [[Old]]")
        let session = try library.session(for: target.id)
        type("# New", replacing: 5, in: session, id: "rename")
        try session.flush()
        try library.close()
        let reopened = try MobileLibrary(paths: paths)
        defer { try? reopened.close() }
        #expect(try reopened.store.note(id: linking.id)?.text == "See [[New]]")
    }

    /// Note B has typing in its open session that is not saved yet when note A is renamed and B
    /// links to A: B's typing stays, and the link follows once B's editor is idle.
    @Test func unsavedTypingInTheLinkingNoteIsKeptAndTheLinkFollows() throws {
        let (library, scheduler) = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let a = try library.store.create(text: "# Alpha\nbody")
        let b = try library.store.create(text: "Start [[Alpha]] end")
        let sessionA = try library.session(for: a.id)
        let sessionB = try library.session(for: b.id)
        type("typed ", replacing: 0, in: sessionB, id: "b1")
        type("# Beta", replacing: 7, in: sessionA, id: "rename")
        try sessionA.flush()
        #expect(sessionB.text != sessionB.committedText)

        scheduler.advance(by: .milliseconds(1400))
        type("!", replacing: 0, at: sessionB.text.utf16.count, in: sessionB, id: "b2")
        scheduler.advance(by: .milliseconds(100))
        // B's editor is typing: the rewrite waits, and nothing B typed is lost.
        #expect(sessionB.text == "typed Start [[Alpha]] end!")
        #expect(try library.store.note(id: b.id)?.text == "typed Start [[Alpha]] end!")

        scheduler.advance(by: .milliseconds(500))
        #expect(sessionB.text == "typed Start [[Beta]] end!")
        #expect(try library.store.note(id: b.id)?.text == "typed Start [[Beta]] end!")
    }

    /// IOS-LINKS-R5: after a restore the follower starts from the restored notes, not from what it
    /// saw before.
    @Test func aRestoreResetsWhatTheFollowerSawBefore() async throws {
        let (library, scheduler) = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let target = try library.store.create(text: "# Backup\nbody")
        let linking = try library.store.create(text: "See [[Backup]]")
        let backup = try await library.makeBackup()
        _ = try library.store.updateText(id: target.id, text: "# Old\nbody", expectedRevision: target.revision)
        _ = try library.store.updateText(id: linking.id, text: "See [[Old]]", expectedRevision: linking.revision)
        _ = try library.session(for: target.id)
        _ = try await library.restoreBackup(backup, mode: .replaceAll, backupPassword: nil, currentPassword: nil)

        let restored = try #require(try library.store.allNotes().first { $0.title == "Backup" })
        let restoredLink = try #require(try library.store.allNotes().first { $0.text.hasPrefix("See") })
        let session = try library.session(for: restored.id)
        type("# New", replacing: 8, in: session, id: "rename")
        try session.flush()
        scheduler.advance(by: TitleChangeMonitor.delay)
        #expect(try library.store.note(id: restoredLink.id)?.text == "See [[New]]")
    }
}
