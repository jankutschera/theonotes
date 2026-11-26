// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M7 Task 12: note-list labels, actions and rotors, the editor's Headings rotor, sidebar keys.
@MainActor
@Suite struct NoteListAccessibilityTests {
    private func item(_ title: String, pinned: Bool = false, locked: Bool = false, subtitle: String = "the preview") -> NoteListItem {
        NoteListItem(
            id: UUID().uuidString, title: title, subtitle: subtitle, modifiedAt: .now, createdAt: .now, isPinned: pinned,
            isLocked: locked, isReadOnly: false, hasAttachments: false, firstImageFilename: nil)
    }

    @Test func rowLabelOrdersTitleFlagsAndDate() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let label = NoteListAccessibility.label(for: item("Budget", pinned: true, locked: true), date: now.addingTimeInterval(-180), now: now)
        #expect(label.hasPrefix("Budget, pinned, locked, modified "))
        #expect(label.contains("3 minutes ago"), "\(label)")
        #expect(NoteListAccessibility.label(for: item("Plain"), date: now, now: now).hasPrefix("Plain, modified "))
    }

    @Test func untitledAndLockedRowsHideThePreview() {
        let now = Date()
        #expect(NoteListAccessibility.label(for: item(""), date: now, now: now).hasPrefix("Untitled, modified "))
        #expect(NoteListAccessibility.value(for: item("Open")) == "the preview")
        #expect(NoteListAccessibility.value(for: item("Secret", locked: true)) == "")
    }

    @Test func trashRowsOfferRestoreAndDeletePermanently() {
        #expect(NoteListAccessibility.actions(for: item("A"), inTrash: true) == [.restore, .deletePermanently])
        #expect(NoteListAccessibility.actions(for: item("A"), inTrash: false) == [.pin, .archive, .trash, .openInNewWindow, .lockNote])
        #expect(NoteListAccessibility.actions(for: item("A", pinned: true), inTrash: false).first == .unpin)
    }

    @Test func aLockedRowOffersRemoveLockInsteadOfLockNote() {
        let actions = NoteListAccessibility.actions(for: item("A", locked: true), inTrash: false)
        #expect(actions == [.pin, .archive, .trash, .openInNewWindow, .removeLock])
        #expect(NoteAXAction.lockNote.rawValue == "Lock Note")
        #expect(NoteAXAction.removeLock.rawValue == "Remove Lock from Note")
        #expect(NoteListAccessibility.actions(for: item("A", locked: true), inTrash: true) == [.restore, .deletePermanently])
    }

    @Test func aLockedRowShowsNoPreviewAndNoThumbnail() {
        let open = NoteListItem(
            id: "o", title: "Open", subtitle: "the preview", modifiedAt: .now, createdAt: .now, isPinned: false,
            isLocked: false, isReadOnly: false, hasAttachments: true, firstImageFilename: "photo.png")
        var locked = open
        locked.isLocked = true
        #expect(NoteRow.previewText(for: open) == "the preview")
        #expect(NoteRow.thumbnailFilename(for: open) == "photo.png")
        #expect(NoteRow.previewText(for: locked) == nil)
        #expect(NoteRow.thumbnailFilename(for: locked) == nil)
    }

    @Test func theLockedRowSaysLockedAndCarriesNoContent() {
        let now = Date()
        let secret = item("Quarterly plan", locked: true, subtitle: "zqxsecretbody")
        let label = NoteListAccessibility.label(for: secret, date: now, now: now)
        #expect(label.contains("locked"))
        #expect(!label.contains("zqxsecretbody"))
        #expect(NoteListAccessibility.value(for: secret).isEmpty)
        #expect(NoteRow.lockedLabel == "Locked")
    }

    @Test func theLabelOfTwoLockedNotesDiffersOnlyByTheirTitle() {
        let now = Date()
        let short = item("A", locked: true, subtitle: "x")
        let long = item("A", locked: true, subtitle: String(repeating: "zqx", count: 10_000))
        #expect(
            NoteListAccessibility.label(for: short, date: now, now: now)
                == NoteListAccessibility.label(for: long, date: now, now: now))
        #expect(NoteListAccessibility.value(for: short) == NoteListAccessibility.value(for: long))
    }

    @Test func pinnedRotorListsPinnedRowsInOrder() {
        let rows = [item("A", pinned: true), item("B"), item("C", pinned: true)]
        #expect(NoteListAccessibility.pinnedRotor(rows) == [rows[0].id, rows[2].id])
    }

    @Test func rightArrowLeavesTheSidebarExceptOnAParentTag() {
        let parents: Set<String> = ["work"]
        #expect(SidebarView.rightArrowMovesToTheList(scope: .notes, isParentTag: parents.contains))
        #expect(SidebarView.rightArrowMovesToTheList(scope: .trash, isParentTag: parents.contains))
        #expect(SidebarView.rightArrowMovesToTheList(scope: .tag("work/a"), isParentTag: parents.contains))
        #expect(!SidebarView.rightArrowMovesToTheList(scope: .tag("work"), isParentTag: parents.contains))
    }

    @Test func headingsRotorListsHeadingsAndScrolls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesAX-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let noteId = try environment.store.create(text: "# One\ntext\n## Two\nmore").id
        let page = FakeEditorPage()
        let controller = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let webView = try #require(controller.webView as? TheoNotesWebView)
        #expect(webView.accessibilityCustomRotors().contains { $0.label == "Headings" })
        let rotor = try #require(webView.headingsRotor)
        #expect(rotor.headings().map(\.label) == ["H1 One", "H2 Two"])

        // Searching (VoiceOver builds its rotor menu this way) never scrolls.
        let first = try #require(rotor.result(filter: "", from: nil, forward: true))
        #expect(first.customLabel == "H1 One")
        let firstElement = try #require(first.targetElement as? HeadingElement)
        let second = try #require(rotor.result(filter: "", from: firstElement.index, forward: true))
        #expect(second.customLabel == "H2 Two")
        #expect(rotor.result(filter: "", from: 1, forward: true) == nil)
        #expect(rotor.result(filter: "", from: nil, forward: false)?.customLabel == "H2 Two")
        #expect(rotor.result(filter: "two", from: nil, forward: true)?.customLabel == "H2 Two")
        func scrolls() -> [Int] { page.delivered.compactMap { if case .scrollToHeading(_, let index) = $0 { index } else { nil } } }
        #expect(scrolls().isEmpty)
        // Landing on an entry (VoiceOver focus) or pressing it scrolls the editor there.
        let secondElement = try #require(second.targetElement as? HeadingElement)
        secondElement.setAccessibilityFocused(true)
        #expect(scrolls() == [1])
        #expect(firstElement.accessibilityPerformPress())
        #expect(scrolls() == [1, 0])
        #expect(secondElement.accessibilityLabel() == "H2 Two")
    }

    /// VoiceOver searches through every entry to build its rotor menu, so a search must not parse the
    /// note: the headings are cached per session revision and recomputed only when the text changes.
    @Test func theHeadingsRotorParsesTheNoteOncePerRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesAX-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let noteId = try environment.store.create(text: "# One\ntext\n## Two\nmore").id
        let controller = EditorBridgeController(
            environment: environment, page: FakeEditorPage(), openExternally: { _ in }, checksumInterval: nil)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let webView = try #require(controller.webView as? TheoNotesWebView)
        let rotor = try #require(webView.headingsRotor)
        #expect(controller.headingsCache.parseCount == 0, "computed on first use, not on open")
        for _ in 0..<25 {
            _ = rotor.result(filter: "", from: nil, forward: true)
            _ = rotor.result(filter: "two", from: 0, forward: true)
            _ = rotor.result(filter: "", from: nil, forward: false)
        }
        #expect(controller.headingsCache.parseCount == 1, "75 searches over an unchanged note parse once")

        // A text change invalidates the cache: the next search parses again and sees the new heading.
        let session = try #require(controller.session)
        let length = session.text.utf16.count
        let change = ChangeSet(sections: [.retain(length), .replace(deleteLength: 0, insert: "\n### Three")])
        guard case .acked = session.apply(txId: "h3", baseRevision: session.revision, changeSet: change, origin: nil) else {
            Issue.record("the edit was not applied")
            return
        }
        #expect(rotor.headings().map(\.label) == ["H1 One", "H2 Two", "H3 Three"])
        #expect(controller.headingsCache.parseCount == 2)
        for _ in 0..<10 { _ = rotor.result(filter: "", from: 1, forward: true) }
        #expect(controller.headingsCache.parseCount == 2)

        // Another note is another session: never the previous note's headings.
        let other = try environment.store.create(text: "# Other").id
        try controller.open(noteId: other)
        #expect(rotor.headings().map(\.label) == ["H1 Other"])
        #expect(controller.headingsCache.parseCount == 3)
    }

    /// Every toolbar button and note-list context action has a menu-bar item (keyboard-only use).
    @Test func everyToolbarAndContextActionHasAMenuBarItem() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let titles = Set(mainMenu.items.compactMap(\.submenu).flatMap(items).map(\.title))
        // Toolbar: New Note, Info. Context menu: Open In New Window, Pin/Unpin, Archive, Move to
        // Trash, Restore, Delete Permanently…, Duplicate (Remove Tag is per tag, also in the Note menu).
        for title in ["New Note", "Toggle Info Panel", "Open In New Window", "Archive", "Move to Trash", "Restore", "Delete Permanently…", "Duplicate"] {
            #expect(titles.contains(title), "\(title) has no menu-bar item")
        }
        #expect(titles.contains("Pin") || titles.contains("Unpin"))
    }
}
