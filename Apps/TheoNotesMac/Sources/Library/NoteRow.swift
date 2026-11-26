// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import ImageIO
import SwiftUI

/// One note list cell: title, two preview lines, relative date, pin/lock glyphs and an optional
/// thumbnail of the note's first image (spec §4.3). Colours come from the theme's `ShellPalette`, except on a
/// selected row: the selection fill is the system's (the user's accent when the list is focused, the system's
/// grey when it is not), so selected rows use the system's text colours for that fill and matches are
/// underlined instead of highlighted ("system selection, system text").
struct NoteRow: View {
    let item: NoteListItem
    /// The date the list is sorted by (created or modified).
    let date: Date
    let thumbnailURL: URL?
    /// The search's terms, highlighted in title and preview.
    var terms: [String] = []
    /// Whether the list has this note selected (the selection fill is drawn whatever the list's focus).
    var isSelected = false

    @Environment(\.shellPalette) private var palette
    /// `.increased` while the row sits on the list's emphasized selection fill (key window, focused list).
    @Environment(\.backgroundProminence) private var prominence

    /// How the system paints this row's background: no selection, its accent fill (emphasized) or its grey
    /// fill (selected but the list is not focused).
    enum SelectionStyle: Equatable { case none, unemphasized, emphasized }

    static func selectionStyle(isSelected: Bool, prominence: BackgroundProminence) -> SelectionStyle {
        if prominence == .increased { return .emphasized }
        return isSelected ? .unemphasized : .none
    }

    /// The system's text colours for the fill of `style`; `nil` on an unselected row, which keeps the
    /// theme's. Emphasized: the pair of the accent fill (`alternateSelectedControlTextColor`, "equivalent to
    /// labelColor in an emphasized context", NSColor.h). Unemphasized: plain label colours, which the system
    /// pairs with `unemphasizedSelectedContentBackgroundColor`.
    static func systemText(for style: SelectionStyle) -> (primary: NSColor, secondary: NSColor)? {
        switch style {
        case .none: nil
        case .unemphasized: (.labelColor, .secondaryLabelColor)
        case .emphasized: (.alternateSelectedControlTextColor, .alternateSelectedControlTextColor)
        }
    }

    /// No highlight fill on a selected row (a composited Reduce Transparency tint under selected text is
    /// unreadable, 1.19:1 measured, and the grey fill is not checked against it): matches are underlined.
    static func underlinesMatches(in style: SelectionStyle) -> Bool { style != .none }

    static let lockedLabel = "Locked"

    /// The quiet mark of a note a capture gesture made; the weight of the pin and the lock.
    static let capturedSymbol = "tray.and.arrow.down"
    static let capturedLabel = "Captured"

    static func showsCapturedMark(for item: NoteListItem) -> Bool { item.captureSource != nil }

    /// The two preview lines; none for a locked note (its title is all the list shows).
    static func previewText(for item: NoteListItem) -> String? {
        item.isLocked || item.subtitle.isEmpty ? nil : item.subtitle
    }

    /// The first image's file name for the row's thumbnail; none for a locked note.
    static func thumbnailFilename(for item: NoteListItem) -> String? {
        item.isLocked ? nil : item.firstImageFilename
    }

    static func typeLabel(for type: NoteType) -> String { "Type: \(type.displayName)" }

    private var style: SelectionStyle { Self.selectionStyle(isSelected: isSelected, prominence: prominence) }
    private var primary: Color { Self.systemText(for: style).map { Color(nsColor: $0.primary) } ?? palette.text }
    private var secondary: Color { Self.systemText(for: style).map { Color(nsColor: $0.secondary) } ?? palette.secondaryText }
    /// The system's pair for its emphasized selection fill: readable whatever accent the user picked.
    static let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
    private var matchBackground: Color? { Self.underlinesMatches(in: style) ? nil : palette.searchHighlight }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(
                        item.title.isEmpty
                            ? AttributedString("Untitled")
                            : SearchHighlight.attributed(item.title, terms: terms, background: matchBackground)
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(item.title.isEmpty ? secondary : primary)
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    if item.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(secondary)
                            .accessibilityLabel(Self.lockedLabel)
                    }
                    if Self.showsCapturedMark(for: item) {
                        Image(systemName: Self.capturedSymbol)
                            .font(.caption2)
                            .foregroundStyle(secondary)
                            .accessibilityLabel(Self.capturedLabel)
                    }
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(style == .none ? palette.accent : secondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                // Locked notes show their title only (spec §4.9).
                if let preview = Self.previewText(for: item) {
                    Text(SearchHighlight.attributed(preview, terms: terms, background: matchBackground))
                        .font(.callout)
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let type = item.noteType {
                        Text(type.displayName)
                            .font(.caption2)
                            .foregroundStyle(secondary)
                            .padding(.horizontal, 6)
                            .background(Capsule().strokeBorder(secondary.opacity(0.5)))
                            .accessibilityLabel(Self.typeLabel(for: type))
                    }
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(secondary)
                }
            }
            if let thumbnailURL {
                NoteThumbnail(url: thumbnailURL)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// Search matches in list text, found like the search indexes (`SearchOffsets`: case- and
/// diacritic-insensitive substrings).
enum SearchHighlight {
    /// The colour outside a themed root; the list passes the palette's `searchHighlight`.
    static let background = ShellPalette.default.searchHighlight

    /// Matches get `background`, or an underline when it is `nil`.
    static func attributed(_ text: String, terms: [String], background: Color? = SearchHighlight.background)
        -> AttributedString
    {
        var out = AttributedString(text)
        guard !terms.isEmpty else { return out }
        for match in SearchOffsets.sourceRanges(for: terms, in: text) {
            let lower = String.Index(utf16Offset: match.lowerBound, in: text)
            let upper = String.Index(utf16Offset: match.upperBound, in: text)
            guard let range = Range(lower..<upper, in: out) else { continue }
            if let background {
                out[range].swiftUI.backgroundColor = background
            } else {
                out[range].swiftUI.underlineStyle = .single
            }
        }
        return out
    }
}

/// A 44 pt square thumbnail, decoded off the main actor.
struct NoteThumbnail: View {
    /// 44 pt at the default size; scales with the body text style where the platform scales it.
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    let url: URL
    @State private var image: CGImage?
    @Environment(\.shellPalette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(palette.separator)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { image = await Self.load(url) }
    }

    /// Decodes at 2x the thumbnail side.
    @concurrent
    nonisolated private static func load(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 88,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
