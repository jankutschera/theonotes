// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import os

private let notionImportLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "import")

/// Imports a Notion export: the "Markdown & CSV" or "HTML" zip (or the unpacked folder), also
/// when a large workspace arrives as a zip of `Part-N.zip` archives. Every page becomes a note
/// titled with the page name (the 32-character id Notion appends to file names is dropped), a
/// database (`Name <id>.csv`) becomes one note holding a Markdown table, links between pages
/// become `[[wiki links]]` (resolved by id, so two pages with the same name stay apart), images
/// and files next to a page become attachments, and the page's place in the tree becomes a tag
/// (`notion/<Parent>/<Child>`, see `docs/decisions.md` IMP-R21...). A failing page goes to the
/// report and never stops the run; archives are extracted by `SafeZip` into a temporary
/// directory that is always removed.
public final class NotionImporter: Sendable {
    private let store: NoteStore
    private let paths: AppPaths
    private let now: @Sendable () -> Date
    private let temporaryDirectory: URL
    private let budget: ArchiveBudget
    private let attachmentLimits: AppleNotesExportImporter.Limits

    /// What one import run may extract in all, whatever the number of nested archives: the
    /// per-archive `SafeZip` limits apply to each part, this applies to their sum.
    struct ArchiveBudget: Sendable, Equatable {
        var bytes: UInt64
        var entries: Int
        var files: Int

        static let standard = ArchiveBudget(bytes: SafeZip.Limits.bulkImports.maxTotalBytes, entries: 200_000, files: 500_000)
    }

    public convenience init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date = { Date() },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(
            store: store, paths: paths, now: now, temporaryDirectory: temporaryDirectory, budget: .standard,
            attachmentLimits: .standard)
    }

    /// `attachmentLimits` caps the files a page's links copy as attachments (IMP-R61): one file,
    /// the files of one page, and everything one run copies. It is separate from `budget`, which
    /// bounds what extraction writes to disk.
    init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date,
        temporaryDirectory: URL, budget: ArchiveBudget,
        attachmentLimits: AppleNotesExportImporter.Limits = .standard
    ) {
        self.store = store
        self.paths = paths
        self.now = now
        self.temporaryDirectory = temporaryDirectory
        self.budget = budget
        self.attachmentLimits = attachmentLimits
    }

    // MARK: - Limits

    /// A page, table or HTML file bigger than this is not read.
    private static let maxFileBytes = 128 << 20
    private static let imageLimits = HTMLToMarkdown.ImageLimits(each: 32 << 20, total: 128 << 20)
    /// Archives inside archives: an export holds parts, parts hold no further parts in practice.
    private static let maxArchiveDepth = 3
    private static let maxRoots = 1_000
    private static let maxFolderDepth = 64

    // MARK: - Recognising an export

    /// True for a zip or folder whose pages (`.md`, `.html`) mostly carry Notion's id suffix (a
    /// space and 32 hex characters before the extension), or a zip that only holds part archives
    /// (`...Part-N.zip`; other `Export-*.zip` names do not count). Nothing is extracted or read; a damaged or unsafe archive
    /// is not an export.
    public static func looksLikeNotionExport(_ zipOrFolder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: zipOrFolder.path, isDirectory: &isDirectory) else { return false }
        let names: [String]
        if isDirectory.boolValue {
            guard let listed = listFolder(zipOrFolder) else { return false }
            names = listed
        } else {
            guard let listed = listArchive(zipOrFolder) else { return false }
            names = listed
        }
        return judge(names)
    }

    /// Most pages carry Notion's id suffix; no pages at all (only tables) counts as an export.
    private static func hasPageSignature(_ ids: [String?]) -> Bool {
        ids.isEmpty || ids.filter { $0 != nil }.count * 2 > ids.count
    }

    private static func judge(_ names: [String]) -> Bool {
        var pages = 0
        var withId = 0
        var archives = 0
        var others = 0
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            if ext == "md" || ext == "html" || ext == "htm" {
                pages += 1
                if splitStem(stem).id != nil { withId += 1 }
            } else if ext == "zip", isNumberedPartArchive((name as NSString).lastPathComponent) {
                archives += 1
            } else if ext != "csv" {
                others += 1
            }
        }
        if pages > 0 { return withId * 2 > pages }
        return archives > 0 && others == 0
    }

    private static func listFolder(_ folder: URL) -> [String]? {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var names: [String] = []
        for case let url as URL in walker {
            if url.lastPathComponent == "__MACOSX" {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            names.append(url.lastPathComponent)
            if names.count > ArchiveBudget.standard.files { break }
        }
        return names
    }

    /// File names of a zip, from its central directory, after the same checks extraction makes.
    private static func listArchive(_ archive: URL) -> [String]? {
        let fd = Darwin.open(archive.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        guard let entries = try? SafeZip.readEntries(
            SafeZip.Reader(fd: fd, size: UInt64(info.st_size)), destination: nil, limits: .bulkImports) else { return nil }
        return entries.filter { !$0.isDirectory && !$0.components.contains("__MACOSX") }.map(\.path)
    }

    /// `Export-<uuid>-Part-1.zip`, `Part-2.zip`, `Export-<uuid>.zip`: what an import extracts
    /// from inside an export it already recognised.
    static func isPartArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".zip") else { return false }
        return lower.hasPrefix("export-") || isNumberedPartArchive(name)
    }

    /// `Export-<uuid>-Part-1.zip`, `Part-2.zip`: the only names that make a zip of archives look
    /// like a multi-part Notion export. Any other `Export-*.zip` is just a zip.
    static func isNumberedPartArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".zip") else { return false }
        let stem = String(lower.dropLast(4))
        guard let range = stem.range(of: "part-", options: .backwards) else { return false }
        let digits = stem[range.upperBound...]
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
            && (range.lowerBound == stem.startIndex || stem[stem.index(before: range.lowerBound)] == "-")
    }

    // MARK: - Names

    /// `Name <32 hex>` → (`Name`, id in lower case); a name without an id keeps `nil`.
    static func splitStem(_ stem: String) -> (name: String, id: String?) {
        let tail = stem.suffix(32)
        guard tail.utf8.count == 32, tail.utf8.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46)
        }) else { return (stem, nil) }
        let head = stem.dropLast(32)
        guard head.isEmpty || head.last == " " else { return (stem, nil) }
        return (head.trimmingCharacters(in: .whitespaces), tail.lowercased())
    }

    /// A page title as written into the note and into links: one line, no characters that the
    /// wiki-link syntax uses.
    static func cleanTitle(_ raw: String) -> String {
        let replaced = raw.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "|", with: "-")
        return replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A folder name as one tag segment: no `#`, `|`, `/` or `\`, blanks collapsed.
    static func tagSegment(_ raw: String) -> String {
        var text = ""
        for character in raw {
            switch character {
            case "#", "|", "\\": text.append(" ")
            case "/": text.append("-")
            default: text.append(character)
            }
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Reading the tree

    private enum Kind { case markdown, html, csv }

    private struct Root {
        let url: URL
        let label: String
        let depth: Int
    }

    private struct Page {
        let url: URL
        let root: URL
        let label: String
        let kind: Kind
        let id: String?
        /// Page name without id; the heading or title of the file when it has one.
        var name: String
        /// Name in the notes: `name`, with ` (2)` ... when an earlier page already has it.
        var title: String
        /// Tag segments below `notion`, the names of the pages whose folders contain this one.
        let chain: [String]
        /// File name without extension and id suffix, of the file itself.
        let stem: String
        /// File name without extension, with the id.
        let rawStem: String
    }

    private struct Tree {
        var pages: [Page] = []
        var archives: [URL] = []
        var fileCount = 0
        /// The walk stopped because the run's file budget was used up.
        var truncated = false
    }

    private func walk(
        _ dir: URL, root: Root, chain: [String], relative: String, tree: inout Tree, depth: Int, fileBudget: Int
    ) {
        guard depth <= Self.maxFolderDepth, !tree.truncated else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        var files: [(url: URL, name: String)] = []
        var folders: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "__MACOSX", let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true { folders.append(entry) } else { files.append((entry, name)) }
        }
        var pageNames = Set<String>()
        for file in files {
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard let kind = Self.kind(ofExtension: ext) else { continue }
            let rawStem = (file.name as NSString).deletingPathExtension
            if let parts = Self.pageParts(rawStem, kind: kind) { pageNames.insert(CanonicalKey.make(parts.name)) }
        }
        for file in files {
            guard tree.fileCount < fileBudget else {
                tree.truncated = true
                return
            }
            tree.fileCount += 1
            let ext = (file.name as NSString).pathExtension.lowercased()
            let label = relative + "/" + file.name
            if ext == "zip", Self.isPartArchive(file.name) {
                tree.archives.append(file.url)
                continue
            }
            guard let kind = Self.kind(ofExtension: ext) else { continue }
            let rawStem = (file.name as NSString).deletingPathExtension
            guard let parts = Self.pageParts(rawStem, kind: kind) else { continue }
            if kind == .csv, rawStem.hasSuffix("_all"), parts.id != nil { continue }
            let cleaned = Self.cleanTitle(parts.name)
            let name = cleaned.isEmpty ? "Untitled" : cleaned
            tree.pages.append(Page(
                url: file.url, root: root.url, label: label, kind: kind, id: parts.id, name: name, title: name,
                chain: chain, stem: parts.name, rawStem: rawStem))
        }
        for folder in folders where !tree.truncated {
            let name = folder.lastPathComponent
            let parts = Self.splitStem(name)
            var next = chain
            if parts.id != nil || pageNames.contains(CanonicalKey.make(name)) {
                let segment = Self.tagSegment(parts.name)
                if !segment.isEmpty { next.append(segment) }
            }
            walk(
                folder, root: root, chain: next, relative: relative + "/" + name, tree: &tree, depth: depth + 1,
                fileBudget: fileBudget)
        }
    }

    private static func kind(ofExtension ext: String) -> Kind? {
        switch ext {
        case "md": .markdown
        case "html", "htm": .html
        case "csv": .csv
        default: nil
        }
    }

    /// A Markdown file is a page with or without an id; HTML files and tables only with one (the
    /// others are attachments or the export's index). A table's `_all` twin is dropped by the caller.
    private static func pageParts(_ rawStem: String, kind: Kind) -> (name: String, id: String?)? {
        var stem = rawStem
        if kind == .csv, stem.hasSuffix("_all") { stem = String(stem.dropLast(4)) }
        let parts = splitStem(stem)
        if kind != .markdown, parts.id == nil { return nil }
        return parts
    }

    private static func isLimitRefusal(_ error: any Error) -> Bool {
        switch error as? SafeZipError {
        case .entryTooLarge, .totalTooLarge, .tooManyEntries, .tooManyFolders: true
        default: false
        }
    }

    // MARK: - Import

    /// Throws only when the working directories cannot be created. `progress(done, total)` is
    /// called before the first note and after each one.
    public func importFile(
        _ url: URL, options: FileImportOptions = FileImportOptions(),
        progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try importFile(
            url, options: options, progress: progress, isCancelled: isCancelled, confirmsSignature: false,
            ifNotNotion: { _ in FileImportReport() })
    }

    /// A folder the extraction produced (or the chosen folder itself) with its report label.
    typealias ExtractedRoot = (url: URL, label: String)

    /// The variant `FileImporter` uses (IMP-C1): an archive is routed here by its names alone (a
    /// zip of `...Part-N.zip` files), so once everything is extracted the pages are looked at
    /// again. When most of them lack Notion's id suffix the export is not a Notion export:
    /// `confirmingSignature` imports the extracted folders (they still exist while it runs) and
    /// its report is returned in place of this importer's.
    func importFile(
        _ url: URL, options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool,
        confirmingSignature ifNotNotion: ([ExtractedRoot]) -> FileImportReport
    ) throws -> FileImportReport {
        try importFile(
            url, options: options, progress: progress, isCancelled: isCancelled, confirmsSignature: true,
            ifNotNotion: ifNotNotion)
    }

    private func importFile(
        _ url: URL, options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool,
        confirmsSignature: Bool, ifNotNotion: ([ExtractedRoot]) -> FileImportReport
    ) throws -> FileImportReport {
        try paths.createDirectories()
        let work = temporaryDirectory.appendingPathComponent("baerchen-notion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var report = run(
            url, work: work, options: options, progress: progress, isCancelled: isCancelled,
            confirmsSignature: confirmsSignature, ifNotNotion: ifNotNotion)
        if let failure = TemporaryTree.remove(at: work) { report.errors.append(failure) }
        return report
    }

    private func run(
        _ url: URL, work: URL, options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool,
        confirmsSignature: Bool, ifNotNotion: ([ExtractedRoot]) -> FileImportReport
    ) -> FileImportReport {
        var report = FileImportReport()
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            report.errors.append("\(name): not found")
            return report
        }
        var roots: [Root] = []
        var extracted = 0
        var remainingBytes = budget.bytes
        var remainingEntries = budget.entries
        var exhausted = false
        func extract(_ archive: URL, label: String, depth: Int) -> Bool {
            guard !exhausted else {
                report.warnings.append("\(label): extraction budget used up, skipped")
                return false
            }
            let destination = work.appendingPathComponent("\(extracted)", isDirectory: true)
            extracted += 1
            var limits = SafeZip.Limits.bulkImports
            limits.maxTotalBytes = min(limits.maxTotalBytes, remainingBytes)
            limits.maxEntryBytes = min(limits.maxEntryBytes, remainingBytes)
            limits.maxEntries = min(limits.maxEntries, remainingEntries)
            limits.maxFolders = min(limits.maxFolders, remainingEntries)
            let written: [String]
            do {
                written = try SafeZip.extract(archive: archive, to: destination, limits: limits)
            } catch {
                if limits != .bulkImports, Self.isLimitRefusal(error) {
                    exhausted = true
                    report.warnings.append("\(label): does not fit the extraction budget of this import, this and later parts skipped")
                } else {
                    report.errors.append("\(label): \(FileImporter.describe(error))")
                }
                return false
            }
            var bytes: UInt64 = 0
            for path in written {
                let size = (try? destination.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                bytes += UInt64(size ?? 0)
            }
            remainingBytes = remainingBytes > bytes ? remainingBytes - bytes : 0
            remainingEntries = max(0, remainingEntries - written.count)
            roots.append(Root(url: destination, label: label, depth: depth))
            return true
        }
        if isDirectory.boolValue {
            roots.append(Root(url: url, label: name, depth: 0))
        } else if url.pathExtension.lowercased() == "zip" {
            if isCancelled() {
                report.wasCancelled = true
                return report
            }
            guard extract(url, label: name, depth: 0) else { return report }
        } else {
            report.errors.append("\(name): choose the export's zip file or its folder")
            return report
        }

        // Every root is read before any note is written, so a link finds its page in any part.
        var tree = Tree()
        var position = 0
        var fileBudget = budget.files
        while position < roots.count {
            let root = roots[position]
            position += 1
            var found = Tree()
            walk(root.url, root: root, chain: [], relative: root.label, tree: &found, depth: 0, fileBudget: fileBudget)
            tree.pages += found.pages
            tree.fileCount += found.fileCount
            fileBudget = max(0, fileBudget - found.fileCount)
            if found.truncated {
                exhausted = true
                report.warnings.append("\(root.label): more files than the file budget of this import allows, the rest of it and later parts were skipped")
            }
            for archive in found.archives.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
                guard root.depth < Self.maxArchiveDepth, roots.count < Self.maxRoots else {
                    report.warnings.append("\(root.label)/\(archive.lastPathComponent): nested archives too deep or too many, skipped")
                    continue
                }
                if isCancelled() {
                    report.wasCancelled = true
                    return report
                }
                _ = extract(archive, label: root.label + "/" + archive.lastPathComponent, depth: root.depth + 1)
            }
        }
        guard !tree.pages.isEmpty else {
            report.warnings.append("\(name): no Notion pages found")
            return report
        }
        if confirmsSignature, !Self.hasPageSignature(tree.pages.filter { $0.kind != .csv }.map(\.id)) {
            var inner = ifNotNotion(roots.map { ($0.url, $0.label) })
            inner.warnings = report.warnings + inner.warnings
            inner.errors = report.errors + inner.errors
            return inner
        }

        var index = Index(pages: tree.pages)
        index.nameFromContents()
        index.numberTitles()
        index.build()

        progress(0, index.pages.count)
        var copiedBytes = 0
        for position in index.pages.indices {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            let page = index.pages[position]
            do {
                try importPage(page, index: index, options: options, copiedBytes: &copiedBytes, report: &report)
            } catch {
                report.errors.append("\(page.label): \(FileImporter.describe(error))")
            }
            progress(position + 1, index.pages.count)
        }
        notionImportLogger.info("""
            notion import: created \(report.created), skipped \(report.skipped), \
            attachments \(report.attachmentsCopied), warnings \(report.warnings.count), errors \(report.errors.count)
            """)
        return report
    }

    // MARK: - Page index

    /// All pages of the export with the lookups that links need.
    private struct Index {
        var pages: [Page]
        private(set) var byId: [String: Int] = [:]
        private(set) var byPath: [String: Int] = [:]
        /// Per folder: canonical page name → page, for linking a database row to its page.
        private(set) var byFolder: [String: [String: Int]] = [:]

        init(pages: [Page]) { self.pages = pages }

        /// A Markdown page is named by its first `# ` heading and an HTML page by its `<title>`:
        /// Notion shortens long titles in file names. Falls back to the file name.
        mutating func nameFromContents() {
            for position in pages.indices where pages[position].kind != .csv {
                let page = pages[position]
                guard let head = Self.readHead(page.url) else { continue }
                let found: String? = page.kind == .markdown ? Self.heading(in: head) : Self.htmlTitle(in: head)
                let cleaned = found.map(NotionImporter.cleanTitle) ?? ""
                if !cleaned.isEmpty {
                    pages[position].name = cleaned
                    pages[position].title = cleaned
                }
            }
        }

        /// Pages that share a name (compared as the note index does) keep both; the later one in
        /// reading order gets ` (2)`, ` (3)` ...
        mutating func numberTitles() {
            var used = Set<String>()
            for position in pages.indices {
                let name = pages[position].name
                var title = name
                var counter = 2
                while used.contains(CanonicalKey.make(title)) {
                    title = "\(name) (\(counter))"
                    counter += 1
                }
                used.insert(CanonicalKey.make(title))
                pages[position].title = title
            }
        }

        mutating func build() {
            for (position, page) in pages.enumerated() {
                if let id = page.id, byId[id] == nil { byId[id] = position }
                byPath[page.url.standardizedFileURL.path] = position
                if page.kind != .csv {
                    let folder = page.url.deletingLastPathComponent().standardizedFileURL.path
                    byFolder[folder, default: [:]][CanonicalKey.make(page.stem)] = position
                }
            }
        }

        private static func readHead(_ url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16 << 10) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        private static func heading(in head: String) -> String? {
            var text = head
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard trimmed.hasPrefix("# ") else { return nil }
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            }
            return nil
        }

        private static func htmlTitle(in head: String) -> String? {
            guard let open = head.range(of: "<title>", options: .caseInsensitive),
                  let close = head.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<head.endIndex)
            else { return nil }
            return HTMLText.unescape(String(head[open.upperBound..<close.lowerBound]))
        }

        /// The page a link points at, or `nil` when it is not a page of this export.
        func target(of destination: String, from directory: URL) -> Int? {
            guard LinkDestination.isRelative(destination) else { return nil }
            var raw = destination
            if let cut = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) { raw = String(raw[..<cut]) }
            let decoded = raw.removingPercentEncoding ?? raw
            let ext = (decoded as NSString).pathExtension.lowercased()
            guard ["md", "html", "htm", "csv"].contains(ext) else { return nil }
            let resolved = URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL.path
            if let hit = byPath[resolved] { return hit }
            let stem = ((decoded as NSString).lastPathComponent as NSString).deletingPathExtension
            if let id = NotionImporter.splitStem(stem).id, let hit = byId[id] { return hit }
            return nil
        }

        /// A relative link to something that looks like a page but is not in the export.
        func looksLikeMissingPage(_ destination: String) -> Bool {
            guard LinkDestination.isRelative(destination) else { return false }
            var raw = destination
            if let cut = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) { raw = String(raw[..<cut]) }
            let ext = ((raw.removingPercentEncoding ?? raw) as NSString).pathExtension.lowercased()
            return ["md", "html", "htm", "csv"].contains(ext)
        }
    }

    // MARK: - One page

    private func importPage(
        _ page: Page, index: Index, options: FileImportOptions, copiedBytes: inout Int, report: inout FileImportReport
    ) throws {
        let size = (try? page.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw FileImportError.tooLarge }
        let decoded = try TextDecoding.decode(try Data(contentsOf: page.url))
        var warnings: [String] = []
        if decoded.usedFallback { warnings.append("\(page.label): not valid UTF-8, read as Windows-1252") }
        let directory = page.url.deletingLastPathComponent()
        var missing = 0
        var images: [ImportedAttachment] = []
        var text: String

        switch page.kind {
        case .markdown:
            text = TextNormalization.normalizeLineEndings(decoded.text)
            text = Self.replacingPageLinks(in: text, from: directory, index: index, missing: &missing)
        case .html:
            let linked = Self.replacingAnchors(in: decoded.text, from: directory, index: index, missing: &missing)
            let converted = HTMLToMarkdown.convert(
                linked, imageLimits: Self.imageLimits, makesTitle: false, keepsRelativeImages: true)
            warnings += converted.warnings.map { "\(page.label): \($0)" }
            if converted.oversizedImages > 0 {
                warnings.append("\(page.label): \(converted.oversizedImages) embedded image(s) too large, left out")
            }
            images = converted.images
            text = TextNormalization.normalizeLineEndings(converted.markdown)
        case .csv:
            text = Self.table(fromCSV: TextNormalization.normalizeLineEndings(decoded.text), page: page, index: index)
        }
        if missing > 0 {
            warnings.append("\(page.label): \(missing) link(s) to pages outside this export left as they were")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.skipped += 1
            report.warnings.append("\(page.label): empty, skipped")
            return
        }

        var attachments = images
        if page.kind != .csv {
            var rewriter = AttachmentLinkRewriter(
                noteDir: directory, root: page.root, index: nil, reservedNames: images.map(\.filename),
                limits: .init(
                    each: attachmentLimits.each,
                    total: max(0, min(attachmentLimits.perNote, attachmentLimits.total - copiedBytes))))
            text = rewriter.rewrite(text)
            copiedBytes += rewriter.attachments.reduce(0) { $0 + $1.data.count }
            attachments += rewriter.attachments
            warnings += rewriter.warnings.map { "\(page.label): \($0)" }
        }
        text = Self.settingTitle(page.title, in: text)
        text = Self.expandingTokens(in: text, pages: index.pages)
        text = Self.appendingTags(Self.tagLine(for: page.chain), to: text)

        let dates = fileDates(page.url)
        var modifiedAt = dates.modified, createdAt = min(dates.created, dates.modified)
        if !options.keepDates {
            modifiedAt = now()
            createdAt = modifiedAt
        }
        let draft = ImportedNoteDraft(text: text, createdAt: createdAt, modifiedAt: modifiedAt, attachments: attachments)
        try store.importNote(draft)
        report.created += 1
        report.attachmentsCopied += attachments.count
        report.warnings += warnings
    }

    private func fileDates(_ url: URL) -> (created: Date, modified: Date) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate ?? now()
        return (values?.creationDate ?? modified, modified)
    }

    // MARK: - Title and tags

    /// The first line is `# <title>`: an existing level-1 heading is rewritten when its text
    /// differs, otherwise the heading is added in front.
    static func settingTitle(_ title: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "# \(escapingTags(title))\n"
        }
        let line = lines[first].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("# ") else {
            return "# \(escapingTags(title))\n\n" + lines[first...].joined(separator: "\n")
        }
        let wanted = "# " + escapingTags(title)
        if line != wanted { lines[first] = wanted }
        return lines.joined(separator: "\n")
    }

    /// A title written into the heading line: each `#` becomes `\#` (the dialect's literal hash), so
    /// a name such as `Plan #word` is a title and never a tag. Links name the title unescaped.
    static func escapingTags(_ title: String) -> String {
        title.replacingOccurrences(of: "#", with: "\\#")
    }

    /// `#notion/Parent/Child`, with the closing `#` when the path has blanks, checked against the
    /// tag scanner so the line always reads back as exactly this one tag.
    static func tagLine(for chain: [String]) -> String {
        func candidates(_ segments: [String]) -> [(path: String, line: String)] {
            let path = segments.joined(separator: "/")
            return [(path, "#\(path)"), (path, "#\(path)#")]
        }
        for segments in [["notion"] + chain, ["notion"] + chain.map(Self.plain)] {
            for candidate in candidates(segments.filter { !$0.isEmpty }) where TagScanner.tags(inLine: candidate.line) == [candidate.path] {
                return candidate.line
            }
        }
        return "#notion"
    }

    /// Letters, digits, blanks, `-` and `_` only.
    private static func plain(_ segment: String) -> String {
        let kept = segment.unicodeScalars.map { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == " " || $0 == "-" || $0 == "_" ? Character($0) : " " }
        return String(kept).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    static func appendingTags(_ line: String, to text: String) -> String {
        var body = Substring(text)
        while body.last == "\n" { body = body.dropLast() }
        return String(body) + "\n\n" + line
    }

    // MARK: - Page links

    private static let tokenOpen: Character = "\u{E000}"
    private static let tokenClose: Character = "\u{E001}"

    /// A stand-in for a page link while the attachment rewriter and the title edit run; it holds
    /// the page's position and is replaced by `[[title]]` last.
    private static func token(_ position: Int) -> String { "\(tokenOpen)\(position)\(tokenClose)" }

    private static func expandingTokens(in text: String, pages: [Page]) -> String {
        guard text.contains(tokenOpen) else { return text }
        var out = ""
        var number = ""
        var inside = false
        for character in text {
            if inside {
                if character == tokenClose {
                    if let position = Int(number), pages.indices.contains(position) {
                        out += "[[\(wikiTarget(pages[position].title))]]"
                    }
                    inside = false
                    number = ""
                } else {
                    number.append(character)
                }
            } else if character == tokenOpen {
                inside = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func wikiTarget(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "\\/")
    }

    /// `[Text](path/Page <id>.md)` → a token, outside code. Images are left to the attachment
    /// rewriter. `missing` counts relative links to pages that are not in the export.
    private static func replacingPageLinks(
        in text: String, from directory: URL, index: Index, missing: inout Int
    ) -> String {
        var out: [String] = []
        var fence: (marker: Unicode.Scalar, length: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let scalars = Array(line.unicodeScalars)
            if let open = fence {
                if closesFence(scalars, open) { fence = nil }
                out.append(String(line))
            } else if let open = fenceOpening(scalars) {
                fence = open
                out.append(String(line))
            } else {
                out.append(replacingPageLinks(inLine: scalars, original: line, from: directory, index: index, missing: &missing))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func fenceOpening(_ s: [Unicode.Scalar]) -> (marker: Unicode.Scalar, length: Int)? {
        var i = 0
        while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
        guard i < s.count, s[i] == "`" || s[i] == "~" else { return nil }
        let marker = s[i]
        var j = i
        while j < s.count, s[j] == marker { j += 1 }
        guard j - i >= 3 else { return nil }
        if marker == "`", s[j...].contains("`") { return nil }
        return (marker, j - i)
    }

    private static func closesFence(_ s: [Unicode.Scalar], _ open: (marker: Unicode.Scalar, length: Int)) -> Bool {
        var i = 0
        while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
        var j = i
        while j < s.count, s[j] == open.marker { j += 1 }
        guard j - i >= open.length else { return false }
        return s[j...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func replacingPageLinks(
        inLine s: [Unicode.Scalar], original: Substring, from directory: URL, index: Index, missing: inout Int
    ) -> String {
        var edits: [(range: Range<Int>, replacement: String)] = []
        var openers: [(pos: Int, isImage: Bool)] = []
        let n = s.count
        var i = 0
        while i < n {
            let c = s[i]
            if c == "\\" {
                i += 2
            } else if c == "`" {
                var j = i
                while j < n, s[j] == "`" { j += 1 }
                let length = j - i
                var k = j, closed: Int?
                while k < n {
                    if s[k] == "`" {
                        var m = k
                        while m < n, s[m] == "`" { m += 1 }
                        if m - k == length { closed = m; break }
                        k = m
                    } else {
                        k += 1
                    }
                }
                i = closed ?? j
            } else if c == "[" || (c == "!" && i + 1 < n && s[i + 1] == "[") {
                let bang = c == "!"
                openers.append((i, bang))
                i = (bang ? i + 1 : i) + 1
            } else if c == "]" {
                if let opener = openers.popLast(), i + 1 < n, s[i + 1] == "(",
                   let dest = LinkDestination.parseWithRange(s, from: i + 2) {
                    if !opener.isImage {
                        if let position = index.target(of: dest.text, from: directory) {
                            let range = opener.pos..<dest.end
                            edits.removeAll { range.contains($0.range.lowerBound) }
                            edits.append((range, token(position)))
                        } else if index.looksLikeMissingPage(dest.text) {
                            missing += 1
                        }
                    }
                    i = dest.end
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        guard !edits.isEmpty else { return String(original) }
        var result = s
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: Array(edit.replacement.unicodeScalars))
        }
        return String(String.UnicodeScalarView(result))
    }

    /// HTML export: `<a href="Page <id>.html">...</a>` → a token before the HTML is converted
    /// (the converter keeps no relative links). One forward pass: each `<a` tag is read up to its
    /// `>`, and only an anchor that links a page of the export is followed to its `</a`; when no
    /// closing tag is left the scan stops, so hostile input costs time linear in its size.
    private static func replacingAnchors(
        in html: String, from directory: URL, index: Index, missing: inout Int
    ) -> String {
        replacingAnchors(
            in: html, resolve: { index.target(of: $0, from: directory) },
            isMissingPage: index.looksLikeMissingPage, missing: &missing)
    }

    static func replacingAnchors(
        in html: String, resolve: (String) -> Int?, isMissingPage: (String) -> Bool, missing: inout Int
    ) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var copied = 0
        var i = 0
        var nextClose: Int?
        var searchedFrom = 0
        let hrefName = Array("href".utf8)
        func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C }
        /// Position of the next `</a` followed by a space, `>` or `/`, at or after `from`.
        func findClose(from: Int) -> Int? {
            var k = from
            while k + 3 < n {
                if b[k] == 0x3C, b[k + 1] == 0x2F, lower(b[k + 2]) == 0x61,
                   b[k + 3] == 0x3E || b[k + 3] == 0x2F || isSpace(b[k + 3]) { return k }
                k += 1
            }
            return nil
        }
        scan: while i + 2 < n {
            guard b[i] == 0x3C, lower(b[i + 1]) == 0x61, b[i + 2] == 0x3E || isSpace(b[i + 2]) else {
                i += 1
                continue
            }
            // The tag up to its `>`, quotes respected; blanks are allowed around `=`, and the value
            // of the first `href` may be quoted either way or bare.
            var j = i + 2
            var quote: UInt8?
            var hrefStart: Int?
            var hrefEnd = 0
            var attribute: [UInt8] = []
            var nameDone = false
            var afterEquals = false
            var bare = false
            var valueIsHref = false
            while j < n {
                let c = b[j]
                if let q = quote {
                    if c == q {
                        if valueIsHref { hrefEnd = j }
                        quote = nil
                        afterEquals = false
                        valueIsHref = false
                        attribute = []
                    }
                } else if bare {
                    if isSpace(c) || c == 0x3E {
                        if valueIsHref { hrefEnd = j }
                        bare = false
                        afterEquals = false
                        valueIsHref = false
                        attribute = []
                        if c == 0x3E { break }
                    }
                } else if c == 0x3E {
                    break
                } else if isSpace(c) {
                    if !afterEquals { nameDone = true }
                } else if c == 0x3D, !afterEquals {
                    afterEquals = true
                    nameDone = false
                } else if afterEquals {
                    valueIsHref = hrefStart == nil && attribute == hrefName
                    if c == 0x22 || c == 0x27 {
                        quote = c
                        if valueIsHref { hrefStart = j + 1 }
                    } else {
                        bare = true
                        if valueIsHref { hrefStart = j }
                    }
                } else if c == 0x2F {
                    nameDone = true
                } else {
                    if nameDone {
                        attribute = []
                        nameDone = false
                    }
                    if attribute.count < 5 { attribute.append(lower(c)) }
                }
                j += 1
            }
            guard j < n else { break scan }
            guard let start = hrefStart, hrefEnd >= start, hrefEnd > 0 else {
                i = j + 1
                continue
            }
            let href = HTMLText.unescape(String(decoding: b[start..<hrefEnd], as: UTF8.self))
            guard let position = resolve(href) else {
                if isMissingPage(href) { missing += 1 }
                i = j + 1
                continue
            }
            if nextClose == nil || searchedFrom > j + 1 || nextClose! < j + 1 {
                nextClose = findClose(from: j + 1)
                searchedFrom = j + 1
            }
            guard let close = nextClose else { break scan }
            var end = close + 3
            while end < n, b[end] != 0x3E { end += 1 }
            guard end < n else { break scan }
            out += b[copied..<i]
            out += Array(token(position).utf8)
            copied = end + 1
            i = end + 1
        }
        out += b[copied...]
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Databases

    /// The CSV of a database as a Markdown table under the database's title. The first column
    /// links to the row's page when the export has it in the database's folder.
    private static func table(fromCSV text: String, page: Page, index: Index) -> String {
        let rows = parseCSV(text)
        guard let header = rows.first, header.contains(where: { !$0.isEmpty }) else { return "" }
        let columns = rows.map(\.count).max() ?? header.count
        var folders: [String] = []
        let parent = page.url.deletingLastPathComponent()
        for name in [page.rawStem, page.stem] {
            folders.append(parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL.path)
        }
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columns - cells.count)
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = ["# \(page.title)", ""]
        lines.append(line(header.map(cell)))
        lines.append(line(Array(repeating: "---", count: columns)))
        for row in rows.dropFirst() {
            var cells = row.map(cell)
            if let first = row.first {
                let key = CanonicalKey.make(first.trimmingCharacters(in: .whitespacesAndNewlines))
                for folder in folders {
                    if let position = index.byFolder[folder]?[key] {
                        cells[0] = token(position)
                        break
                    }
                }
            }
            lines.append(line(cells))
        }
        return lines.joined(separator: "\n")
    }

    /// One table cell: one line, `|` escaped, a leading `#` kept from being read as a tag.
    private static func cell(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|")
        var out = ""
        var previous: Character = " "
        for character in text {
            if character == "#", previous.isWhitespace || previous == "(" { out.append("\\") }
            out.append(character)
            previous = character
        }
        text = out
        return text
    }

    /// RFC 4180: quoted fields with `""`, commas and line breaks inside quotes.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var atStart = true
        let s = Array(text.unicodeScalars)
        var i = 0
        func endRow() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            atStart = true
        }
        while i < s.count {
            let c = s[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < s.count, s[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"", atStart {
                inQuotes = true
                atStart = false
            } else if c == "," {
                row.append(String(field))
                field = String.UnicodeScalarView()
                atStart = true
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < s.count, s[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.append(c)
                atStart = false
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

/// The few character references that appear in an attribute or a title.
private enum HTMLText {
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
