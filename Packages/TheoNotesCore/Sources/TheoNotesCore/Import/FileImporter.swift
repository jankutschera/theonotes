// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

#if canImport(AppKit)
import AppKit
#endif
import Foundation
import os

private let fileImportLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "import")

public struct FileImportOptions: Equatable, Sendable {
    /// Notes keep the source's created/modified dates (file dates, or Bear's `info.json`); off
    /// gives every note "now".
    public var keepDates: Bool
    /// Inserts `# <filename>` as the first body line unless it already is that heading.
    public var titleFromFilename: Bool
    /// Makes the first line of text a `# ` heading unless it already is a heading, a tag line or a
    /// block (list, quote, fence, table). Wins over `titleFromFilename` (A14).
    public var titleFromFirstLine: Bool
    /// Escapes tags that start with a digit (`#3rd`, `#2026-07-09`) as `\#3rd` so they stay text.
    /// A closed `#2021#` is a deliberate tag and stays one (A14).
    public var keepHashNumbersAsText: Bool

    public init(
        keepDates: Bool = true, titleFromFilename: Bool = false, titleFromFirstLine: Bool = false,
        keepHashNumbersAsText: Bool = false
    ) {
        self.keepDates = keepDates
        self.titleFromFilename = titleFromFilename
        self.titleFromFirstLine = titleFromFirstLine
        self.keepHashNumbersAsText = keepHashNumbersAsText
    }
}

/// Outcome of a file import. Paths in `warnings` / `errors` start with the item's path (the
/// dropped file, or the dropped folder/archive plus the path inside it); never note text.
public struct FileImportReport: Equatable, Sendable {
    public var created = 0
    /// Items not imported and not failed: unsupported file types, empty notes.
    public var skipped = 0
    public var attachmentsCopied = 0
    public var warnings: [String] = []
    public var errors: [String] = []
    /// `isCancelled` stopped the run between two notes.
    public var wasCancelled = false
    /// Ids of the notes the run made, in order (File ▸ Import does not use them; opening a file from
    /// the Finder shows the last one).
    public var createdNoteIds: [String] = []

    public init(
        created: Int = 0, skipped: Int = 0, attachmentsCopied: Int = 0,
        warnings: [String] = [], errors: [String] = [], wasCancelled: Bool = false,
        createdNoteIds: [String] = []
    ) {
        self.created = created
        self.skipped = skipped
        self.attachmentsCopied = attachmentsCopied
        self.warnings = warnings
        self.errors = errors
        self.wasCancelled = wasCancelled
        self.createdNoteIds = createdNoteIds
    }
}

/// Imports Markdown / text files, TextBundles, TextPacks, Bear backups (`.bear2bk`), zip archives
/// and folders of Markdown (Obsidian, UpNote, Apple Notes exports). Each note with its
/// attachments is one `NoteStore.importNote` transaction; per-item failures go to the report,
/// so one broken file never stops the run. Archives are extracted by `SafeZip` into a temporary
/// directory that is always removed.
public final class FileImporter: Sendable {
    private let store: NoteStore
    private let paths: AppPaths
    private let now: @Sendable () -> Date
    private let temporaryDirectory: URL
    private let limits: AppleNotesExportImporter.Limits

    public convenience init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date = { Date() },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(store: store, paths: paths, now: now, temporaryDirectory: temporaryDirectory, limits: .standard)
    }

    /// `limits` caps the files that links in Markdown notes copy as attachments (IMP-R61): one
    /// file, the files of one note, and everything one run copies.
    init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date, temporaryDirectory: URL,
        limits: AppleNotesExportImporter.Limits
    ) {
        self.store = store
        self.paths = paths
        self.now = now
        self.temporaryDirectory = temporaryDirectory
        self.limits = limits
    }

    /// Formats read from a chosen file or package only, never found by a folder walk (M8-R16).
    private enum DocumentFormat { case html, rtf, rtfd }

    private enum Unit {
        /// A Markdown/text file; `searchable` lets `[[name.ext]]` embeds be found anywhere in `root`.
        case file(url: URL, root: URL, searchable: Bool, label: String)
        case bundle(url: URL, name: String, label: String)
        case document(url: URL, format: DocumentFormat, label: String)
        /// A chosen `.enex` file: read by `EvernoteImporter`.
        case evernote(url: URL, label: String)
        /// A chosen zip (also a zip of part archives) or folder that is a Notion export: read by
        /// `NotionImporter`.
        case notion(url: URL, label: String)

        var label: String {
            switch self {
            case .file(_, _, _, let label), .bundle(_, _, let label), .document(_, _, let label),
                 .evernote(_, let label), .notion(_, let label): label
            }
        }
    }

    private static let archiveExtensions: Set<String> = ["textpack", "bear2bk", "zip", "bear", "bearnote", "panda"]
    /// Archives that are always one zipped TextBundle written by someone else's app (M8-R57).
    /// Every archive is extracted by `SafeZip`, which refuses it whole before writing anything
    /// unsafe; these get the one-note limits, the others the bulk ones (M8-R100, R101).
    private static let singleNoteArchiveExtensions: Set<String> = ["bear", "bearnote", "panda"]
    private static let documentExtensions: [String: DocumentFormat] = ["html": .html, "htm": .html, "rtf": .rtf, "rtfd": .rtfd]
    /// An HTML or RTF file bigger than this is not read.
    private static let maxDocumentBytes = 128 << 20
    private static let htmlImageLimits = HTMLToMarkdown.ImageLimits(each: 32 << 20, total: 128 << 20)

    /// Throws only when the working directories cannot be created. `progress(done, total)` is
    /// called before the first note and after each one.
    public func importItems(
        _ urls: [URL], options: FileImportOptions = FileImportOptions(),
        progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try paths.createDirectories()
        let work = temporaryDirectory.appendingPathComponent("baerchen-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var report = importAll(urls, work: work, options: options, progress: progress, isCancelled: isCancelled)
        if let failure = TemporaryTree.remove(at: work) { report.errors.append(failure) }
        return report
    }

    private func importAll(
        _ urls: [URL], work: URL, options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) -> FileImportReport {
        var report = FileImportReport()
        var units: [Unit] = []
        for (n, url) in urls.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                return report
            }
            expand(url, work: work.appendingPathComponent("\(n)", isDirectory: true), into: &units, report: &report)
        }

        importUnits(units, options: options, progress: progress, isCancelled: isCancelled, report: &report)
        return report
    }

    /// Imports the units in order into `report`. An `.enex` file or a Notion export counts as the
    /// notes it holds, so the total grows once such a source reports its size.
    private func importUnits(
        _ units: [Unit], options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool,
        report: inout FileImportReport
    ) {
        var indexes: [String: VaultIndex] = [:]
        var copiedBytes = 0
        progress(0, units.count)
        // Notes finished so far.
        var completed = 0
        for (position, unit) in units.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            let pending = units.count - position - 1
            switch unit {
            case .evernote, .notion:
                var innerDone = 0
                do {
                    let inner = try runForeignImporter(unit, options: options, progress: { done, total in
                        innerDone = done
                        progress(completed + done, completed + total + pending)
                    }, isCancelled: isCancelled)
                    report.created += inner.created
                    report.createdNoteIds += inner.createdNoteIds
                    report.skipped += inner.skipped
                    report.attachmentsCopied += inner.attachmentsCopied
                    report.warnings += inner.warnings
                    report.errors += inner.errors
                    report.wasCancelled = report.wasCancelled || inner.wasCancelled
                } catch {
                    report.errors.append("\(unit.label): \(Self.describe(error))")
                }
                completed += innerDone
            default:
                do {
                    try process(unit, options: options, indexes: &indexes, copiedBytes: &copiedBytes, report: &report)
                } catch {
                    report.errors.append("\(unit.label): \(Self.describe(error))")
                }
                completed += 1
            }
            progress(completed, completed + pending)
            if report.wasCancelled { break }
        }
        let done = report
        fileImportLogger.info("""
            file import: created \(done.created), skipped \(done.skipped), \
            attachments \(done.attachmentsCopied), warnings \(done.warnings.count), errors \(done.errors.count)
            """)
    }

    // MARK: - Finding notes

    private func expand(_ url: URL, work: URL, into units: inout [Unit], report: inout FileImportReport) {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            report.errors.append("\(name): not found")
            return
        }
        if isDirectory.boolValue {
            if ext == "textbundle" {
                units.append(.bundle(url: url, name: url.deletingPathExtension().lastPathComponent, label: name))
            } else if ext == "rtfd" {
                units.append(.document(url: url, format: .rtfd, label: name))
            } else if NotionImporter.looksLikeNotionExport(url) {
                units.append(.notion(url: url, label: name))
            } else {
                walk(url, root: url, relative: name, into: &units)
            }
        } else if ext == "enex" {
            units.append(.evernote(url: url, label: name))
        } else if AttachmentLinkRewriter.noteExtensions.contains(ext) {
            units.append(.file(url: url, root: url.deletingLastPathComponent(), searchable: false, label: name))
        } else if let format = Self.documentExtensions[ext] {
            units.append(.document(url: url, format: format, label: name))
        } else if ext == "zip", NotionImporter.looksLikeNotionExport(url) {
            units.append(.notion(url: url, label: name))
        } else if Self.archiveExtensions.contains(ext) {
            let singleNote = Self.singleNoteArchiveExtensions.contains(ext)
            do {
                try SafeZip.extract(archive: url, to: work, limits: singleNote ? .imports : .bulkImports)
            } catch {
                report.errors.append("\(name): \(Self.describe(error))")
                return
            }
            let stem = url.deletingPathExtension().lastPathComponent
            if singleNote {
                do {
                    units.append(try singleBundle(in: work, name: stem, label: name))
                } catch {
                    report.errors.append("\(name): \(Self.describe(error))")
                }
            } else if Self.textFile(in: work) != nil {
                units.append(.bundle(url: work, name: stem, label: name))
            } else {
                walk(work, root: work, relative: name, into: &units)
            }
        } else {
            report.skipped += 1
            report.warnings.append("\(name): unsupported file type, skipped")
        }
    }

    /// Notes, TextBundles and `.enex` files below `dir`, in name order; hidden items, `__MACOSX` and symbolic
    /// links are ignored. Other files are attachments, imported only when a note links them.
    private func walk(_ dir: URL, root: URL, relative: String, into units: inout [Unit]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "__MACOSX", let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            let label = relative + "/" + name
            let ext = entry.pathExtension.lowercased()
            if values.isDirectory == true {
                if ext == "textbundle" {
                    units.append(.bundle(url: entry, name: entry.deletingPathExtension().lastPathComponent, label: label))
                } else {
                    walk(entry, root: root, relative: label, into: &units)
                }
            } else if ext == "enex" {
                units.append(.evernote(url: entry, label: label))
            } else if AttachmentLinkRewriter.noteExtensions.contains(ext) {
                units.append(.file(url: entry, root: root, searchable: true, label: label))
            }
        }
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Looks at an RTFD package with `lstat` semantics before AppKit reads it: no symbolic link
    /// or special file anywhere, `TXT.rtf` within `maxDocumentBytes`, each other file within the
    /// image cap, everything together within the HTML total cap, and a sane file count and depth.
    /// Nothing is read (M8-R56).
    private static func preflightPackage(_ package: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        if (try? package.resourceValues(forKeys: keys))?.isSymbolicLink == true {
            throw FileImportError.unsafePackage("the package is a symbolic link")
        }
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: Array(keys), options: []) else {
            throw FileImportError.unsafePackage("the package could not be listed")
        }
        var files = 0
        var total = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys) else {
                throw FileImportError.unsafePackage("an item could not be examined")
            }
            if values.isSymbolicLink == true { throw FileImportError.unsafePackage("it contains a symbolic link") }
            if values.isDirectory == true {
                if walker.level > 8 { throw FileImportError.unsafePackage("folders are nested too deeply") }
                continue
            }
            guard values.isRegularFile == true else { throw FileImportError.unsafePackage("it contains a special file") }
            files += 1
            let size = values.fileSize ?? 0
            total += size
            let isText = walker.level == 1 && url.lastPathComponent == "TXT.rtf"
            guard files <= 10_000 else { throw FileImportError.unsafePackage("it holds too many files") }
            guard size <= (isText ? maxDocumentBytes : htmlImageLimits.each) else {
                throw FileImportError.unsafePackage("a file is too large (\(url.lastPathComponent))")
            }
            guard total <= htmlImageLimits.total else { throw FileImportError.unsafePackage("it is larger than 128 MB") }
        }
    }

    /// The bundle of a `.bear`, `.bearnote` or `.panda` archive: exactly one TextBundle, as the
    /// extracted root itself, as the only folder in it (any name), or as the only `*.textbundle`
    /// below it. Anything else (two bundles, a bundle beside loose notes, none) is refused before
    /// a note is written (M8-R57).
    private func singleBundle(in work: URL, name: String, label: String) throws -> Unit {
        var found: [Unit] = []
        walk(work, root: work, relative: label, into: &found)
        let bundles = found.filter { if case .bundle = $0 { true } else { false } }
        if Self.textFile(in: work) != nil {
            guard bundles.isEmpty else { throw FileImportError.notOneBundle(1 + bundles.count) }
            return .bundle(url: work, name: name, label: label)
        }
        if let inner = Self.onlyFolder(in: work), Self.textFile(in: inner) != nil,
           inner.pathExtension.lowercased() != "textbundle" {
            var below: [Unit] = []
            walk(inner, root: inner, relative: label + "/" + inner.lastPathComponent, into: &below)
            let nested = below.filter { if case .bundle = $0 { true } else { false } }
            guard nested.isEmpty else { throw FileImportError.notOneBundle(1 + nested.count) }
            return .bundle(url: inner, name: name, label: label)
        }
        guard found.count == 1, case .bundle = found[0] else { throw FileImportError.notOneBundle(found.count) }
        return found[0]
    }

    /// The one visible folder in `dir` when it holds nothing else visible (`__MACOSX` aside).
    private static func onlyFolder(in dir: URL) -> URL? {
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard entries.count == 1, let values = try? entries[0].resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return entries[0]
    }

    /// `text.md`, `text.markdown`, `text.txt`, else any `text.*`. A symbolic link is never a
    /// text file (it could point at any file the user can read).
    private static func textFile(in bundle: URL) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? [])
            .filter { !isSymbolicLink(bundle.appendingPathComponent($0)) }
        let byLower = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in ["text.md", "text.markdown", "text.txt"] {
            if let name = byLower[candidate] { return bundle.appendingPathComponent(name) }
        }
        return names.sorted().first { $0.lowercased().hasPrefix("text.") && !$0.hasPrefix(".") }
            .map { bundle.appendingPathComponent($0) }
    }

    // MARK: - Importing a note

    private func process(
        _ unit: Unit, options: FileImportOptions, indexes: inout [String: VaultIndex], copiedBytes: inout Int,
        report: inout FileImportReport
    ) throws {
        switch unit {
        case .file(let url, let root, let searchable, let label):
            let decoded = try TextDecoding.decode(try Data(contentsOf: url))
            var warnings: [String] = []
            if decoded.usedFallback {
                warnings.append("\(label): not valid UTF-8, read as Windows-1252")
            }
            let dates = fileDates(url)
            try importText(
                decoded.text, name: url.deletingPathExtension().lastPathComponent, label: label,
                noteDir: url.deletingLastPathComponent(), root: root, searchable: searchable,
                created: dates.created, modified: dates.modified, info: nil, options: options,
                warnings: warnings, indexes: &indexes, copiedBytes: &copiedBytes, report: &report)
        case .bundle(let dir, let name, let label):
            guard let textURL = Self.textFile(in: dir) else { throw FileImportError.noTextFile }
            let decoded = try TextDecoding.decode(try Data(contentsOf: textURL))
            var warnings: [String] = []
            if decoded.usedFallback {
                warnings.append("\(label): not valid UTF-8, read as Windows-1252")
            }
            let info = BundleInfo.read(dir.appendingPathComponent("info.json"))
            let dates = fileDates(textURL)
            try importText(
                decoded.text, name: name, label: label, noteDir: dir, root: dir, searchable: true,
                created: info.created ?? dates.created, modified: info.modified ?? dates.modified, info: info,
                options: options, warnings: warnings, indexes: &indexes, copiedBytes: &copiedBytes, report: &report)
        case .document(let url, let format, let label):
            try processDocument(
                url, format: format, label: label, options: options, indexes: &indexes, copiedBytes: &copiedBytes,
                report: &report)
        case .evernote, .notion:
            break // run by `runForeignImporter`, which needs the progress and cancel callbacks
        }
    }

    /// An `.enex` file or a Notion export through its own importer; the report is that
    /// importer's. Both keep their per-note failures in the report and stop between notes when
    /// `isCancelled` says so.
    private func runForeignImporter(
        _ unit: Unit, options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) throws -> FileImportReport {
        switch unit {
        case .evernote(let url, _):
            return try EvernoteImporter(store: store, paths: paths, now: now)
                .importFile(url, options: options, progress: progress, isCancelled: isCancelled)
        case .notion(let url, _):
            return try NotionImporter(store: store, paths: paths, now: now, temporaryDirectory: temporaryDirectory)
                .importFile(url, options: options, progress: progress, isCancelled: isCancelled, confirmingSignature: { roots in
                    // Not a Notion export after all (IMP-C1): the extracted folders are plain files.
                    var units: [Unit] = []
                    for root in roots { self.walk(root.url, root: root.url, relative: root.label, into: &units) }
                    var report = FileImportReport()
                    self.importUnits(units, options: options, progress: progress, isCancelled: isCancelled, report: &report)
                    return report
                })
        default:
            return FileImportReport()
        }
    }

    /// A chosen HTML, RTF or RTFD document → Markdown (M8-R55, M8-R56). HTML links its images as
    /// relative files that the rewriter resolves inside the file's folder; RTF has no file links, so
    /// its text skips the rewriter and keeps only the images it holds.
    private func processDocument(
        _ url: URL, format: DocumentFormat, label: String, options: FileImportOptions,
        indexes: inout [String: VaultIndex], copiedBytes: inout Int, report: inout FileImportReport
    ) throws {
        let name = url.deletingPathExtension().lastPathComponent
        let dates = fileDates(url)
        switch format {
        case .html:
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= Self.maxDocumentBytes else { throw FileImportError.tooLarge }
            let decoded = try TextDecoding.decode(try Data(contentsOf: url))
            var warnings: [String] = []
            if decoded.usedFallback { warnings.append("\(label): not valid UTF-8, read as Windows-1252") }
            let converted = HTMLToMarkdown.convert(
                decoded.text, imageLimits: Self.htmlImageLimits, makesTitle: false, keepsRelativeImages: true)
            warnings += converted.warnings.map { "\(label): \($0)" }
            if converted.oversizedImages > 0 { warnings.append("\(label): \(converted.oversizedImages) embedded image(s) too large, left out") }
            try importText(
                converted.markdown, name: name, label: label, noteDir: url.deletingLastPathComponent(),
                root: url.deletingLastPathComponent(), searchable: false, created: dates.created, modified: dates.modified,
                info: nil, options: options, warnings: warnings, indexes: &indexes, copiedBytes: &copiedBytes,
                report: &report, convertedImages: converted.images, readsFrontMatterTags: false)
        case .rtf, .rtfd:
            #if canImport(AppKit)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isDirectory == true {
                try Self.preflightPackage(url)
            } else {
                guard (values?.fileSize ?? 0) <= Self.maxDocumentBytes else { throw FileImportError.tooLarge }
            }
            let attributed: NSAttributedString
            do {
                attributed = try NSAttributedString(
                    url: url, options: [.documentType: format == .rtf ? NSAttributedString.DocumentType.rtf : .rtfd],
                    documentAttributes: nil)
            } catch {
                throw FileImportError.unreadableDocument
            }
            let converted = AttributedStringToMarkdown.convert(attributed)
            try importText(
                converted.markdown, name: name, label: label, noteDir: url.deletingLastPathComponent(),
                root: url.deletingLastPathComponent(), searchable: false, created: dates.created, modified: dates.modified,
                info: nil, options: options, warnings: converted.warnings.map { "\(label): \($0)" },
                indexes: &indexes, copiedBytes: &copiedBytes, report: &report,
                convertedImages: converted.images, rewritesLinks: false, readsFrontMatterTags: false)
            #else
            report.skipped += 1
            report.warnings.append("\(label): RTF is not supported on this platform, skipped")
            #endif
        }
    }

    private func importText(
        _ raw: String, name: String, label: String, noteDir: URL, root: URL, searchable: Bool,
        created: Date, modified: Date, info: BundleInfo?, options: FileImportOptions,
        warnings: [String], indexes: inout [String: VaultIndex], copiedBytes: inout Int,
        report: inout FileImportReport,
        convertedImages: [ImportedAttachment] = [], rewritesLinks: Bool = true, readsFrontMatterTags: Bool = true
    ) throws {
        var text = TextNormalization.normalizeLineEndings(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.skipped += 1
            report.warnings.append("\(label): empty, skipped")
            return
        }
        var index: VaultIndex?
        if searchable {
            let key = root.standardizedFileURL.path
            if let known = indexes[key] {
                index = known
            } else {
                index = VaultIndex(root: root)
                indexes[key] = index
            }
        }
        var rewriter = AttachmentLinkRewriter(
            noteDir: noteDir, root: root, index: index, reservedNames: convertedImages.map(\.filename),
            attachmentsFolder: info == nil ? nil : noteDir.appendingPathComponent("assets", isDirectory: true),
            limits: .init(each: limits.each, total: max(0, min(limits.perNote, limits.total - copiedBytes))))
        if rewritesLinks { text = rewriter.rewrite(text) }
        copiedBytes += rewriter.attachments.reduce(0) { $0 + $1.data.count }
        // Front matter from a Bear-dialect app is literal text (M8-R15).
        if options.keepHashNumbersAsText { text = Self.escapingNumberedTags(in: text) }
        if info?.fromDialectApp != true, readsFrontMatterTags { text = ObsidianTags.appending(to: text) }
        if options.titleFromFirstLine {
            text = Self.makingFirstLineTheTitle(text)
        } else if options.titleFromFilename {
            text = Self.insertingTitle(name, into: text)
        }

        var modifiedAt = modified, createdAt = min(created, modified)
        if !options.keepDates {
            modifiedAt = now()
            createdAt = modifiedAt
        }
        let location: NoteLocation = info?.isTrashed == true ? .trash : info?.isArchived == true ? .archive : .notes
        let draft = ImportedNoteDraft(
            text: text, createdAt: createdAt, modifiedAt: modifiedAt, location: location,
            isPinnedGlobal: info?.isPinned ?? false, tagPins: info?.tagPins ?? [],
            isReadOnly: info?.isReadOnly ?? false, attachments: convertedImages + rewriter.attachments)
        let note = try store.importNote(draft)
        report.created += 1
        report.createdNoteIds.append(note.id)
        report.attachmentsCopied += draft.attachments.count
        report.warnings += warnings
        report.warnings += rewriter.warnings.map { "\(label): \($0)" }
    }

    private func fileDates(_ url: URL) -> (created: Date, modified: Date) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate ?? now()
        return (values?.creationDate ?? modified, modified)
    }

    /// `# <name>` + blank line as the first body line (after YAML front matter), unless the first
    /// body line already is a heading with that text.
    static func insertingTitle(_ name: String, into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let start = NoteParser.frontMatterEnd(NoteParser.splitLines(text)) ?? 0
        if start < lines.count {
            var first = lines[start].trimmingCharacters(in: .whitespaces)
            if first.hasPrefix("#") {
                first = String(first.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if first == name { return text }
            }
        }
        lines.insert(contentsOf: ["# \(name)", ""], at: min(start, lines.count))
        return lines.joined(separator: "\n")
    }

    /// `# ` in front of the first non-blank body line (after front matter), unless it starts with
    /// `#` (a heading or a tag line) or is a list, quote, fence or table line.
    static func makingFirstLineTheTitle(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var index = NoteParser.frontMatterEnd(NoteParser.splitLines(text)) ?? 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        guard index < lines.count else { return text }
        let original = lines[index]
        // Indented code (four spaces or a tab) is not a title; a Setext underline below makes the line a heading already.
        if original.hasPrefix("    ") || original.hasPrefix("\t") { return text }
        if index + 1 < lines.count, lines[index + 1].range(of: #"^(=+|-+)\s*$"#, options: .regularExpression) != nil { return text }
        let line = original.trimmingCharacters(in: .whitespaces)
        if line.range(of: #"^(#|```|~~~|[-*+|]( |$)|\d+[.)] |>|---+|\*\*\*+|___+|\$\$|<|\[\^|!\[)"#, options: .regularExpression) != nil { return text }
        // Only leading spaces go: trailing ones may be a hard break.
        lines[index] = "# " + String(original.drop { $0 == " " })
        return lines.joined(separator: "\n")
    }

    /// A backslash before the `#` of every open-form tag whose name starts with an ASCII digit.
    static func escapingNumberedTags(in text: String) -> String {
        var bytes = Array(text.utf8)
        for span in NoteParser.tagSpans(in: text).reversed() {
            guard let first = span.name.utf8.first, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first),
                  bytes[span.bytes.upperBound - 1] != UInt8(ascii: "#") || span.bytes.count == 1
            else { continue }
            bytes.insert(UInt8(ascii: "\\"), at: span.bytes.lowerBound)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Error text for reports: kinds, codes, names; never note text.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as FileImportError: error.description
        case let error as SafeZipError: "archive refused: \(error.description)"
        default: BearImporter.describe(error)
        }
    }
}

// MARK: - Text decoding

enum FileImportError: Error, CustomStringConvertible {
    case noTextFile
    case undecodable
    case tooLarge
    case unreadableDocument
    case notOneBundle(Int)
    case unsafePackage(String)

    var description: String {
        switch self {
        case .noTextFile: "TextBundle has no text file (text.md, text.markdown or text.txt)"
        case .undecodable: "text could not be decoded"
        case .tooLarge: "file is too large (over 128 MB)"
        case .unreadableDocument: "document could not be read"
        case .notOneBundle(let count):
            count == 0 ? "archive refused: no TextBundle found" : "archive refused: expected exactly one TextBundle, found \(count) notes"
        case .unsafePackage(let reason): "package refused: \(reason)"
        }
    }
}

enum TextDecoding {
    /// UTF-8 (with or without BOM) and UTF-16 with BOM; anything else that is not valid UTF-8 is
    /// read as Windows-1252 (`usedFallback`).
    static func decode(_ data: Data) throws -> (text: String, usedFallback: Bool) {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, false)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(data: data.dropFirst(2), encoding: encoding) else { throw FileImportError.undecodable }
            return (text, false)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, false) }
        if let text = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            return (text, true)
        }
        throw FileImportError.undecodable
    }
}

// MARK: - Bear info.json

/// Flags and dates from a TextBundle's `info.json`. Bear nests its keys under
/// `net.shinyfrog.bear` and Theo Notes under `com.truebrewbirdie.baerchen`; flat keys are read too. Unknown keys and broken files are ignored.
struct BundleInfo {
    var created: Date?
    var modified: Date?
    var isPinned: Bool?
    var isTrashed: Bool?
    var isArchived: Bool?
    var isReadOnly: Bool?
    /// Tag paths of per-tag pins (Theo Notes' key only).
    var tagPins: [String]?
    /// `info.json` carries Bear's or Theo Notes' own key (M8-R15).
    var fromDialectApp = false

    static func read(_ url: URL) -> BundleInfo {
        guard !FileImporter.isSymbolicLink(url), let data = try? Data(contentsOf: url),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return BundleInfo() }
        var merged = top
        if let bear = top["net.shinyfrog.bear"] as? [String: Any] {
            merged.merge(bear) { _, nested in nested }
        }
        let ours = top[NoteExporter.creatorIdentifier] as? [String: Any]
        if let ours { merged.merge(ours) { _, nested in nested } }
        return BundleInfo(
            created: date(merged["creationDate"]), modified: date(merged["modificationDate"]),
            isPinned: flag(merged["pinned"]), isTrashed: flag(merged["trashed"]),
            isArchived: flag(merged["archived"]), isReadOnly: flag(merged["readOnly"]),
            tagPins: ours.flatMap { $0["tagPins"] as? [String] },
            fromDialectApp: ours != nil || top["net.shinyfrog.bear"] is [String: Any])
    }

    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.doubleValue != 0
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": true
            case "false", "no", "0": false
            default: nil
            }
        default: nil
        }
    }

    /// ISO-8601 strings, or numbers as seconds since the Apple reference date (2001-01-01).
    private static func date(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        case let string as String:
            if let seconds = Double(string) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        default:
            return nil
        }
    }
}

// MARK: - Obsidian front matter tags

enum ObsidianTags {
    /// Appends the YAML front matter's `tags:` / `tag:` (list, flow list or comma string) as
    /// Bear tags on a last line: `#tag`, multi-word `#two words#`.
    static func appending(to text: String) -> String {
        let tags = extract(from: text)
        guard !tags.isEmpty else { return text }
        var body = Substring(text)
        while body.last == "\n" { body = body.dropLast() }
        return body + "\n\n" + tags.joined(separator: " ")
    }

    static func extract(from text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let end = NoteParser.frontMatterEnd(NoteParser.splitLines(text)) else { return [] }
        let front = lines[1..<max(1, end - 1)]
        var items: [String] = []
        var inList = false
        for line in front {
            if inList {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-") {
                    items.append(String(trimmed.dropFirst()))
                    continue
                }
                if trimmed.isEmpty { continue }
                inList = false
            }
            for key in ["tags:", "tag:"] where line.hasPrefix(key) {
                var value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    inList = true
                } else {
                    if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
                    items += value.split(separator: ",").map(String.init)
                }
            }
        }
        var seen = Set<String>()
        var tags: [String] = []
        for item in items {
            var name = item.trimmingCharacters(in: .whitespaces)
            if name.count >= 2, let q = name.first, q == "\"" || q == "'", name.last == q { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(CanonicalKey.make(name)).inserted else { continue }
            tags.append(name.contains(where: \.isWhitespace) ? "#\(name)#" : "#\(name)")
        }
        return tags
    }
}
