// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Where the export page loads attachment files from, by filename as written in the note.
public enum AttachmentSources: Sendable {
    /// `baerchen-asset://attachment/<enc(noteId)>/<enc(file)>`: the editor's own scheme (PDF, print, Copy As).
    case assetURLs
    /// `<enc(folder)>/<enc(file)>`: the folder next to a Markdown or HTML export.
    case relative(folder: String)
    /// `data:<mime>;base64,…` for raster images the page accepts inline (PNG, JPEG, GIF, WebP,
    /// HEIC); every other file, images of other types included, is relative to `folder`.
    case inlineImages(folder: String)
    /// No sources: attachments render as placeholder cards (rich text).
    case none
}

/// Where a wiki link points in the rendered note.
public enum WikiLinkTargets: Sendable {
    /// Wiki links render as plain text.
    case none
    /// Only links to the note itself become links (`#h-<n>`).
    case sameNote
    /// A note id → the relative href of its export from this item; other notes stay plain text.
    case exported([String: String])
}

/// Builds the `RenderRequest` for one note: the text (tags removed on request), the attachment
/// sources and sizes, and one `href` per wiki link occurrence (M8 Task 10). Theme variables and
/// fonts go through the same sanitisers as `setSettings`.
public struct RenderRequestBuilder: Sendable {
    private let store: NoteStore
    private let paths: AppPaths

    public init(store: NoteStore, paths: AppPaths) {
        self.store = store
        self.paths = paths
    }

    /// Throws `ExportError.noteLocked` for a locked note, before anything is read.
    public func request(
        for note: Note, mode: RenderMode, theme: [String: String], appearance: EditorAppearance,
        typography: EditorTypography, attachments: AttachmentSources, wikiLinks: WikiLinkTargets, keepTags: Bool
    ) throws -> RenderRequest {
        guard !note.isLocked else { throw ExportError.noteLocked(id: note.id) }
        let text = keepTags ? note.text : ExportText.removingTags(note.text)
        let metadata = NoteParser.metadata(for: text)
        let files = try attachmentFiles(of: note, referenced: metadata.attachments.map(\.filename))
        return RenderRequest(
            noteId: note.id, title: note.title, text: text, mode: mode,
            theme: ThemeSchema.sanitize(variables: theme), appearance: appearance,
            typography: typography.withoutInvalidFonts,
            attachmentSources: sources(of: files, noteId: note.id, attachments),
            attachmentSizes: files.compactMap { file in file.size.map { (file.name, $0) } }
                .reduce(into: [:]) { $0[$1.0] = $1.1 },
            wikiLinks: try self.wikiLinks(of: metadata.wikiLinks, in: note, wikiLinks))
    }

    // MARK: - Wiki links

    /// `href` per occurrence: the target's mapped href (`""` for the note itself) plus `#h-<ordinal + 1>`
    /// when the link names a heading. An occurrence with no target, or whose note is not mapped, has none.
    private func wikiLinks(of links: [WikiLinkRef], in note: Note, _ targets: WikiLinkTargets) throws -> [RenderWikiLink?] {
        if case .none = targets { return links.map { _ in nil } }
        return try links.map { link in
            guard let target = try store.resolveWikiLink(link, from: note.id) else { return nil }
            let base: String
            if target.noteId == note.id {
                base = ""
            } else if case .exported(let hrefs) = targets, let href = hrefs[target.noteId] {
                base = href
            } else {
                return nil
            }
            let href = base + (target.headingOrdinal.map { "#h-\($0 + 1)" } ?? "")
            return href.isEmpty ? nil : RenderWikiLink(href: href)
        }
    }

    // MARK: - Attachments

    /// A file the note links, with the bytes it has (the row's, else the file's).
    private struct LinkedFile {
        var name: String
        var url: URL?
        var size: Int?
    }

    /// Every distinct filename the text links that has a live attachment row, in text order. A
    /// name spelled two ways (case, NFD) is two entries that share one file.
    private func attachmentFiles(of note: Note, referenced: [String]) throws -> [LinkedFile] {
        guard !referenced.isEmpty else { return [] }
        let rows = try store.db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT filename, filenameKey, byteSize FROM attachment WHERE noteId = ? AND deletedAt IS NULL
                """, arguments: [note.id])
        }
        var byKey: [String: (filename: String, byteSize: Int?)] = [:]
        for row in rows { byKey[row["filenameKey"]] = (row["filename"], row["byteSize"]) }
        let attachmentStore = AttachmentStore(paths: paths, database: store.db)
        var seen = Set<String>()
        return referenced.compactMap { name in
            guard seen.insert(name).inserted, let row = byKey[AttachmentFiles.fileSystemKey(name)] else { return nil }
            let url = attachmentStore.url(for: row.filename, noteId: note.id) ?? attachmentStore.url(for: name, noteId: note.id)
            let onDisk = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            return LinkedFile(name: name, url: url, size: row.byteSize ?? onDisk)
        }
    }

    /// Raster types the page accepts as `data:` images (`attachmentSource` in render.ts).
    private static let inlineTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic",
    ]

    private func sources(of files: [LinkedFile], noteId: String, _ mode: AttachmentSources) -> [String: String] {
        var result: [String: String] = [:]
        for file in files {
            let name = AttachmentLinkRewriter.encode(file.name)
            switch mode {
            case .none:
                continue
            case .assetURLs:
                result[file.name] = "baerchen-asset://attachment/\(AttachmentLinkRewriter.encode(noteId))/\(name)"
            case .relative(let folder):
                result[file.name] = "\(AttachmentLinkRewriter.encode(folder))/\(name)"
            case .inlineImages(let folder):
                let ext = (file.name as NSString).pathExtension.lowercased()
                if let mime = Self.inlineTypes[ext] {
                    // A file that cannot be read has no source: the page shows a missing-file card.
                    guard let url = file.url, let data = try? Data(contentsOf: url) else { continue }
                    result[file.name] = "data:\(mime);base64,\(data.base64EncodedString())"
                } else {
                    result[file.name] = "\(AttachmentLinkRewriter.encode(folder))/\(name)"
                }
            }
        }
        return result
    }
}
