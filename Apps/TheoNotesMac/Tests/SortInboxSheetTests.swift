// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI
import TheoNotesCore
import Testing
@testable import TheoNotes

/// The sort buttons show their full labels ("Reference", not "Refere…") at the sheet's width.
@MainActor
@Suite struct SortInboxSheetTests {
    /// Reports the smallest and the natural size SwiftUI gives its one child.
    private final class Sizes: @unchecked Sendable {
        var smallest = CGSize.zero
        var natural = CGSize.zero
    }

    private struct SizeProbe: Layout {
        let sizes: Sizes

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let natural = subviews[0].sizeThatFits(.unspecified)
            sizes.smallest = subviews[0].sizeThatFits(.zero)
            sizes.natural = natural
            return natural
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: .init(bounds.size))
        }
    }

    private func host<V: View>(_ view: V, width: CGFloat, window: inout NSWindow?) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        let height = hosting.fittingSize.height
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let host = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = hosting
        window = host
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    @Test func labelsFitTheSheetWidth() async throws {
        let inner = SortInboxSheet.width - 2 * SortInboxSheet.padding
        let sizes = Sizes()
        let probe = SizeProbe(sizes: sizes)
        var window: NSWindow?
        let hosting = host(probe { SortInboxActions { _ in } }, width: inner, window: &window)
        hosting.layoutSubtreeIfNeeded()
        let (smallest, natural) = (sizes.smallest, sizes.natural)

        // SwiftUI exposes no "is truncated", so measure what the row guarantees. Even squeezed as far as it
        // goes, the row must keep room for every label's text on one line (the 13 pt system font is a lower
        // bound for the button font) plus the gaps; with a truncating label it drops well below that.
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let titles = NoteType.allCases.map(\.displayName) + ["Archive", "Trash", "Skip"]
        let text = titles.reduce(CGFloat(0)) { $0 + ceil(($1 as NSString).size(withAttributes: [.font: font]).width) }
        let floor = text + 8 * CGFloat(titles.count - 1)
        #expect(smallest.width >= floor, "squeezed to \(smallest.width) pt, the labels alone need \(floor) pt")
        // And the natural width of all six buttons fits inside the sheet.
        #expect(natural.width <= inner, "the six buttons need \(natural.width) pt, the sheet gives \(inner) pt")

        // Optional look: TEST_RUNNER_BAERCHEN_SORT_INBOX_PNG_DIR=/some/dir xcodebuild … test
        if let dir = ProcessInfo.processInfo.environment["BAERCHEN_SORT_INBOX_PNG_DIR"] {
            window?.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sort-inbox-actions.png"))
            }
        }
        window?.contentView = nil
        window?.close()
    }
}
