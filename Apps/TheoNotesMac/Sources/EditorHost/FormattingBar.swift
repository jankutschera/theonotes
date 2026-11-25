// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// The formatting bar under the editor (MACBAR-R1 … R6): the pointer surface of the Format menu,
/// not a second menu. Every control runs a Format menu item through `FormatTarget.perform`, carries
/// its title (tooltip with the shortcut, accessibility label) and is enabled exactly when the item is.
enum FormattingBar {
    /// View ▸ Show / Hide Formatting Bar, remembered app-wide; on by default.
    static let shownKey = "showsFormattingBar"
    static let shortcut = KeyboardShortcut("y", modifiers: [.command, .shift])
    static let showTitle = "Show Formatting Bar"
    static let hideTitle = "Hide Formatting Bar"
    static let accessibilityLabel = "Formatting"
    static let moreTitle = "More"

    static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: shownKey) as? Bool ?? true
    }

    static func viewMenuTitle(shown: Bool) -> String { shown ? hideTitle : showTitle }

    /// One bar control: a single Format menu item (a button) or several of them (a menu).
    struct Control: Identifiable, Equatable {
        let title: String
        /// nil: the heading control, drawn as "H" with the level.
        let symbol: String?
        let items: [FormatMenuItem]
        let isMenu: Bool
        /// Controls of one group sit between dividers.
        let group: Int
        var id: String { title }

        /// The tooltip: the title, and the shortcut when the control is one item that has one.
        var help: String { isMenu ? title : FormattingBar.help(items[0]) }

        func isEnabled(in state: EditorMenuState) -> Bool { items.contains { $0.isEnabled(in: state) } }

        /// Pressed when the selection has the item's style (a menu: one of its items).
        func isActive(in state: EditorMenuState) -> Bool {
            state.enabled || state.canOpenLink ? items.contains { $0.isChecked(in: state.format) == true } : false
        }
    }

    static func help(_ item: FormatMenuItem) -> String {
        item.shortcutDisplay.map { "\(item.menuTitle) (\($0))" } ?? item.menuTitle
    }

    private static func item(_ title: String) -> FormatMenuItem {
        guard let item = FormatMenu.items.first(where: { $0.title == title }) else {
            preconditionFailure("Format menu has no \(title)")
        }
        return item
    }

    private static func submenu(_ title: String) -> [FormatMenuItem] {
        for case .submenu(title, let items) in FormatMenu.entries { return items }
        preconditionFailure("Format menu has no submenu \(title)")
    }

    private static func button(_ title: String, _ symbol: String, group: Int) -> Control {
        Control(title: title, symbol: symbol, items: [item(title)], isMenu: false, group: group)
    }

    /// Left to right; a narrow bar drops them from the right into More (`visibleControls`).
    static let controls: [Control] = [
        Control(title: "Heading", symbol: nil, items: submenu("Heading"), isMenu: true, group: 0),
        button("Todo", "checkmark.square", group: 0),
        Control(title: "Lists", symbol: "list.bullet", items: [item("List"), item("Ordered List")], isMenu: true, group: 0),
        button("Bold", "bold", group: 1),
        button("Italic", "italic", group: 1),
        Control(title: "Highlight", symbol: "highlighter", items: [item("Highlight")] + submenu("Highlight Color"), isMenu: true, group: 1),
        button("Link", "link", group: 2),
        button("Create Table", "tablecells", group: 2),
        button("File…", "paperclip", group: 2),
    ]

    static let moreSymbol = "ellipsis"

    // MARK: - More

    /// The Format menu's entries without the items the bar's controls carry, in the menu's order;
    /// submenus that lose every item vanish and dividers never double up.
    static let moreEntries: [FormatMenu.Entry] = {
        let onBar = Set(controls.flatMap(\.items).map(\.title))
        var out: [FormatMenu.Entry] = []
        for entry in FormatMenu.entries {
            switch entry {
            case .item(let item):
                if !onBar.contains(item.title) { out.append(entry) }
            case .submenu(let title, let items):
                let rest = items.filter { !onBar.contains($0.title) }
                if !rest.isEmpty { out.append(.submenu(title, rest)) }
            case .divider:
                if let last = out.last, case .divider = last { continue }
                if !out.isEmpty { out.append(entry) }
            case .copyLinkToHere:
                out.append(entry)
            }
        }
        if let last = out.last, case .divider = last { out.removeLast() }
        return out
    }()

    /// The items More lists (without the controls a narrow bar moved there).
    static var moreItems: [FormatMenuItem] {
        moreEntries.flatMap { entry -> [FormatMenuItem] in
            switch entry {
            case .item(let item): [item]
            case .submenu(_, let items): items
            case .divider, .copyLinkToHere: []
            }
        }
    }

    // MARK: - Layout

    /// Hit areas (MACBAR-R7): every control at least 28 × 28 points.
    static let buttonWidth: CGFloat = 28
    static let menuWidth: CGFloat = 38
    static let controlHeight: CGFloat = 28
    /// Between two controls of one group.
    static let spacing: CGFloat = 2
    /// A 1-point separator with 6 points on each side.
    static let dividerWidth: CGFloat = 13
    /// Inside the capsule's round ends.
    static let padding: CGFloat = 10
    /// The height of the window's toolbar items on macOS 26.
    static let height: CGFloat = 36
    /// The band under the editor that holds the bar; the editor's text ends above it.
    static let bandHeight: CGFloat = 48
    /// The soft edge where the editor's text fades into the band.
    static let fadeHeight: CGFloat = 14

    static func width(of shown: [Control]) -> CGFloat {
        let controlsWidth = shown.reduce(0) { $0 + ($1.isMenu ? menuWidth : buttonWidth) }
        let groups = Set(shown.map(\.group)).count
        // Spacing between neighbours of one group; a divider after each group, the last one before More.
        let gaps = CGFloat(max(0, shown.count - groups)) * spacing
        return controlsWidth + gaps + CGFloat(groups) * dividerWidth + buttonWidth + 2 * padding
    }

    /// The controls that fit `width`, always a prefix of `controls`: the rest go into More, rightmost first.
    static func visibleControls(fitting width: CGFloat) -> [Control] {
        for count in stride(from: controls.count, through: 1, by: -1) where Self.width(of: Array(controls.prefix(count))) <= width {
            return Array(controls.prefix(count))
        }
        return []
    }
}

extension FormatTarget {
    /// The bar's state: the Format menu's while this window's editor has keyboard focus, so the bar
    /// does not grey out when the note list or the bar itself has focus (MACBAR-R2).
    var formattingBarState: EditorMenuState { menuState(editorFocused: true) }

    /// A bar control: focus goes back to the editor (CodeMirror keeps caret and selection), then the
    /// Format menu's own path runs the item.
    func performFromBar(_ item: FormatMenuItem) {
        guard item.isEnabled(in: formattingBarState) else { return }
        if !isEditorFocused { editor.focusEditor() }
        perform(item)
    }

    func copyHeadingLinkFromBar() {
        guard formattingBarState.canCopyHeadingLink else { return }
        copyHeadingLink()
    }
}

extension View {
    /// The formatting bar under this editor view: a band holding the bar, and a soft edge where the
    /// text fades into it (MACBAR-R4, R8).
    func formattingBar(_ target: any FormatTarget, isShown: Bool) -> some View {
        modifier(FormattingBarPlacement(target: target, isShown: isShown))
    }
}

private struct FormattingBarPlacement: ViewModifier {
    let target: any FormatTarget
    let isShown: Bool
    @Environment(\.shellPalette) private var palette

    func body(content: Content) -> some View {
        content
            // The web view scrolls inside its own process, so SwiftUI's scroll-edge effect cannot reach
            // it: a short gradient in the page colour softens the edge instead.
            .overlay(alignment: .bottom) {
                if isShown {
                    LinearGradient(colors: [palette.background.opacity(0), palette.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: FormattingBar.fadeHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // The editor's text ends above the bar's band, so the bar never covers a line.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isShown { FormattingBarBand(target: target) }
            }
    }
}

/// The band under the editor with the bar centred in it.
private struct FormattingBarBand: View {
    let target: any FormatTarget
    @AppStorage(FormattingBar.shownKey) private var shown = true
    @Environment(\.shellPalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            FormattingBarView(
                target: target, state: target.formattingBarState,
                visible: FormattingBar.visibleControls(fitting: geometry.size.width - 24), hide: { shown = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: FormattingBar.bandHeight)
        .background(palette.background)
    }
}

private struct FormattingBarView: View {
    let target: any FormatTarget
    let state: EditorMenuState
    let visible: [FormattingBar.Control]
    let hide: () -> Void
    @Environment(\.shellPalette) private var palette

    var body: some View {
        // One glass capsule like the window's toolbar items; the system material follows the
        // appearance, Reduce Transparency and Increase Contrast (MACBAR-R6 as amended).
        GlassEffectContainer {
            HStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, control in
                    controlView(control)
                    if index == visible.count - 1 || visible[index + 1].group != control.group {
                        divider
                    } else {
                        Color.clear.frame(width: FormattingBar.spacing, height: 1)
                    }
                }
                moreMenu
            }
            .padding(.horizontal, FormattingBar.padding)
            .frame(height: FormattingBar.height)
            .glassEffect(.regular, in: .capsule)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FormattingBar.accessibilityLabel)
    }

    private var divider: some View {
        Rectangle().fill(palette.separator).frame(width: 1, height: 16)
            .frame(width: FormattingBar.dividerWidth)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func controlView(_ control: FormattingBar.Control) -> some View {
        let active = control.isActive(in: state)
        if control.isMenu {
            Menu {
                ForEach(control.items) { item in menuItem(item) }
            } label: {
                HStack(spacing: 2) {
                    icon(control)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(BarButtonStyle(width: FormattingBar.menuWidth, active: active, palette: palette))
            .disabled(!control.isEnabled(in: state))
            .help(control.help)
            .accessibilityLabel(control.title)
            .accessibilityValue(control.items.first { $0.isChecked(in: state.format) == true && active }?.menuTitle ?? "")
        } else {
            let item = control.items[0]
            Button { target.performFromBar(item) } label: { icon(control) }
                .buttonStyle(BarButtonStyle(width: FormattingBar.buttonWidth, active: active, palette: palette))
                .disabled(!control.isEnabled(in: state))
                .help(control.help)
                .accessibilityLabel(item.menuTitle)
                .accessibilityAddTraits(active ? .isSelected : [])
        }
    }

    @ViewBuilder
    private func icon(_ control: FormattingBar.Control) -> some View {
        if let symbol = control.symbol {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
        } else {
            let level = state.enabled || state.canOpenLink ? state.format.headingLevel : nil
            Text(level.map { "H\($0)" } ?? "H").font(.system(size: 13, weight: .semibold))
        }
    }

    private var moreMenu: some View {
        let collapsed = FormattingBar.controls.filter { !visible.contains($0) }
        return Menu {
            if !collapsed.isEmpty {
                ForEach(collapsed) { control in
                    if control.isMenu {
                        Menu(control.title) { ForEach(control.items) { menuItem($0) } }
                            .disabled(!control.isEnabled(in: state))
                    } else {
                        menuItem(control.items[0])
                    }
                }
                Divider()
            }
            ForEach(Array(FormattingBar.moreEntries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let item):
                    menuItem(item)
                case .submenu(let title, let items):
                    Menu(title) {
                        ForEach(items.filter { $0.command != .copyTable }) { menuItem($0) }
                        if items.contains(where: { $0.command == .copyTable }) {
                            Menu(FormatMenu.copyTableTitle) {
                                ForEach(items.filter { $0.command == .copyTable }) { menuItem($0) }
                            }
                        }
                    }
                case .divider:
                    Divider()
                case .copyLinkToHere:
                    Button(FormatMenu.copyLinkToHereTitle) { target.copyHeadingLinkFromBar() }
                        .disabled(!state.canCopyHeadingLink)
                }
            }
            Divider()
            Button(FormattingBar.hideTitle, action: hide)
        } label: {
            Image(systemName: FormattingBar.moreSymbol).font(.system(size: 15, weight: .regular))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(BarButtonStyle(width: FormattingBar.buttonWidth, active: false, palette: palette))
        .help(FormattingBar.moreTitle)
        .accessibilityLabel(FormattingBar.moreTitle)
    }

    /// A Format menu item as the menu shows it, without the key equivalent (the menu bar owns the shortcuts).
    @ViewBuilder
    private func menuItem(_ item: FormatMenuItem) -> some View {
        if let checked = item.isChecked(in: state.format) {
            Toggle(item.menuTitle, isOn: Binding(get: { checked && state.enabled }, set: { _ in target.performFromBar(item) }))
                .disabled(!item.isEnabled(in: state))
                .help(FormattingBar.help(item))
        } else {
            Button(item.menuTitle) { target.performFromBar(item) }
                .disabled(!item.isEnabled(in: state))
                .help(FormattingBar.help(item))
        }
    }
}

private struct BarButtonStyle: ButtonStyle {
    let width: CGFloat
    let active: Bool
    let palette: ShellPalette

    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration, width: width, active: active, palette: palette)
    }

    private struct BarButtonBody: View {
        let configuration: Configuration
        let width: CGFloat
        let active: Bool
        let palette: ShellPalette
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(active ? palette.accent : palette.text)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: width, height: FormattingBar.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? palette.accent.opacity(0.16) : configuration.isPressed ? palette.text.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
        }
    }
}
