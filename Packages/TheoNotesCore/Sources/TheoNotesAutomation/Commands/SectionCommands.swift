// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// `cat`, `outline` and `search-in`. Check order (ruling M5-R51): arguments, the library, the
/// note, fields and the address's syntax, the content lock, then the address against the text
/// (which a locked note never exposes).
enum SectionCommands {
    static let handlers: [[String]: CommandHandler] = [
        ["cat"]: cat,
        ["outline"]: outline,
        ["search-in"]: searchIn,
    ]

    // MARK: cat

    private static func cat(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let rawSection = parsed.value("--section")
        let rawOffset = parsed.value("--offset")
        let rawLimit = parsed.value("--limit")
        if rawSection != nil, rawOffset != nil || rawLimit != nil {
            throw AutomationError(code: .usage, message: "Provide address or offset/limit, not both")
        }
        let limit = try nonNegative(rawLimit, "Limit")
        let offset = try nonNegative(rawOffset, "Offset")
        let library = try env.library()
        let (note, address) = try ReadFailure.read(library) { db -> (Note, SectionAddress?) in
            let note = try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
            let address = try rawSection.map { raw throws(AutomationError) in try SectionAddress.parse(raw) }
            try NoteAccess.requireReadable(note)
            return (note, address)
        }
        let text = note.text
        var fields: [(String, JSONValue)]
        let content: String
        if let address {
            let sections = NoteSections(text: text)
            let target = try sections.resolve(address)
            let entry = sections.entry(target)
            let slice = text.utf8[byteRange(entry.offset..<entry.offset + entry.length, in: text)]
            content = String(Substring(slice))
            fields = [
                ("content", .string(content)),
                (
                    "section",
                    .object([
                        ("address", .string(entry.address)), ("offset", .int(entry.offset)),
                        ("length", .int(entry.length)),
                    ])
                ),
                ("hash", .string(ContentHash.of(slice))),
            ]
        } else if rawOffset != nil || rawLimit != nil {
            content = byteSlice(text, offset: offset ?? 0, limit: limit)
            fields = [("content", .string(content))]
        } else {
            content = text
            fields = [("content", .string(content)), ("hash", .string(ContentHash.of(text)))]
        }
        switch parsed.format {
        case .tsv: env.io.write(Data(content.utf8))
        case .csv: env.io.write(Data(RecordWriter.csv(header: ["content"], [[.string(content)]]).utf8))
        case .json: env.io.write(Data((JSONValue.object(fields).serialized(sortedKeys: false) + "\n").utf8))
        }
    }

    /// Bytes `offset ..< offset + limit`, clamped to the text; the start then moves forward and
    /// the end backward to scalar boundaries, so the result may be empty but is never split.
    static func byteSlice(_ text: String, offset: Int, limit: Int?) -> String {
        let count = text.utf8.count
        let start = min(offset, count)
        let end = limit.map { start + min($0, count - start) } ?? count
        let lower = NoteFind.scalarIndex(atOrAfter: start, in: text)
        let upper = NoteFind.scalarIndex(atOrBefore: end, in: text)
        guard lower < upper else { return "" }
        return String(text[lower..<upper])
    }

    static func byteRange(_ range: Range<Int>, in text: String) -> Range<String.Index> {
        let utf8 = text.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        return lower..<utf8.index(lower, offsetBy: range.count)
    }

    // MARK: outline

    private static func outline(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        let library = try env.library()
        let (note, fields, address) = try ReadFailure.read(library) { db -> (Note, [String], SectionAddress?) in
            let note = try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
            let fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
            let address = try parsed.value("--section").map { raw throws(AutomationError) in
                try SectionAddress.parse(raw)
            }
            try NoteAccess.requireReadable(note)
            return (note, fields, address)
        }
        let sections = NoteSections(text: note.text)
        var target: SectionTarget?
        if let address { target = try sections.resolve(address) }
        let rows = sections.outline(within: target).map { entry in
            fields.map { field -> FieldValue in
                switch field {
                case "address": .string(entry.address)
                case "offset": .int(entry.offset)
                default: .int(entry.length)
                }
            }
        }
        ReadCommands.writeRows(rows, fields: fields, format: parsed.format, emptyMessage: nil, env: env)
    }

    // MARK: search-in

    struct Hit: Equatable {
        /// UTF-8 bytes into the note text; for an attachment hit, the offset of its link.
        var offset: Int
        var length: Int
        var snippet: String
        /// The innermost section (or preamble) at `offset`; nil before the first heading.
        var section: OutlineEntry?
        var source: Source

        enum Source: String {
            case body
            case attachment
        }
    }

    private static func searchIn(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
        guard let needle = parsed.value("--string") else {
            throw AutomationError(code: .usage, message: "--string is required")
        }
        let limit = try nonNegative(parsed.value("--limit"), "Limit")
        let context = try nonNegative(parsed.value("--context"), "Context") ?? 120
        let counting = parsed.flag("--count")
        let library = try env.library()
        let (note, fields, address, recognized) = try ReadFailure.read(library) {
            db -> (Note, [String], SectionAddress?, [String: String]) in
            let note = try NoteResolver.resolve(selector, scope: .unrestricted, db: db)
            let fields = counting ? [] : try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
            let address = try parsed.value("--section").map { raw throws(AutomationError) in
                try SectionAddress.parse(raw)
            }
            try NoteAccess.requireReadable(note)
            return (note, fields, address, try recognizedText(noteId: note.id, db: db))
        }
        let hits = try searchHits(
            needle, text: note.text, recognized: recognized, address: address, context: context)
        if counting { return ReadCommands.writeCount(hits.count, format: parsed.format, env: env) }
        // `-n 0` prints nothing at all, as in `list` (M5-R33).
        if limit == 0 { return }
        let rows = hits.prefix(limit ?? Int.max).map { hit in
            fields.map { field -> FieldValue in
                switch field {
                case "offset": .int(hit.offset)
                case "snippet": .escaped(TextEscapes.escapeTSV(hit.snippet))
                case "section": .string(hit.section?.address ?? "")
                default: .string(hit.source.rawValue)
                }
            }
        }
        ReadCommands.writeRows(Array(rows), fields: fields, format: parsed.format, emptyMessage: nil, env: env)
    }

    /// Case-insensitive occurrences of `needle` in the note text and in the recognized text of the
    /// files it links, in offset order (a body hit before an attachment hit at the same offset).
    /// `recognized` maps `attachment.filenameKey` to the OCR text; with `address`, only hits whose
    /// offset lies in that section count. Snippets: `context / 2` characters on each side of the
    /// match, clamped to the text they come from (ruling M5-R15).
    static func searchHits(
        _ needle: String, text: String, recognized: [String: String], address: SectionAddress?, context: Int
    ) throws(AutomationError) -> [Hit] {
        let sections = NoteSections(text: text)
        let within = try address.map { a throws(AutomationError) in sections.range(of: try sections.resolve(a)) }
        let half = context / 2
        func section(at offset: Int) -> OutlineEntry? {
            sections.innermost(at: offset).map { OutlineEntry(address: $0.address, offset: $0.offset, length: $0.length) }
        }
        var hits = NoteFind.occurrences(of: needle, in: text, within: within, ignoreCase: true, word: false).map {
            Hit(
                offset: $0.lowerBound, length: $0.count, snippet: snippet(text, $0, half: half),
                section: section(at: $0.lowerBound), source: .body)
        }
        if !recognized.isEmpty, !needle.isEmpty {
            // Each file once, at its first link inside the search range (ruling M5-R61).
            var seen = Set<String>()
            for link in NoteParser.attachmentLinks(in: text) {
                if let within, !within.contains(link.offset) { continue }
                let key = AttachmentFiles.fileSystemKey(link.filename)
                guard let ocr = recognized[key], seen.insert(key).inserted else { continue }
                for range in NoteFind.occurrences(of: needle, in: ocr, within: nil, ignoreCase: true, word: false) {
                    hits.append(
                        Hit(
                            offset: link.offset, length: range.count, snippet: snippet(ocr, range, half: half),
                            section: section(at: link.offset), source: .attachment))
                }
            }
        }
        return hits.enumerated()
            .sorted { a, b in
                (a.element.offset, a.element.source == .body ? 0 : 1, a.offset)
                    < (b.element.offset, b.element.source == .body ? 0 : 1, b.offset)
            }
            .map(\.element)
    }

    /// Recognized text of the note's live attachments (`done` rows with text), by the stored
    /// `filenameKey` (`AttachmentFiles.fileSystemKey`, ruling M5-R66).
    static func recognizedText(noteId: String, db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT filenameKey, ocrText FROM attachment
                WHERE noteId = ? AND ocrState = 'done' AND ocrText IS NOT NULL AND ocrText != '' AND deletedAt IS NULL
                """,
            arguments: [noteId])
        var result: [String: String] = [:]
        for row in rows { result[row["filenameKey"]] = row["ocrText"] }
        return result
    }

    private static func snippet(_ text: String, _ range: Range<Int>, half: Int) -> String {
        let lower = NoteFind.scalarIndex(atOrAfter: range.lowerBound, in: text)
        let upper = NoteFind.scalarIndex(atOrBefore: range.upperBound, in: text)
        let start = text.index(lower, offsetBy: -half, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(upper, offsetBy: half, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<max(start, end)])
    }

    // MARK: Shared

    /// A whole-number option that must not be negative (the parser already checked it is a number).
    private static func nonNegative(_ raw: String?, _ name: String) throws(AutomationError) -> Int? {
        guard let raw else { return nil }
        let value = Int(raw) ?? Int.max
        if value < 0 { throw AutomationError(code: .usage, message: "\(name) must be non-negative") }
        return value
    }
}
