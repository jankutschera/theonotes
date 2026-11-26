// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

struct OutlineEntry: Equatable {
    var address: String
    var offset: Int
    var length: Int
}

/// A resolved address: a section (heading line through the end of its subsections) or its lead.
enum SectionTarget: Equatable {
    case section(Int)
    case preamble(Int)
    /// The text above the first heading, addressed as `preamble`.
    case lead
}

/// The sections of a note: one per ATX heading `NoteParser` recognizes, empty ones included (code
/// blocks, math and front matter excluded), with UTF-8 byte ranges and canonical addresses. Text
/// before the first heading is the note's lead, addressed `preamble`.
struct NoteSections {
    struct Section: Equatable {
        var level: Int
        /// The heading line as written, without its line break.
        var headingLine: String
        /// UTF-8 bytes: the heading line through the byte before the next heading of level ≤ this.
        var range: Range<Int>
        /// After the heading line's line break (the end of the text when it has none).
        var headingEnd: Int
        var parent: Int?
        var children: [Int]
        /// The lead above the first subheading: only with a subheading and a lead of at least one
        /// byte, a blank line included.
        var preamble: Range<Int>?
        var address: String
        /// `headingLine` trimmed, inner space runs collapsed: what address lines are compared with.
        var key: String
    }

    private(set) var sections: [Section] = []
    /// The bytes above the first heading: only when the note has a heading and something stands above it.
    private(set) var lead: Range<Int>?
    private let text: String
    /// Section indices by `key`, in document order.
    private var byKey: [String: [Int]] = [:]

    init(text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        var lineStarts = [0]
        for (i, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(i + 1) }
        let headings = NoteParser.sectionHeadings(in: text)
        var stack: [Int] = []
        for heading in headings {
            let line = heading.line - 1
            guard line >= 0, line < lineStarts.count else { continue }
            let start = lineStarts[line]
            let headingEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : bytes.count
            var lineEnd = headingEnd
            if lineEnd > start, bytes[lineEnd - 1] == UInt8(ascii: "\n") { lineEnd -= 1 }
            if lineEnd > start, bytes[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
            var written = String(decoding: bytes[start..<lineEnd], as: UTF8.self)
            if line == 0, written.unicodeScalars.first == "\u{FEFF}" { written.unicodeScalars.removeFirst() }
            let index = sections.count
            while let top = stack.last, sections[top].level >= heading.level {
                sections[top].range = sections[top].range.lowerBound..<start
                stack.removeLast()
            }
            let parent = stack.last
            if let parent { sections[parent].children.append(index) }
            sections.append(
                Section(
                    level: heading.level, headingLine: written, range: start..<bytes.count, headingEnd: headingEnd,
                    parent: parent, children: [], preamble: nil, address: "",
                    key: SectionAddress.normalize(Substring(written))))
            stack.append(index)
        }
        for i in sections.indices {
            guard let first = sections[i].children.first else { continue }
            let lead = sections[i].headingEnd..<sections[first].range.lowerBound
            if !lead.isEmpty { sections[i].preamble = lead }
        }
        if let first = sections.first, first.range.lowerBound > 0 { lead = 0..<first.range.lowerBound }
        for i in sections.indices { byKey[sections[i].key, default: []].append(i) }
        for i in sections.indices { sections[i].address = canonicalAddress(i) }
    }

    // MARK: Addresses

    /// Parent first, then further out.
    private func ancestors(_ i: Int) -> [Int] {
        var chain: [Int] = []
        var current = sections[i].parent
        while let index = current {
            chain.append(index)
            current = sections[index].parent
        }
        return chain
    }

    /// Sections whose heading is the last line and whose ancestor chain carries the earlier lines
    /// in order (outer to inner, not necessarily adjacent), in document order.
    private func matches(_ lines: [String]) -> [Int] {
        guard let last = lines.last else { return [] }
        let outer = lines.dropLast()
        return (byKey[last] ?? []).filter { i in
            guard !outer.isEmpty else { return true }
            var wanted = outer.startIndex
            for ancestor in ancestors(i).reversed() where sections[ancestor].key == outer[wanted] {
                wanted += 1
                if wanted == outer.endIndex { return true }
            }
            return false
        }
    }

    /// The heading alone when it is unique; else the shortest chain of nearest ancestors that is
    /// unique; else the heading and its 1-based index among the sections with the same heading.
    private func canonicalAddress(_ i: Int) -> String {
        let key = sections[i].key
        let same = byKey[key] ?? [i]
        if same.count == 1 { return key }
        let chain = ancestors(i)
        for k in chain.indices {
            let lines = chain[...k].reversed().map { sections[$0].key } + [key]
            if matches(lines).count == 1 { return lines.joined(separator: "\n") }
        }
        return key + "\n" + String((same.firstIndex(of: i) ?? 0) + 1)
    }

    private func preambleAddress(_ i: Int) -> String { sections[i].address + "\npreamble" }

    // MARK: Queries

    func resolve(_ address: SectionAddress) throws(AutomationError) -> SectionTarget {
        // A heading line starts with `#`, so the bare word can only mean the lead.
        if address.lines == ["preamble"], address.index == nil, !address.preamble {
            guard lead != nil else { throw AutomationError(code: .notFound, message: "No section matched the address.") }
            return .lead
        }
        var found = matches(address.lines)
        if let index = address.index { found = index <= found.count ? [found[index - 1]] : [] }
        guard !found.isEmpty else {
            throw AutomationError(code: .notFound, message: "No section matched the address.")
        }
        guard found.count == 1 else {
            let candidates = found.map { i -> JSONValue in
                let usePreamble = address.preamble && sections[i].preamble != nil
                let range = usePreamble ? sections[i].preamble! : sections[i].range
                return .object([
                    ("address", .string(usePreamble ? preambleAddress(i) : sections[i].address)),
                    ("offset", .int(range.lowerBound)), ("length", .int(range.count)),
                    ("snippet", .string(snippet(i))),
                ])
            }
            throw AutomationError(
                code: .ambiguous,
                message: "\(found.count) sections match that address; repeat the call with one of the candidates.",
                details: .object([("candidates", .array(candidates))]))
        }
        let i = found[0]
        guard address.preamble else { return .section(i) }
        guard sections[i].preamble != nil else {
            throw AutomationError(code: .notFound, message: "No section matched the address.")
        }
        return .preamble(i)
    }

    /// The start of a candidate's body (after its heading line), leading blanks dropped, at most
    /// `snippetLength` characters.
    static let snippetLength = 60

    private func snippet(_ i: Int) -> String {
        let section = sections[i]
        let body = String(decoding: Array(text.utf8)[section.headingEnd..<section.range.upperBound], as: UTF8.self)
        let trimmed = body.drop { $0.isWhitespace }
        return String(trimmed.prefix(Self.snippetLength))
    }

    func range(of target: SectionTarget) -> Range<Int> {
        switch target {
        case .section(let i): sections[i].range
        case .preamble(let i): sections[i].preamble ?? sections[i].headingEnd..<sections[i].headingEnd
        case .lead: lead ?? 0..<0
        }
    }

    func address(of target: SectionTarget) -> String {
        switch target {
        case .section(let i): sections[i].address
        case .preamble(let i): preambleAddress(i)
        case .lead: "preamble"
        }
    }

    func entry(_ target: SectionTarget) -> OutlineEntry {
        let range = range(of: target)
        return OutlineEntry(address: address(of: target), offset: range.lowerBound, length: range.count)
    }

    /// Every section followed by its preamble row, in document order; within a section, that
    /// section and its descendants; within a preamble, that preamble.
    func outline(within target: SectionTarget?) -> [OutlineEntry] {
        let indices: Range<Int>
        switch target {
        case .preamble, .lead: return [entry(target!)]
        case .section(let i):
            let end = sections[(i + 1)...].firstIndex { $0.range.lowerBound >= sections[i].range.upperBound }
            indices = i..<(end ?? sections.count)
        case nil:
            indices = sections.indices
        }
        let head = target == nil && lead != nil ? [entry(.lead)] : []
        return head + indices.flatMap { i -> [OutlineEntry] in
            [entry(.section(i))] + (sections[i].preamble == nil ? [] : [entry(.preamble(i))])
        }
    }

    /// The innermost section containing `offset`, or its preamble when `offset` lies in that lead;
    /// nil before the first heading.
    func innermost(at offset: Int) -> (address: String, offset: Int, length: Int)? {
        // The last section starting at or before `offset` (binary search), then out to the first
        // ancestor whose range still contains it.
        var low = 0
        var high = sections.count
        while low < high {
            let mid = (low + high) / 2
            if sections[mid].range.lowerBound <= offset { low = mid + 1 } else { high = mid }
        }
        var candidate = low > 0 ? low - 1 : nil
        while let index = candidate, !sections[index].range.contains(offset) { candidate = sections[index].parent }
        guard let i = candidate else {
            guard let lead, lead.contains(offset) else { return nil }
            return ("preamble", lead.lowerBound, lead.count)
        }
        let target: SectionTarget =
            sections[i].preamble?.contains(offset) == true ? .preamble(i) : .section(i)
        let found = entry(target)
        return (found.address, found.offset, found.length)
    }
}
