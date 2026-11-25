// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import UniformTypeIdentifiers

extension NoteExport {
    public enum BatchFormat: Sendable { case markdown, textBundle }

    /// A portable directory. Each note owns its assets, so equal attachment names never collide.
    /// A tag export places each note in its deepest direct tag below the requested root.
    public static func batch(notes: [Note], format: BatchFormat, tagRoot: String? = nil, fileExtension: String? = nil,
                             options: ExportOptions = ExportOptions(), attachmentURL: (String, String) throws -> URL?) throws -> FileWrapper {
        var paths: [String: String] = [:]
        return try batch(notes: notes, format: format, tagRoot: tagRoot, fileExtension: fileExtension, options: options, paths: &paths, attachmentURL: attachmentURL)
    }

    /// `options` (A9): `includeAttachments` off copies no file, makes no `.assets` folder and leaves the links as the
    /// note wrote them; `embedImages` (Markdown only) puts image files up to `embedLimit` bytes into the text as `data:` URIs.
    public static func batch(notes: [Note], format: BatchFormat, tagRoot: String? = nil, fileExtension: String? = nil,
                             options: ExportOptions = ExportOptions(), paths: inout [String: String],
                             attachmentURL: (String, String) throws -> URL?) throws -> FileWrapper {
        guard fileExtension == nil || ["md", "txt", "html", "pdf", "rtf"].contains(fileExtension!) else { throw CocoaError(.fileWriteInvalidFileName) }
        paths = [:]
        let root = FileWrapper(directoryWithFileWrappers: [:])
        var directories: [String: FileWrapper] = ["": root]
        var originalPaths: [String: String] = ["": ""]
        var totalBytes = 0
        for note in notes.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            guard !note.isLocked else { throw StoreError.noteLocked(id: note.id) }
            var parent = root, parentPath = "", originalParent = ""
            if let tagRoot {
                let key = CanonicalKey.make(tagRoot)
                let tag = NoteParser.metadata(for: note.text).tags.filter {
                    let candidate = CanonicalKey.make($0)
                    return candidate == key || candidate.hasPrefix(key + "/")
                }.sorted { $0.split(separator: "/").count == $1.split(separator: "/").count ? $0 < $1 : $0.split(separator: "/").count > $1.split(separator: "/").count }.first ?? tagRoot
                for component in tag.split(separator: "/").prefix(32) {
                    originalParent += "/" + String(component)
                    if let mapped = originalPaths[originalParent], let directory = directories[mapped] {
                        parent = directory; parentPath = mapped; continue
                    }
                    let name = unique(filename(title: String(component)), in: parent)
                    let directory = FileWrapper(directoryWithFileWrappers: [:]); directory.preferredFilename = name
                    parent.addFileWrapper(directory)
                    parentPath += "/" + name; parent = directory
                    originalPaths[originalParent] = parentPath; directories[parentPath] = directory
                }
            }
            let suffix = format == .markdown ? "." + (fileExtension ?? "md") : ".textbundle"
            // Reserve the note and its asset directory together before writing either.
            var stem = filename(title: note.title), number = 1
            while occupied(stem + suffix, in: parent) || (options.includeAttachments && occupied(stem + ".assets", in: parent)) {
                number += 1; stem = filename(title: note.title) + " (\(number))"
            }
            paths[note.id] = (parentPath.isEmpty ? "" : String(parentPath.dropFirst()) + "/") + stem + suffix
            var assetFiles: [String: FileWrapper] = [:]
            var embedded: [String: String] = [:]
            for occurrence in NoteParser.attachmentOccurrences(in: note.text) where options.includeAttachments && assetFiles[occurrence.filename] == nil {
                let name = occurrence.filename
                guard let url = try attachmentURL(note.id, name) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "An attachment is missing: " + name])
                }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                let remaining = 256 * 1024 * 1024 - totalBytes
                guard (values.fileSize ?? 0) <= remaining else { throw CocoaError(.fileReadTooLarge) }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= remaining else { throw CocoaError(.fileReadTooLarge) }
                if format == .markdown, options.embedImages, bytes.count <= embedLimit,
                   let type = UTType(filenameExtension: (name as NSString).pathExtension), embeddableMIMETypes[type] != nil {
                    embedded[AttachmentFiles.fileSystemKey(name)] = "data:\(embeddableMIMETypes[type]!);base64,\(bytes.base64EncodedString())"
                    assetFiles[name] = FileWrapper(regularFileWithContents: Data())  // marks the name as read; not written
                    continue
                }
                totalBytes += bytes.count
                assetFiles[name] = FileWrapper(regularFileWithContents: bytes)
            }
            if format == .textBundle {
                let formatter = ISO8601DateFormatter()
                let info: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown", "creatorIdentifier": "com.truebrewbirdie.baerchen",
                    "transient": false, "creationDate": formatter.string(from: note.createdAt), "modificationDate": formatter.string(from: note.modifiedAt)]
                var parts = [
                    "text.md": FileWrapper(regularFileWithContents: Data((options.includeAttachments ? textBundleSource(note.text) : note.text).utf8)),
                    "info.json": FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])),
                ]
                if options.includeAttachments { parts["assets"] = FileWrapper(directoryWithFileWrappers: assetFiles) }
                let portable = FileWrapper(directoryWithFileWrappers: parts)
                portable.preferredFilename = stem + suffix; parent.addFileWrapper(portable)
            }
            else {
                let source = options.includeAttachments ? batchMarkdownSource(note.text, assets: stem + ".assets/", embedded: embedded) : note.text
                assetFiles = assetFiles.filter { !embedded.keys.contains(AttachmentFiles.fileSystemKey($0.key)) }
                let document = FileWrapper(regularFileWithContents: Data(source.utf8)); document.preferredFilename = stem + suffix
                parent.addFileWrapper(document)
                if !assetFiles.isEmpty {
                    let copy = FileWrapper(directoryWithFileWrappers: assetFiles)
                    copy.preferredFilename = stem + ".assets"; parent.addFileWrapper(copy)
                }
            }
        }
        return root
    }

    /// Image types a Markdown reader shows from a `data:` URI (HEIC is left in the folder), and the largest file embedded.
    private static let embeddableMIMETypes: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg", .gif: "image/gif", .webP: "image/webp", .svg: "image/svg+xml"]
    private static let embedLimit = 10 * 1024 * 1024

    private static func batchMarkdownSource(_ source: String, assets: String, embedded: [String: String] = [:]) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        for occurrence in NoteParser.attachmentOccurrences(in: source).sorted(by: { ($0.line, $0.range.lowerBound) > ($1.line, $1.range.lowerBound) }) {
            let bom = occurrence.line == 0 && lines[0].first == "\u{FEFF}" ? 1 : 0
            let range = occurrence.range.lowerBound + bom..<occurrence.range.upperBound + bom
            let target = embedded[AttachmentFiles.fileSystemKey(occurrence.filename)]
                ?? AttachmentLinkRewriter.encode(String(assets.dropLast())) + "/" + AttachmentLinkRewriter.encode(occurrence.filename)
            lines[occurrence.line].replaceSubrange(range, with: target.unicodeScalars)
        }
        return lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n")
    }
    private static func occupied(_ name: String, in directory: FileWrapper) -> Bool {
        directory.fileWrappers?.keys.contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) } == true
    }
    private static func unique(_ base: String, in directory: FileWrapper) -> String {
        var result = base, number = 1
        while occupied(result, in: directory) { number += 1; result = base + " (\(number))" }
        return result
    }
}
