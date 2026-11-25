// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// How attachments are written in note text (spec D4, Bear's format): images `![](name.ext)`,
/// PDFs `[name.pdf](name.pdf)<!-- {"preview":"true","embed":"true"} -->`, other files
/// `[name.ext](name.ext)<!-- {"embed":"true"} -->`; the destination is the percent-encoded
/// filename, relative to the note. Metadata (`width`, `preview`, `embed`) sits in the trailing
/// comment, blanks allowed before it.
public enum AttachmentMarkdown {
    public static let imageExtensions = AttachmentLinkRewriter.imageExtensions

    public static func isImage(_ filename: String) -> Bool {
        imageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// Whether `text` still references the attachment file `name` (generously, see
    /// `AttachmentReferences`); the cleanup removes files for which this is false.
    public static func isReferenced(_ name: String, in text: String) -> Bool {
        AttachmentReferences(text: text).references(name)
    }

    /// The Markdown for a newly inserted attachment.
    public static func link(for filename: String) -> String {
        let destination = AttachmentLinkRewriter.encode(filename)
        if isImage(filename) { return "![](\(destination))" }
        let comment = (filename as NSString).pathExtension.lowercased() == "pdf"
            ? #"<!-- {"preview":"true","embed":"true"} -->"# : #"<!-- {"embed":"true"} -->"#
        return "[\(escapeTitle(filename))](\(destination))\(comment)"
    }

    /// One attachment's source text, split up.
    struct Parts {
        var bang: Bool
        var title: String
        var destination: String
        /// The blanks before the comment, and the JSON inside it (nil: no comment).
        var gap: String
        var json: String?

        /// The destination without `<…>` (CommonMark's angle-bracket form), percent-decoded.
        var filename: String {
            let bare = destination.hasPrefix("<") && destination.hasSuffix(">") ? String(destination.dropFirst().dropLast()) : destination
            return bare.removingPercentEncoding ?? bare
        }

        var text: String {
            "\(bang ? "!" : "")[\(title)](\(destination))" + (json.map { "\(gap)<!-- \($0) -->" } ?? "")
        }
    }

    private static let pattern = try! NSRegularExpression(
        // The same shape as attachments.ts `SOURCE`, `<…>` destinations included.
        pattern: #"^(!?)\[((?:\\.|[^\\\]])*)\]\(([^()\s<>]+|<[^<>\n]*>)\)(?:([ \t]*)<!--\s*(\{.*\})\s*-->)?$"#,
        options: [.dotMatchesLineSeparators])

    static func parts(_ source: String) -> Parts? {
        let ns = source as NSString
        guard let m = pattern.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        return Parts(bang: group(1) == "!", title: group(2) ?? "", destination: group(3) ?? "",
                     gap: group(4) ?? "", json: group(5))
    }

    /// The source pointing at `newName`: the destination always; the link text too when it was
    /// the old filename (a file card's title). Nil when `source` is not one attachment link.
    public static func renaming(_ source: String, to newName: String) -> String? {
        guard var parts = parts(source) else { return nil }
        if !parts.bang, unescapeTitle(parts.title) == parts.filename { parts.title = escapeTitle(newName) }
        parts.destination = AttachmentLinkRewriter.encode(newName)
        return parts.text
    }

    /// Pasted `text` with the attachment links at `items` (UTF-16 ranges) pointing at their new
    /// names (`renamed[old] = new`); ranges that are out of bounds or not one link stay as they are.
    public static func rewriting(_ text: String, items: [PastedAttachment], renamed: [String: String]) -> String {
        let utf16 = Array(text.utf16)
        var out = utf16
        for item in items.sorted(by: { $0.from > $1.from }) {
            guard let new = renamed[item.filename], new != item.filename, item.from <= item.to, item.to <= utf16.count,
                  let slice = String(utf16CodeUnits: Array(utf16[item.from..<item.to]), count: item.to - item.from) as String?,
                  parts(slice)?.filename == item.filename, let link = renaming(slice, to: new) else { continue }
            out.replaceSubrange(item.from..<item.to, with: Array(link.utf16))
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The trailing comment's metadata (values as strings).
    public static func metadata(_ source: String) -> [String: String] {
        Dictionary(orderedMetadata(parts(source)?.json), uniquingKeysWith: { _, last in last })
    }

    /// Sets (`value`) or removes (`nil`) one metadata key, keeping the other keys and their order;
    /// a comment is added when there is none. Nil when `source` is not one attachment link.
    public static func settingMetadata(_ source: String, _ key: String, _ value: String?) -> String? {
        guard var parts = parts(source) else { return nil }
        var pairs = orderedMetadata(parts.json)
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            if let value { pairs[index].1 = value } else { pairs.remove(at: index) }
        } else if let value {
            pairs.append((key, value))
        }
        parts.json = pairs.isEmpty ? nil : "{" + pairs.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",") + "}"
        return parts.text
    }

    /// Key/value pairs in source order (non-string values stringified).
    private static func orderedMetadata(_ json: String?) -> [(String, String)] {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        let keyPattern = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"\s*:"#)
        let ns = json as NSString
        var keys: [String] = []
        for m in keyPattern.matches(in: json, range: NSRange(location: 0, length: ns.length)) {
            let quoted = "\"" + ns.substring(with: m.range(at: 1)) + "\""
            if let key = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)), object[key] != nil, !keys.contains(key) {
                keys.append(key)
            }
        }
        for key in object.keys.sorted() where !keys.contains(key) { keys.append(key) }
        return keys.map { key in (key, object[key].map { $0 as? String ?? "\($0)" } ?? "") }
    }

    private static func jsonString(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    static func escapeTitle(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func unescapeTitle(_ text: String) -> String {
        var out = "", escaped = false
        for c in text {
            if escaped || c != "\\" {
                out.append(c)
                escaped = false
            } else {
                escaped = true
            }
        }
        return out
    }
}

/// Whether note text still references an attachment file. Deliberately generous: a file is kept
/// when the parser finds it as an attachment, or when its name (as is or percent-encoded) appears
/// anywhere in the text, case-insensitively. Keeping a file too long costs disk; removing one too
/// early loses it.
struct AttachmentReferences {
    private let keys: Set<String>
    private let lowered: String

    init(text: String) {
        keys = Set(NoteParser.metadata(for: text).attachments.map { AttachmentFiles.fileSystemKey($0.filename) })
        lowered = text.precomposedStringWithCanonicalMapping.lowercased()
    }

    func references(_ name: String) -> Bool {
        if keys.contains(AttachmentFiles.fileSystemKey(name)) { return true }
        let forms = [name, AttachmentLinkRewriter.encode(name), name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name]
        return forms.contains { lowered.contains($0.precomposedStringWithCanonicalMapping.lowercased()) }
    }
}
