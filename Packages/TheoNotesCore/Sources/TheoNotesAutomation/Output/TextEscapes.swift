// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// The escaping bearcli uses in TSV output and in text flags: `\n \t \r \\`.
public enum TextEscapes {
    /// Turns the four escapes into the characters they name. An unknown `\x`, and a lone trailing
    /// backslash, stay as typed.
    public static func unescape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var iterator = s.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                out.append(scalar)
                continue
            }
            guard let next = iterator.next() else {
                out.append(scalar)
                break
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default:
                out.append(scalar)
                out.append(next)
            }
        }
        return String(out)
    }

    /// The inverse of `unescape` for the four characters.
    public static func escapeTSV(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
