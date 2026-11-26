// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import GRDB
import UniformTypeIdentifiers

public enum FileExportFormat: String, Sendable, CaseIterable {
    case markdown, textBundle, plainText
}

public struct ExportOptions: Sendable, Equatable {
    /// Off drops every tag from the exported text.
    public var keepTags: Bool
    /// Off leaves attachments out of a Markdown or TextBundle export: no file is copied and the
    /// links stay as the note wrote them (A9).
    public var includeAttachments: Bool
    /// Markdown only: image attachments go into the file as `data:` URIs instead of the folder
    /// next to it. Other files still go to the folder. No effect while `includeAttachments` is off.
    public var embedImages: Bool

    public init(keepTags: Bool = true, includeAttachments: Bool = true, embedImages: Bool = false) {
        self.keepTags = keepTags
        self.includeAttachments = includeAttachments
        self.embedImages = embedImages
    }
}

public struct ExportedFiles: Sendable, Equatable {
    /// `<stem>.md`, `<stem>.textbundle` or `<stem>.txt`.
    public var primary: URL
    /// `<stem>/` next to a Markdown file, `assets/` inside a TextBundle; nil when no file was copied.
    public var attachmentsFolder: URL?
    /// `"<noteId>/<filename>"` of each linked attachment whose file could not be copied.
    public var missingAttachments: [String]

    public init(primary: URL, attachmentsFolder: URL? = nil, missingAttachments: [String] = []) {
        self.primary = primary
        self.attachmentsFolder = attachmentsFolder
        self.missingAttachments = missingAttachments
    }
}

public enum ExportError: Error, Equatable, CustomStringConvertible {
    /// Locked notes are never exported (their text is encrypted).
    case noteLocked(id: String)
    /// A file or folder of that name is already there; nothing is overwritten.
    case destinationExists(String)
    /// A plan component that would leave the chosen folder (empty, `.`, `..`, contains `/`).
    case unsafeName(String)
    /// A folder component below the chosen folder exists but is a symbolic link or a file, so
    /// writing through it could land outside the chosen folder.
    case notAPlainFolder(String)

    public var description: String {
        switch self {
        case .noteLocked(let id): "note \(id) is locked and cannot be exported"
        case .destinationExists(let name): "'\(name)' already exists"
        case .unsafeName(let name): "'\(name)' is not a usable file name"
        case .notAPlainFolder(let name): "'\(name)' is not a plain folder (a link or a file), so nothing is written through it"
        }
    }
}

/// Writes one planned note (`ExportPlan`) as Markdown, TextBundle or plain text.
/// Never writes outside `destination`; never overwrites. Everything is built in a hidden
/// `.partial` folder next to the result and renamed into place, so a failing note leaves nothing.
public struct NoteExporter: Sendable {
    public static let creatorIdentifier = "com.truebrewbirdie.baerchen"

    private let store: NoteStore
    private let paths: AppPaths

    public init(store: NoteStore, paths: AppPaths) {
        self.store = store
        self.paths = paths
    }

    public func write(
        _ item: ExportItem, format: FileExportFormat, under destination: URL, options: ExportOptions
    ) throws -> ExportedFiles {
        let (note, tagPins) = try snapshot(of: item.noteId)
        if note.isLocked { throw ExportError.noteLocked(id: note.id) }
        for name in item.folder + [item.stem] {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.unicodeScalars.contains("\u{0}")
            else { throw ExportError.unsafeName(name) }
        }

        let fm = FileManager.default
        let folder = item.folder.reduce(destination) { $0.appendingPathComponent($1, isDirectory: true) }
        let stem = item.stem
        let primaryName: String
        switch format {
        case .markdown: primaryName = stem + ".md"
        case .textBundle: primaryName = stem + ".textbundle"
        case .plainText: primaryName = stem + ".txt"
        }
        let primary = folder.appendingPathComponent(primaryName, isDirectory: format == .textBundle)
        let siblingFolder = folder.appendingPathComponent(stem, isDirectory: true)

        // Walk the existing folder components with lstat: a link or a file in the way is refused
        // (the chosen destination itself may be a link), and so is any existing name we would
        // create, a dangling link included.
        if Self.kind(at: destination) == nil {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        var walked = destination
        for name in item.folder {
            walked = walked.appendingPathComponent(name, isDirectory: true)
            switch Self.kind(at: walked) {
            case .directory: continue
            case nil: try fm.createDirectory(at: walked, withIntermediateDirectories: false)
            case .link?, .other?: throw ExportError.notAPlainFolder(name)
            }
        }
        for taken in [primary] + (format == .markdown && options.includeAttachments ? [siblingFolder] : []) where Self.kind(at: taken) != nil {
            throw ExportError.destinationExists(taken.lastPathComponent)
        }

        var text = note.text
        if !options.keepTags { text = ExportText.removingTags(text) }

        let stage = folder.appendingPathComponent(".baerchen-export-\(UUID().uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }

        var missing: [String] = []
        var copiedFolder: URL?
        var staged: [(from: URL, to: URL)] = []
        switch format {
        case .plainText:
            let file = stage.appendingPathComponent(primaryName)
            try Data(PlainTextExport.text(text).utf8).write(to: file)
            staged = [(file, primary)]
        case .markdown:
            let file = stage.appendingPathComponent(primaryName)
            let assets = stage.appendingPathComponent(stem, isDirectory: true)
            let prefix = options.includeAttachments ? AttachmentLinkRewriter.encode(stem) + "/" : ""
            let embedded = options.includeAttachments && options.embedImages
                ? dataURIs(of: note, from: note.text) : [:]
            try Data(ExportText.prefixingAttachmentLinks(text, with: prefix, replacing: embedded).utf8).write(to: file)
            let copied = options.includeAttachments
                ? try copyAttachments(of: note, from: note.text, into: assets, skipping: Set(embedded.keys), missing: &missing)
                : false
            staged = [(file, primary)] + (copied ? [(assets, siblingFolder)] : [])
            if copied { copiedFolder = siblingFolder }
        case .textBundle:
            let bundle = stage.appendingPathComponent(primaryName, isDirectory: true)
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            let assets = bundle.appendingPathComponent("assets", isDirectory: true)
            try Data(ExportText.prefixingAttachmentLinks(text, with: options.includeAttachments ? "assets/" : "").utf8)
                .write(to: bundle.appendingPathComponent("text.md"))
            let copied = options.includeAttachments
                ? try copyAttachments(of: note, from: note.text, into: assets, missing: &missing) : false
            try Self.infoJSON(for: note, tagPins: tagPins).write(to: bundle.appendingPathComponent("info.json"))
            staged = [(bundle, primary)]
            if copied { copiedFolder = primary.appendingPathComponent("assets", isDirectory: true) }
        }

        for entry in staged { try Self.applyDates(of: note, to: entry.from) }
        var placed: [URL] = []
        do {
            for entry in staged {
                try fm.moveItem(at: entry.from, to: entry.to)
                placed.append(entry.to)
            }
        } catch {
            for url in placed { try? fm.removeItem(at: url) }
            throw error
        }
        return ExportedFiles(primary: primary, attachmentsFolder: copiedFolder, missingAttachments: missing)
    }

    /// Sets the note's `createdAt` / `modifiedAt` as creation and modification date of `url`
    /// and, for a folder, of everything inside it (children first, so a folder's own date is set
    /// last; symbolic links are not followed).
    public static func applyDates(of note: Note, to url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if !isLink, fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try applyDates(of: note, to: child)
            }
        }
        var values = URLResourceValues()
        values.creationDate = note.createdAt
        values.contentModificationDate = note.modifiedAt
        var target = url
        try target.setResourceValues(values)
    }

    // MARK: - Links and folders

    enum EntryKind { case directory, link, other }

    /// What `url` is, without following a final symbolic link (`lstat`); nil when nothing is there.
    static func kind(at url: URL) -> EntryKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .link
        default: return .other
        }
    }

    // MARK: - Reading

    private func snapshot(of id: String) throws -> (Note, [String]) {
        try store.db.pool.read { db in
            guard let note = try Note.fetchOne(db, sql: "SELECT * FROM note WHERE id = ? AND deletedAt IS NULL", arguments: [id])
            else { throw StoreError.noteNotFound(id: id) }
            let pins = try String.fetchAll(db, sql: """
                SELECT t.displayPath FROM note_pin p JOIN tag t ON t.id = p.tagId
                WHERE p.noteId = ? ORDER BY t.pathKey
                """, arguments: [id])
            return (note, pins)
        }
    }

    // MARK: - Attachments

    /// Copies the files the text links (once per `fileSystemKey`) into `folder`, which is created
    /// only when the first file is copied. A file that is missing or not a plain file with a
    /// plain name is reported in `missing`. Returns whether anything was copied.
    private func copyAttachments(
        of note: Note, from text: String, into folder: URL, skipping skipped: Set<String> = [], missing: inout [String]
    ) throws -> Bool {
        let fm = FileManager.default
        var seen = Set<String>()
        var copied = false
        let source = paths.attachments.appendingPathComponent(note.id, isDirectory: true)
        for attachment in NoteParser.metadata(for: text).attachments {
            let name = attachment.filename
            let key = AttachmentFiles.fileSystemKey(name)
            guard !skipped.contains(key), seen.insert(key).inserted else { continue }
            let from = URL(fileURLWithPath: source.path + "/" + name)
            guard (try? AttachmentFiles.validate(name)) != nil,
                  let values = try? from.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else {
                missing.append("\(note.id)/\(name)")
                continue
            }
            if !copied {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                copied = true
            }
            try fm.copyItem(at: from, to: URL(fileURLWithPath: folder.path + "/" + name))
        }
        return copied
    }

    /// `data:` URIs of the linked image files, keyed by `fileSystemKey`. An image that cannot be
    /// read is left to the normal link rewrite and `copyAttachments` reports it.
    private func dataURIs(of note: Note, from text: String) -> [String: String] {
        var result: [String: String] = [:]
        var seen = Set<String>()
        let source = paths.attachments.appendingPathComponent(note.id, isDirectory: true)
        for attachment in NoteParser.metadata(for: text).attachments {
            let name = attachment.filename
            let key = AttachmentFiles.fileSystemKey(name)
            guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image),
                  let mime = type.preferredMIMEType, seen.insert(key).inserted
            else { continue }
            let from = URL(fileURLWithPath: source.path + "/" + name)
            guard (try? AttachmentFiles.validate(name)) != nil,
                  let values = try? from.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let data = try? Data(contentsOf: from)
            else { continue }  // `copyAttachments` reports it
            result[key] = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return result
    }

    // MARK: - info.json

    static func infoJSON(for note: Note, tagPins: [String]) throws -> Data {
        let ours: [String: Any] = [
            "id": note.id,
            "creationDate": iso8601(note.createdAt),
            "modificationDate": iso8601(note.modifiedAt),
            "pinned": note.isPinnedGlobal,
            "archived": note.location == .archive,
            "trashed": note.location == .trash,
            "readOnly": note.isReadOnly,
            "tagPins": tagPins,
        ]
        let info: [String: Any] = [
            "version": 2,
            "type": "net.daringfireball.markdown",
            "creatorIdentifier": creatorIdentifier,
            "transient": false,
            creatorIdentifier: ours,
        ]
        return try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// ISO-8601 UTC with milliseconds, rounded (not truncated) to the millisecond.
    static func iso8601(_ date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Date(timeIntervalSince1970: TimeInterval(millis.floorDiv(1000)))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: seconds)
        let fraction = String(format: "%03d", Int(millis - millis.floorDiv(1000) * 1000))
        return String(whole.dropLast()) + "." + fraction + "Z"
    }
}

private extension Int64 {
    func floorDiv(_ divisor: Int64) -> Int64 {
        let q = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? q - 1 : q
    }
}
