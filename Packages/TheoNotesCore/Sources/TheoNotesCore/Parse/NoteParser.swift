// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Derives `NoteMetadata` from a note's Markdown in Bear's dialect (spec D3, §3.5): a line-based
/// block scan (front matter, fenced code, `$$` math, multi-line HTML comments), then an inline
/// scan of each prose line. No setext headings, no indented code blocks. Linear in text length.
public enum NoteParser {
    static let previewLimit = 300
    /// Bear cuts titles at 500 characters (oracle).
    static let titleLimit = 500

    public static func metadata(for text: String) -> NoteMetadata {
        scan(text).finish()
    }

    /// Headings with the full block/comment rules, skipping inline work on lines
    /// that cannot contain a heading. Useful for navigation through long notes.
    public static func headings(in text: String) -> [HeadingRef] {
        scan(text, lineFilter: { $0.contains("#") }).headings
    }

    /// Direct tags and attachments in source order without deriving the preview,
    /// tasks or links from unrelated prose. Block and comment state is still scanned.
    public static func tagsAndAttachments(in text: String) -> (tags: [String], attachments: [AttachmentRef]) {
        let builder = scan(text, lineFilter: { $0.contains("#") || $0.contains("[") })
        return (builder.tags, builder.attachments)
    }

    /// Metadata plus the search body (one scan).
    static func analyze(_ text: String) -> (metadata: NoteMetadata, searchBody: String) {
        let builder = scan(text, collectSearch: true)
        return (builder.finish(), builder.searchLines.joined(separator: "\n"))
    }

    /// Text for `note_search_content.body`: every line with markup stripped (`InlineStripper`
    /// `.search` mode: tags kept as words without `#`, link URLs dropped, wiki links → their
    /// visible text, images/attachment links and HTML comments dropped), whitespace collapsed;
    /// code/math block lines and front matter verbatim; blank lines skipped; joined by `\n`.
    /// Pure (reads only `text`), so migrations may call it.
    public static func searchBody(for text: String) -> String {
        analyze(text).searchBody
    }

    /// UTF-8 byte offset where each `\n`-separated line of `text` starts. A leading BOM belongs to
    /// line 0 but is not one of its scalars, so line 0 starts after it.
    static func lineStartBytes(of text: String) -> [Int] {
        var starts = [text.unicodeScalars.first == "\u{FEFF}" ? 3 : 0]
        var offset = 0
        for byte in text.utf8 {
            offset += 1
            if byte == UInt8(ascii: "\n") { starts.append(offset) }
        }
        return starts
    }

    /// A tag as written: `range` covers `#…` (closing `#` included) in unicode scalars of line
    /// `line` (0-based, split on `\n`, a leading BOM not counted).
    struct TagOccurrence: Equatable {
        var line: Int
        var range: Range<Int>
        var name: String
    }

    /// Every tag occurrence the indexer counts (prose only: not in code, math, comments or front matter).
    static func tagOccurrences(in text: String) -> [TagOccurrence] {
        scan(text).tagOccurrences
    }

    /// Every tag occurrence the indexer counts, in text order, repeats included: its name as
    /// written (without `#`) and its UTF-8 byte range in `text` (`#` through a closing `#`).
    public static func tagSpans(in text: String) -> [(name: String, bytes: Range<Int>)] {
        let found = tagOccurrences(in: text)
        guard !found.isEmpty else { return [] }
        let lines = splitLines(text)
        let starts = lineStartBytes(of: text)
        return found.map { occurrence in
            let line = lines[occurrence.line]
            let lower = line.prefix(occurrence.range.lowerBound).reduce(0) { $0 + UTF8.width($1) }
            let width = line[occurrence.range].reduce(0) { $0 + UTF8.width($1) }
            return (occurrence.name, (starts[occurrence.line] + lower)..<(starts[occurrence.line] + lower + width))
        }
    }

    /// An attachment link's destination as written (scalar range in line `line`) and its filename,
    /// for the iOS export paths (`NoteExport`). Same ranges as `attachmentLinkTargets`.
    struct AttachmentOccurrence {
        var line: Int
        var range: Range<Int>
        var filename: String
    }

    static func attachmentOccurrences(in text: String) -> [AttachmentOccurrence] {
        scan(text).attachmentOccurrences.map {
            AttachmentOccurrence(line: $0.line, range: $0.destination, filename: $0.filename)
        }
    }

    /// The 0-based line (split on `\n`) the title is taken from: the first line after YAML front
    /// matter, else 0.
    public static func bodyStartLine(in text: String) -> Int {
        frontMatterEnd(splitLines(text)) ?? 0
    }

    /// 0-based lines (split on `\n`), ascending, that hold at least one tag the indexer counts
    /// and nothing else but spaces: the lines Bear's top- or bottom-placed tags occupy.
    public static func tagOnlyLines(in text: String) -> [Int] {
        let occurrences = tagOccurrences(in: text)
        guard !occurrences.isEmpty else { return [] }
        let lines = splitLines(text)
        return Dictionary(grouping: occurrences, by: \.line).compactMap { index, group in
            guard index < lines.count else { return nil }
            var covered = Array(repeating: false, count: lines[index].count)
            for occurrence in group {
                for i in occurrence.range.clamped(to: 0..<covered.count) { covered[i] = true }
            }
            let onlyTags = lines[index].indices.allSatisfy { covered[$0] || Chars.isSpace(lines[index][$0]) }
            return onlyTags ? index : nil
        }.sorted()
    }

    /// A wiki link as written: `link`'s ranges are unicode scalar offsets in line `line` (0-based,
    /// split on `\n`, a leading BOM not counted).
    struct WikiLinkOccurrence {
        var line: Int
        var link: WikiLinkParser.Link
    }

    /// One attachment link as written: `offset` is the UTF-8 byte offset of its `[` or `![` in
    /// the note text. A file linked twice appears twice.
    public struct AttachmentLink: Equatable, Sendable {
        public var filename: String
        public var offset: Int

        public init(filename: String, offset: Int) {
            self.filename = filename
            self.offset = offset
        }
    }

    /// Every attachment link `metadata(for:).attachments` is derived from, in text order.
    public static func attachmentLinks(in text: String) -> [AttachmentLink] {
        let found = scan(text).attachmentOccurrences
        guard !found.isEmpty else { return [] }
        let lines = splitLines(text)
        let starts = lineStartBytes(of: text)
        return found.map { occurrence in
            let prefix = lines[occurrence.line].prefix(occurrence.start)
            let bytes = prefix.reduce(0) { $0 + UTF8.width($1) }
            return AttachmentLink(filename: occurrence.filename, offset: starts[occurrence.line] + bytes)
        }
    }

    /// The UTF-8 byte range of each attachment link's destination as written (inside the
    /// parentheses, without `<…>`), with the filename it names, in text order. Offsets are into
    /// `text.utf8`.
    public static func attachmentLinkTargets(in text: String) -> [(filename: String, bytes: Range<Int>)] {
        let found = scan(text).attachmentOccurrences
        guard !found.isEmpty else { return [] }
        let lines = splitLines(text)
        let starts = lineStartBytes(of: text)
        return found.map { occurrence in
            let line = lines[occurrence.line]
            let lower = line.prefix(occurrence.destination.lowerBound).reduce(0) { $0 + UTF8.width($1) }
            let width = line[occurrence.destination].reduce(0) { $0 + UTF8.width($1) }
            let begin = starts[occurrence.line] + lower
            return (occurrence.filename, begin..<begin + width)
        }
    }

    /// Metadata plus the levels of heading lines with no text (`## `), which the indexer skips.
    static func metadataAndEmptyHeadingLevels(for text: String) -> (NoteMetadata, [Int]) {
        let builder = scan(text)
        return (builder.finish(), builder.emptyHeadingLevels)
    }

    /// Every ATX heading line in document order, those with no text (`## `, or only an image)
    /// included with `text` empty: the sections `bearcli outline` lists. `metadata(for:).headings`
    /// leaves the empty ones out.
    public static func sectionHeadings(in text: String) -> [HeadingRef] {
        let builder = scan(text)
        var all = builder.headings
        for (level, line) in zip(builder.emptyHeadingLevels, builder.emptyHeadingLines) {
            all.append(HeadingRef(level: level, text: "", line: line))
        }
        return all.sorted { $0.line < $1.line }
    }

    /// The 1-based line and done flag of every todo that `openTodos` / `doneTodos` count (so none
    /// inside a fence, math block, comment or front matter), in document order.
    static func todoOccurrences(in text: String) -> [(line: Int, isDone: Bool)] {
        scan(text).todoLines
    }

    /// Every wiki link the indexer records (prose only, like `tagOccurrences`).
    static func wikiLinkOccurrences(in text: String) -> [WikiLinkOccurrence] {
        scan(text).wikiLinkOccurrences
    }

    /// A prose line as the indexer reads it (not code, math or front matter), for mention search
    /// and snippets. `index` and offsets are as in `tagOccurrences`.
    struct ProseLine {
        var index: Int
        var scalars: [Unicode.Scalar]
        /// Inside code spans, math, comments, URLs, autolinks, escapes, links (text and
        /// destination), images, attachments, wiki links or tags: never plain text.
        var blocked: [Bool]
        /// Visible text (`InlineStripper` text mode), whitespace collapsed.
        var visibleText: String
    }

    /// 1-based lines of every table header, delimiter and body row (ruling M6-R1, `TableScanner`).
    public static func tableRowLines(in text: String) -> [Int] {
        scan(text).tableRowLines
    }

    /// Prose lines plus the wiki links in them (one scan). With `onlyLines`, prose lines it
    /// rejects are skipped (no inline scan; they are neither returned nor searched for links)
    /// unless an HTML comment may start in them — block structure is still followed in full.
    static func proseScan(
        _ text: String, onlyLines: ((ArraySlice<Unicode.Scalar>) -> Bool)? = nil
    ) -> (lines: [ProseLine], wikiLinks: [WikiLinkOccurrence]) {
        let builder = scan(text, collectProse: true, lineFilter: onlyLines)
        return (builder.proseLines, builder.wikiLinkOccurrences)
    }

    private static let commentOpen: [Unicode.Scalar] = ["<", "!", "-", "-"]

    private static func scan(
        _ text: String, collectSearch: Bool = false, collectProse: Bool = false,
        lineFilter: ((ArraySlice<Unicode.Scalar>) -> Bool)? = nil
    ) -> Builder {
        let lines = splitLines(text)
        var builder = Builder(collectSearch: collectSearch, collectProse: collectProse)
        let lastCommentCloseLine = lines.lastIndex { Chars.find(["-", "-", ">"], in: $0, from: 0) != nil } ?? -1
        let lastMathFenceLine = lines.lastIndex(where: isMathFence) ?? -1

        let titleLine = frontMatterEnd(lines) ?? 0
        if titleLine > 2 {
            for line in lines[1..<titleLine - 1] { builder.addSearchLine(Chars.string(line[...])) }
        }
        var index = titleLine
        var block = BlockState.prose
        var inComment = false
        /// Set when a list fence was ended by an under-indented line: the next bare matching
        /// fence line is its (hand-typed, column-0) closer, not a new opener.
        var strayCloser: (marker: Unicode.Scalar, length: Int)?
        /// Header of the table the previous line belongs to.
        var table: TableScanner.RowShape?
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            if inComment {
                table = nil
                inComment = builder.addProse(line, index: index, startsInComment: true,
                                             commentMayContinue: index < lastCommentCloseLine)
                continue
            }
            switch block {
            case .fence(let fence):
                switch fence.classify(line) {
                case .close: block = .prose; continue
                case .content(let start): builder.addRaw(line[start...]); continue
                case .ended(let byIndent):
                    block = .prose  // container ended: the line is prose again
                    if byIndent { strayCloser = (fence.marker, fence.length) }
                }
            case .math:
                if isMathFence(line) { block = .prose } else { builder.addRaw(line[...]) }
                continue
            case .prose:
                break
            }
            // A row line can be neither a fence nor a `$$` line, so it is decided first.
            let inTable = table.map { TableScanner.isRow(of: $0, line) } ?? false
            if !inTable { table = TableScanner.header(line, next: index + 1 < lines.count ? lines[index + 1] : nil) }
            if table != nil {
                builder.tableRowLines.append(index + 1)
                if let lineFilter, !lineFilter(line[...]) { continue }
                _ = builder.addProse(line, index: index, startsInComment: false, commentMayContinue: false,
                                     isTitleLine: index == titleLine, tableRow: true)
                continue
            }
            if let stray = strayCloser, Fence.isBareCloser(line, from: 0, marker: stray.marker, length: stray.length) {
                strayCloser = nil
            } else if let fence = Fence.open(line) {
                strayCloser = nil
                block = .fence(fence)
                builder.hasCode = true
                builder.countTodo(fence.todo, line: index + 1)
            } else if isMathFence(line) && index < lastMathFenceLine {
                block = .math
            } else if let lineFilter, !lineFilter(line[...]), Chars.find(commentOpen, in: line, from: 0) == nil {
                continue
            } else {
                inComment = builder.addProse(line, index: index, startsInComment: false,
                                             commentMayContinue: index < lastCommentCloseLine,
                                             isTitleLine: index == titleLine)
            }
        }
        return builder
    }

    private enum BlockState {
        case prose
        case fence(Fence)
        case math
    }

    // MARK: - Lines and blocks

    /// Splits on `\n`, dropping a trailing `\r` (CRLF) and a leading BOM.
    static func splitLines(_ text: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var first = true
        for c in text.unicodeScalars {
            if first { first = false; if c == "\u{FEFF}" { continue } }
            if c == "\n" {
                if current.last == "\r" { current.removeLast() }
                lines.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(c)
            }
        }
        if current.last == "\r" { current.removeLast() }
        lines.append(current)
        return lines
    }

    static func trimmedEquals(_ line: [Unicode.Scalar], _ value: String) -> Bool {
        var lo = 0, hi = line.count
        while lo < hi && Chars.isSpace(line[lo]) { lo += 1 }
        while hi > lo && Chars.isSpace(line[hi - 1]) { hi -= 1 }
        return line[lo..<hi].elementsEqual(value.unicodeScalars)
    }

    static func isMathFence(_ line: [Unicode.Scalar]) -> Bool { trimmedEquals(line, "$$") }

    /// YAML front matter: line 1 is `---` and a later line is `---`. Returns the first body line.
    static func frontMatterEnd(_ lines: [[Unicode.Scalar]]) -> Int? {
        guard let first = lines.first, trimmedEquals(first, "---") else { return nil }
        var i = 1
        while i < lines.count {
            if trimmedEquals(lines[i], "---") { return i + 1 }
            i += 1
        }
        return nil
    }

    /// A fenced code block, possibly inside `>` quotes and/or a list item. No lazy continuation
    /// (Bear dialect): a line without the opener's quote depth, or a non-blank line indented less
    /// than the list item's content column, ends the container and with it the fence.
    struct Fence {
        enum LineKind {
            case close
            /// Code content starting at this offset (after the quote markers).
            case content(Int)
            /// The container ended; `byIndent` when a list item ended by under-indentation.
            case ended(byIndent: Bool)
        }

        var marker: Unicode.Scalar
        var length: Int
        var quoteDepth: Int
        /// Columns from the end of the quote markers to the fence marker, when opened in a list item.
        var listColumn: Int?
        /// Task box on the opener line (`- [ ] ```` `).
        var todo: LineShape.Todo?

        /// ```` ``` ```` or `~~~` (3+), after optional quote markers, indentation and a list marker
        /// (with an optional task box). A backtick fence's info string has no backtick.
        static func open(_ line: [Unicode.Scalar]) -> Fence? {
            let quotes = quotePrefix(line)
            let end = LineShape.trimmedEnd(line)
            var p = quotes.end
            while p < end && Chars.isBlank(line[p]) { p += 1 }
            var listColumn: Int?
            var todo: LineShape.Todo?
            if let afterMarker = LineShape.bulletEnd(line, from: p, to: end) {
                listColumn = columns(line[quotes.end..<afterMarker])
                if let box = LineShape.todoBox(line, at: afterMarker, to: end) {
                    todo = box.todo
                    p = box.end
                } else {
                    p = afterMarker
                }
            } else if let afterMarker = LineShape.orderedMarkerEnd(line, from: p, to: end) {
                listColumn = columns(line[quotes.end..<afterMarker])
                p = afterMarker
            }
            guard p < end, line[p] == "`" || line[p] == "~" else { return nil }
            let marker = line[p]
            var q = p
            while q < line.count && line[q] == marker { q += 1 }
            guard q - p >= 3 else { return nil }
            if marker == "`" && line[q...].contains("`") { return nil }
            return Fence(marker: marker, length: q - p, quoteDepth: quotes.depth, listColumn: listColumn, todo: todo)
        }

        func classify(_ line: [Unicode.Scalar]) -> LineKind {
            guard let start = Self.strip(quoteDepth, quotesFrom: line) else { return .ended(byIndent: false) }
            var p = start
            var indent = 0
            while p < line.count && Chars.isBlank(line[p]) {
                indent += line[p] == "\t" ? 4 : 1
                p += 1
            }
            let blank = p == line.count || line[p...].allSatisfy(Chars.isSpace)
            if Self.isBareCloser(line, from: p, marker: marker, length: length) { return .close }
            if let listColumn, !blank, indent < listColumn { return .ended(byIndent: true) }
            return .content(start)
        }

        /// Blanks, then at least `length` of `marker`, then only whitespace.
        static func isBareCloser(_ line: [Unicode.Scalar], from start: Int, marker: Unicode.Scalar, length: Int) -> Bool {
            var p = start
            while p < line.count && Chars.isBlank(line[p]) { p += 1 }
            var q = p
            while q < line.count && line[q] == marker { q += 1 }
            return q - p >= length && line[q...].allSatisfy(Chars.isSpace)
        }

        /// All leading `>` markers (each optionally preceded by blanks and followed by one blank).
        static func quotePrefix(_ line: [Unicode.Scalar]) -> (depth: Int, end: Int) {
            var depth = 0
            var end = 0
            while true {
                var p = end
                while p < line.count && Chars.isBlank(line[p]) { p += 1 }
                guard p < line.count, line[p] == ">" else { return (depth, end) }
                p += 1
                if p < line.count && Chars.isBlank(line[p]) { p += 1 }
                depth += 1
                end = p
            }
        }

        /// Offset after exactly `depth` quote markers, or nil when the line has fewer.
        static func strip(_ depth: Int, quotesFrom line: [Unicode.Scalar]) -> Int? {
            var p = 0
            for _ in 0..<depth {
                while p < line.count && Chars.isBlank(line[p]) { p += 1 }
                guard p < line.count, line[p] == ">" else { return nil }
                p += 1
                if p < line.count && Chars.isBlank(line[p]) { p += 1 }
            }
            return p
        }

        static func columns(_ s: ArraySlice<Unicode.Scalar>) -> Int {
            s.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
    }

    // MARK: - Accumulation

    private struct Builder {
        var collectSearch = false
        var collectProse = false
        var searchLines: [String] = []
        var proseLines: [ProseLine] = []
        var title = ""
        var subtitle = ""
        var tags: [String] = []
        var tagKeys: Set<String> = []
        var tagOccurrences: [TagOccurrence] = []
        var wikiLinkOccurrences: [WikiLinkOccurrence] = []
        var emptyHeadingLevels: [Int] = []
        /// 1-based lines of the headings with no text, level by level with `emptyHeadingLevels`.
        var emptyHeadingLines: [Int] = []
        var openTodos = 0
        var doneTodos = 0
        /// 1-based line and done flag of every todo `openTodos` / `doneTodos` count, in order.
        var todoLines: [(line: Int, isDone: Bool)] = []
        var wikiLinks: [WikiLinkRef] = []
        var headings: [HeadingRef] = []
        var attachments: [AttachmentRef] = []
        var attachmentNames: Set<String> = []
        /// Every attachment link: line index, scalar offset of its `[` / `![`, filename.
        var attachmentOccurrences: [(line: Int, start: Int, filename: String, destination: Range<Int>)] = []
        var hasCode = false
        var hasInlineCode = false
        var previewFull = false
        var tableRowLines: [Int] = []

        /// Returns whether the line ends inside a multi-line comment. The title comes from the
        /// first body line only (Bear oracle: a blank or markup-only first line gives an untitled
        /// note); the preview from the lines after it. In a table row (`tableRow`) an unmasked `|`
        /// separates cells: tags end there, and a comment never runs past the row.
        mutating func addProse(
            _ s: [Unicode.Scalar], index: Int, startsInComment: Bool, commentMayContinue: Bool,
            isTitleLine: Bool = false, tableRow: Bool = false
        ) -> Bool {
            let scan = InlineScanner.scan(s, startsInComment: startsInComment, commentMayContinue: commentMayContinue)
            let shape = startsInComment ? LineShape.plain(s) : tableRow ? LineShape.tableRow(s) : LineShape.parse(s)
            let found = TagScanner.find(in: s, mask: scan.mask, tableRow: tableRow)
            tagOccurrences += found.map { TagOccurrence(line: index, range: $0.range, name: $0.name) }
            for tag in found where tagKeys.insert(CanonicalKey.make(tag.name)).inserted {
                tags.append(tag.name)
            }
            wikiLinks.append(contentsOf: scan.wikiLinks)
            wikiLinkOccurrences += scan.wikiLinkSpans.map { WikiLinkOccurrence(line: index, link: $0) }
            for (attachment, (start, destination)) in zip(
                scan.attachments, zip(scan.attachmentStarts, scan.attachmentDestinations)
            ) {
                attachmentOccurrences.append((index, start, attachment.filename, destination))
            }
            for attachment in scan.attachments where attachmentNames.insert(attachment.filename).inserted {
                attachments.append(attachment)
            }
            hasInlineCode = hasInlineCode || scan.hasInlineCode
            countTodo(shape.todo, line: index + 1)
            if isTitleLine {
                title = Self.title(InlineStripper.strip(
                    s, range: shape.content, scan: scan, tags: found, tableRow: shape.isTableRow, mode: .title
                ))
            }
            if collectSearch {
                addSearchLine(Chars.collapse(InlineStripper.strip(
                    s, range: shape.content, scan: scan, tags: found, tableRow: shape.isTableRow, mode: .search
                )))
            }
            if collectProse {
                proseLines.append(ProseLine(
                    index: index, scalars: s, blocked: Self.blocked(scan, tags: found),
                    visibleText: Chars.collapse(InlineStripper.strip(
                        s, range: shape.content, scan: scan, tags: found, tableRow: shape.isTableRow
                    ))
                ))
            }
            guard !previewFull || shape.headingLevel != nil else { return scan.endsInComment }
            let text = Chars.collapse(InlineStripper.strip(
                s, range: shape.content, scan: scan, tags: found, tableRow: shape.isTableRow
            ))
            if let level = shape.headingLevel {
                if text.isEmpty {
                    emptyHeadingLevels.append(level)
                    emptyHeadingLines.append(index + 1)
                } else {
                    headings.append(HeadingRef(level: level, text: text, line: index + 1))
                }
            }
            if !isTitleLine { addPreview(text) }
            return scan.endsInComment
        }

        /// The scan's mask plus tags and the whole extent of links, from `[` to the end of `](…)`
        /// (the mask leaves link text open for emphasis and tags).
        static func blocked(_ scan: InlineScan, tags: [TagScanner.Match]) -> [Bool] {
            var blocked = scan.mask
            func block(_ range: Range<Int>) {
                for i in range where i < blocked.count { blocked[i] = true }
            }
            tags.forEach { block($0.range) }
            var opens: [Int] = []
            for span in scan.spans {
                switch span.kind {
                case .linkOpen: opens.append(span.range.lowerBound)
                case .linkClose:
                    if let start = opens.popLast(), opens.isEmpty { block(start..<span.range.upperBound) }
                default: break
                }
            }
            return blocked
        }

        /// Trimmed, inner whitespace kept (Bear oracle), cut at `titleLimit` characters.
        static func title(_ raw: String) -> String {
            var scalars = Substring(raw).unicodeScalars[...]
            while let first = scalars.first, Chars.isSpace(first) { scalars.removeFirst() }
            while let last = scalars.last, Chars.isSpace(last) { scalars.removeLast() }
            return String(String(scalars).prefix(NoteParser.titleLimit))
        }

        mutating func countTodo(_ todo: LineShape.Todo?, line: Int) {
            switch todo {
            case .open?: openTodos += 1; todoLines.append((line, false))
            case .done?: doneTodos += 1; todoLines.append((line, true))
            case nil: break
            }
        }

        /// Code and math block content: verbatim.
        mutating func addRaw(_ s: ArraySlice<Unicode.Scalar>) {
            if collectSearch { addSearchLine(Chars.string(s)) }
            guard !previewFull else { return }
            addPreview(Chars.collapse(Chars.string(s)))
        }

        mutating func addSearchLine(_ line: String) {
            if !line.unicodeScalars.allSatisfy(Chars.isSpace) { searchLines.append(line) }
        }

        mutating func addPreview(_ text: String) {
            guard !text.isEmpty else { return }
            if !previewFull {
                subtitle += subtitle.isEmpty ? text : " " + text
                if subtitle.unicodeScalars.count >= NoteParser.previewLimit && subtitle.count >= NoteParser.previewLimit {
                    previewFull = true
                }
            }
        }

        func finish() -> NoteMetadata {
            var preview = subtitle
            if preview.count > NoteParser.previewLimit {
                preview = String(preview.prefix(NoteParser.previewLimit))
                while let last = preview.unicodeScalars.last, Chars.isSpace(last) { preview.unicodeScalars.removeLast() }
            }
            return NoteMetadata(
                title: title, subtitle: preview, tags: tags, openTodos: openTodos, doneTodos: doneTodos,
                wikiLinks: wikiLinks, headings: headings, attachments: attachments,
                hasCode: hasCode, hasInlineCode: hasInlineCode,
                isEmpty: title.isEmpty && preview.isEmpty && attachments.isEmpty
            )
        }
    }
}

/// Block-level prefix of a prose line: where visible content starts and ends, ATX heading,
/// todo box, table row.
struct LineShape {
    enum Todo { case open, done }

    var content: Range<Int>
    /// Top-level ATX heading (≤ 3 columns indent, not in a quote).
    var headingLevel: Int?
    var todo: Todo?
    var isTableRow = false

    static func plain(_ s: [Unicode.Scalar]) -> LineShape {
        LineShape(content: 0..<trimmedEnd(s))
    }

    static func trimmedEnd(_ s: [Unicode.Scalar]) -> Int {
        var end = s.count
        while end > 0 && Chars.isSpace(s[end - 1]) { end -= 1 }
        return end
    }

    static func parse(_ s: [Unicode.Scalar]) -> LineShape {
        let end = trimmedEnd(s)
        var p = 0
        var column = 0
        while p < end && Chars.isBlank(s[p]) {
            column += s[p] == "\t" ? 4 : 1
            p += 1
        }
        if isThematicBreak(s, from: p, to: end) { return LineShape(content: end..<end) }

        var quoteDepth = 0
        while p < end && s[p] == ">" {
            quoteDepth += 1
            p += 1
            while p < end && Chars.isBlank(s[p]) { p += 1 }
        }
        if quoteDepth > 0 { p = skipCalloutMarker(s, from: p, to: end) }

        if let heading = atxHeading(s, from: p, to: end) {
            let level = (quoteDepth == 0 && column <= 3) ? heading.level : nil
            return LineShape(content: heading.content, headingLevel: level)
        }

        var shape = LineShape(content: p..<end)
        if let afterBullet = bulletEnd(s, from: p, to: end) {
            p = afterBullet
            if let box = todoBox(s, at: p, to: end) {
                shape.todo = box.todo
                p = box.end
            }
        } else if let afterNumber = orderedMarkerEnd(s, from: p, to: end) {
            p = afterNumber
        }
        shape.content = p..<end
        return shape
    }

    /// `---`, `***`, `___` (3+ of one marker, blanks allowed between).
    static func isThematicBreak(_ s: [Unicode.Scalar], from p: Int, to end: Int) -> Bool {
        guard p < end, s[p] == "-" || s[p] == "*" || s[p] == "_" else { return false }
        let marker = s[p]
        var count = 0
        for c in s[p..<end] {
            if c == marker { count += 1 } else if !Chars.isBlank(c) { return false }
        }
        return count >= 3
    }

    /// `[!NOTE]` / `[!TIP]` … after a quote marker.
    static func skipCalloutMarker(_ s: [Unicode.Scalar], from p: Int, to end: Int) -> Int {
        guard p + 2 < end, s[p] == "[", s[p + 1] == "!" else { return p }
        var q = p + 2
        while q < end && Chars.isASCIILetter(s[q]) { q += 1 }
        guard q < end, q > p + 2, s[q] == "]" else { return p }
        q += 1
        while q < end && Chars.isBlank(s[q]) { q += 1 }
        return q
    }

    /// `#{1,6}` followed by blank or end; content excludes an optional closing `#` sequence.
    static func atxHeading(_ s: [Unicode.Scalar], from p: Int, to end: Int) -> (level: Int, content: Range<Int>)? {
        var q = p
        while q < end && s[q] == "#" { q += 1 }
        let level = q - p
        guard (1...6).contains(level), q == end || Chars.isBlank(s[q]) else { return nil }
        while q < end && Chars.isBlank(s[q]) { q += 1 }
        var contentEnd = end
        var r = end
        while r > q && s[r - 1] == "#" { r -= 1 }
        if r < end && (r == q || Chars.isBlank(s[r - 1])) {
            contentEnd = r
            while contentEnd > q && Chars.isBlank(s[contentEnd - 1]) { contentEnd -= 1 }
        }
        return (level, q..<contentEnd)
    }

    /// A row of a table (`TableScanner`): content from the leading `|`; none for a `|---|` row.
    static func tableRow(_ s: [Unicode.Scalar]) -> LineShape {
        let end = trimmedEnd(s)
        let from = TableScanner.rowShape(s)?.from ?? 0
        let content = isTableSeparator(s, from: from, to: end) ? end..<end : from..<end
        return LineShape(content: content, isTableRow: true)
    }

    /// `|---|:--:|` rows of a GFM table.
    static func isTableSeparator(_ s: [Unicode.Scalar], from p: Int, to end: Int) -> Bool {
        var sawDash = false
        for c in s[p..<end] {
            switch c {
            case "-": sawDash = true
            case "|", ":", " ", "\t": continue
            default: return false
            }
        }
        return sawDash
    }

    /// `-`, `*`, `+` followed by blank or end.
    static func bulletEnd(_ s: [Unicode.Scalar], from p: Int, to end: Int) -> Int? {
        guard p < end, s[p] == "-" || s[p] == "*" || s[p] == "+" else { return nil }
        guard p + 1 == end || Chars.isBlank(s[p + 1]) else { return nil }
        var q = p + 1
        while q < end && Chars.isBlank(s[q]) { q += 1 }
        return q
    }

    /// `1.` / `1)` (1–9 digits) followed by blank or end.
    static func orderedMarkerEnd(_ s: [Unicode.Scalar], from p: Int, to end: Int) -> Int? {
        var q = p
        while q < end && Chars.isDigit(s[q]) && q - p < 9 { q += 1 }
        guard q > p, q < end, s[q] == "." || s[q] == ")" else { return nil }
        q += 1
        guard q == end || Chars.isBlank(s[q]) else { return nil }
        while q < end && Chars.isBlank(s[q]) { q += 1 }
        return q
    }

    /// `[ ]`, `[x]`, `[X]` followed by blank or end of line.
    static func todoBox(_ s: [Unicode.Scalar], at p: Int, to end: Int) -> (todo: Todo, end: Int)? {
        guard p + 2 < end, s[p] == "[", s[p + 2] == "]" else { return nil }
        let mark = s[p + 1]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        guard p + 3 == end || Chars.isBlank(s[p + 3]) else { return nil }
        var q = p + 3
        while q < end && Chars.isBlank(s[q]) { q += 1 }
        return (mark == " " ? .open : .done, q)
    }
}
