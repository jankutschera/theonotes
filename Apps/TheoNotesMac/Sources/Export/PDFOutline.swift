// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import PDFKit

/// The PDF outline of an exported or printed note (M8-R7): one entry per heading, nested by level.
/// An extension of PDFKit's `PDFOutline` rather than a type of the same name, which would shadow
/// PDFKit's class in this module (M8-R60).
extension PDFOutline {
    /// Replaces `document`'s outline. Each heading's destination is the first match of its text
    /// after the previous heading's match (`PDFDocument.findString(_:fromSelection:withOptions:)`)
    /// that is a line of its own, else the first match at all (M8-R62), at the top left of the
    /// match; a heading whose text is not found is skipped. A heading nests under the nearest
    /// earlier one of a lower level.
    static func add(_ headings: [RenderedHeading], to document: PDFDocument) {
        let root = PDFOutline()
        var parents: [(level: Int, outline: PDFOutline)] = []
        var previous: PDFSelection?
        for heading in headings {
            let label = heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  let match = Self.match(label, in: document, after: previous),
                  let page = match.pages.first else { continue }
            previous = match
            let bounds = match.bounds(for: page)
            let entry = PDFOutline()
            entry.label = label
            entry.destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY))
            while let last = parents.last, last.level >= heading.level { parents.removeLast() }
            let parent = parents.last?.outline ?? root
            parent.insertChild(entry, at: parent.numberOfChildren)
            parents.append((heading.level, entry))
        }
        document.outlineRoot = root.numberOfChildren > 0 ? root : nil
    }

    /// The first match of `label` after `previous` whose line is exactly `label` (the heading,
    /// not a mention of it in the text before), else the first match.
    private static func match(_ label: String, in document: PDFDocument, after previous: PDFSelection?) -> PDFSelection? {
        var first: PDFSelection?
        var from = previous
        while let found = document.findString(label, fromSelection: from, withOptions: []) {
            if first == nil { first = found }
            if let line = found.copy() as? PDFSelection {
                line.extendForLineBoundaries()
                if line.string?.trimmingCharacters(in: .whitespacesAndNewlines) == label { return found }
            }
            from = found
        }
        return first
    }
}
