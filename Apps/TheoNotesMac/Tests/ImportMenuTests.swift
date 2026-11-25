// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TheoNotes

/// File ▸ Import From ▸ Evernote… and Notion…, their open panels, and the gates the whole Import
/// menu shares.
@MainActor
@Suite struct ImportMenuTests {
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private func importFromMenu() throws -> NSMenu {
        let mainMenu = try #require(NSApp.mainMenu)
        let file = try #require(mainMenu.items.first { $0.title == "File" }?.submenu)
        return try #require(file.items.first { $0.title == "Import From" }?.submenu)
    }

    // MARK: - The menu bar

    @Test func evernoteAndNotionSitUnderImportFromBesideBearAndAppleNotes() throws {
        let titles = try importFromMenu().items.filter { !$0.isSeparatorItem }.map(\.title)

        #expect(titles == ["Bear…", "Apple Notes…", "Apple Notes Export…", "Evernote…", "Notion…", "Pull from Bear"])
    }

    @Test func theNewItemsTakeNoShortcutAndTheOldOnesKeepTheirs() throws {
        let menu = try importFromMenu()
        for title in ["Apple Notes Export…", "Evernote…", "Notion…"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.keyEquivalent.isEmpty, "\(title)")
        }
        let pull = try #require(menu.items.first { $0.title == "Pull from Bear" })
        #expect(pull.keyEquivalent.lowercased() == "b")
        let mainMenu = try #require(NSApp.mainMenu)
        let file = try #require(mainMenu.items.first { $0.title == "File" }?.submenu)
        let notes = try #require(file.items.first { $0.title == "Import Notes…" })
        #expect(notes.keyEquivalent.lowercased() == "o")
    }

    /// The test host has no main window, so no Import item has a window to act on.
    @Test func withoutAWindowEveryImportItemIsOff() throws {
        let menu = try importFromMenu()
        let mainMenu = try #require(NSApp.mainMenu)
        let file = try #require(mainMenu.items.first { $0.title == "File" }?.submenu)
        let notes = try #require(file.items.first { $0.title == "Import Notes…" })
        menu.autoenablesItems = true
        for item in menu.items.filter({ !$0.isSeparatorItem }) + [notes] {
            #expect(!item.isEnabled, "\(item.title)")
        }
    }

    // MARK: - The gates

    @Test func theImportItemsAreOnOnlyWhenNothingBlocksThem() {
        func off(window: Bool = true, importing: Bool = false, busy: Bool = false, locked: Bool = false) -> Bool {
            ImportCommandAvailability.isUnavailable(
                hasWindow: window, importRunning: importing, libraryOperationBusy: busy, appLocked: locked)
        }
        #expect(!off())
        #expect(off(window: false))
        #expect(off(importing: true), "an import runs")
        #expect(off(busy: true), "a backup, restore or export runs")
        #expect(off(locked: true), "the app is locked")
        #expect(off(importing: true, busy: true, locked: true))
    }

    @Test func theLockGateDefaultsToOffForOlderCallers() {
        #expect(!ImportCommandAvailability.isUnavailable(hasWindow: true, importRunning: false, libraryOperationBusy: false))
    }

    // MARK: - The open panels

    @Test func theEvernotePanelOffersEnexFilesOnly() throws {
        let panel = ImportPanel.makePanel(for: .evernote)
        let enex = try #require(UTType(filenameExtension: "enex"))

        #expect(panel.allowedContentTypes.contains { enex.conforms(to: $0) })
        #expect(!panel.allowedContentTypes.contains(.folder))
        #expect(panel.canChooseFiles)
        #expect(!panel.canChooseDirectories)
        #expect(panel.allowsMultipleSelection)
        #expect(panel.message.contains("Evernote"))
    }

    @Test func theNotionPanelOffersZipsAndFolders() throws {
        let panel = ImportPanel.makePanel(for: .notion)
        let zip = try #require(UTType(filenameExtension: "zip"))
        let enex = try #require(UTType(filenameExtension: "enex"))

        #expect(panel.allowedContentTypes.contains { zip.conforms(to: $0) })
        #expect(panel.allowedContentTypes.contains(.folder))
        #expect(!panel.allowedContentTypes.contains { enex.conforms(to: $0) })
        #expect(panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(panel.message.contains("Notion"))
    }

    @Test func theImportNotesPanelAlsoTakesEnexAndMentionsBothExports() throws {
        #expect(ImportPanel.fileExtensions.contains("enex"))
        let enex = try #require(UTType(filenameExtension: "enex"))
        #expect(ImportPanel.allowedTypes.contains { enex.conforms(to: $0) })
        let panel = ImportPanel.makePanel(for: .notes)
        #expect(panel.message.contains("Evernote"))
        #expect(panel.message.contains("Notion"))
        #expect(panel.canChooseDirectories)
        #expect(panel.allowedContentTypes.contains(.folder))
    }

    @Test func eachPanelHasItsOwnTitle() {
        let titles = [ImportPanel.Source.notes, .evernote, .notion, .appleNotesExport].map(ImportPanel.title(for:))
        #expect(titles == ["Import Notes", "Import From Evernote", "Import From Notion", "Import From Apple Notes Export"])
    }
}
