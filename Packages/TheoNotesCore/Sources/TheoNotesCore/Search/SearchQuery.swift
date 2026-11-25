// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// A parsed Bear search query (`SearchParser.parse`). Semantics, as measured on real Bear
/// (docs/oracle/m4-search.md):
/// - `term`: case-, diacritic- and `ß`/`ss`-insensitive substring of the note's raw text,
///   attachment names or OCR text (`ystem` finds `system`, `**` finds bold markup).
/// - `phrase`: with whitespace inside, the same substring match of the whole phrase; a single
///   word must match as a whole word (`"build"` does not find `building`).
/// - `and([])` is true, `or([])` is false.
public indirect enum SearchExpr: Equatable, Sendable {
    case term(String)
    case phrase(String)
    /// `path` as typed (without `#`, closing `#` removed); compared by `CanonicalKey`.
    case tag(String, mode: TagMode)
    case special(SpecialSearch)
    case not(SearchExpr)
    case and([SearchExpr])
    case or([SearchExpr])
}

public enum TagMode: String, Codable, Sendable {
    /// `#tag`: the tag or any of its nested tags.
    case withDescendants
    /// `!#tag`: tagged with the tag itself and with none of its nested tags.
    case exact
    /// `#*/tag`: a tag ending in `/tag` (at least one parent).
    case subtagsOnly
}

public enum DateComparison: String, Codable, Sendable {
    case on = "", before = "<", after = ">"
}

/// A calendar day, month (`day == nil`) or year (`month == nil`) in the search's calendar.
public struct DateFilter: Equatable, Sendable {
    public var comparison: DateComparison
    public var year: Int
    public var month: Int?
    public var day: Int?

    public init(_ comparison: DateComparison, year: Int, month: Int? = nil, day: Int? = nil) {
        self.comparison = comparison; self.year = year; self.month = month; self.day = day
    }
}

public enum SpecialSearch: Equatable, Sendable {
    case tagged, untagged
    case today, yesterday, lastDays(Int), modified(DateFilter)
    case createdToday, createdDays(Int), created(DateFilter)
    case images, files, attachments
    case task, todo, done
    case code
    /// Modifiers: restrict every text term of the query to titles / OCR text. Not filters.
    case title, ocr
    case locked, pinned, readOnly, empty, untitled
    case wikiLinks, backlinks

    /// The canonical English spelling, e.g. `@last10days`, `@date(<2026-05-29)`.
    public var canonical: String {
        switch self {
        case .tagged: "@tagged"
        case .untagged: "@untagged"
        case .today: "@today"
        case .yesterday: "@yesterday"
        case .lastDays(let n): "@last\(n)days"
        case .modified(let f): "@date(\(f.canonical))"
        case .createdToday: "@ctoday"
        case .createdDays(let n): "@created\(n)days"
        case .created(let f): "@cdate(\(f.canonical))"
        case .images: "@images"
        case .files: "@files"
        case .attachments: "@attachments"
        case .task: "@task"
        case .todo: "@todo"
        case .done: "@done"
        case .code: "@code"
        case .title: "@title"
        case .ocr: "@ocr"
        case .locked: "@locked"
        case .pinned: "@pinned"
        case .readOnly: "@readonly"
        case .empty: "@empty"
        case .untitled: "@untitled"
        case .wikiLinks: "@wikilinks"
        case .backlinks: "@backlinks"
        }
    }
}

extension DateFilter {
    /// `<2026-05-29`, `2026-05`, `>2026`.
    var canonical: String {
        var s = comparison.rawValue + String(format: "%04d", year)
        if let month { s += String(format: "-%02d", month) }
        if let day { s += String(format: "-%02d", day) }
        return s
    }
}

/// JSON shape used by `Fixtures/search/parse.json`: `{"term": s}`, `{"phrase": s}`,
/// `{"tag": path, "mode": TagMode}`, `{"special": "@canonical"}`, `{"not": e}`, `{"and": [e]}`,
/// `{"or": [e]}`.
extension SearchExpr: Codable {
    private enum Key: String, CodingKey { case term, phrase, tag, mode, special, not, and, or }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .term) { self = .term(s); return }
        if let s = try c.decodeIfPresent(String.self, forKey: .phrase) { self = .phrase(s); return }
        if let s = try c.decodeIfPresent(String.self, forKey: .tag) {
            self = .tag(s, mode: try c.decode(TagMode.self, forKey: .mode)); return
        }
        if let s = try c.decodeIfPresent(String.self, forKey: .special) {
            guard case .special(let special)? = SearchParser.special(fromToken: s) else {
                throw DecodingError.dataCorruptedError(forKey: .special, in: c, debugDescription: "unknown special \(s)")
            }
            self = .special(special); return
        }
        if let e = try c.decodeIfPresent(SearchExpr.self, forKey: .not) { self = .not(e); return }
        if let e = try c.decodeIfPresent([SearchExpr].self, forKey: .and) { self = .and(e); return }
        if let e = try c.decodeIfPresent([SearchExpr].self, forKey: .or) { self = .or(e); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown expression"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .term(let s): try c.encode(s, forKey: .term)
        case .phrase(let s): try c.encode(s, forKey: .phrase)
        case .tag(let s, let mode): try c.encode(s, forKey: .tag); try c.encode(mode, forKey: .mode)
        case .special(let s): try c.encode(s.canonical, forKey: .special)
        case .not(let e): try c.encode(e, forKey: .not)
        case .and(let e): try c.encode(e, forKey: .and)
        case .or(let e): try c.encode(e, forKey: .or)
        }
    }
}
