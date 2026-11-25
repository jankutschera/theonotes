// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// A to-do line of a note: 1-based `line`, whether it is checked, and the line's full text as
/// typed (without its line break).
public struct TodoLine: Equatable, Sendable {
    public let line: Int
    public let isDone: Bool
    public let text: String

    public init(line: Int, isDone: Bool, text: String) {
        self.line = line
        self.isDone = isDone
        self.text = text
    }
}

/// The to-dos the indexer counts as `openTodos` / `doneTodos`, with their lines. It reuses the
/// parser's block rules, so a `- [ ]` inside a fence, math block, comment or front matter is not
/// a to-do.
public enum TodoLines {
    /// Every to-do in document order.
    public static func all(in text: String) -> [TodoLine] {
        let found = NoteParser.todoOccurrences(in: text)
        guard !found.isEmpty else { return [] }
        let index = LineIndex(text)
        return found.compactMap { occurrence in
            guard let range = index.range(ofLine: occurrence.line) else { return nil }
            return TodoLine(line: occurrence.line, isDone: occurrence.isDone, text: String(text[range]))
        }
    }

    /// `text` with the box of the to-do on 1-based `line` flipped (`[ ]` to `[x]`, `[x]`/`[X]` to
    /// `[ ]`); every other byte is unchanged. Nil when that line is not a to-do.
    public static func toggled(_ text: String, line: Int) -> String? {
        guard let todo = NoteParser.todoOccurrences(in: text).first(where: { $0.line == line }) else { return nil }
        let index = LineIndex(text)
        guard let range = index.range(ofLine: line) else { return nil }
        // Before the box a to-do line holds only blanks, quote markers, a `[!kind]` callout marker
        // and the bullet, so the first `[ ]` / `[x]` / `[X]` is the box.
        let scalars = text.unicodeScalars
        var i = range.lowerBound
        while i < range.upperBound {
            if scalars[i] == "[" {
                let mark = scalars.index(after: i)
                if mark < range.upperBound {
                    let close = scalars.index(after: mark)
                    if close < range.upperBound, scalars[close] == "]",
                       scalars[mark] == " " || scalars[mark] == "x" || scalars[mark] == "X" {
                        var result = text
                        result.replaceSubrange(mark..<close, with: todo.isDone ? " " : "x")
                        return result
                    }
                }
            }
            i = scalars.index(after: i)
        }
        return nil
    }
}
