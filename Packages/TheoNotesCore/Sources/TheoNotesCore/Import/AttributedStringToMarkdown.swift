// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

#if canImport(AppKit)
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts an attributed string (RTF / RTFD read by `NSAttributedString`) into Bear-dialect
/// Markdown (M8-R56). This file is the one place in TheoNotesCore that needs AppKit (fonts, text
/// lists, attachments); the rest of the core stays portable.
///
/// - Paragraphs become lines (U+2028 and U+000B are line breaks inside one); no title line is added.
/// - Bold and italic come from the font's traits, `.underlineStyle` → `~`, `.strikethroughStyle` →
///   `~~` (strike wins where the two would touch, as for HTML).
/// - `.link` becomes a link only for http, https and mailto; any other target leaves the text.
/// - `NSParagraphStyle.textLists` → `- ` / `1. ` with one tab per nesting level. The reader leaves
///   a list's marker text (`\t•\t`) in the string; it is removed.
/// - A paragraph whose every run is fixed-pitch → fenced code; a fixed-pitch run in prose → code span.
/// - An `NSTextAttachment` holding an image → an attachment (`image.png`, `image 2.png`, … or its
///   file wrapper's `preferredFilename`); any other attachment is dropped with a warning.
public enum AttributedStringToMarkdown {
    public static func convert(_ text: NSAttributedString) -> HTMLToMarkdown.Result {
        var converter = Converter()
        return converter.run(text)
    }

    // MARK: - Model

    private struct Style: Equatable {
        var bold = false, italic = false, underline = false, strike = false, mono = false
        var link: String?
    }

    private struct Piece {
        var style: Style
        var text: String
        var attachment: NSTextAttachment?
    }

    private struct Converter {
        var lines: [HTMLToMarkdown.Line] = []
        var images: [ImportedAttachment] = []
        var skippedAttachments = 0
        var nameByDigest: [String: String] = [:]
        var usedKeys: Set<String> = []
        var counters: [(format: String, number: Int)] = []

        mutating func run(_ text: NSAttributedString) -> HTMLToMarkdown.Result {
            let string = text.string as NSString
            var position = 0
            while position < string.length {
                var start = 0, end = 0, contentsEnd = 0
                string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
                position = max(end, position + 1)
                paragraph(text, start: start, contentsEnd: contentsEnd)
            }
            var warnings: [String] = []
            if skippedAttachments > 0 { warnings.append("\(skippedAttachments) attachment(s) that are not images were skipped") }
            return HTMLToMarkdown.Result(
                markdown: HTMLToMarkdown.assemble(lines), images: images, warnings: warnings)
        }

        // MARK: Paragraphs

        private mutating func paragraph(_ text: NSAttributedString, start: Int, contentsEnd: Int) {
            let string = text.string as NSString
            let style = string.length > 0
                ? text.attribute(.paragraphStyle, at: min(start, string.length - 1), effectiveRange: nil) as? NSParagraphStyle : nil
            let lists = style?.textLists ?? []
            var contentStart = start
            var marker: String?
            if let list = lists.last {
                if counters.count > lists.count { counters.removeLast(counters.count - lists.count) }
                // A different marker format at a level starts a new list there.
                for (level, entry) in counters.enumerated() where entry.format != lists[level].markerFormat.rawValue {
                    counters.removeSubrange(level...)
                    break
                }
                while counters.count < lists.count {
                    let next = lists[counters.count]
                    counters.append((next.markerFormat.rawValue, next.startingItemNumber - 1))
                }
                counters[lists.count - 1].number += 1
                let number = counters[lists.count - 1].number
                contentStart = Self.afterMarkerText(string, start: start, end: contentsEnd, list: list, number: number)
                marker = Self.isOrdered(list) ? "\(number). " : "- "
            } else {
                counters = []
            }

            var segments: [[Piece]] = [[]]
            if contentStart < contentsEnd {
                text.enumerateAttributes(in: NSRange(location: contentStart, length: contentsEnd - contentStart), options: []) { attributes, range, _ in
                    addRun(string.substring(with: range), attributes, to: &segments)
                }
            }
            let depth = max(0, lists.count - 1)

            let isCode = marker == nil && Self.isCode(segments)
            if isCode {
                for line in segments {
                    let raw = line.map(\.text).joined().replacingOccurrences(of: "\u{00A0}", with: " ")
                    lines.append(.init(text: raw, kind: .code))
                }
                return
            }
            var rendered = segments.map { renderLine($0) }
            if marker == nil {
                rendered = rendered.map { Renderer.escapeLineStart($0) }
            }
            if rendered.allSatisfy(\.isEmpty), marker == nil {
                lines.append(.init(text: "", kind: .empty))
                return
            }
            let indent = String(repeating: "\t", count: depth)
            for (index, line) in rendered.enumerated() {
                if let marker {
                    let prefix = index == 0 ? indent + marker : indent + "\t"
                    lines.append(.init(text: (prefix + line).trimmingTrailingBlanks(), kind: .list))
                } else {
                    lines.append(.init(text: line, kind: line.isEmpty ? .empty : .text))
                }
            }
        }

        private static func isCode(_ lines: [[Piece]]) -> Bool {
            var sawCode = false
            for piece in lines.joined() {
                if piece.attachment != nil { return false }
                if piece.text.allSatisfy(\.isWhitespace) { continue }
                if !piece.style.mono { return false }
                sawCode = true
            }
            return sawCode
        }

        private static func isOrdered(_ list: NSTextList) -> Bool {
            let format = list.markerFormat.rawValue
            return ["decimal", "alpha", "latin", "roman", "octal", "hexadecimal"].contains { format.contains($0) }
        }

        /// The reader keeps a list item's marker as text (`\t•\t`, `\t1.\t`); the index after it,
        /// or `start` when the paragraph does not begin with one.
        private static func afterMarkerText(_ string: NSString, start: Int, end: Int, list: NSTextList, number: Int) -> Int {
            var i = start
            if i < end, string.character(at: i) == 9 { i += 1 }
            let tokenStart = i
            while i < end, i - tokenStart < 12, string.character(at: i) != 9 { i += 1 }
            guard i < end, i > tokenStart, string.character(at: i) == 9 else { return start }
            let token = string.substring(with: NSRange(location: tokenStart, length: i - tokenStart))
            let looksLikeMarker = token == list.marker(forItemNumber: number)
                || token.range(of: #"^(\d+|[A-Za-z]+)[.)]$"#, options: .regularExpression) != nil
                || (token.count == 1 && "•◦▪▫‣◆◇■□✓☐☑-–—·∙*".contains(token))
            return looksLikeMarker ? i + 1 : start
        }

        // MARK: Runs

        private mutating func addRun(_ raw: String, _ attributes: [NSAttributedString.Key: Any], to segments: inout [[Piece]]) {
            var style = Style()
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.mono = font.isFixedPitch || traits.contains(.monoSpace)
                style.bold = traits.contains(.bold) && !style.mono
                style.italic = traits.contains(.italic) && !style.mono
            }
            style.underline = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
            style.strike = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
            if let link = Self.allowedLink(attributes[.link]) {
                style.link = link
                style.underline = false
            }
            let attachment = attributes[.attachment] as? NSTextAttachment
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                append(Piece(style: style, text: current, attachment: nil), to: &segments)
                current = ""
            }
            for scalar in raw.unicodeScalars {
                switch scalar {
                case "\u{FFFC}":
                    flush()
                    if let attachment {
                        segments[segments.count - 1].append(Piece(style: style, text: "", attachment: attachment))
                    }
                case "\u{2028}", "\u{000B}":
                    flush()
                    segments.append([])
                default:
                    current.unicodeScalars.append(scalar)
                }
            }
            flush()
        }

        /// Adjacent runs with the same style are one piece, so `**a****b**` never happens.
        private func append(_ piece: Piece, to segments: inout [[Piece]]) {
            if let last = segments[segments.count - 1].last, last.attachment == nil, last.style == piece.style {
                segments[segments.count - 1][segments[segments.count - 1].count - 1].text += piece.text
            } else {
                segments[segments.count - 1].append(piece)
            }
        }

        private static func allowedLink(_ value: Any?) -> String? {
            let text: String
            switch value {
            case let url as URL: text = url.absoluteString
            case let string as String: text = string
            default: return nil
            }
            return HTMLToMarkdown.allowedLinkTarget(text)
        }

        // MARK: Rendering

        private mutating func renderLine(_ pieces: [Piece]) -> String {
            var rendered: [(piece: Piece, text: String)] = []
            for piece in pieces {
                if let attachment = piece.attachment {
                    rendered.append((piece, image(attachment)))
                    continue
                }
                var text = render(piece, dropUnderline: false)
                if let previous = rendered.last, previous.piece.attachment == nil,
                   Renderer.endsWithMarkerTilde(previous.text), text.hasPrefix("~") {
                    // A touching `~` and `~~` would read as `~~~`: strike wins.
                    if previous.piece.style.strike, !piece.style.strike {
                        text = render(piece, dropUnderline: true)
                    } else if !previous.piece.style.strike, piece.style.strike {
                        rendered[rendered.count - 1].text = render(previous.piece, dropUnderline: true)
                    }
                }
                rendered.append((piece, text))
            }
            let line = rendered.map(\.text).joined().replacingOccurrences(of: "\u{00A0}", with: " ")
            return line.trimmingTrailingBlanks()
        }

        private func render(_ piece: Piece, dropUnderline: Bool) -> String {
            let style = piece.style
            var text: String
            if style.mono {
                text = Renderer.codeSpan(piece.text)
            } else {
                text = Renderer.escape(piece.text)
                if style.strike {
                    text = Renderer.wrap(text, "~~")
                } else if style.underline, !dropUnderline {
                    text = Renderer.wrap(text, "~")
                }
                if style.italic { text = Renderer.wrap(text, "*") }
                if style.bold { text = Renderer.wrap(text, "**") }
            }
            guard let link = style.link else { return text }
            let plain = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if plain == link { return text.replacingOccurrences(of: plain, with: link) }
            if link.lowercased().hasPrefix("mailto:"), plain == String(link.dropFirst(7)) { return text }
            guard !plain.isEmpty else { return text }
            let destination = link
                .replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            // Whitespace stays outside the brackets.
            let lead = String(text.prefix { $0 == " " || $0 == "\t" })
            let trail = String(text.reversed().prefix { $0 == " " || $0 == "\t" })
            let core = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return "\(lead)[\(core)](\(destination))\(trail)"
        }

        // MARK: Images

        private mutating func image(_ attachment: NSTextAttachment) -> String {
            guard let data = Self.imageData(of: attachment), let type = Self.imageType(of: data) else {
                skippedAttachments += 1
                return ""
            }
            let preferred = Self.preferredName(attachment.fileWrapper?.preferredFilename)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "/" + (preferred ?? "")
            if let existing = nameByDigest[digest] { return "![](\(AttachmentLinkRewriter.encode(existing)))" }
            let ext = type.preferredFilenameExtension ?? "png"
            var name = preferred ?? "image.\(ext)"
            if preferred != nil, (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
            let base = (name as NSString).deletingPathExtension
            let nameExt = (name as NSString).pathExtension
            var counter = 2
            while usedKeys.contains(AttachmentFiles.fileSystemKey(name)) {
                name = nameExt.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(nameExt)"
                counter += 1
            }
            usedKeys.insert(AttachmentFiles.fileSystemKey(name))
            nameByDigest[digest] = name
            images.append(ImportedAttachment(filename: name, data: data))
            return "![](\(AttachmentLinkRewriter.encode(name)))"
        }

        private static func preferredName(_ name: String?) -> String? {
            guard let name else { return nil }
            let last = (name as NSString).lastPathComponent
                .unicodeScalars.filter { !$0.properties.generalCategory.isControl }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
                .trimmingCharacters(in: .whitespaces)
            guard !last.isEmpty, !last.hasPrefix("."), (try? AttachmentFiles.validate(last)) != nil else { return nil }
            // AppKit's placeholder for an attachment that never had a name.
            if last.range(of: #"^Attachment( \d+)?(\.[A-Za-z0-9]+)?$"#, options: .regularExpression) != nil { return nil }
            return last
        }

        private static func imageData(of attachment: NSTextAttachment) -> Data? {
            if let data = attachment.fileWrapper?.regularFileContents, !data.isEmpty { return data }
            if let data = attachment.contents, !data.isEmpty { return data }
            if let tiff = attachment.image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                return rep.representation(using: .png, properties: [:])
            }
            return nil
        }

        private static func imageType(of data: Data) -> UTType? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let identifier = CGImageSourceGetType(source) as String? else { return nil }
            return UTType(identifier)
        }
    }
}

private extension String {
    func trimmingTrailingBlanks() -> String {
        var s = self
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return s
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool { self == .control }
}
#endif
