// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// A note that serves as a template: tagged `#template` or a descendant (`#template/<name>`).
public struct TemplateInfo: Identifiable, Equatable, Sendable {
    /// The template note's id.
    public var id: String
    public var title: String
    /// Display path of the most specific direct template tag (`template` or `template/meeting`).
    public var tagPath: String
    public var modifiedAt: Date

    public init(id: String, title: String, tagPath: String, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.tagPath = tagPath
        self.modifiedAt = modifiedAt
    }
}

/// Inputs for placeholder expansion. `calendar` supplies the time zone for `{{date}}`, `{{time}}`
/// and `{{datetime}}`; `locale` the language of `{{weekday}}`.
public struct TemplateContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    /// `nil` expands `{{clipboard}}` to the empty string.
    public var clipboard: String?
    /// `nil` expands `{{title}}` to the empty string and sets `TemplateResult.needsTitle`.
    public var title: String?

    public init(
        now: Date = .now, calendar: Calendar = .current, locale: Locale = .current,
        clipboard: String? = nil, title: String? = nil
    ) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.clipboard = clipboard
        self.title = title
    }
}

public struct TemplateResult: Equatable, Sendable {
    public var text: String
    /// UTF-16 offset of the first `{{cursor}}` in `text` (the placeholder itself is removed).
    public var caretOffset: Int?
    /// The template contains `{{title}}` (outside code) and the context carries no title: the
    /// caller should prompt for one and instantiate again.
    public var needsTitle: Bool

    public init(text: String, caretOffset: Int?, needsTitle: Bool) {
        self.text = text
        self.caretOffset = caretOffset
        self.needsTitle = needsTitle
    }
}

/// Templates (Theo Notes extension beyond Bear, spec §4.10).
///
/// Placeholders (exact, lowercase): `{{date}}` `YYYY-MM-DD`, `{{time}}` `HH:mm`, `{{datetime}}`
/// `YYYY-MM-DD HH:mm` (Gregorian, in `context.calendar`'s time zone whatever its calendar
/// system), `{{weekday}}` (full name in `context.locale`), `{{title}}` (newlines become spaces),
/// `{{clipboard}}` (line endings normalized), `{{cursor}}`. Unknown `{{x}}` stays as typed.
/// Text inside fenced code blocks and inline code spans is never touched, so a template can
/// document its own placeholders. Expansion is a single pass: placeholder-looking text in the
/// clipboard or title is not expanded again.
public enum Templates {
    public static let rootTag = "template"

    /// Notes in Notes (not Archive/Trash, not locked) tagged `#template` or a descendant, most
    /// recently modified first.
    public static func list(db: Database) throws -> [TemplateInfo] {
        let isTemplate = predicate()
        let rows = try Row.fetchAll(db, sql: """
            SELECT n.id, n.title, n.modifiedAt,
                   (SELECT t.displayPath FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                    WHERE nt.noteId = n.id AND nt.isDirect
                      AND (t.pathKey = 'template' OR t.pathKey LIKE 'template/%')
                    ORDER BY length(t.pathKey) DESC, t.pathKey LIMIT 1) AS tagPath
            FROM note n
            WHERE \(isTemplate.sql)
            ORDER BY n.modifiedAt DESC, n.id
            """, arguments: StatementArguments(isTemplate.arguments))
        return rows.map {
            TemplateInfo(
                id: $0["id"], title: $0["title"], tagPath: $0["tagPath"] ?? rootTag,
                modifiedAt: $0["modifiedAt"])
        }
    }

    /// The one template condition (`list`, Quick Open, the Today and Todo sections): a SQL boolean
    /// over the note alias `note` that holds for a note in Notes, not locked, carrying `#template`
    /// or a descendant (`note_tag` materializes ancestors). Bind `arguments` where `sql` appears.
    public static func predicate(note alias: String = "n") -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        ("""
            (\(alias).location = 'notes' AND NOT \(alias).isLocked
                AND EXISTS (SELECT 1 FROM note_tag tpl_nt WHERE tpl_nt.noteId = \(alias).id
                    AND tpl_nt.tagId = (SELECT id FROM tag WHERE pathKey = ?)))
            """, [rootTag])
    }

    public static func instantiate(templateText: String, context: TemplateContext) -> TemplateResult {
        let normalized = TextNormalization.normalizeLineEndings(templateText)
        let text = NoteStore.removingTags(from: normalized, matching: isTemplateTag) ?? normalized
        var expander = Expander(context: context)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var fence: NoteParser.Fence?
        var out = ""
        for (index, rawLine) in lines.enumerated() {
            if index > 0 { out += "\n" }
            let line = Array(rawLine.unicodeScalars)
            if let open = fence {
                switch open.classify(line) {
                case .close: fence = nil; out += rawLine; continue
                case .content: out += rawLine; continue
                case .ended: fence = nil
                }
            }
            if let opener = NoteParser.Fence.open(line) {
                fence = opener
                out += rawLine
                continue
            }
            let scan = InlineScanner.scan(line, startsInComment: false, commentMayContinue: false)
            var position = 0
            for span in scan.spans {
                guard case .code = span.kind, span.range.lowerBound >= position else { continue }
                expander.expand(line[position..<span.range.lowerBound], into: &out)
                out += String(String.UnicodeScalarView(line[span.range]))
                position = span.range.upperBound
            }
            expander.expand(line[position...], into: &out)
        }
        return TemplateResult(
            text: out, caretOffset: expander.caretOffset,
            needsTitle: expander.sawTitle && context.title == nil)
    }

    /// `#template` or `#template/…`, any spelling (closed `#template/my thing#` included).
    static func isTemplateTag(_ name: String) -> Bool {
        let key = CanonicalKey.make(name)
        return key == rootTag || key.hasPrefix(rootTag + "/")
    }

    private struct Expander {
        let context: TemplateContext
        var caretOffset: Int?
        var sawTitle = false

        let clipboard: String
        let title: String?
        let gregorian: Calendar

        init(context: TemplateContext) {
            self.context = context
            // A `#template` tag in the clipboard or title must not make the new note a template.
            func withoutTemplateTags(_ value: String) -> String {
                NoteStore.removingTags(from: value, matching: Templates.isTemplateTag) ?? value
            }
            clipboard = withoutTemplateTags(TextNormalization.normalizeLineEndings(context.clipboard ?? ""))
            title = context.title.map {
                withoutTemplateTags(
                    TextNormalization.normalizeLineEndings($0)
                        .split(separator: "\n", omittingEmptySubsequences: false).joined(separator: " "))
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = context.calendar.timeZone
            gregorian = calendar
        }

        /// Expands placeholders in `segment` (prose outside code) and appends to `out`.
        mutating func expand(_ segment: ArraySlice<Unicode.Scalar>, into out: inout String) {
            let s = Array(segment)
            var p = 0
            var literalStart = 0
            while p < s.count {
                guard s[p] == "{", p + 1 < s.count, s[p + 1] == "{",
                      let close = closing(s, from: p + 2) else { p += 1; continue }
                let name = String(String.UnicodeScalarView(s[p + 2..<close]))
                let literal = String(String.UnicodeScalarView(s[literalStart..<p]))
                guard let value = value(of: name, caretAt: out.utf16.count + literal.utf16.count) else {
                    p += 1
                    continue
                }
                out += literal
                out += value
                p = close + 2
                literalStart = p
            }
            out += String(String.UnicodeScalarView(s[literalStart...]))
        }

        private func closing(_ s: [Unicode.Scalar], from start: Int) -> Int? {
            var j = start
            while j + 1 < s.count {
                if s[j] == "}" && s[j + 1] == "}" { return j }
                if s[j] == "{" { return nil }
                j += 1
            }
            return nil
        }

        /// `nil` for an unknown name. `{{cursor}}` records the caret and expands to nothing.
        private mutating func value(of name: String, caretAt: Int) -> String? {
            switch name {
            case "date": return date()
            case "time": return time()
            case "datetime": return date() + " " + time()
            case "weekday": return weekday()
            case "title": sawTitle = true; return title ?? ""
            case "clipboard": return clipboard
            case "cursor":
                if caretOffset == nil { caretOffset = caretAt }
                return ""
            default: return nil
            }
        }

        private func date() -> String {
            let c = gregorian.dateComponents([.year, .month, .day], from: context.now)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        private func time() -> String {
            let c = gregorian.dateComponents([.hour, .minute], from: context.now)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }

        private func weekday() -> String {
            let formatter = DateFormatter()
            formatter.locale = context.locale
            formatter.calendar = context.calendar
            formatter.timeZone = context.calendar.timeZone
            formatter.dateFormat = "EEEE"
            return formatter.string(from: context.now)
        }
    }
}

extension NoteStore {
    /// Creates a note from the text of template `templateId` with placeholders expanded and the
    /// template tag removed. Throws `StoreError.noteLocked` for a locked template. `caretOffset` is the UTF-16 position of `{{cursor}}` in the new
    /// note's text. A template that needs a title (`TemplateResult.needsTitle`) gets an empty one
    /// here; prompt first via `Templates.instantiate` and pass `context.title`.
    public func createFromTemplate(
        templateId: String, context: TemplateContext
    ) throws -> (Note, caretOffset: Int?) {
        guard let template = try note(id: templateId) else { throw StoreError.noteNotFound(id: templateId) }
        guard !template.isLocked else { throw StoreError.noteLocked(id: templateId) }
        let result = Templates.instantiate(templateText: template.text, context: context)
        let created = try create(text: result.text, now: context.now)
        return (created, result.caretOffset)
    }

    /// `createFromTemplate` for a new note in a window: the note also gets `extraTags` (the
    /// selected tag, tags a search requires; each unless the note carries it already) and, in
    /// `workspace` (spec §3.5), the workspace's tag unless the note then carries a tag inside it.
    /// All in one write, the tags where `tagPosition` says. The template's own tags stay, only
    /// `#template` goes. `caretOffset` follows an inserted tag line. An empty template becomes
    /// what a new empty note with those tags is (`\n\n#tag`, or `#tag\n\n` with the caret after
    /// it). Throws `invalidTag` for an unusable tag before anything is made.
    public func createFromTemplate(
        templateId: String, context: TemplateContext, workspace: Workspace?, tagPosition: TagPosition,
        extraTags: [String] = []
    ) throws -> (Note, caretOffset: Int?) {
        guard let template = try note(id: templateId) else { throw StoreError.noteNotFound(id: templateId) }
        guard !template.isLocked else { throw StoreError.noteLocked(id: templateId) }
        return try createFromTemplate(
            templateText: template.text, context: context, workspace: workspace, tagPosition: tagPosition,
            extraTags: extraTags)
    }

    /// The same for template text already read (so a caller that looked at it, e.g. for
    /// `needsTitle`, creates from exactly that text).
    public func createFromTemplate(
        templateText: String, context: TemplateContext, workspace: Workspace?, tagPosition: TagPosition,
        extraTags: [String] = []
    ) throws -> (Note, caretOffset: Int?) {
        let result = Templates.instantiate(templateText: templateText, context: context)
        var text = result.text
        var caret = result.caretOffset
        let tokens = try Self.newNoteTagTokens(
            carrying: NoteParser.metadata(for: text).tags, extraTags: extraTags, workspace: workspace)
        if !tokens.isEmpty {
            let line = tokens.joined(separator: " ")
            if text.isEmpty {
                text = tagPosition == .bottom ? "\n\n" + line : line + "\n\n"
                caret = tagPosition == .bottom ? 0 : text.utf16.count
            } else if tagPosition == .bottom {
                text += "\n" + line
            } else {
                let normalized = TextNormalization.normalizeLineEndings(text)
                let titleEnd = Self.titleLineEnd(of: normalized)
                text = Self.insertingTagLineAfterTitle(line, into: normalized)
                // A caret at the end of the title line stays before the new line.
                if let offset = caret, offset > titleEnd { caret = offset + line.utf16.count + 1 }
            }
        }
        return (try create(text: text, now: context.now), caret)
    }
}
