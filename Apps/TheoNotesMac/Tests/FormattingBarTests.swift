// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// The formatting bar is the pointer surface of the Format menu (MACBAR-R1 … R6).
@MainActor
@Suite struct FormattingBarTests {
    private var barItems: [FormatMenuItem] { FormattingBar.controls.flatMap(\.items) }

    private static let states: [(String, EditorMenuState)] = [
        ("editable", EditorMenuState(enabled: true, format: .plain, canFind: true, canOpenLink: true)),
        ("read-only, locked or in Trash", EditorMenuState(enabled: false, format: .plain, canFind: true, canOpenLink: true)),
        ("no note", .unavailable),
        ("code span", EditorMenuState(
            enabled: true, format: FormatState(active: [.inlineCode], headingLevel: nil, inTodo: false, inCode: true, canIndent: false),
            canFind: true, canOpenLink: true)),
        ("code block", EditorMenuState(
            enabled: true, format: FormatState(active: [.codeBlock], headingLevel: nil, inTodo: false, inCode: true, canIndent: false),
            canFind: true, canOpenLink: true)),
        ("bold heading", EditorMenuState(
            enabled: true, format: FormatState(active: [.bold, .heading], headingLevel: 2, inTodo: false, inCode: false, canIndent: false),
            canFind: true, canOpenLink: true)),
    ]

    // MARK: - One place per action

    @Test func everyBarItemIsAFormatMenuItemWithTheSameTitleCommandAndShortcut() {
        for item in barItems + FormattingBar.moreItems {
            #expect(FormatMenu.items.contains(item), "\(item.title) has no Format menu twin")
        }
        #expect(Set(barItems.map(\.title)).count == barItems.count, "a Format item twice on the bar")
    }

    @Test func barAndMoreHoldEveryFormatMenuItemOnceInTheMenusOrder() {
        let all = barItems + FormattingBar.moreItems
        #expect(all.count == FormatMenu.items.count)
        #expect(Set(all.map(\.title)) == Set(FormatMenu.items.map(\.title)))
        let order = FormatMenu.items.map(\.title)
        let more = FormattingBar.moreItems.map(\.title)
        #expect(more == order.filter(more.contains), "More keeps the Format menu's order")
        #expect(FormattingBar.moreEntries.contains { if case .copyLinkToHere = $0 { true } else { false } })
    }

    @Test func moreHasNoEmptySubmenusOrDoubleDividers() {
        var previousWasDivider = true
        for entry in FormattingBar.moreEntries {
            switch entry {
            case .divider:
                #expect(!previousWasDivider)
                previousWasDivider = true
            case .submenu(let title, let items):
                #expect(!items.isEmpty, "\(title)")
                previousWasDivider = false
            case .item, .copyLinkToHere:
                previousWasDivider = false
            }
        }
        #expect(!previousWasDivider, "More ends on a divider")
    }

    @Test func controlsCarryTheFormatMenuTitleAndShortcutAsTooltip() throws {
        for control in FormattingBar.controls where !control.isMenu {
            let item = control.items[0]
            #expect(control.title == item.title)
            #expect(control.help == FormattingBar.help(item))
        }
        #expect(FormattingBar.help(try item("Bold")) == "Bold (⌘B)")
        #expect(FormattingBar.help(try item("Create Table")) == "Create Table (⌥⌘T)")
        #expect(FormattingBar.help(try item("Callout")) == "Callout")
        // A menu control named like a Format submenu holds exactly that submenu.
        let heading = try #require(FormattingBar.controls.first { $0.title == "Heading" })
        for case .submenu("Heading", let items) in FormatMenu.entries { #expect(heading.items == items) }
    }

    @Test func controlsAreEnabledExactlyWhenTheirMenuItemsAre() {
        for (name, state) in Self.states {
            for control in FormattingBar.controls {
                #expect(control.isEnabled(in: state) == control.items.contains { $0.isEnabled(in: state) }, "\(control.title), \(name)")
                if !control.isMenu {
                    #expect(control.isEnabled(in: state) == control.items[0].isEnabled(in: state), "\(control.title), \(name)")
                }
            }
        }
        let readOnly = Self.states[1].1
        #expect(FormattingBar.controls.allSatisfy { !$0.isEnabled(in: readOnly) }, "nothing on the bar edits a read-only note")
        #expect(FormattingBar.controls.allSatisfy { !$0.isEnabled(in: .unavailable) })
        #expect(FormattingBar.moreItems.contains { $0.isEnabled(in: readOnly) }, "Open Link, folding, Copy Table run read-only")
    }

    @Test func activeStatesFollowTheEditorsFormatState() throws {
        let state = Self.states[5].1
        let active = FormattingBar.controls.filter { $0.isActive(in: state) }.map(\.title)
        #expect(active == ["Heading", "Bold"])
        #expect(FormattingBar.controls.allSatisfy { !$0.isActive(in: Self.states[0].1) })
    }

    @Test func theBarUsesTheWindowsMenuStateWithTheEditorFocused() throws {
        let env = try FormatCommandsTests.Env()
        #expect(env.state.formattingBarState == env.state.menuState(editorFocused: true))
        #expect(FormattingBar.controls.allSatisfy { $0.isEnabled(in: env.state.formattingBarState) })
        let readOnly = try FormatCommandsTests.Env(readOnly: true)
        #expect(FormattingBar.controls.allSatisfy { !$0.isEnabled(in: readOnly.state.formattingBarState) })
    }

    @Test func aControlFocusesTheEditorAndRunsTheMenuCommand() throws {
        let env = try FormatCommandsTests.Env()
        env.page.delivered.removeAll()
        env.state.performFromBar(try item("Bold"))
        env.state.performFromBar(try #require(FormattingBar.controls.first { $0.title == "Heading" }?.items[1]))
        #expect(env.page.delivered.first == .focus)
        #expect(env.commands == [.applyCommand(name: .bold), .applyCommand(name: .heading, args: ["level": .int(2)])])

        let readOnly = try FormatCommandsTests.Env(readOnly: true)
        readOnly.state.performFromBar(try item("Bold"))
        #expect(readOnly.commands.isEmpty)
    }

    // MARK: - Layout

    @Test func narrowBarsMoveControlsIntoMoreFromTheRight() {
        let all = FormattingBar.controls
        #expect(FormattingBar.visibleControls(fitting: 10_000) == all)
        #expect(FormattingBar.visibleControls(fitting: FormattingBar.width(of: all)) == all)
        #expect(FormattingBar.visibleControls(fitting: FormattingBar.width(of: all) - 1) == Array(all.dropLast()))
        #expect(FormattingBar.visibleControls(fitting: 0).isEmpty)
        // 3 menus × 38 + 6 buttons × 28, 6 gaps × 2, 3 dividers × 13, More 28, padding 2 × 10.
        #expect(FormattingBar.width(of: all) == 381)
        // A 360-point note window leaves 336 points (12 on each side): File… and Create Table go into More.
        #expect(FormattingBar.visibleControls(fitting: 336).map(\.title) == [
            "Heading", "Todo", "Lists", "Bold", "Italic", "Highlight", "Link",
        ])
        #expect(FormattingBar.buttonWidth >= 28 && FormattingBar.menuWidth >= 28 && FormattingBar.controlHeight >= 28)
        #expect(FormattingBar.height == 36)
        var previous = all.count
        for width in stride(from: FormattingBar.width(of: all), through: 0, by: -4) {
            let shown = FormattingBar.visibleControls(fitting: width)
            #expect(shown == Array(all.prefix(shown.count)), "a prefix at \(width)")
            #expect(shown.count <= previous)
            #expect(shown.isEmpty || FormattingBar.width(of: shown) <= width)
            previous = shown.count
        }
        #expect(FormattingBar.controls.map(\.title) == [
            "Heading", "Todo", "Lists", "Bold", "Italic", "Highlight", "Link", "Create Table", "File…",
        ])
    }

    @Test func everySymbolIsASystemSymbol() {
        for name in FormattingBar.controls.compactMap(\.symbol) + [FormattingBar.moreSymbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    // MARK: - Show / hide

    @Test func theBarIsOnByDefaultAndRemembered() throws {
        let suite = "TheoNotesFormattingBarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FormattingBar.isShown(in: defaults))
        defaults.set(false, forKey: FormattingBar.shownKey)
        #expect(!FormattingBar.isShown(in: UserDefaults(suiteName: suite)!))
        defaults.set(true, forKey: FormattingBar.shownKey)
        #expect(FormattingBar.isShown(in: defaults))
    }

    @Test func viewMenuTitleFlipsWithTheSetting() {
        #expect(FormattingBar.viewMenuTitle(shown: true) == "Hide Formatting Bar")
        #expect(FormattingBar.viewMenuTitle(shown: false) == "Show Formatting Bar")
    }

    @Test func viewMenuHasTheItemOnShiftCommandYAndNothingElseUsesIt() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let view = try #require(mainMenu.items.first { $0.title == "View" }?.submenu)
        let title = FormattingBar.viewMenuTitle(shown: FormattingBar.isShown(in: .standard))
        let item = try #require(view.items.first { $0.title == title })
        #expect(item.keyEquivalent.lowercased() == "y")
        #expect(item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]).contains([.command]))
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let shiftY = mainMenu.items.compactMap(\.submenu).flatMap(all).filter {
            $0.keyEquivalent.lowercased() == "y"
                && $0.keyEquivalentModifierMask.intersection([.command, .option, .control]) == [.command]
                && ($0.keyEquivalent == "Y" || $0.keyEquivalentModifierMask.contains(.shift))
        }
        #expect(shiftY.map(\.title) == [title])
        #expect(!view.items.contains { $0.title == "Customize Toolbar…" }, "M6-R4")
    }

    private func item(_ title: String) throws -> FormatMenuItem {
        try #require(FormatMenu.items.first { $0.title == title })
    }
}
