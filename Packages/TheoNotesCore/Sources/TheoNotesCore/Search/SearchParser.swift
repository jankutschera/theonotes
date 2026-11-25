// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Bear's search language → `SearchExpr`. Tolerant: anything that is not valid syntax is a
/// literal term (unterminated quotes, a lone `-`/`#`/`!`/`@`, unknown `@x`, malformed dates).
///
/// Grammar, as measured on real Bear (docs/oracle/m4-search.md):
/// - whitespace-separated operands are ANDed; `or` (any case) separates OR groups, so
///   `a b or c` = `(a AND b) OR c`. Leading, trailing and repeated `or`s are dropped; a lone `or`
///   is the empty query; `-or` is false.
/// - `-x` negates one operand; only one `-` is consumed (`--x` = NOT the literal `-x`).
///   Negated exact tags (`-!#tag`) and negated subtag searches (`-#*/tag`) are ignored.
/// - `"…"` is a phrase when the closing quote exists and it is not empty.
/// - `#tag`, `#multi word#`, `#2021#` (number/slash-date tags need the closing `#`), `!#tag`
///   (exact), `#*/tag` (subtags). Tag names are not normalized (`#a/` ≠ `#a`).
/// - `@special` (case-insensitive) incl. the localized aliases.
public enum SearchParser {
    /// The query is NFC-normalized first, so decomposed input (e.g. Hangul jamo) still matches
    /// the localized aliases (Bear itself misses `@생성됨60일` when decomposed).
    public static func parse(_ query: String, locale: Locale = .current) -> SearchExpr {
        // U+0000 would end an FTS5 MATCH string early; it separates words like a space.
        let normalized = query.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{0}", with: " ")
        var groups: [[SearchExpr]] = [[]]
        var operands = 0
        for token in tokenize(normalized) where operands < maxOperands {
            switch token {
            case .phrase(let text, let negated):
                groups[groups.count - 1].append(negated ? .not(.phrase(text)) : .phrase(text))
                operands += 1
            case .word(let word):
                if word.lowercased() == "or" {
                    groups.append([])
                } else if let expr = operand(word, locale: locale) {
                    groups[groups.count - 1].append(expr)
                    operands += 1
                }
            }
        }
        let nonEmpty = groups.filter { !$0.isEmpty }.map { $0.count == 1 ? $0[0] : .and($0) }
        switch nonEmpty.count {
        case 0: return .and([])
        case 1: return nonEmpty[0]
        default: return .or(nonEmpty)
        }
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case word(String)
        case phrase(String, negated: Bool)
    }

    static func tokenize(_ query: String) -> [Token] {
        let s = Array(query)
        var tokens: [Token] = []
        var i = 0
        while i < s.count {
            if s[i].isWhitespace { i += 1; continue }
            // Phrase: `"…"` or `-"…"` with a closing quote and something inside.
            let quoteAt = s[i] == "-" ? i + 1 : i
            if quoteAt < s.count, s[quoteAt] == "\"",
               let close = s[(quoteAt + 1)...].firstIndex(of: "\""), close > quoteAt + 1 {
                tokens.append(.phrase(String(s[(quoteAt + 1)..<close]), negated: quoteAt != i))
                i = close + 1
                continue
            }
            var end = i
            while end < s.count && !s[end].isWhitespace { end += 1 }
            if let close = multiWordTagEnd(s, wordStart: i, wordEnd: end) { end = close + 1 }
            tokens.append(.word(String(s[i..<end])))
            i = end
        }
        return tokens
    }

    /// For a word that opens a tag (`#`, `!#`, `-#`, `-!#`) without closing it, the index of the
    /// `#` closing a multi-word tag later on: preceded by a non-space, followed by the end or
    /// whitespace, with no other tag opener (whitespace + `#`) in between.
    private static func multiWordTagEnd(_ s: [Character], wordStart: Int, wordEnd: Int) -> Int? {
        var p = wordStart
        if p < wordEnd && s[p] == "-" { p += 1 }
        if p < wordEnd && s[p] == "!" { p += 1 }
        guard p < wordEnd, s[p] == "#", wordEnd - p > 1, s[wordEnd - 1] != "#" else { return nil }
        var j = wordEnd
        while j < s.count {
            if s[j] == "#" {
                if s[j - 1].isWhitespace { return nil }
                if j + 1 == s.count || s[j + 1].isWhitespace { return j }
            }
            j += 1
        }
        return nil
    }

    // MARK: - Operands

    /// `nil`: the operand is dropped.
    private static func operand(_ word: String, locale: Locale) -> SearchExpr? {
        guard word.count > 1, word.hasPrefix("-") else { return positive(word, locale: locale) }
        let rest = String(word.dropFirst())
        if rest.lowercased() == "or" { return .not(.and([])) }
        let expr = positive(rest, locale: locale)
        if case .tag(_, let mode) = expr, mode != .withDescendants { return nil }
        return .not(expr)
    }

    private static func positive(_ word: String, locale: Locale) -> SearchExpr {
        if word.hasPrefix("#*/") {
            if let name = tagName(word.dropFirst(3)) { return .tag(name, mode: .subtagsOnly) }
        } else if word.hasPrefix("!#") {
            if !word.hasPrefix("!#*/"), let name = tagName(word.dropFirst(2)) { return .tag(name, mode: .exact) }
        } else if word.hasPrefix("#") {
            if let name = tagName(word.dropFirst()) { return .tag(name, mode: .withDescendants) }
        } else if word.hasPrefix("@"), let special = special(fromToken: word, locale: locale) {
            return special
        }
        return .term(word)
    }

    /// The tag name after `#`: a closing `#` is removed; open number/slash-date names (`#2021`)
    /// are not tags; inner whitespace runs of a multi-word tag become one space.
    private static func tagName(_ raw: Substring) -> String? {
        var name = raw
        let closed = name.count > 1 && name.hasSuffix("#")
        if closed { name = name.dropLast() }
        guard !name.isEmpty, !name.hasPrefix("#") else { return nil }
        if !closed && TagScanner.needsClosedForm(String(name)) { return nil }
        if name.contains(where: \.isWhitespace) {
            return name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return String(name)
    }

    // MARK: - Specials

    /// `@…` → `.special`, or `nil` when it is not a special Bear knows.
    static func special(fromToken token: String, locale: Locale = .current) -> SearchExpr? {
        guard token.hasPrefix("@") else { return nil }
        let body = token.dropFirst().lowercased()
        if let simple = simpleSpecials[body] { return .special(simple) }
        for pattern in dayCountPatterns {
            guard body.hasPrefix(pattern.prefix), body.hasSuffix(pattern.suffix),
                  body.count > pattern.prefix.count + pattern.suffix.count else { continue }
            let number = String(body.dropFirst(pattern.prefix.count).dropLast(pattern.suffix.count))
            guard let n = number.allSatisfy(\.isASCIIDigitChar) ? Int(number)
                    : (pattern.chineseNumerals ? chineseNumber(number) : nil),
                  n <= maxDays else { continue }
            return .special(pattern.created ? .createdDays(n) : .lastDays(n))
        }
        for pattern in datePatterns {
            guard body.hasPrefix(pattern.open), body.hasSuffix(pattern.close) else { continue }
            let argument = String(body.dropFirst(pattern.open.count).dropLast(pattern.close.count))
            guard let filter = dateFilter(argument, locale: locale) else { return nil }
            return .special(pattern.created ? .created(filter) : .modified(filter))
        }
        return nil
    }

    static let maxDays = 1_000_000

    /// Operands kept per query (tags, terms, specials; `or` excluded); later ones are ignored.
    /// Keeps the compiled SQL far below SQLite's expression depth limit (1000) and parameter
    /// limit.
    public static let maxOperands = 256

    /// Lowercased name after `@` → special. English plus the FAQ's localized names (zh-Hans,
    /// zh-Hant, ja, ko, ru), copied exactly (inventory §2.5.3); all of them are accepted in any
    /// UI language. The Korean backlinks alias works with one `@` (the FAQ shows `@@`).
    static let simpleSpecials: [String: SpecialSearch] = {
        let table: [(SpecialSearch, [String])] = [
            (.tagged, ["tagged", "有标签", "有標籤", "タグ付き", "태그있음", "теги"]),
            (.untagged, ["untagged", "无标签", "無標籤", "タグなし", "태그없음", "безтегов"]),
            (.today, ["today", "今天", "今日", "오늘", "сегодня"]),
            (.createdToday, ["ctoday", "今天创建", "今天創建", "今日作成されました", "오늘생성됨", "ссегодня"]),
            (.yesterday, ["yesterday", "昨天", "昨日", "어제", "вчера"]),
            (.images, ["images", "图片", "影像", "画像", "이미지", "изображения"]),
            (.files, ["files", "文件", "檔案", "ファイル", "파일", "файлы"]),
            (.attachments, ["attachments", "附件", "添付ファイル", "첨부파일", "вложения"]),
            (.task, ["task", "任务", "任務", "タスク", "작업", "задача"]),
            (.todo, ["todo", "待办", "待辦事項", "해야할일", "дело"]),
            (.done, ["done", "完成", "完了", "완료", "сделано"]),
            (.code, ["code", "代码", "程式碼", "コード", "코드", "код"]),
            (.title, ["title", "标题", "標題", "タイトル", "제목", "заголовок"]),
            (.ocr, ["ocr"]),
            (.locked, ["locked", "已加密", "ロック", "잠긴항목", "Залокировано"]),
            (.pinned, ["pinned", "置顶", "已釘選", "ピン留めしました", "고정됨", "прикреплено"]),
            (.readOnly, ["readonly"]),
            (.empty, ["empty"]),
            (.untitled, ["untitled"]),
            (.wikiLinks, ["wikilinks", "维基链接", "Wiki連結", "Wikiリンク", "읽는시간"]),
            (.backlinks, ["backlinks", "反向链接", "反向連結", "バックリンク", "역방향링크"]),
        ]
        var map: [String: SpecialSearch] = [:]
        for (special, names) in table { for name in names { map[name.lowercased()] = special } }
        return map
    }()

    struct DayCountPattern {
        var prefix: String, suffix: String, created: Bool, chineseNumerals: Bool
    }

    /// `@last10days` and the localized forms. Chinese numerals are read in the
    /// zh/ja "last" forms (`@前十天`, `@前四十五天`) but not in `@已创建十天`. The FAQ's ja/ru
    /// "created" forms (`@日間10過去`, `@дн10дн`) and the Korean form without `@` do not work in
    /// Bear and are not aliases here.
    static let dayCountPatterns: [DayCountPattern] = [
        .init(prefix: "last", suffix: "days", created: false, chineseNumerals: false),
        .init(prefix: "前", suffix: "天", created: false, chineseNumerals: true),
        .init(prefix: "過去", suffix: "天", created: false, chineseNumerals: true),
        .init(prefix: "過去", suffix: "日間", created: false, chineseNumerals: true),
        .init(prefix: "과거", suffix: "일", created: false, chineseNumerals: false),
        .init(prefix: "посл", suffix: "дн", created: false, chineseNumerals: false),
        .init(prefix: "created", suffix: "days", created: true, chineseNumerals: false),
        .init(prefix: "已创建", suffix: "天", created: true, chineseNumerals: false),
        .init(prefix: "已建立", suffix: "天", created: true, chineseNumerals: false),
        .init(prefix: "생성됨", suffix: "일", created: true, chineseNumerals: false),
    ]

    /// `@date(…)`/`@cdate(…)` and localized forms; zh/ja use fullwidth parentheses only, ko/ru
    /// ASCII ones only.
    static let datePatterns: [(open: String, close: String, created: Bool)] = [
        ("date(", ")", false), ("日期（", "）", false), ("日付（", "）", false), ("날짜(", ")", false), ("дата(", ")", false),
        ("cdate(", ")", true), ("创建日期（", "）", true), ("創建日期（", "）", true), ("作成日（", "）", true),
        ("생성일(", ")", true), ("сдата(", ")", true),
    ]

    /// `[<|>]` + `YYYY-MM-DD` (also `/`, unpadded, `THH:MM` ignored), `YYYYMMDD`, `YYYY-MM`,
    /// `MM-YYYY` (also `/`), `YYYY`, or the locale's numeric short date (`M/d/y` in en_US).
    static func dateFilter(_ argument: String, locale: Locale) -> DateFilter? {
        var arg = Substring(argument)
        var comparison = DateComparison.on
        if arg.hasPrefix("<") { comparison = .before; arg = arg.dropFirst() } else if arg.hasPrefix(">") {
            comparison = .after; arg = arg.dropFirst()
        }
        if let t = arg.firstIndex(of: "t") { arg = arg[..<t] }  // lowercased `T`
        let parts = arg.split(separator: "-", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: false) }
        let allDigits = parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigitChar) }
        let separators = arg.filter { $0 == "-" || $0 == "/" }
        if allDigits && (separators.allSatisfy { $0 == "-" } || separators.allSatisfy { $0 == "/" }) {
            guard parts.allSatisfy({ $0.count <= 8 }) else { return nil }  // `Int` overflow, not a date
            let n = parts.map { Int($0)! }
            let lengths = parts.map(\.count)
            switch lengths.count {
            case 1 where lengths[0] == 4:
                return (1...9999).contains(n[0]) ? DateFilter(comparison, year: n[0]) : nil
            case 1 where lengths[0] == 8:
                return validated(comparison, n[0] / 10000, n[0] / 100 % 100, n[0] % 100)
            case 2 where lengths[0] == 4 && lengths[1] <= 2:
                return validated(comparison, n[0], n[1], nil)
            case 2 where lengths[1] == 4 && lengths[0] <= 2:
                return validated(comparison, n[1], n[0], nil)
            case 3 where lengths[0] == 4 && lengths[1] <= 2 && lengths[2] <= 2:
                return validated(comparison, n[0], n[1], n[2])
            default:
                break
            }
        }
        return localDate(String(arg), comparison: comparison, locale: locale)
    }

    private static func validated(_ comparison: DateComparison, _ year: Int, _ month: Int, _ day: Int?) -> DateFilter? {
        // Dates are stored as `YYYY-…` text: only 4-digit years compare correctly.
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        if let day {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month
            else { return nil }
        }
        return DateFilter(comparison, year: year, month: month, day: day)
    }

    /// The device-local numeric date (`DateFormatter` template `yMd` for `locale`), strict.
    private static func localDate(_ s: String, comparison: DateComparison, locale: Locale) -> DateFilter? {
        guard !s.isEmpty, s.contains(where: \.isASCIIDigitChar),
              let format = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        formatter.dateFormat = format
        guard let date = formatter.date(from: s) else { return nil }
        let c = formatter.calendar.dateComponents(in: formatter.timeZone, from: date)
        guard let year = c.year, let month = c.month, let day = c.day, (1000...9999).contains(year) else { return nil }
        return DateFilter(comparison, year: year, month: month, day: day)
    }

    /// Chinese numerals up to 9999 (`十` 10, `四十五` 45, `一百二十` 120); `nil` if not one.
    static func chineseNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        guard !s.isEmpty else { return nil }
        var total = 0, current = 0
        for c in s {
            if let d = digits[c] {
                current = d
            } else if let u = units[c] {
                total += (current == 0 ? 1 : current) * u
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }
}

extension Character {
    var isASCIIDigitChar: Bool { ("0"..."9").contains(self) }
}
