// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// File and folder names for exported notes (M8-R2).
public enum ExportNaming {
    /// Longest stem in UTF-8 bytes; leaves room for ` 99`, `.textbundle` and the 255-byte name limit.
    static let maxStemBytes = 180

    /// The note title as a file stem: `/`, `:` and C0/DEL controls become `-`, NFC, leading dots and
    /// surrounding whitespace trimmed, at most 180 UTF-8 bytes (cut on a grapheme boundary), and
    /// `Untitled` when nothing is left.
    public static func stem(forTitle title: String) -> String {
        var replaced = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.value {
            case 0x2F, 0x3A, 0x00...0x1F, 0x7F: replaced.append("-")
            default: replaced.append(scalar)
            }
        }
        var s = String(replaced).precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.utf8.count > maxStemBytes {
            var cut = ""
            var bytes = 0
            for character in s {
                let n = String(character).utf8.count
                if bytes + n > maxStemBytes { break }
                cut.append(character)
                bytes += n
            }
            s = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? "Untitled" : s
    }
}

/// Hands out stems that are unique within one output folder, comparing by
/// `CanonicalKey` (NFC plus Unicode case folding, as APFS compares names, so `Straße` and
/// `STRASSE` collide): `Name`, `Name 2`, `Name 3`, …
public struct StemAllocator: Sendable {
    private var used: Set<String> = []
    private var nextSuffix: [String: Int] = [:]

    public init() {}

    public mutating func claim(_ stem: String) -> String {
        let key = CanonicalKey.make(stem)
        if used.insert(key).inserted { return stem }
        var n = nextSuffix[key] ?? 2
        while true {
            let candidate = "\(stem) \(n)"
            n += 1
            if used.insert(CanonicalKey.make(candidate)).inserted {
                nextSuffix[key] = n
                return candidate
            }
        }
    }
}
