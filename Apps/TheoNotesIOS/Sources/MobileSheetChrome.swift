// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// Title row and buttons for a single-page sheet that opens over the editor. It replaces a
/// `NavigationStack` with plain views: a nested stack in such a sheet caused an AttributeGraph
/// hang on the iPad (device session 2026-11-08, `4906bb8f`; docs/decisions.md).
struct MobileSheetChrome<Leading: View, Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            // Equal side columns keep the title centred; unlike an overlay it truncates instead of
            // running under the buttons at large Dynamic Type sizes, as a navigation bar title does.
            // No band of its own; the sheet's background shows through, the buttons are glass
            // capsules as in a navigation bar (a call site gives its confirming button `.glassProminent`).
            HStack {
                leading.fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                Text(title).font(.headline).lineLimit(1).layoutPriority(1).accessibilityAddTraits(.isHeader)
                trailing.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.glass)
            .padding()
        }
    }
}

/// A sheet's search field in the system look (magnifier, rounded fill), not a flat band.
struct MobileSearchFieldLook: ViewModifier {
    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            content
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .padding(.horizontal).padding(.bottom, 8)
    }
}
