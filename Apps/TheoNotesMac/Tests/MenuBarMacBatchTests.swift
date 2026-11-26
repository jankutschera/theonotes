// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// The 1.1 Mac menu changes (A7, A11, A12), read from the real menu bar like
/// `NoteTypeCommandTests.menuBarHasTypeSubmenuAndSortInbox`.
@MainActor
@Suite struct MenuBarMacBatchTests {
    private func menu(_ title: String) throws -> NSMenu {
        let mainMenu = try #require(NSApp.mainMenu)
        let menu = try #require(mainMenu.items.first { $0.title == title }?.submenu, "\(title) menu missing")
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private func visible(_ menu: NSMenu) -> [NSMenuItem] { menu.items.filter { !$0.isHidden && !$0.isSeparatorItem } }

    private func titles(_ menu: NSMenu) -> [String] { visible(menu).map(\.title) }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(visible(menu).first { $0.title == title }, "\(title) missing: \(titles(menu))")
    }

    private func keys(_ item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + item.keyEquivalent
    }

    @Test func editMenuHasCopyAsWithPlainTextKeepTagsAndShiftCommandC() throws {
        let edit = try menu("Edit")
        let copyAs = try #require(try item("Copy As", in: edit).submenu)
        #expect(copyAs.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Markdown", "Plain Text", "HTML", "Rich Text", "Keep Tags"])
        #expect(try keys(item("Rich Text", in: copyAs)).lowercased() == "⇧⌘c")
        // ⇧⌘C is used once in the whole bar (A10: checked free before it was given away).
        var users: [String] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                let flags = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                if item.keyEquivalent.lowercased() == "c", flags == [.command, .shift] { users.append(path + item.title) }
                if let sub = item.submenu { walk(sub, path: path + item.title + " > ") }
            }
        }
        for top in try #require(NSApp.mainMenu).items { if let sub = top.submenu { sub.delegate?.menuNeedsUpdate?(sub); walk(sub, path: top.title + " > ") } }
        #expect(users == ["Edit > Copy As > Rich Text"], "\(users)")
    }

    @Test func formatComesBeforeNote() throws {
        let order = try #require(NSApp.mainMenu).items.map(\.title)
        let format = try #require(order.firstIndex(of: "Format"))
        let note = try #require(order.firstIndex(of: "Note"))
        #expect(format < note, "\(order)")
    }

    @Test func viewMenuHasNoShowSidebarAndQuickOpenMovedHere() throws {
        let view = try menu("View")
        let all = titles(view)
        #expect(!all.contains("Show Sidebar") && !all.contains("Hide Sidebar"), "\(all)")
        // No window tabs: the system's tab items are gone with automatic tabbing.
        #expect(!NSWindow.allowsAutomaticWindowTabbing)
        #expect(!all.contains("Show Tab Bar") && !all.contains("Show All Tabs") && !all.contains("Hide Tab Bar"), "\(all)")
        // The layout presets stay; Quick Open moved here from File.
        #expect(try keys(item("Show Notes and Editor", in: view)) == "⌃2")
        #expect(try keys(item("Quick Open…", in: view)) == "⌘o")
        #expect(titles(try menu("File")).contains("Quick Open…") == false)
    }

    @Test func viewMenuHasTheSectionsAndNoteSorting() throws {
        let view = try menu("View")
        // The menu mirrors the sidebar: its sections, its order, its names.
        let sections = SectionMenu.items.map { SectionMenu.title($0.scope) }
        #expect(sections == [
            "Show Notes", "Show Inbox", "Show Ideas", "Show Logs", "Show References", "Show Pinned", "Show Untagged",
            "Show To Do", "Show Today", "Show Locked", "Show Archive", "Show Trash",
        ])
        #expect(SectionMenu.items.map(\.scope) == SidebarView.fixedScopes)
        let shown = visible(view).map(\.title).filter { $0.hasPrefix("Show ") && sections.contains($0) }
        #expect(shown == sections, "\(titles(view))")
        for (entry, title) in zip(SectionMenu.items, sections) {
            let item = try item(title, in: view)
            if let key = entry.key {
                #expect(keys(item) == "⌥⌘" + String(key), "\(title)")
            } else {
                #expect(item.keyEquivalent.isEmpty, "\(title) has no shortcut")
            }
        }
        // The unit-test host has no app model, so the submenu is empty here; its items are read from the running app
        // (docs/release/evidence/2026-11-13-mac-menus-1.1.md).
        _ = try #require(try item(NoteSortMenu.submenu, in: view).submenu)
    }

    @Test func fileMenuHasNoCaptureThought() throws {
        let file = titles(try menu("File"))
        #expect(!file.contains("Capture Thought"), "\(file)")
        #expect(file.contains("Capture Voice Note"))
    }

    /// The Trash row's Empty Trash… asks like this File item (A13), so the File item must exist.
    @Test func fileMenuHasEmptyTrash() throws {
        let file = try menu("File")
        let raw = file.items.map { "\($0.title)|hidden=\($0.isHidden)|key=\($0.keyEquivalent)" }
        let emptyTrash = try #require(file.items.first { $0.title == "Empty Trash…" }, "File items: \(raw)")
        #expect(!emptyTrash.isHidden, "File items: \(raw)")
        #expect(emptyTrash.keyEquivalentModifierMask.intersection([.command, .shift]) == [.command, .shift])
    }

    @Test func editMenuHasExactlyOneFindSubmenu() throws {
        let edit = try menu("Edit")
        let finds = visible(edit).filter { $0.title == "Find" }
        #expect(finds.count == 1, "\(titles(edit))")
        #expect(titles(try #require(finds.first?.submenu)).contains("Search Notes"))
    }

    @Test func noteMenuHasReadOnlyCopyLinkAndCopyIdentifier() throws {
        let note = try menu("Note")
        let readOnly = try item(NoteCommandMenu.makeReadOnly, in: note)
        #expect(!readOnly.isEnabled, "no selection, no read-only switch")
        #expect(try keys(item(NoteCommandMenu.copyLink, in: note)) == "⌥⇧⌘l")
        #expect(try keys(item(NoteCommandMenu.copyIdentifier, in: note)) == "⌥⇧⌘i")
    }

    @Test func formatMenuHasOneCopyTableSubmenuAndHeadingNumbers() throws {
        let format = try menu("Format")
        let heading = try #require(try item("Heading", in: format).submenu)
        #expect(titles(heading) == (1...6).map { "Heading \($0)" })
        let table = try #require(try item("Table", in: format).submenu)
        let names = titles(table)
        #expect(!names.contains { $0.hasPrefix("Copy Table as") }, "\(names)")
        let copy = try #require(try item(FormatMenu.copyTableTitle, in: table).submenu)
        #expect(titles(copy) == ["CSV", "HTML", "Markdown"])
    }

    @Test func helpMenuHoldsTheDiagnostics() throws {
        let help = titles(try menu("Help"))
        #expect(help.contains(DiagnosticsMenu.showReports) && help.contains(DiagnosticsMenu.copySummary), "\(help)")
    }
}

@MainActor
@Suite struct NoteCommandStateMacBatchTests {
    private func item(_ id: String, readOnly: Bool) -> NoteListItem {
        NoteListItem(
            id: id, title: id, subtitle: "", modifiedAt: .now, createdAt: .now, isPinned: false, isLocked: false,
            isReadOnly: readOnly, hasAttachments: false, firstImageFilename: nil)
    }

    @Test func readOnlyTitleFollowsTheSelection() {
        let items = [item("a", readOnly: true), item("b", readOnly: false)]
        func state(_ ids: Set<String>, scope: SidebarScope = .notes) -> NoteCommandState {
            NoteCommandState(scope: scope, items: items, selectedNoteIDs: ids, counts: SidebarCounts())
        }
        #expect(state(["a"]).readOnlyTitle == "Allow Editing")
        #expect(state(["b"]).readOnlyTitle == "Make Read-Only")
        #expect(state(["a", "b"]).readOnlyTitle == "Make Read-Only")
        #expect(state(["a"]).canSetReadOnly && state(["a"]).canCopyLink)
        #expect(!state([]).canSetReadOnly && !state([]).canCopyLink)
        #expect(!state(["a"], scope: .trash).canSetReadOnly)
    }

    @Test func sectionsTheSidebarHidesAreNotReachable() {
        var counts = SidebarCounts()
        counts.pinned = 1
        #expect(SidebarView.isShown(.pinned, in: counts))
        #expect(!SidebarView.isShown(.archive, in: counts) && !SidebarView.isShown(.locked, in: counts))
        #expect(SidebarView.isShown(.trash, in: counts))
    }

    @Test func noteLinkUsesTheIdentitysScheme() {
        #expect(NoteLink.url(id: "abc", identity: .dev).absoluteString == "theonotes-dev://x-callback-url/open-note?id=abc")
        #expect(NoteLink.url(id: "abc", identity: .production).absoluteString == "theonotes://x-callback-url/open-note?id=abc")
    }

    @Test func sortMenuNamesTheOrderByField() {
        #expect(NoteSortMenu.orderTitle(ascending: false, field: .modified) == "Newest First")
        #expect(NoteSortMenu.orderTitle(ascending: true, field: .title) == "A to Z")
        #expect(NoteSortMenu.orderTitle(ascending: false, field: .title) == "Z to A")
    }
}
