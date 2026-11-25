// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

extension FocusedValues {
    /// The key window's Info panel (a main window's or a note window's).
    @Entry var infoPanel: InfoPanelModel?
}

/// View ▸ Toggle Info Panel and the tabs with Bear's shortcuts (inventory §2.17.1 "Panels and
/// search": ⇧⌘I statistics, ⇧⌘A table of contents, ⇧⌘B backlinks), for the key window.
struct InfoCommands: Commands {
    @FocusedValue(\.infoPanel) private var info

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Group {
                Button("Toggle Info Panel") { info?.togglePanel() }
                ForEach(InfoPanelModel.Tab.allCases) { tab in
                    Button(tab.menuTitle) { info?.toggle(tab) }
                        .keyboardShortcut(tab.shortcutKey, modifiers: [.command, .shift])
                }
            }
            .disabled(info == nil)
            Divider()
        }
    }
}

/// The ⓘ toolbar button; the popover hangs from it.
struct InfoToolbarButton: View {
    @Bindable var info: InfoPanelModel

    var body: some View {
        Button("Info", systemImage: "info.circle") { info.togglePanel() }
            .help("Info (⇧⌘I Statistics, ⇧⌘A Contents, ⇧⌘B Backlinks)")
            .popover(isPresented: $info.isPresented, arrowEdge: .bottom) {
                InfoPanelView(info: info)
            }
    }
}
