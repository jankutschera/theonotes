// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import os

private let exportImportLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "import")

/// Imports notes that Apple Notes itself wrote with File > Export as > Markdown (macOS 26, iOS 26
/// Share > Export as Markdown). This is the way to bring PDFs and other attachments over: the
/// scripting import (`AppleNotesImporter`) only sees embedded images.
///
/// The format is the one a real macOS 26 export showed (ANX-R30): a folder per note named after
/// the title, holding `<Title>.md` and `Attachments/<UUID>.<ext>`, files linked with image
/// syntax. Beyond that it assumes only standard Markdown: every `.md` / `.markdown` file in the
/// chosen folder (or zip) is a note; a relative link or image in it that names a file inside the
/// export is copied as an attachment (`AttachmentLinkRewriter`: images, PDFs and any other file
/// type; a UUID file name becomes the link text, ANX-R32); the folders between the chosen folder
/// and the note become the tag `apple-notes/<chosen folder>/<folder>`, except a per-note folder,
/// which adds no level (ANX-R31).
/// Dates are the files' dates (Apple documents no other date). Files that no note links are
/// counted in one warning, so a link spelling this reader does not know is visible instead of
/// silently losing files. A failing note goes to the report and never stops the run; a zip is
/// extracted by `SafeZip` into a temporary directory that is always removed.
public final class AppleNotesExportImporter: Sendable {
    /// The first part of every tag this importer writes.
    public static let tagRoot = "apple-notes"

    private let store: NoteStore
    private let paths: AppPaths
    private let now: @Sendable () -> Date
    private let temporaryDirectory: URL
    private let limits: Limits

    /// What a run may copy as attachments (ANX-R21). A note's attachments are held in memory
    /// until the note is written, so `perNote` bounds that; `total` bounds the whole run.
    struct Limits: Equatable, Sendable {
        var each: Int
        var perNote: Int
        var total: Int

        static let standard = Limits(each: 128 << 20, perNote: 512 << 20, total: 2 << 30)
    }

    public convenience init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date = { Date() },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(store: store, paths: paths, now: now, temporaryDirectory: temporaryDirectory, limits: .standard)
    }

    init(
        store: NoteStore, paths: AppPaths, now: @escaping @Sendable () -> Date, temporaryDirectory: URL, limits: Limits
    ) {
        self.store = store
        self.paths = paths
        self.now = now
        self.temporaryDirectory = temporaryDirectory
        self.limits = limits
    }

    private static let noteExtensions: Set<String> = ["md", "markdown"]
    private static let maxFileBytes = 128 << 20
    private static let maxFolderDepth = 64

    /// A folder of notes: the chosen folder, or the folder a zip unpacked into.
    private struct Export {
        var root: URL
        /// What the report calls it (the chosen name).
        var label: String
        /// Tag parts between `tagRoot` and a note's own folders: the chosen folder's name.
        var tagBase: [String]
        /// Count the files no note links. Off for a chosen note file (its folder is not ours).
        var audit: Bool
        var notes: [NoteFile] = []
    }

    private struct NoteFile {
        var url: URL
        var label: String
        /// Folders between the export root and the note.
        var folders: [String]
    }

    /// Throws only when the working directories cannot be created. `progress(done, total)` is
    /// called before the first note and after each one.
    public func importItems(
        _ urls: [URL], options: FileImportOptions = FileImportOptions(),
        progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try paths.createDirectories()
        let work = temporaryDirectory.appendingPathComponent("baerchen-apple-notes-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var report = run(urls, work: work, options: options, progress: progress, isCancelled: isCancelled)
        if let failure = TemporaryTree.remove(at: work) { report.errors.append(failure) }
        return report
    }

    private func run(
        _ urls: [URL], work: URL, options: FileImportOptions, progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) -> FileImportReport {
        var report = FileImportReport()
        var exports: [Export] = []
        for (n, url) in urls.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                return report
            }
            expand(url, work: work.appendingPathComponent("\(n)", isDirectory: true), into: &exports, report: &report)
        }

        let total = exports.reduce(0) { $0 + $1.notes.count }
        progress(0, total)
        var done = 0
        var warnedFolders = Set<String>()
        var copiedBytes = 0
        for export in exports {
            var linked = Set<String>()
            for note in export.notes {
                if isCancelled() {
                    report.wasCancelled = true
                    break
                }
                do {
                    try importNote(
                        note, in: export, options: options, linked: &linked, warnedFolders: &warnedFolders,
                        copiedBytes: &copiedBytes, report: &report)
                } catch {
                    report.errors.append("\(note.label): \(FileImporter.describe(error))")
                }
                done += 1
                progress(done, total)
            }
            if report.wasCancelled { break }
            if export.audit { auditUnlinked(export, linked: linked, report: &report) }
        }
        exportImportLogger.info("""
            apple notes export import: created \(report.created), skipped \(report.skipped), \
            attachments \(report.attachmentsCopied), warnings \(report.warnings.count), errors \(report.errors.count)
            """)
        return report
    }

    // MARK: - Finding notes

    private func expand(_ url: URL, work: URL, into exports: inout [Export], report: inout FileImportReport) {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            report.errors.append("\(name): not found")
            return
        }
        if isDirectory.boolValue {
            exports.append(directoryExport(url, label: name, folderName: name, relative: name, report: &report))
        } else if Self.noteExtensions.contains(ext) {
            let parent = url.deletingLastPathComponent()
            exports.append(Export(
                root: parent, label: name, tagBase: [], audit: false,
                notes: [NoteFile(url: url, label: name, folders: [])]))
        } else if ext == "zip" {
            do {
                try SafeZip.extract(archive: url, to: work, limits: .bulkImports)
            } catch {
                report.errors.append("\(name): \(FileImporter.describe(error))")
                return
            }
            var root = work
            var folderName = url.deletingPathExtension().lastPathComponent
            if let only = Self.onlyFolder(in: work) {
                root = only
                folderName = only.lastPathComponent
            }
            exports.append(directoryExport(root, label: name, folderName: folderName, relative: name, report: &report))
        } else {
            report.skipped += 1
            report.warnings.append("\(name): not a folder, zip or Markdown file, skipped")
        }
    }

    /// A chosen folder (or the folder a zip unpacked into). A folder that is itself one note's
    /// folder adds no tag level (ANX-R30); any other is the first level of the tag.
    private func directoryExport(
        _ root: URL, label: String, folderName: String, relative: String, report: inout FileImportReport
    ) -> Export {
        if let note = Self.perNoteFile(in: root) {
            return Export(
                root: root, label: label, tagBase: [], audit: true,
                notes: [NoteFile(url: note, label: relative + "/" + note.lastPathComponent, folders: [])])
        }
        var export = Export(root: root, label: label, tagBase: [folderName], audit: true)
        walk(root, relative: relative, folders: [], depth: 0, into: &export, report: &report)
        return export
    }

    /// The note of a per-note folder, as macOS 26 writes it (ANX-R30): the folder holds exactly one
    /// `.md` / `.markdown` file whose base name is the folder's name, and nothing else but an
    /// `Attachments` folder.
    private static func perNoteFile(in dir: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
        let wanted = dir.lastPathComponent.precomposedStringWithCanonicalMapping
        var note: URL?
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return nil }
            if values.isDirectory == true {
                guard entry.lastPathComponent == "Attachments" else { return nil }
            } else if noteExtensions.contains(entry.pathExtension.lowercased()), note == nil,
                      entry.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping == wanted {
                note = entry
            } else {
                return nil
            }
        }
        return note
    }

    /// Notes below `dir` in name order; hidden items, `__MACOSX` and symbolic links are ignored.
    /// Other files are attachments, imported only when a note links them.
    private func walk(
        _ dir: URL, relative: String, folders: [String], depth: Int, into export: inout Export,
        report: inout FileImportReport
    ) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "__MACOSX", let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            let label = relative + "/" + name
            if values.isDirectory == true, let note = Self.perNoteFile(in: entry) {
                export.notes.append(NoteFile(
                    url: note, label: label + "/" + note.lastPathComponent, folders: folders))
            } else if values.isDirectory == true {
                guard depth < Self.maxFolderDepth else {
                    report.warnings.append("\(label): folders nested too deeply, skipped")
                    continue
                }
                walk(entry, relative: label, folders: folders + [name], depth: depth + 1, into: &export, report: &report)
            } else if Self.noteExtensions.contains(entry.pathExtension.lowercased()) {
                export.notes.append(NoteFile(url: entry, label: label, folders: folders))
            }
        }
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

    // MARK: - Importing a note

    private func importNote(
        _ note: NoteFile, in export: Export, options: FileImportOptions, linked: inout Set<String>,
        warnedFolders: inout Set<String>, copiedBytes: inout Int, report: inout FileImportReport
    ) throws {
        let size = (try? note.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw FileImportError.tooLarge }
        let decoded = try TextDecoding.decode(try Data(contentsOf: note.url))
        var warnings: [String] = []
        if decoded.usedFallback { warnings.append("\(note.label): not valid UTF-8, read as Windows-1252") }
        var text = TextNormalization.normalizeLineEndings(decoded.text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.skipped += 1
            report.warnings.append("\(note.label): empty, skipped")
            return
        }

        var rewriter = AttachmentLinkRewriter(
            noteDir: note.url.deletingLastPathComponent(), root: export.root, index: nil,
            namesFromLinkText: true,
            limits: .init(each: limits.each, total: max(0, min(limits.perNote, limits.total - copiedBytes))))
        text = rewriter.rewrite(text)
        copiedBytes += rewriter.attachments.reduce(0) { $0 + $1.data.count }
        for attachment in rewriter.attachments {
            if let source = attachment.source { linked.insert(source.standardizedFileURL.path) }
        }

        let tag = folderTag(export.tagBase + note.folders, label: export.label, warnedFolders: &warnedFolders, report: &report)
        if let tag {
            while text.last == "\n" { text.removeLast() }
            text += "\n\n" + tag
        }
        let name = note.url.deletingPathExtension().lastPathComponent
        if options.titleFromFilename { text = FileImporter.insertingTitle(name, into: text) }

        let values = try? note.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        var modified = values?.contentModificationDate ?? now()
        var created = min(values?.creationDate ?? modified, modified)
        if !options.keepDates {
            modified = now()
            created = modified
        }
        let draft = ImportedNoteDraft(
            text: text, createdAt: created, modifiedAt: modified, attachments: rewriter.attachments)
        try store.importNote(draft)
        report.created += 1
        report.attachmentsCopied += draft.attachments.count
        report.warnings += warnings
        report.warnings += rewriter.warnings.map { "\(note.label): \($0)" }
    }

    /// `#apple-notes/<folders>` for the longest leading part of the path that can be a tag; a
    /// name that cannot be one cuts the path there (so notes never land in a tag that looks like
    /// another folder) and is reported once per folder.
    private func folderTag(
        _ folders: [String], label: String, warnedFolders: inout Set<String>, report: inout FileImportReport
    ) -> String? {
        var usable = [Self.tagRoot]
        for (position, component) in folders.enumerated() {
            guard AppleNotesImporter.tag(usable + [component]) != nil else {
                let kept = AppleNotesImporter.tag(usable)
                let path = folders.prefix(position + 1).joined(separator: " / ")
                if warnedFolders.insert(label + "/" + path).inserted {
                    let outcome = kept.map { "its notes keep the tag \($0)" } ?? "its notes get no folder tag"
                    report.warnings.append("\(label): folder “\(path)” cannot become a tag; \(outcome)")
                }
                return kept
            }
            usable.append(component)
        }
        return AppleNotesImporter.tag(usable)
    }

    // MARK: - Files nobody linked

    /// One warning with the number of files in the export that are neither notes nor linked by a
    /// note the run read. Hidden items, `__MACOSX` and symbolic links do not count.
    private func auditUnlinked(_ export: Export, linked: Set<String>, report: inout FileImportReport) {
        guard let walker = FileManager.default.enumerator(
            at: export.root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return }
        var unlinked = 0
        for case let url as URL in walker {
            if url.lastPathComponent == "__MACOSX" {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  !Self.noteExtensions.contains(url.pathExtension.lowercased()),
                  !linked.contains(url.standardizedFileURL.path) else { continue }
            unlinked += 1
        }
        if unlinked > 0 {
            report.warnings.append("\(export.label): \(unlinked) file(s) not linked from any note, not imported")
        }
    }
}
