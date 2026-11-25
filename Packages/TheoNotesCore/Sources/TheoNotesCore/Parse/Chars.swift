// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// Character classes used by the dialect scanners (all on Unicode scalars for speed).
enum Chars {
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII {
            return c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}"
        }
        return c.properties.isWhitespace
    }

    static func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
    }

    static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII { return isASCIILetter(c) || isDigit(c) }
        return c.properties.isAlphabetic || c.properties.numericType != nil
    }

    /// CommonMark "ASCII punctuation" (escapable characters).
    static func isASCIIPunct(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }

    static func isSchemeChar(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || isDigit(c) || c == "+" || c == "." || c == "-"
    }

    /// Unicode punctuation outside ASCII (e.g. `。`, `、`, `“`, `…`).
    static func isNonASCIIPunct(_ c: Unicode.Scalar) -> Bool {
        guard !c.isASCII else { return false }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    static func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        return String(view)
    }

    /// Collapses whitespace runs to one space and trims.
    static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for c in s.unicodeScalars {
            if isSpace(c) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(c)
        }
        return String(out)
    }

    static func find(_ pattern: [Unicode.Scalar], in s: [Unicode.Scalar], from start: Int) -> Int? {
        guard !pattern.isEmpty, s.count >= pattern.count else { return nil }
        var i = start
        let last = s.count - pattern.count
        while i <= last {
            if s[i] == pattern[0] {
                var k = 1
                while k < pattern.count && s[i + k] == pattern[k] { k += 1 }
                if k == pattern.count { return i }
            }
            i += 1
        }
        return nil
    }
}
