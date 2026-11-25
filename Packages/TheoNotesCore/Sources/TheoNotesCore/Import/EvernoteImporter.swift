// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import UniformTypeIdentifiers
import os

private let evernoteLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "import")

/// Size caps of an ENEX import (IMP-R1). Tests shrink them.
struct ENEXLimits: Equatable, Sendable {
    /// One decoded resource.
    var resource = 128 << 20
    /// All decoded resources of one run.
    var run = 2 << 30
    /// One note's ENML.
    var content = 64 << 20

    static let standard = ENEXLimits()
}

/// Why a resource's bytes were not kept.
enum ENEXSkip: Equatable, Sendable {
    case tooLarge
    case overBudget
    case undecodable
}

struct ENEXResource: Sendable {
    var mime = ""
    var fileName: String?
    /// Decoded bytes; `nil` when `skip` says why.
    var data: Data?
    var skip: ENEXSkip?
}

/// One `<note>` as read from the file: raw strings only, nothing interpreted yet.
struct ENEXNote: Sendable {
    var title = ""
    /// The ENML document (UTF-8 bytes of the CDATA section).
    var content = Data()
    var contentTooLarge = false
    var created = ""
    var updated = ""
    var tags: [String] = []
    var sourceURL = ""
    var resources: [ENEXResource] = []
}

/// Streaming reader: `XMLParser` over an `InputStream` hands over each finished note and forgets
/// it, so at most one note (with its decoded resources) is in memory. External entities and DTDs
/// are never fetched.
final class ENEXReader: NSObject, XMLParserDelegate {
    private static let leafKeys: Set<String> = [
        "en-export/note/title", "en-export/note/content", "en-export/note/created", "en-export/note/updated",
        "en-export/note/tag", "en-export/note/note-attributes/source-url",
        "en-export/note/resource/data", "en-export/note/resource/mime",
        "en-export/note/resource/resource-attributes/file-name",
    ]
    /// Titles, dates, tags and names are short; anything longer is cut.
    private static let maxLeafCharacters = 1 << 16

    /// Deeper elements are refused; ENEX nests five levels at most (recognition data included).
    static let maxDepth = 64

    private let limits: ENEXLimits
    private let decoder: @Sendable (String) -> Data?
    private let onNote: (ENEXNote) -> Bool
    private var path: [String] = []
    private var note: ENEXNote?
    private var resource: ENEXResource?
    private var leaf: String?
    private var text = ""
    private var bytes = Data()
    private var dropping = false
    private var sawRoot = false

    /// Total decoded resource bytes so far.
    private(set) var decodedTotal = 0
    /// `onNote` returned false.
    private(set) var stoppedByHandler = false
    private(set) var notEnex = false
    private(set) var tooDeep = false
    private(set) var failure: (line: Int, code: Int)?

    init(
        limits: ENEXLimits, decoder: @escaping @Sendable (String) -> Data? = ENEXReader.decodeBase64,
        onNote: @escaping (ENEXNote) -> Bool
    ) {
        self.limits = limits
        self.decoder = decoder
        self.onNote = onNote
    }

    /// Parses the stream to the end, or until `onNote` says stop.
    func read(_ stream: InputStream) {
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        _ = parser.parse()
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard !tooDeep else { return }
        if path.count >= Self.maxDepth {
            tooDeep = true
            parser.abortParsing()
            return
        }
        path.append(name)
        if path.count == 1 {
            sawRoot = true
            if name != "en-export" {
                notEnex = true
                parser.abortParsing()
            }
            return
        }
        guard path.count <= 5 else { return }
        if path.count == 2, name == "note" {
            note = ENEXNote()
        } else if path.count == 3, name == "resource", note != nil {
            resource = ENEXResource()
        }
        let key = path.joined(separator: "/")
        guard note != nil, Self.leafKeys.contains(key) else { return }
        leaf = key
        text = ""
        bytes = Data()
        dropping = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let leaf, !dropping, !tooDeep else { return }
        append(Data(string.utf8), as: string, leaf: leaf)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let leaf, !dropping else { return }
        append(CDATABlock, as: nil, leaf: leaf)
    }

    private func append(_ data: Data, as string: String?, leaf: String) {
        if leaf.hasSuffix("/content") {
            bytes.append(data)
            if bytes.count > limits.content {
                dropping = true
                bytes = Data()
                note?.contentTooLarge = true
            }
        } else if leaf.hasSuffix("/data") {
            text += string ?? String(decoding: data, as: UTF8.self)
            // Base64 is 4 characters per 3 bytes; twice that (line breaks, indentation) is kept at most.
            let remaining = limits.run - decodedTotal
            let allowed = max(0, min(limits.resource, remaining))
            if text.utf8.count > (allowed / 3 + 1) * 8 + 1024 {
                dropping = true
                text = ""
                resource?.skip = remaining < limits.resource ? .overBudget : .tooLarge
            }
        } else if text.utf8.count < Self.maxLeafCharacters {
            text += string ?? String(decoding: data, as: UTF8.self)
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
    ) {
        guard !tooDeep, !path.isEmpty else { return }
        defer { path.removeLast() }
        if path.count <= 5 {
            if let leaf, leaf == path.joined(separator: "/") {
                finishLeaf(leaf)
                self.leaf = nil
                text = ""
                bytes = Data()
            }
            if path.count == 3, name == "resource", let finished = resource {
                note?.resources.append(finished)
                resource = nil
            }
            if path.count == 2, name == "note", let finished = note {
                note = nil
                if !onNote(finished) {
                    stoppedByHandler = true
                    parser.abortParsing()
                }
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        if stoppedByHandler || notEnex || tooDeep { return }
        failure = (parser.lineNumber, (parseError as NSError).code)
    }

    // MARK: - Leaves

    private func finishLeaf(_ key: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "en-export/note/title": note?.title = value
        case "en-export/note/content": if !dropping { note?.content = bytes }
        case "en-export/note/created": note?.created = value
        case "en-export/note/updated": note?.updated = value
        case "en-export/note/tag": if !value.isEmpty { note?.tags.append(value) }
        case "en-export/note/note-attributes/source-url": note?.sourceURL = value
        case "en-export/note/resource/mime": resource?.mime = value
        case "en-export/note/resource/resource-attributes/file-name": resource?.fileName = value
        case "en-export/note/resource/data": finishData()
        default: break
        }
    }

    private func finishData() {
        guard resource?.skip == nil else { return }
        // Judged from the text, before anything is decoded.
        let estimate = Self.estimatedDecodedSize(text)
        if estimate > limits.resource {
            resource?.skip = .tooLarge
            return
        }
        if decodedTotal + estimate > limits.run {
            resource?.skip = .overBudget
            return
        }
        guard let decoded = decoder(text) else {
            resource?.skip = .undecodable
            return
        }
        // The estimate counts symbols, so the real size can only be smaller; keep the check honest anyway.
        guard decoded.count <= limits.resource, decodedTotal + decoded.count <= limits.run else {
            resource?.skip = decoded.count > limits.resource ? .tooLarge : .overBudget
            return
        }
        decodedTotal += decoded.count
        resource?.data = decoded
    }

    @Sendable static func decodeBase64(_ text: String) -> Data? {
        Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    /// Bytes the Base64 text decodes to: three per four symbols (padding and line breaks do not count).
    static func estimatedDecodedSize(_ text: String) -> Int {
        var symbols = 0
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F: symbols += 1
            default: break
            }
        }
        return symbols * 3 / 4
    }
}

/// Imports Evernote `.enex` exports: one note per `<note>`, with tags, dates, to-do items,
/// images and attachments. The file is read as a stream (IMP-R1); each note with its attachments
/// is one `NoteStore.importNote` transaction; a failing note goes to the report and never stops
/// the run. Reports carry note numbers, counts and kinds, never titles or text.
public final class EvernoteImporter: Sendable {
    private let store: NoteStore
    private let paths: AppPaths
    private let now: @Sendable () -> Date
    private let limits: ENEXLimits
    private let decoder: @Sendable (String) -> Data?

    public init(store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.paths = paths
        self.now = now
        self.limits = .standard
        self.decoder = ENEXReader.decodeBase64
    }

    init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date = { Date() }, limits: ENEXLimits,
        decoder: @escaping @Sendable (String) -> Data? = ENEXReader.decodeBase64
    ) {
        self.store = store
        self.paths = paths
        self.now = now
        self.limits = limits
        self.decoder = decoder
    }

    static let notFoundPlaceholder = "[Evernote attachment not imported]"
    static let encryptedPlaceholder = "[Encrypted Evernote text not imported]"
    private static let imageLimits = HTMLToMarkdown.ImageLimits(each: 32 << 20, total: 128 << 20)

    /// Throws only when the library's working directories cannot be created. `progress(done,
    /// total)` is called before the first note and after each one.
    public func importFile(
        _ url: URL, options: FileImportOptions = FileImportOptions(),
        progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try paths.createDirectories()
        let label = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let stream = InputStream(url: url)
        else {
            return FileImportReport(errors: ["\(label): not found"])
        }
        let notebook = url.deletingPathExtension().lastPathComponent
        return importStream(
            stream, notebook: notebook, label: label, total: Self.countNotes(in: url), options: options,
            progress: progress, isCancelled: isCancelled)
    }

    // MARK: - Run

    func importStream(
        _ stream: InputStream, notebook: String, label: String, total: Int, options: FileImportOptions,
        progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) -> FileImportReport {
        var report = FileImportReport()
        var notebookTag: String?
        if !notebook.isEmpty {
            notebookTag = AppleNotesImporter.tag(["evernote", notebook])
            if notebookTag == nil { report.warnings.append("\(label): the notebook name cannot become a tag, left out") }
        }
        var done = 0
        progress(0, total)
        withoutActuallyEscaping(progress) { progress in
            withoutActuallyEscaping(isCancelled) { isCancelled in
                let reader = ENEXReader(limits: limits, decoder: decoder) { enote in
                    if isCancelled() {
                        report.wasCancelled = true
                        return false
                    }
                    done += 1
                    self.process(
                        enote, number: done, notebookTag: notebookTag, label: label, options: options, report: &report)
                    progress(done, max(total, done))
                    return true
                }
                reader.read(stream)
                if reader.tooDeep {
                    report.errors.append(
                        "\(label): the file is nested too deeply (over \(ENEXReader.maxDepth) levels), reading stopped")
                } else if reader.notEnex {
                    report.errors.append("\(label): not an Evernote export (ENEX) file")
                } else if let failure = reader.failure {
                    report.errors.append(
                        "\(label): the file is not valid XML (line \(failure.line), code \(failure.code)); "
                            + "notes before that point were imported")
                }
            }
        }
        evernoteLogger.info("""
            evernote import: created \(report.created), skipped \(report.skipped), \
            attachments \(report.attachmentsCopied), warnings \(report.warnings.count), errors \(report.errors.count)
            """)
        return report
    }

    /// `<note>` occurrences, counted by scanning the bytes in chunks (used for progress only).
    static func countNotes(in url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let needle = Data("<note>".utf8)
        var count = 0
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            let window = carry + chunk
            var searchFrom = window.startIndex
            while let found = window.range(of: needle, in: searchFrom..<window.endIndex) {
                count += 1
                searchFrom = found.upperBound
            }
            carry = Data(window.suffix(needle.count - 1))
        }
        return count
    }

    // MARK: - One note

    private func process(
        _ enote: ENEXNote, number: Int, notebookTag: String?, label: String, options: FileImportOptions,
        report: inout FileImportReport
    ) {
        let noteLabel = "\(label): note \(number)"
        if enote.contentTooLarge {
            report.errors.append("\(noteLabel): the note body is too large (over \(limits.content >> 20) MB)")
            return
        }
        var warnings: [String] = []
        // Evernote's own elements become plain-text tokens the converter leaves alone (one linear scan).
        let prepared = ENMLPreprocessor.prepare(enote.content)
        let enml = prepared.html
        let mediaRefs = prepared.mediaHashes
        let encryptedSections = prepared.encryptedSections

        let converted = HTMLToMarkdown.convert(
            enml, imageLimits: Self.imageLimits, makesTitle: false, keepsRelativeImages: true)
        warnings += converted.warnings.map { "\(noteLabel): \($0)" }
        if converted.oversizedImages > 0 { warnings.append("\(noteLabel): \(converted.oversizedImages) embedded image(s) too large, left out") }

        // Resources: named and stored, matched to en-media by the MD5 of their bytes.
        var attachments = converted.images
        var used = Set(attachments.map { AttachmentFiles.fileSystemKey($0.filename) })
        var byHash: [String: StoredResource] = [:]
        var order: [String] = []
        for resource in enote.resources {
            guard let data = resource.data else {
                warnings.append("\(noteLabel): an attachment was not imported (\(Self.describe(resource.skip)))")
                continue
            }
            let hash = Self.md5Hex(data)
            if byHash[hash] != nil { continue }
            let wanted = Self.attachmentName(fileName: resource.fileName, mime: resource.mime, hash: hash)
            var name = wanted
            for candidate in AttachmentFiles.uniqueCandidates(wanted) where !used.contains(AttachmentFiles.fileSystemKey(candidate)) {
                name = candidate
                break
            }
            used.insert(AttachmentFiles.fileSystemKey(name))
            let isImage = resource.mime.lowercased().hasPrefix("image/")
                && AttachmentLinkRewriter.imageExtensions.contains((name as NSString).pathExtension.lowercased())
            byHash[hash] = StoredResource(name: name, isImage: isImage)
            order.append(hash)
            attachments.append(ImportedAttachment(filename: name, data: data))
        }

        var body = Self.expandingTodos(converted.markdown)
        var referenced = Set<String>()
        var missing = 0
        body = Self.replacing(Self.mediaTokenPattern, in: body) { match, source in
            let index = Int((source as NSString).substring(with: match.range(at: 1))) ?? -1
            guard mediaRefs.indices.contains(index), let stored = byHash[mediaRefs[index]] else {
                missing += 1
                return Self.notFoundPlaceholder
            }
            referenced.insert(mediaRefs[index])
            return stored.markdown
        }
        body = body.replacingOccurrences(of: Self.cryptToken, with: Self.encryptedPlaceholder)
        if missing > 0 { warnings.append("\(noteLabel): \(missing) attachment(s) are not in the export, marked in the text") }
        if encryptedSections > 0 { warnings.append("\(noteLabel): \(encryptedSections) encrypted section(s) not imported") }
        let loose = order.filter { !referenced.contains($0) }
        if !loose.isEmpty {
            body += (body.isEmpty ? "" : "\n\n") + loose.compactMap { byHash[$0]?.markdown }.joined(separator: "\n")
        }

        // Title, source, tags.
        let title = enote.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var text = body
        if !title.isEmpty { text = body.isEmpty ? "# \(title)" : FileImporter.insertingTitle(title, into: body) }
        let sourceURL = enote.sourceURL.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !sourceURL.isEmpty { text += (text.isEmpty ? "" : "\n\n") + "Source: \(sourceURL)" }
        // A note that is only tags (or nothing) carries no content worth a note.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.skipped += 1
            report.warnings.append("\(noteLabel): empty, skipped")
            return
        }

        var tokens: [String] = []
        var seen = Set<String>()
        var rejectedTags = 0
        for name in enote.tags {
            guard let token = AppleNotesImporter.tag([name]) else {
                rejectedTags += 1
                continue
            }
            if seen.insert(token.lowercased()).inserted { tokens.append(token) }
        }
        if let notebookTag, seen.insert(notebookTag.lowercased()).inserted { tokens.append(notebookTag) }
        if rejectedTags > 0 { warnings.append("\(noteLabel): \(rejectedTags) tag(s) cannot become a tag, left out") }
        if !tokens.isEmpty { text += (text.isEmpty ? "" : "\n\n") + tokens.joined(separator: " ") }

        let created = Self.parseDate(enote.created)
        let updated = Self.parseDate(enote.updated)
        var modifiedAt = updated ?? created ?? now()
        var createdAt = min(created ?? modifiedAt, modifiedAt)
        if !options.keepDates {
            modifiedAt = now()
            createdAt = modifiedAt
        }
        let draft = ImportedNoteDraft(text: text, createdAt: createdAt, modifiedAt: modifiedAt, attachments: attachments)
        do {
            try store.importNote(draft)
        } catch {
            report.errors.append("\(noteLabel): \(FileImporter.describe(error))")
            return
        }
        report.created += 1
        report.attachmentsCopied += attachments.count
        report.warnings += warnings
    }

    // MARK: - Resources

    private struct StoredResource {
        var name: String
        var isImage: Bool

        var markdown: String {
            let target = AttachmentLinkRewriter.encode(name)
            if isImage { return "![](\(target))" }
            let display = name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let ext = (name as NSString).pathExtension.lowercased()
            return "[\(display)](\(target)) \(AttachmentLinkRewriter.comment(ext: ext))"
        }
    }

    private static func describe(_ skip: ENEXSkip?) -> String {
        switch skip {
        case .tooLarge: "larger than the 128 MB limit"
        case .overBudget: "the 2 GB total limit of the run was reached"
        case .undecodable, nil: "its data could not be decoded"
        }
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The file name from the export, made safe (one path component, no hidden or control
    /// characters, at most 200 bytes), with an extension from the MIME type when it has none;
    /// without a name: `<md5>.<ext>`.
    static func attachmentName(fileName: String?, mime: String, hash: String) -> String {
        let ext = fileExtension(forMime: mime)
        var name = (fileName ?? "").unicodeScalars.map { scalar -> String in
            scalar == "/" || scalar == "\\" || scalar.properties.generalCategory == .control ? "-" : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return "\(hash).\(ext)" }
        if (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
        let fileExt = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        while (base + "." + fileExt).utf8.count > 200, !base.isEmpty { base.removeLast() }
        return base.isEmpty ? "\(hash).\(ext)" : base + "." + fileExt
    }

    private static let commonExtensions: [String: String] = [
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/svg+xml": "svg", "image/tiff": "tiff", "image/bmp": "bmp",
        "application/pdf": "pdf", "text/plain": "txt", "audio/mpeg": "mp3", "audio/wav": "wav",
        "audio/x-m4a": "m4a", "audio/mp4": "m4a", "video/mp4": "mp4", "video/quicktime": "mov",
        "application/zip": "zip",
    ]

    static func fileExtension(forMime mime: String) -> String {
        let lower = mime.lowercased()
        if let known = commonExtensions[lower] { return known }
        if let ext = UTType(mimeType: lower)?.preferredFilenameExtension { return ext }
        return "bin"
    }

    // MARK: - ENML helpers

    fileprivate static let mediaToken = "ZQMEDIA"
    fileprivate static let todoOpen = "ZQTODO0ZQ"
    fileprivate static let todoDone = "ZQTODO1ZQ"
    fileprivate static let cryptToken = "ZQCRYPTZQ"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let mediaTokenPattern = regex(mediaToken + #"(\d+)ZQ"#)
    private static let attribute = regex(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let todoToken = regex(#"ZQTODO([01])ZQ"#)
    private static let todoLineStart = regex(#"^(\s*)(?:(?:[-*+]|\d+\.)\s+)?(?=ZQTODO[01]ZQ)"#)

    static func attributes(of source: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = source as NSString
        for match in attribute.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            result[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: valueRange)
        }
        return result
    }

    /// Replaces every match with the closure's result; the closure also gets the source string.
    private static func replacing(
        _ regex: NSRegularExpression, in source: String, with replacement: (NSTextCheckingResult, String) -> String
    ) -> String {
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += replacement(match, source)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Evernote's to-do items sit inside a `div` or `li`; each becomes its own `- [ ]` /
    /// `- [x]` line, keeping the list indentation the converter wrote.
    static func expandingTodos(_ markdown: String) -> String {
        guard markdown.contains("ZQTODO") else { return markdown }
        var out: [String] = []
        var afterItem = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard line.contains("ZQTODO") else {
                // A plain line right under an item would read as part of it.
                if afterItem, !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("- ") { out.append("") }
                afterItem = false
                out.append(line)
                continue
            }
            afterItem = true
            let ns = line as NSString
            var indent = ""
            var rest = line
            if let start = todoLineStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                indent = ns.substring(with: start.range(at: 1))
                rest = ns.substring(from: start.range.location + start.range.length)
            }
            let restNS = rest as NSString
            let tokens = todoToken.matches(in: rest, range: NSRange(location: 0, length: restNS.length))
            let head = restNS.substring(to: tokens[0].range.location).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { out.append(indent + head) }
            for (i, token) in tokens.enumerated() {
                let from = token.range.location + token.range.length
                let to = i + 1 < tokens.count ? tokens[i + 1].range.location : restNS.length
                let item = restNS.substring(with: NSRange(location: from, length: to - from)).trimmingCharacters(in: .whitespaces)
                let done = restNS.substring(with: token.range(at: 1)) == "1"
                out.append(indent + (done ? "- [x] " : "- [ ] ") + item)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Dates

    /// `yyyyMMdd'T'HHmmss'Z'` (UTC).
    static func parseDate(_ string: String) -> Date? {
        let digits = Array(string.utf8)
        guard digits.count == 16, digits[8] == UInt8(ascii: "T"), digits[15] == UInt8(ascii: "Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard digits[i] >= 48, digits[i] <= 57 else { return nil }
                value = value * 10 + Int(digits[i] - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}

/// Replaces Evernote's own elements in an ENML document with plain-text tokens in one pass over
/// the bytes: the XML prolog and the `en-note` wrapper are dropped (the converter flattens block
/// elements inside an unknown wrapper), `en-media` and `en-todo` become tokens, `en-crypt`
/// sections become one token each. Every search moves forward only, and an opener without its end
/// stops the scan (the rest is kept as it is, or for `en-crypt` counted as encrypted), so hostile
/// input costs time linear in its size (IMP-R6).
enum ENMLPreprocessor {
    struct Prepared {
        var html: String
        /// Lower-cased `hash` attribute of each `en-media`, in document order.
        var mediaHashes: [String]
        var encryptedSections: Int
    }

    private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")

    static func prepare(_ content: Data) -> Prepared {
        let b = [UInt8](content)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var hashes: [String] = []
        var encrypted = 0
        var i = 0

        func append(_ text: String) { out.append(contentsOf: text.utf8) }

        while i < n {
            if b[i] != lt {
                var j = i + 1
                while j < n, b[j] != lt { j += 1 }
                out.append(contentsOf: b[i..<j])
                i = j
                continue
            }
            if matches(b, at: i, "<?xml") {
                guard let end = find(b, "?>", from: i + 5) else { out.append(contentsOf: b[i...]); break }
                i = end + 2
            } else if matches(b, at: i, "<!DOCTYPE") {
                guard let end = find(b, ">", from: i + 9) else { out.append(contentsOf: b[i...]); break }
                i = end + 1
            } else if let nameEnd = element(b, at: i, "en-note", closing: false) ?? element(b, at: i, "en-note", closing: true) {
                guard let end = tagEnd(b, from: nameEnd) else { out.append(contentsOf: b[i...]); break }
                i = end + 1
            } else if let nameEnd = element(b, at: i, "en-media", closing: false) {
                guard let end = tagEnd(b, from: nameEnd) else { out.append(contentsOf: b[i...]); break }
                let attributes = EvernoteImporter.attributes(of: String(decoding: b[nameEnd..<end], as: UTF8.self))
                hashes.append((attributes["hash"] ?? "").lowercased())
                append("\(EvernoteImporter.mediaToken)\(hashes.count - 1)ZQ")
                i = skippingClosing(b, after: end, "en-media")
            } else if let nameEnd = element(b, at: i, "en-todo", closing: false) {
                guard let end = tagEnd(b, from: nameEnd) else { out.append(contentsOf: b[i...]); break }
                let attributes = EvernoteImporter.attributes(of: String(decoding: b[nameEnd..<end], as: UTF8.self))
                append(attributes["checked"]?.lowercased() == "true" ? EvernoteImporter.todoDone : EvernoteImporter.todoOpen)
                i = skippingClosing(b, after: end, "en-todo")
            } else if let nameEnd = element(b, at: i, "en-crypt", closing: false) {
                encrypted += 1
                append(EvernoteImporter.cryptToken)
                guard let end = tagEnd(b, from: nameEnd) else { break }
                if b[end - 1] == slash {
                    i = end + 1
                } else {
                    // Unclosed: everything after the opener counts as the encrypted section.
                    guard let close = find(b, "</en-crypt", from: end + 1),
                          let closeEnd = find(b, ">", from: close + 10) else { break }
                    i = closeEnd + 1
                }
            } else {
                out.append(lt)
                i += 1
            }
        }
        return Prepared(html: String(decoding: out, as: UTF8.self), mediaHashes: hashes, encryptedSections: encrypted)
    }

    /// ASCII lower case; names in ENML are matched ignoring case, as the XML prolog and tags were
    /// before the scan replaced the regular expressions.
    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func matches(_ b: [UInt8], at i: Int, _ text: StaticString) -> Bool {
        let count = text.utf8CodeUnitCount
        guard i >= 0, i + count <= b.count else { return false }
        return text.withUTF8Buffer { needle in
            for k in 0..<count where lower(b[i + k]) != lower(needle[k]) { return false }
            return true
        }
    }

    /// The index after the element name when `b[i...]` opens (or, `closing`, closes) `name` and the
    /// name ends there (whitespace, `/` or `>`).
    private static func element(_ b: [UInt8], at i: Int, _ name: StaticString, closing: Bool) -> Int? {
        guard i + 1 < b.count, b[i] == lt, (b[i + 1] == slash) == closing else { return nil }
        let start = i + (closing ? 2 : 1)
        guard matches(b, at: start, name) else { return nil }
        let end = start + name.utf8CodeUnitCount
        guard end < b.count else { return nil }
        switch b[end] {
        case 0x20, 0x09, 0x0A, 0x0D, slash, gt: return end
        default: return nil
        }
    }

    /// The index of the `>` that ends the tag whose attributes start at `from`, skipping quoted values.
    private static func tagEnd(_ b: [UInt8], from: Int) -> Int? {
        var k = from
        var quote: UInt8?
        while k < b.count {
            let c = b[k]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == gt {
                return k
            }
            k += 1
        }
        return nil
    }

    /// The first index at or after `from` where `needle` starts.
    private static func find(_ b: [UInt8], _ needle: StaticString, from: Int) -> Int? {
        let count = needle.utf8CodeUnitCount
        guard from >= 0, count > 0, b.count >= count else { return nil }
        let first = lower(needle.withUTF8Buffer { $0[0] })
        var k = from
        while k + count <= b.count {
            if lower(b[k]) == first, matches(b, at: k, needle) { return k }
            k += 1
        }
        return nil
    }

    /// After `end` (the `>` of an opener): an optional `</name>` directly following, whitespace allowed.
    private static func skippingClosing(_ b: [UInt8], after end: Int, _ name: StaticString) -> Int {
        var k = end + 1
        while k < b.count, b[k] == 0x20 || b[k] == 0x09 || b[k] == 0x0A || b[k] == 0x0D { k += 1 }
        guard let nameEnd = element(b, at: k, name, closing: true), let close = find(b, ">", from: nameEnd) else { return end + 1 }
        return close + 1
    }
}
