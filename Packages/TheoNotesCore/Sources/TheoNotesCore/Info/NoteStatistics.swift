// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The Info panel's statistics of a note or a selection (spec §4.6, inventory §2.8), counted on
/// the markup-stripped text the search body uses (`NoteParser.searchBody`): Markdown marks, link
/// URLs, images and comments removed; tags count as their names, wiki links as their visible
/// text; code and front matter verbatim; whitespace runs collapsed.
/// - Words: whitespace-separated runs that contain a letter or digit (`don't`, `well-known` and
///   `3.14` are one word each; a lone `-` or `…` is none). Han, Hiragana and Katakana are written
///   without spaces, so each of their characters counts as a word, as other editors
///   count CJK text; Hangul is space-separated and counted like Latin text.
/// - Characters: grapheme clusters of the stripped lines, spaces included, line breaks not.
/// - Paragraphs: lines with visible text.
public struct NoteStatistics: Equatable, Sendable {
    public static let wordsPerMinute = 230

    public var words: Int
    public var characters: Int
    public var paragraphs: Int

    public init(words: Int, characters: Int, paragraphs: Int) {
        self.words = words
        self.characters = characters
        self.paragraphs = paragraphs
    }

    public static let zero = NoteStatistics(words: 0, characters: 0, paragraphs: 0)

    /// Estimated read time at `wordsPerMinute`, rounded to the second.
    public var readingSeconds: Int {
        Int((Double(words) * 60 / Double(Self.wordsPerMinute)).rounded())
    }

    /// Statistics of `text` (a whole note or a selection of one).
    public static func of(_ text: String) -> NoteStatistics {
        var result = NoteStatistics.zero
        for line in NoteParser.searchBody(for: text).split(separator: "\n") {
            result.paragraphs += 1
            result.characters += line.count
            result.words += words(in: line)
        }
        return result
    }

    static func words(in text: Substring) -> Int {
        var count = 0
        var inWord = false
        var hasWordChar = false
        func endRun() {
            if inWord && hasWordChar { count += 1 }
            inWord = false
            hasWordChar = false
        }
        for c in text.unicodeScalars {
            if c.properties.isWhitespace {
                endRun()
            } else if isSpacelessScript(c) {
                endRun()
                count += 1
            } else {
                inWord = true
                if c.properties.isAlphabetic || c.properties.numericType != nil { hasWordChar = true }
            }
        }
        endRun()
        return count
    }

    /// Han (incl. radicals and compatibility ideographs), Hiragana, Katakana (incl. half-width).
    static func isSpacelessScript(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x2E80...0x2FDF, 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }
}
