// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// A parsed `--section` value: heading lines outer to inner, an optional 1-based index and an
/// optional trailing `preamble`.
struct SectionAddress: Equatable {
    /// Normalized heading lines (trimmed, inner space runs collapsed), outer to inner.
    var lines: [String]
    /// Selects the Nth section (1-based, document order) among those the lines match.
    var index: Int?
    /// The lead of the section, above its first subheading.
    var preamble: Bool

    /// Lines split on `\n` (the option's escapes are already interpreted); blank lines are dropped.
    /// A final `preamble` line comes off first, then a final all-digit line ≥ 1 is the index; each
    /// only while a line stays behind, so `2` alone is a heading line that matches nothing.
    static func parse(_ raw: String) throws(AutomationError) -> SectionAddress {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalize(Substring($0)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw AutomationError(code: .usage, message: "Address must not be empty") }
        var preamble = false
        var index: Int?
        if lines.count > 1, lines.last == "preamble" {
            preamble = true
            lines.removeLast()
        }
        if lines.count > 1, let last = lines.last, last.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
            let n = Int(last), n >= 1
        {
            index = n
            lines.removeLast()
        }
        return SectionAddress(lines: lines, index: index, preamble: preamble)
    }

    /// Trimmed, with each run of white space inside (spaces, tabs, no-break spaces) collapsed to one
    /// space: bearcli addresses carry no no-break space.
    static func normalize(_ line: Substring) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in line.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\r" || scalar.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        return String(out)
    }
}
