// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum ChangeSetError: Error, Equatable, Sendable {
    case lengthMismatch(expected: Int, actual: Int)
    case splitsSurrogatePair(offset: Int)
    case lengthOverflow
}

/// Mirror of CodeMirror's `ChangeSet.toJSON()`: a number retains that many UTF-16 units,
/// `[len]` deletes `len`, `[len, "l1", "l2", ...]` deletes `len` and inserts the lines joined by "\n".
public struct ChangeSet: Codable, Equatable, Sendable {
    public enum Section: Codable, Equatable, Sendable {
        case retain(Int)
        case replace(deleteLength: Int, insert: String)

        public init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let n = try? single.decode(Int.self) {
                guard n >= 0 else {
                    throw DecodingError.dataCorruptedError(in: single, debugDescription: "negative retain")
                }
                self = .retain(n)
                return
            }
            var arr = try decoder.unkeyedContainer()
            guard !arr.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: arr, debugDescription: "empty section")
            }
            let del = try arr.decode(Int.self)
            guard del >= 0 else {
                throw DecodingError.dataCorruptedError(in: arr, debugDescription: "negative delete")
            }
            var lines: [String] = []
            while !arr.isAtEnd { lines.append(try arr.decode(String.self)) }
            self = .replace(deleteLength: del, insert: lines.joined(separator: "\n"))
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .retain(let n):
                var c = encoder.singleValueContainer()
                try c.encode(n)
            case .replace(let del, let insert):
                var c = encoder.unkeyedContainer()
                try c.encode(del)
                if !insert.isEmpty {
                    // Split on the "\n" scalar: as a Character, "\r\n" would not match.
                    for line in insert.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
                        try c.encode(String(String.UnicodeScalarView(line)))
                    }
                }
            }
        }
    }

    public var sections: [Section]

    public init(sections: [Section]) { self.sections = sections }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Section] = []
        while !c.isAtEnd { out.append(try c.decode(Section.self)) }
        guard ChangeSet.checkedLengths(of: out) != nil else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "changeset length overflows Int")
        }
        sections = out
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        for s in sections { try c.encode(s) }
    }

    /// Overflow-checked (old, new) lengths; nil if either sum overflows Int.
    private static func checkedLengths(of sections: [Section]) -> (old: Int, new: Int)? {
        var old = 0, new = 0
        for s in sections {
            let (o, n): (Int, Int)
            switch s {
            case .retain(let k): (o, n) = (k, k)
            case .replace(let d, let ins): (o, n) = (d, ins.utf16.count)
            }
            let (ro, f1) = old.addingReportingOverflow(o)
            let (rn, f2) = new.addingReportingOverflow(n)
            if f1 || f2 { return nil }
            old = ro; new = rn
        }
        return (old, new)
    }

    /// Saturates at Int.max on overflow (apply throws in that case).
    public var oldLength: Int { ChangeSet.checkedLengths(of: sections)?.old ?? Int.max }

    public var newLength: Int { ChangeSet.checkedLengths(of: sections)?.new ?? Int.max }

    public func apply(to text: String) throws -> String {
        let old = text as NSString
        guard let lengths = ChangeSet.checkedLengths(of: sections) else {
            throw ChangeSetError.lengthOverflow
        }
        guard lengths.old == old.length else {
            throw ChangeSetError.lengthMismatch(expected: lengths.old, actual: old.length)
        }
        func check(_ pos: Int) throws {
            guard pos > 0, pos < old.length else { return }
            if UTF16.isLeadSurrogate(old.character(at: pos - 1)),
               UTF16.isTrailSurrogate(old.character(at: pos)) {
                throw ChangeSetError.splitsSurrogatePair(offset: pos)
            }
        }
        var result = ""
        var pos = 0
        for s in sections {
            try check(pos)
            switch s {
            case .retain(let n):
                result += old.substring(with: NSRange(location: pos, length: n))
                pos += n
            case .replace(let d, let ins):
                result += ins
                pos += d
            }
        }
        try check(pos)
        return result
    }
}

extension ChangeSet {
    /// Where `range` (UTF-16, old text) lies in the new text; nil when a change touches it. An
    /// insertion right at its start counts as before it, one right at its end as after it.
    public func mapped(_ range: Range<Int>) -> Range<Int>? {
        var old = 0, shift = 0
        for section in sections {
            switch section {
            case .retain(let count):
                old += count
            case .replace(let deleted, let inserted):
                if old + deleted <= range.lowerBound {
                    shift += inserted.utf16.count - deleted
                } else if old < range.upperBound {
                    return nil
                }
                old += deleted
            }
        }
        return (range.lowerBound + shift)..<(range.upperBound + shift)
    }
}
