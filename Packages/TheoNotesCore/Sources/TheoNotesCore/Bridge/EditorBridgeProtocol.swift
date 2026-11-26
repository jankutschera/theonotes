// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Swift mirror of `web/editor/src/bridge/protocol.ts`. `Fixtures/bridge/messages-*.json` pin the
/// wire format for both sides. All positions are UTF-16 code-unit offsets.
public enum EditorBridge {
    /// v3 (M6 Task 2): menus with `menuId`, fold state, rich copy, typewriter mode, `selectRange`.
    /// v4 (M7 Task 6): `setSettings` carries `appearance`, `reduceMotion`, the three font families and
    /// `paragraphIndent`; theme tokens are limited to the schema's.
    /// v5 (integration merge 2026-10-26): Baerchen's v4 plus ios-iphone-ipad's `scrollChanged`.
    public static let version = 5
    /// Per dropped or pasted file (attachments.ts `MAX_ATTACHMENT_BYTES`); larger files go
    /// through Format ▸ File… (⇧⌘V).
    public static let maxAttachmentBytes = 50 * 1024 * 1024
    /// Per drop or paste (`MAX_UPLOAD_BYTES`).
    public static let maxUploadBytes = 100 * 1024 * 1024
    /// No note carries more folds than this (JS `MAX_FOLDS`); longer lists are cut.
    public static let maxFolds = 10_000

    /// The longest base64 text of `bytes` bytes.
    static func base64Length(_ bytes: Int) -> Int { (bytes + 2) / 3 * 4 }
}

/// Editor commands the host runs with `applyCommand` (JS `COMMAND_NAMES`, in the same order as
/// `Fixtures/bridge/command-names.json`).
public enum EditorCommandName: String, Codable, CaseIterable, Sendable {
    case bold, italic, underline, strike, highlight, inlineCode, codeBlock, heading
    case bulletList, orderedList, todo, toggleTodo, moveCheckedToBottom, quote, link, setLink
    case horizontalRule, insertDate, indent, outdent, moveLineUp, moveLineDown, toggleFold
    case selectAll, insertText
    /// Edit ▸ Find ▸ Find Next / Find Previous: with the find panel open they select its next /
    /// previous match, else they step through the search highlight (R32).
    case findNext, findPrevious
    /// Edit ▸ Find ▸ Find… / Find and Replace…: the editor's find panel (read-only notes: find only).
    case find, findAndReplace
    case wikiLink, footnote, openLink
    /// Format ▸ File… (⇧⌘V): the host's open panel; the editor command does nothing.
    case insertFile
    /// `{from, to, expect, text}`: replaces the range if it still reads `expect`.
    case replaceRange
    /// `{text}`: Edit ▸ Paste From ▸ Code (the pasteboard's text in a fenced block).
    case pasteCode
    // Tables (M6 Tasks 5-6): the row and column commands take an optional `menuId` (the cell the
    // menu was opened on); `tableMoveRow {direction: "up" | "down"}`, `tableMoveColumn
    // {direction: "left" | "right"}`, `copyTable {format: "csv" | "html" | "markdown", menuId?}`.
    case createTable, tableAddRow, tableAddColumn, tableDeleteRow, tableDeleteColumn
    case tableMoveRow, tableMoveColumn, copyTable
    /// `callout {type?}` and `setCalloutType {type, menuId?}` (M6 Task 10).
    case callout, setCalloutType
    /// `insertMath {display: Bool}` (M6 Task 11).
    case insertMath
    /// Fold All / Unfold All (M6 Task 7); `toggleFold` takes an optional `menuId` (a heading line).
    case foldAll, unfoldAll
}

/// Bear's callout types (JS `CALLOUT_TYPES`); the wire uses the lowercase names.
public enum CalloutType: String, Codable, CaseIterable, Sendable {
    case note, tip, important, warning, caution
}

/// One folded block of a note (`note_ui_state.foldState`): `line` is the 1-based line of the
/// fold's first line, `hash` the FNV-1a 32-bit hash of that line's text as 8 lowercase hex
/// characters. A fold whose line no longer matches its hash is dropped when the note opens.
public struct FoldEntry: Codable, Equatable, Hashable, Sendable {
    public let line: Int
    public let hash: String

    /// Nil unless `line` is at least 1 and `hash` is 8 lowercase hex characters.
    public init?(line: Int, hash: String) {
        guard line >= 1, hash.utf8.count == 8, hash.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            return nil
        }
        self.line = line
        self.hash = hash
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let line = try c.decode(Int.self, forKey: .line)
        let hash = try c.decode(String.self, forKey: .hash)
        guard let entry = FoldEntry(line: line, hash: hash) else {
            throw DecodingError.dataCorruptedError(forKey: .line, in: c, debugDescription: "fold entry \(line) \(hash)")
        }
        self = entry
    }

    private enum CodingKeys: String, CodingKey { case line, hash }

    /// The valid entries of a stored or received list, in order; invalid ones are dropped one by
    /// one (a damaged fold must not stop a note from opening), at most `EditorBridge.maxFolds`.
    public static func valid(from decoder: any Decoder) throws -> [FoldEntry] {
        struct Skip: Decodable { init(from decoder: any Decoder) throws {} }
        var c = try decoder.unkeyedContainer()
        var entries: [FoldEntry] = []
        while !c.isAtEnd, entries.count < EditorBridge.maxFolds {
            if let entry = try? c.decode(FoldEntry.self) {
                entries.append(entry)
            } else {
                _ = try c.decode(Skip.self)
            }
        }
        return entries
    }
}

/// A fold list decoded leniently (`FoldEntry.valid`).
private struct LenientFolds: Decodable {
    let entries: [FoldEntry]
    init(from decoder: any Decoder) throws { entries = try FoldEntry.valid(from: decoder) }
}

/// `headingMenu`: the heading badge was clicked. The host shows the menu at `rect` and answers
/// with `applyCommand {..., menuId}`.
public struct HeadingMenuRequest: Equatable, Sendable {
    public var noteId: String
    public var menuId: String
    /// 1-based.
    public var line: Int
    /// 1-6.
    public var level: Int
    public var folded: Bool
    public var rect: CaretRect

    public init(noteId: String, menuId: String, line: Int, level: Int, folded: Bool, rect: CaretRect) {
        self.noteId = noteId
        self.menuId = menuId
        self.line = line
        self.level = level
        self.folded = folded
        self.rect = rect
    }
}

/// `tableMenu`: the cell button of a table. `row` 0 is the header; `rows` and `columns` count the
/// header row and every column, so `row` < `rows` and `column` < `columns`.
public struct TableMenuRequest: Equatable, Sendable {
    public var noteId: String
    public var menuId: String
    public var row: Int
    public var column: Int
    public var rows: Int
    public var columns: Int
    public var rect: CaretRect

    public init(noteId: String, menuId: String, row: Int, column: Int, rows: Int, columns: Int, rect: CaretRect) {
        self.noteId = noteId
        self.menuId = menuId
        self.row = row
        self.column = column
        self.rows = rows
        self.columns = columns
        self.rect = rect
    }
}

/// `calloutMenu`: the type button of a callout.
public struct CalloutMenuRequest: Equatable, Sendable {
    public var noteId: String
    public var menuId: String
    public var calloutType: CalloutType
    public var rect: CaretRect

    public init(noteId: String, menuId: String, calloutType: CalloutType, rect: CaretRect) {
        self.noteId = noteId
        self.menuId = menuId
        self.calloutType = calloutType
        self.rect = rect
    }
}

/// One dropped or pasted file of `insertAttachments`.
public struct AttachmentUpload: Codable, Equatable, Sendable {
    public var filename: String
    /// The bytes, base64-encoded.
    public var dataBase64: String

    public init(filename: String, dataBase64: String) {
        self.filename = filename
        self.dataBase64 = dataBase64
    }
}

/// One attachment link inside pasted text (`pasteAttachments`): its UTF-16 range and filename.
public struct PastedAttachment: Codable, Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var filename: String

    public init(from: Int, to: Int, filename: String) {
        self.from = from
        self.to = to
        self.filename = filename
    }
}

/// What an opened link points at (JS `LINK_KINDS`): `url` any URL with a scheme, `bearURL` a
/// `bear://` URL, `attachment` a link without a scheme, `wiki` a note title (empty: the same note),
/// `tag` a tag path without `#`. The host decides what it opens.
public enum LinkKind: String, Codable, CaseIterable, Sendable {
    case url, wiki, tag, attachment, bearURL
}

/// `openLink`: ⌘-click, the external-link icon, ⇧⌘K / ⌥⇧⌘K.
public struct OpenLinkRequest: Equatable, Sendable {
    public var noteId: String
    public var kind: LinkKind
    public var target: String
    /// A wiki link's heading.
    public var heading: String?
    public var newWindow: Bool

    public init(noteId: String, kind: LinkKind, target: String, heading: String?, newWindow: Bool) {
        self.noteId = noteId
        self.kind = kind
        self.target = target
        self.heading = heading
        self.newWindow = newWindow
    }
}

/// The caret in web view viewport coordinates (CSS px), for anchoring the link panel.
public struct CaretRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// `editLinkRequest` (⌘K): the link's current fields. The editor keeps the range under `requestId`
/// (mapped through later edits); the panel answers with `setLink{requestId, title, url}`.
public struct EditLinkRequest: Equatable, Sendable {
    public var noteId: String
    public var requestId: String
    public var from: Int
    public var to: Int
    public var title: String
    public var url: String
    /// An existing `[title](url)` link (the panel offers Remove Link); false for a new one.
    public var editing: Bool
    public var caretRect: CaretRect

    public init(
        noteId: String, requestId: String, from: Int, to: Int, title: String, url: String, editing: Bool,
        caretRect: CaretRect
    ) {
        self.noteId = noteId
        self.requestId = requestId
        self.from = from
        self.to = to
        self.title = title
        self.url = url
        self.editing = editing
        self.caretRect = caretRect
    }
}

/// One `applyCommand` argument: `heading` {level}, `highlight` {color}, `insertDate` {style},
/// `insertMath` {display}, …
public enum CommandArgument: Codable, Equatable, Hashable, Sendable {
    case int(Int)
    case string(String)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        }
    }
}

/// What the native Format menu shows for the editor's main selection (`formatState`).
public struct FormatState: Equatable, Sendable {
    /// The styles and blocks the selection has; `heading` comes with `headingLevel`.
    public var active: Set<EditorCommandName>
    public var headingLevel: Int?
    public var inTodo: Bool
    /// Inside a code block or span: inline styles are disabled.
    public var inCode: Bool
    /// Tab would indent a list item.
    public var canIndent: Bool

    public init(active: Set<EditorCommandName>, headingLevel: Int?, inTodo: Bool, inCode: Bool, canIndent: Bool) {
        self.active = active
        self.headingLevel = headingLevel
        self.inTodo = inTodo
        self.inCode = inCode
        self.canIndent = canIndent
    }

    /// Plain text: no style, not in code.
    public static let plain = FormatState(active: [], headingLevel: nil, inTodo: false, inCode: false, canIndent: false)
}

public struct SelectionRange: Codable, Equatable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }
}

private enum MessageKeys: String, CodingKey {
    case type, noteId, text, revision, readOnly, selection, scrollTop, changeSet, requestId
    case version, txId, baseRevision, anchor, head, sha256, message, stack, line, level
    case status, currentRevision
    case name, args, active, headingLevel, inTodo, inCode, canIndent, query, terms
    case kind, target, heading, newWindow, from, to, title, url, caretRect, index, editing
    case insertId, items, filename, source, sourceNoteId, reason, filenames
    case noteTitle, icons, autocomplete, hideMarkdown, autoSortTodos, showHeadingLevels, typography, theme
    case menuId, folded, rect, row, column, rows, columns, calloutType, folds, foldState, html, typewriterMode
    case appearance, reduceMotion
    case ok, editedSinceLoad, lastAckedTxId
}

/// `setSettings` typography: sizes in points (CSS px), `lineHeight` a multiple of the size,
/// `paragraphSpacing` and `paragraphIndent` (0...4) in em. A field left nil uses the editor's
/// default (`Fixtures/themes/typography-defaults.json`). A font is a family name; the editor
/// puts its default stack behind it.
public struct EditorTypography: Codable, Equatable, Sendable {
    public var fontSize: Double?
    public var lineHeight: Double?
    public var lineWidth: Double?
    public var paragraphSpacing: Double?
    public var paragraphIndent: Double?
    public var fontText: String?
    public var fontHeading: String?
    public var fontCode: String?

    public init(
        fontSize: Double? = nil, lineHeight: Double? = nil, lineWidth: Double? = nil, paragraphSpacing: Double? = nil,
        paragraphIndent: Double? = nil, fontText: String? = nil, fontHeading: String? = nil, fontCode: String? = nil
    ) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.lineWidth = lineWidth
        self.paragraphSpacing = paragraphSpacing
        self.paragraphIndent = paragraphIndent
        self.fontText = fontText
        self.fontHeading = fontHeading
        self.fontCode = fontCode
    }

    /// The editor rejects a whole `setSettings` for a family it cannot put in a declaration (JS
    /// `fontFamily`): 1...100 UTF-16 code units (JS `length`), none of `;{}<>\"` or a line break
    /// (checked per Unicode scalar, so CRLF counts as two).
    public static func isValidFontFamily(_ name: String) -> Bool {
        (1...100).contains(name.utf16.count) && !name.unicodeScalars.contains { ";{}<>\\\"\n\r".unicodeScalars.contains($0) }
    }

    private static var fontFields: [(name: String, path: WritableKeyPath<EditorTypography, String?>)] {
        [("fontText", \.fontText), ("fontHeading", \.fontHeading), ("fontCode", \.fontCode)]
    }

    /// The fonts the editor would reject: the field name and the length of the name (never the name).
    public var invalidFonts: [(field: String, length: Int)] {
        Self.fontFields.compactMap { field in
            guard let name = self[keyPath: field.path], !Self.isValidFontFamily(name) else { return nil }
            return (field.name, name.utf16.count)
        }
    }

    /// The same typography without the fonts the editor would reject.
    var withoutInvalidFonts: EditorTypography {
        var result = self
        for field in Self.fontFields {
            if let name = result[keyPath: field.path], !Self.isValidFontFamily(name) { result[keyPath: field.path] = nil }
        }
        return result
    }
}

/// The editor's own light or dark look (`setSettings.appearance`, default light).
public enum EditorAppearance: String, Codable, Sendable { case light, dark }

/// `setSettings`: editor settings, applied without reloading the note. A field left nil is not
/// sent and stays as the editor has it; a `typography` or `theme` replaces the previous one.
public struct EditorSettings: Equatable, Sendable {
    /// `SettingKey.hideMarkdown`: markup hidden unless the caret is inside (off: shown, dimmed).
    public var hideMarkdown: Bool?
    /// `SettingKey.autoSortTodos`: checked todos move to the end of their checklist.
    public var autoSortTodos: Bool?
    /// `SettingKey.showHeadingLevels`: the H1…H6 badges in the left margin (the text column stays).
    public var showHeadingLevels: Bool?
    /// Tag, note, heading and emoji completion (M3 Task 7).
    public var autocomplete: Bool?
    /// Typewriter mode (M6 Task 14, default off): the caret line stays at the vertical centre.
    public var typewriterMode: Bool?
    public var typography: EditorTypography?
    /// Theme tokens: `--bc-<schema editor token>` CSS variable → value (`[:]`: the default theme).
    /// Encoding passes the map through `ThemeSchema.sanitize(variables:)`, so no other variable and
    /// no value that is not `#rrggbb[aa]` ever reaches the editor.
    public var theme: [String: String]?
    /// The editor's dark flag and `color-scheme` (default light; follows the resolved theme's appearance).
    public var appearance: EditorAppearance?
    /// No transitions or animations (default off; the system's Reduce Motion).
    public var reduceMotion: Bool?

    public init(
        hideMarkdown: Bool? = nil, autoSortTodos: Bool? = nil, showHeadingLevels: Bool? = nil, autocomplete: Bool? = nil,
        typewriterMode: Bool? = nil, typography: EditorTypography? = nil, theme: [String: String]? = nil,
        appearance: EditorAppearance? = nil, reduceMotion: Bool? = nil
    ) {
        self.hideMarkdown = hideMarkdown
        self.autoSortTodos = autoSortTodos
        self.showHeadingLevels = showHeadingLevels
        self.autocomplete = autocomplete
        self.typewriterMode = typewriterMode
        self.typography = typography
        self.theme = theme
        self.appearance = appearance
        self.reduceMotion = reduceMotion
    }
}

/// Why a `frozenForClose` is not ok. The host only needs "not ok" (it keeps the note); the cases
/// say what happened, for logs and tests.
public enum FreezeFailure: String, Codable, Equatable, Sendable {
    case timeout, halted, notShown, composing, superseded, reloaded, unfrozen
}

/// The editor's answer to `freezeForClose` (docs/editor-bridge-capture-close.md). `ok`: the editor
/// is frozen and every transaction it sent before has been acknowledged; `sha256` is the hash of
/// its document, `lastAckedTxId` the latest acknowledged transaction (nil if none was).
/// `editedSinceLoad`: a change has touched this note's document since it was loaded. Not ok:
/// `reason` says why; there is no hash.
public struct FrozenForClose: Equatable, Sendable {
    public var requestId: String
    public var noteId: String
    public var ok: Bool
    public var editedSinceLoad: Bool
    public var sha256: String?
    public var lastAckedTxId: String?
    public var reason: FreezeFailure?

    public init(
        requestId: String, noteId: String, ok: Bool, editedSinceLoad: Bool, sha256: String? = nil,
        lastAckedTxId: String? = nil, reason: FreezeFailure? = nil
    ) {
        self.requestId = requestId
        self.noteId = noteId
        self.ok = ok
        self.editedSinceLoad = editedSinceLoad
        self.sha256 = sha256
        self.lastAckedTxId = lastAckedTxId
        self.reason = reason
    }
}

public enum HostToEditorMessage: Encodable, Equatable, Sendable {
    case loadNote(
        noteId: String, text: String, revision: Int, readOnly: Bool,
        selection: SelectionRange? = nil, scrollTop: Double? = nil, foldState: [FoldEntry]? = nil
    )
    case applyExternalChange(noteId: String, revision: Int, changeSet: ChangeSet)
    case setRevision(noteId: String, revision: Int)
    case focus
    case requestChecksum(requestId: String)
    /// `noteId` was opened from the note-list search: highlight `terms` (`SearchResult.terms`) and
    /// scroll to the first match without moving the selection; empty `terms` clear. The editor
    /// drops it for another note. `query` is the raw search text.
    case searchHighlight(noteId: String, query: String, terms: [String])
    /// Runs a registry command (native menu / shortcut); one undo step in the editor.
    case applyCommand(name: EditorCommandName, args: [String: CommandArgument]? = nil)
    /// Puts the caret on the note's `index`-th heading (0-based, `NoteParser` order) and scrolls
    /// it to the top (Info panel table of contents).
    case scrollToHeading(noteId: String, index: Int)
    /// The answer to `requestCompletions` `requestId`, ranked; the editor ignores all but the
    /// answer to its latest request.
    case completionResults(requestId: String, items: [CompletionItem])
    /// Tag path key (`CanonicalKey` of the path) → TagCon symbol for every tag; the editor shows
    /// the icon next to tag pills (served as `baerchen-asset://tagcon/v2/<symbol>.png`).
    case tagIcons([String: String])
    case setSettings(EditorSettings)
    /// Selects the UTF-16 range `anchor`...`head` of the shown note `noteId` and scrolls it into
    /// view (`anchor` > `head`: backwards; equal: a caret). The editor drops it for another note or
    /// a range outside the document. Not an edit, so also for read-only notes.
    case selectRange(noteId: String, anchor: Int, head: Int)
    /// Capture close: the editor ends a running composition, switches to read-only, waits until
    /// everything it sent is acknowledged and answers with `frozenForClose` (same `requestId`).
    case freezeForClose(requestId: String, noteId: String)
    /// Ends the freeze `requestId` started; the editor gets the mode it had back.
    case unfreeze(requestId: String, noteId: String)

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: MessageKeys.self)
        switch self {
        case let .loadNote(noteId, text, revision, readOnly, selection, scrollTop, foldState):
            try c.encode("loadNote", forKey: .type)
            try c.encode(noteId, forKey: .noteId)
            try c.encode(text, forKey: .text)
            try c.encode(revision, forKey: .revision)
            try c.encode(readOnly, forKey: .readOnly)
            try c.encodeIfPresent(selection, forKey: .selection)
            try c.encodeIfPresent(scrollTop, forKey: .scrollTop)
            try c.encodeIfPresent(foldState.map { Array($0.prefix(EditorBridge.maxFolds)) }, forKey: .foldState)
        case let .applyExternalChange(noteId, revision, changeSet):
            try c.encode("applyExternalChange", forKey: .type)
            try c.encode(noteId, forKey: .noteId)
            try c.encode(revision, forKey: .revision)
            try c.encode(changeSet, forKey: .changeSet)
        case let .setRevision(noteId, revision):
            try c.encode("setRevision", forKey: .type)
            try c.encode(noteId, forKey: .noteId)
            try c.encode(revision, forKey: .revision)
        case .focus:
            try c.encode("focus", forKey: .type)
        case let .requestChecksum(requestId):
            try c.encode("requestChecksum", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
        case let .searchHighlight(noteId, query, terms):
            try c.encode("searchHighlight", forKey: .type)
            try c.encode(noteId, forKey: .noteId)
            try c.encode(query, forKey: .query)
            try c.encode(terms, forKey: .terms)
        case let .applyCommand(name, args):
            try c.encode("applyCommand", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(args, forKey: .args)
        case let .scrollToHeading(noteId, index):
            try c.encode("scrollToHeading", forKey: .type)
            try c.encode(noteId, forKey: .noteId)
            try c.encode(index, forKey: .index)
        case let .completionResults(requestId, items):
            try c.encode("completionResults", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(items, forKey: .items)
        case .tagIcons(let icons):
            try c.encode("tagIcons", forKey: .type)
            try c.encode(icons, forKey: .icons)
        case .setSettings(let settings):
            try c.encode("setSettings", forKey: .type)
            try c.encodeIfPresent(settings.hideMarkdown, forKey: .hideMarkdown)
            try c.encodeIfPresent(settings.autoSortTodos, forKey: .autoSortTodos)
            try c.encodeIfPresent(settings.showHeadingLevels, forKey: .showHeadingLevels)
            try c.encodeIfPresent(settings.autocomplete, forKey: .autocomplete)
            try c.encodeIfPresent(settings.typewriterMode, forKey: .typewriterMode)
            try c.encodeIfPresent(settings.typography?.withoutInvalidFonts, forKey: .typography)
            try c.encodeIfPresent(settings.theme.map(ThemeSchema.sanitize(variables:)), forKey: .theme)
            try c.encodeIfPresent(settings.appearance, forKey: .appearance)
            try c.encodeIfPresent(settings.reduceMotion, forKey: .reduceMotion)
        case let .selectRange(noteId, anchor, head):
            try c.encode("selectRange", forKey: .type)
            try c.encode(noteId, forKey: .noteId)
            try c.encode(anchor, forKey: .anchor)
            try c.encode(head, forKey: .head)
        case let .freezeForClose(requestId, noteId):
            try c.encode("freezeForClose", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(noteId, forKey: .noteId)
        case let .unfreeze(requestId, noteId):
            try c.encode("unfreeze", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(noteId, forKey: .noteId)
        }
    }
}

public enum EditorToHostMessage: Decodable, Equatable, Sendable {
    case ready(version: Int)
    case changes(noteId: String, txId: String, baseRevision: Int, revision: Int, changeSet: ChangeSet)
    case recoveryText(noteId: String, baseRevision: Int, text: String)
    case scrollChanged(noteId: String, scrollTop: Double)
    case selectionChanged(noteId: String, anchor: Int, head: Int)
    case checksum(requestId: String, noteId: String, sha256: String)
    case error(message: String, stack: String?)
    /// The answer to `freezeForClose`.
    case frozenForClose(FrozenForClose)
    /// The heading badge in the editor gutter was clicked (v3: with the `menuId` to answer with,
    /// the fold state and the badge's rect).
    case headingMenu(HeadingMenuRequest)
    /// The cell button of a table.
    case tableMenu(TableMenuRequest)
    /// The type button of a callout.
    case calloutMenu(CalloutMenuRequest)
    /// The note's folds changed; the host stores them (`note_ui_state.foldState`) for the next
    /// `loadNote`.
    case foldState(noteId: String, folds: [FoldEntry])
    /// The Format menu state, debounced (50 ms) after selection and document changes.
    case formatState(noteId: String, state: FormatState)
    case openLink(OpenLinkRequest)
    case editLinkRequest(EditLinkRequest)
    /// Files dropped (at the drop point) or pasted (over the selection) into the editor; the host
    /// stores them and answers with `applyCommand insertText {text, insertId}`. Rejected when an
    /// item is over `maxAttachmentBytes` or all over `maxUploadBytes`.
    case insertAttachments(noteId: String, insertId: String, items: [AttachmentUpload])
    /// Attachment links pasted from `sourceNoteId`: the host copies their files and answers with
    /// `insertText {text, insertId}`, links renamed where a name was taken.
    case pasteAttachments(noteId: String, insertId: String, sourceNoteId: String, text: String, items: [PastedAttachment])
    /// Dropped or pasted files over the caps (the host explains and points to ⇧⌘V).
    case attachmentsRefused(noteId: String, filenames: [String])
    /// Attachment links copied or cut (ruling R30): the host keeps these files until the
    /// pasteboard changes.
    case cutAttachments(noteId: String, filenames: [String])
    /// Space or a double click on an attachment.
    case quickLook(noteId: String, filename: String)
    /// A touch tap, carrying the exact attachment source for revalidation.
    case attachmentTap(noteId: String, filename: String, from: Int, to: Int, source: String)
    /// The context menu of the attachment whose source text `[from, to)` is `source`.
    case attachmentMenu(noteId: String, filename: String, from: Int, to: Int, source: String)
    /// Copy Code / Copy Table As: put `text` on the general pasteboard as plain text, and `html`
    /// as HTML too when present.
    case copyText(text: String, html: String?)
    /// The editor wants completions; the host answers with `completionResults`.
    case requestCompletions(CompletionRequest)

    /// A menu message's `menuId`: never empty.
    private static func menuId(_ c: KeyedDecodingContainer<MessageKeys>) throws -> String {
        let id = try c.decode(String.self, forKey: .menuId)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .menuId, in: c, debugDescription: "empty menuId")
        }
        return id
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: MessageKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready(version: try c.decode(Int.self, forKey: .version))
        case "changes":
            self = .changes(
                noteId: try c.decode(String.self, forKey: .noteId),
                txId: try c.decode(String.self, forKey: .txId),
                baseRevision: try c.decode(Int.self, forKey: .baseRevision),
                revision: try c.decode(Int.self, forKey: .revision),
                changeSet: try c.decode(ChangeSet.self, forKey: .changeSet)
            )
        case "recoveryText":
            let id = try c.decode(String.self, forKey: .noteId)
            let base = try c.decode(Int.self, forKey: .baseRevision)
            guard !id.isEmpty, base >= 0 else { throw DecodingError.dataCorruptedError(forKey: .noteId, in: c, debugDescription: "Invalid recovery identity") }
            self = .recoveryText(noteId: id, baseRevision: base, text: try c.decode(String.self, forKey: .text))
        case "scrollChanged":
            let top = try c.decode(Double.self, forKey: .scrollTop)
            guard top.isFinite, top >= 0 else { throw DecodingError.dataCorruptedError(forKey: .scrollTop, in: c, debugDescription: "Invalid scroll offset") }
            self = .scrollChanged(noteId: try c.decode(String.self, forKey: .noteId), scrollTop: top)
        case "selectionChanged":
            self = .selectionChanged(
                noteId: try c.decode(String.self, forKey: .noteId),
                anchor: try c.decode(Int.self, forKey: .anchor),
                head: try c.decode(Int.self, forKey: .head)
            )
        case "checksum":
            self = .checksum(
                requestId: try c.decode(String.self, forKey: .requestId),
                noteId: try c.decode(String.self, forKey: .noteId),
                sha256: try c.decode(String.self, forKey: .sha256)
            )
        case "error":
            self = .error(
                message: try c.decode(String.self, forKey: .message),
                stack: try c.decodeIfPresent(String.self, forKey: .stack)
            )
        case "frozenForClose":
            let requestId = try c.decode(String.self, forKey: .requestId)
            let ok = try c.decode(Bool.self, forKey: .ok)
            let sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
            let lastAckedTxId = try c.decodeIfPresent(String.self, forKey: .lastAckedTxId)
            let reason = try c.decodeIfPresent(FreezeFailure.self, forKey: .reason)
            // An ok reply carries the document hash and no reason; a failed one a reason and no hash.
            let isHash = sha256.map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? false
            guard !requestId.isEmpty, lastAckedTxId?.isEmpty != true, ok ? (isHash && reason == nil) : (sha256 == nil && reason != nil) else {
                throw DecodingError.dataCorruptedError(forKey: .ok, in: c, debugDescription: "inconsistent frozenForClose")
            }
            self = .frozenForClose(FrozenForClose(
                requestId: requestId, noteId: try c.decode(String.self, forKey: .noteId), ok: ok,
                editedSinceLoad: try c.decode(Bool.self, forKey: .editedSinceLoad), sha256: sha256,
                lastAckedTxId: lastAckedTxId, reason: reason))
        case "headingMenu":
            let line = try c.decode(Int.self, forKey: .line), level = try c.decode(Int.self, forKey: .level)
            guard line >= 1, (1...6).contains(level) else {
                throw DecodingError.dataCorruptedError(forKey: .line, in: c, debugDescription: "heading line \(line) level \(level)")
            }
            self = .headingMenu(HeadingMenuRequest(
                noteId: try c.decode(String.self, forKey: .noteId), menuId: try Self.menuId(c),
                line: line, level: level, folded: try c.decode(Bool.self, forKey: .folded),
                rect: try c.decode(CaretRect.self, forKey: .rect)
            ))
        case "tableMenu":
            let row = try c.decode(Int.self, forKey: .row), column = try c.decode(Int.self, forKey: .column)
            let rows = try c.decode(Int.self, forKey: .rows), columns = try c.decode(Int.self, forKey: .columns)
            guard row >= 0, column >= 0, row < rows, column < columns else {
                throw DecodingError.dataCorruptedError(
                    forKey: .row, in: c, debugDescription: "table cell \(row),\(column) of \(rows)x\(columns)")
            }
            self = .tableMenu(TableMenuRequest(
                noteId: try c.decode(String.self, forKey: .noteId), menuId: try Self.menuId(c),
                row: row, column: column, rows: rows, columns: columns, rect: try c.decode(CaretRect.self, forKey: .rect)
            ))
        case "calloutMenu":
            self = .calloutMenu(CalloutMenuRequest(
                noteId: try c.decode(String.self, forKey: .noteId), menuId: try Self.menuId(c),
                calloutType: try c.decode(CalloutType.self, forKey: .calloutType), rect: try c.decode(CaretRect.self, forKey: .rect)
            ))
        case "foldState":
            self = .foldState(
                noteId: try c.decode(String.self, forKey: .noteId), folds: try c.decode(LenientFolds.self, forKey: .folds).entries)
        case "formatState":
            let level = try c.decodeIfPresent(Int.self, forKey: .headingLevel)
            if let level, !(1...6).contains(level) {
                throw DecodingError.dataCorruptedError(forKey: .headingLevel, in: c, debugDescription: "heading level \(level)")
            }
            self = .formatState(
                noteId: try c.decode(String.self, forKey: .noteId),
                state: FormatState(
                    active: Set(try c.decode([EditorCommandName].self, forKey: .active)),
                    headingLevel: level,
                    inTodo: try c.decode(Bool.self, forKey: .inTodo),
                    inCode: try c.decode(Bool.self, forKey: .inCode),
                    canIndent: try c.decode(Bool.self, forKey: .canIndent)
                )
            )
        case "openLink":
            self = .openLink(OpenLinkRequest(
                noteId: try c.decode(String.self, forKey: .noteId),
                kind: try c.decode(LinkKind.self, forKey: .kind),
                target: try c.decode(String.self, forKey: .target),
                heading: try c.decodeIfPresent(String.self, forKey: .heading),
                newWindow: try c.decode(Bool.self, forKey: .newWindow)
            ))
        case "editLinkRequest":
            let from = try c.decode(Int.self, forKey: .from)
            let to = try c.decode(Int.self, forKey: .to)
            guard from >= 0, from <= to else {
                throw DecodingError.dataCorruptedError(forKey: .from, in: c, debugDescription: "link range \(from)..<\(to)")
            }
            self = .editLinkRequest(EditLinkRequest(
                noteId: try c.decode(String.self, forKey: .noteId),
                requestId: try c.decode(String.self, forKey: .requestId), from: from, to: to,
                title: try c.decode(String.self, forKey: .title),
                url: try c.decode(String.self, forKey: .url),
                editing: try c.decode(Bool.self, forKey: .editing),
                caretRect: try c.decode(CaretRect.self, forKey: .caretRect)
            ))
        case "insertAttachments":
            let items = try c.decode([AttachmentUpload].self, forKey: .items)
            let insertId = try c.decode(String.self, forKey: .insertId)
            let perItem = EditorBridge.base64Length(EditorBridge.maxAttachmentBytes)
            guard !items.isEmpty, !insertId.isEmpty, items.allSatisfy({ !$0.filename.isEmpty && $0.dataBase64.utf8.count <= perItem }),
                  items.reduce(0, { $0 + $1.dataBase64.utf8.count }) <= EditorBridge.base64Length(EditorBridge.maxUploadBytes) else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "no items, unnamed or too large")
            }
            self = .insertAttachments(noteId: try c.decode(String.self, forKey: .noteId), insertId: insertId, items: items)
        case "pasteAttachments":
            let items = try c.decode([PastedAttachment].self, forKey: .items)
            let insertId = try c.decode(String.self, forKey: .insertId), source = try c.decode(String.self, forKey: .sourceNoteId)
            guard !items.isEmpty, !insertId.isEmpty, !source.isEmpty,
                  items.allSatisfy({ !$0.filename.isEmpty && $0.from >= 0 && $0.to >= $0.from }) else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "invalid pasted attachments")
            }
            self = .pasteAttachments(
                noteId: try c.decode(String.self, forKey: .noteId), insertId: insertId, sourceNoteId: source,
                text: try c.decode(String.self, forKey: .text), items: items)
        case "cutAttachments":
            let filenames = try c.decode([String].self, forKey: .filenames)
            guard !filenames.isEmpty, filenames.allSatisfy({ !$0.isEmpty }) else {
                throw DecodingError.dataCorruptedError(forKey: .filenames, in: c, debugDescription: "no filenames")
            }
            self = .cutAttachments(noteId: try c.decode(String.self, forKey: .noteId), filenames: filenames)
        case "attachmentsRefused":
            let filenames = try c.decode([String].self, forKey: .filenames)
            guard try c.decode(String.self, forKey: .reason) == "tooLarge", !filenames.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .reason, in: c, debugDescription: "unknown refusal")
            }
            self = .attachmentsRefused(noteId: try c.decode(String.self, forKey: .noteId), filenames: filenames)
        case "quickLook":
            let filename = try c.decode(String.self, forKey: .filename)
            guard !filename.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .filename, in: c, debugDescription: "empty filename")
            }
            self = .quickLook(noteId: try c.decode(String.self, forKey: .noteId), filename: filename)
        case "attachmentMenu", "attachmentTap":
            let from = try c.decode(Int.self, forKey: .from), to = try c.decode(Int.self, forKey: .to)
            let filename = try c.decode(String.self, forKey: .filename)
            guard from >= 0, to >= from, !filename.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .to, in: c, debugDescription: "range \(from)..<\(to) or empty filename")
            }
            let noteID = try c.decode(String.self, forKey: .noteId)
            let source = try c.decode(String.self, forKey: .source)
            self = type == "attachmentTap"
                ? .attachmentTap(noteId: noteID, filename: filename, from: from, to: to, source: source)
                : .attachmentMenu(noteId: noteID, filename: filename, from: from, to: to, source: source)
        case "copyText":
            self = .copyText(
                text: try c.decode(String.self, forKey: .text), html: try c.decodeIfPresent(String.self, forKey: .html))
        case "requestCompletions":
            self = .requestCompletions(CompletionRequest(
                noteId: try c.decode(String.self, forKey: .noteId),
                requestId: try c.decode(String.self, forKey: .requestId),
                kind: try c.decode(CompletionKind.self, forKey: .kind),
                query: try c.decode(String.self, forKey: .query),
                noteTitle: try c.decodeIfPresent(String.self, forKey: .noteTitle)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown editor message type \(type)"
            )
        }
    }
}

/// Reply to a `changes` message.
public enum ChangesReply: Encodable, Equatable, Sendable {
    case acked(revision: Int)
    case duplicate(revision: Int)
    case needsFullText(currentRevision: Int)

    public init(_ result: ApplyResult) {
        switch result {
        case .acked(let revision): self = .acked(revision: revision)
        case .duplicate(let revision): self = .duplicate(revision: revision)
        case .needsFullText(let current): self = .needsFullText(currentRevision: current)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: MessageKeys.self)
        switch self {
        case .acked(let revision):
            try c.encode("acked", forKey: .status)
            try c.encode(revision, forKey: .revision)
        case .duplicate(let revision):
            try c.encode("duplicate", forKey: .status)
            try c.encode(revision, forKey: .revision)
        case .needsFullText(let current):
            try c.encode("needsFullText", forKey: .status)
            try c.encode(current, forKey: .currentRevision)
        }
    }
}
