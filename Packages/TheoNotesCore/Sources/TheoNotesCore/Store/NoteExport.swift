// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Portable exports use the same attachment parser as indexing, leaving code and prose untouched.
public enum NoteExport {
    public static func textBundle(note: Note, attachments: AttachmentStore) throws -> FileWrapper {
        try textBundle(note: note, attachmentURL: { attachments.url(for: $0, noteId: note.id) })
    }

    /// `includeAttachments` off (A9): no `assets` folder, and the links stay as the note wrote them.
    public static func textBundle(note: Note, includeAttachments: Bool = true, attachmentURL: (String) throws -> URL?) throws -> FileWrapper {
        guard !note.isLocked else { throw StoreError.noteLocked(id: note.id) }
        let occurrences = includeAttachments ? NoteParser.attachmentOccurrences(in: note.text) : []
        var assets: [String: FileWrapper] = [:]
        for occurrence in occurrences where assets[occurrence.filename] == nil {
            guard let url = try attachmentURL(occurrence.filename) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "An attachment is missing: \(occurrence.filename)"])
            }
            assets[occurrence.filename] = try FileWrapper(url: url, options: .immediate)
        }
        let text = includeAttachments ? textBundleSource(note.text) : note.text
        let formatter = ISO8601DateFormatter()
        let info: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown", "creatorIdentifier": "com.truebrewbirdie.baerchen",
            "transient": false, "creationDate": formatter.string(from: note.createdAt), "modificationDate": formatter.string(from: note.modifiedAt)]
        var parts = [
            "text.md": FileWrapper(regularFileWithContents: Data(text.utf8)),
            "info.json": FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])),
        ]
        if includeAttachments { parts["assets"] = FileWrapper(directoryWithFileWrappers: assets) }
        return FileWrapper(directoryWithFileWrappers: parts)
    }

    static func textBundleSource(_ source: String) -> String {
        let occurrences = NoteParser.attachmentOccurrences(in: source)
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        for occurrence in occurrences.sorted(by: { ($0.line, $0.range.lowerBound) > ($1.line, $1.range.lowerBound) }) {
            let bom = occurrence.line == 0 && lines[0].first == "\u{FEFF}" ? 1 : 0
            let range = occurrence.range.lowerBound + bom..<occurrence.range.upperBound + bom
            let target = "assets/" + AttachmentLinkRewriter.encode(occurrence.filename)
            lines[occurrence.line].replaceSubrange(range, with: target.unicodeScalars)
        }
        return lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n")
    }

    public static func filename(title: String) -> String {
        let safe = title.unicodeScalars.map { "/:\\".unicodeScalars.contains($0) || $0.value < 32 ? "-" : String($0) }.joined()
        let trimmed = String(safe.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
