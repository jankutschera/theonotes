// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Darwin
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, textBundle, html, pdf, rtf, plainText, docx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .textBundle: "TextBundle"
        case .plainText: "Plain Text"
        case .html: "HTML"
        case .pdf: "PDF"
        case .rtf: "Rich Text (RTF)"
        case .docx: "Word (DOCX)"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .textBundle: "textbundle"
        case .plainText: "txt"
        case .html: "html"
        case .pdf: "pdf"
        case .rtf: "rtf"
        case .docx: "docx"
        }
    }

    /// The formats `NoteExporter` writes itself; nil for the renderer-based ones.
    var fileFormat: FileExportFormat? {
        switch self {
        case .markdown: .markdown
        case .textBundle: .textBundle
        case .plainText: .plainText
        case .html, .pdf, .rtf, .docx: nil
        }
    }
}

struct ExportSettings: Equatable {
    var format: ExportFormat
    var keepTags: Bool
    var htmlLinksBetweenNotes: Bool = false
    var htmlEmbedImages: Bool = false
    /// Markdown, TextBundle and HTML: off leaves attachments out (A9, MAC11-R16).
    var includeAttachments: Bool = true
    /// Markdown only: images go into the file as `data:` URIs instead of the folder next to it (A9).
    var markdownEmbedImages: Bool = false
    /// PDF only: the theme to print with; nil is the light-slot theme (M8-R7).
    var pdfThemeId: String? = nil
}

/// What one run did. Error lines are `"<stem>: message"` and never carry note text.
struct ExportJobReport: Equatable {
    /// Files written (one per planned item: a note under two tags counts twice).
    var exported = 0
    var skippedLocked = 0
    /// `"<noteId>/<filename>"` of each linked attachment whose file could not be copied.
    var missingAttachments: [String] = []
    var errors: [String] = []
    var destination: URL
}

/// Exports a plan in one format (M8 Task 12). One run is one staged destination: every note is
/// built in a hidden `.baerchen-export-<uuid>.partial` folder inside `destination` and, once
/// all are built, moved into place. A cancelled run places nothing; a note that fails is reported
/// and the others still land (M8-R65).
@MainActor
struct ExportJob {
    private let environment: AppEnvironment
    private let renderer: NoteRenderer
    /// Called with the file or folder about to be written into the stage, after the lock check passed
    /// (a test seam: what a locked run must never reach).
    var beforeStageWrite: @MainActor (URL) -> Void = { _ in }

    init(environment: AppEnvironment, renderer: NoteRenderer) {
        self.environment = environment
        self.renderer = renderer
    }

    /// One planned item that was built in the stage and waits to be moved: the names to move,
    /// relative to the item's folder.
    private struct Staged {
        var item: ExportItem
        var units: [String]
        var missing: [String]
        var createdAt: Date
        var modifiedAt: Date
    }

    /// What `place` did for one item: the files it moved and the folders it created, for taking
    /// them back and for dating the folders.
    private struct Placement {
        var entry: Staged
        var placed: [URL]
        var createdFolders: [URL]
    }

    func run(
        _ plan: ExportPlan.Result, settings: ExportSettings, destination: URL,
        progress: (Int, Int) -> Void, isCancelled isCancelledByCaller: () -> Bool
    ) async -> ExportJobReport {
        var report = ExportJobReport(destination: destination)
        // App Lock (M9M-R76): a run that was started before the lock engaged stops at its next check
        // and places nothing; checked before every item is built and before every item is placed.
        let appLock = environment.appLock
        let generation = appLock.generation
        func isCancelled() -> Bool { isCancelledByCaller() || !appLock.isCurrent(generation) }
        report.skippedLocked = plan.skippedLocked.count
        let total = plan.items.count
        progress(0, total)
        guard total > 0 else { return report }

        let fm = FileManager.default
        var createdDestination = false
        let stage = destination.appendingPathComponent(".baerchen-export-\(UUID().uuidString).partial", isDirectory: true)
        do {
            if Self.kind(at: destination) == nil {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                createdDestination = true
            }
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        } catch {
            if createdDestination { try? fm.removeItem(at: destination) }
            report.errors.append("export: \(Self.message(error))")
            return report
        }
        defer { try? fm.removeItem(at: stage) }

        let exporter = NoteExporter(store: environment.store, paths: environment.paths)
        let hrefs = settings.format == .html && settings.htmlLinksBetweenNotes ? Self.htmlTargets(plan.items) : [:]
        var staged: [Staged] = []
        var cancelled = false
        for (index, item) in plan.items.enumerated() {
            if isCancelled() || Task.isCancelled {
                cancelled = true
                break
            }
            do {
                try Self.checkNames(item)
                try Self.checkFree(item, settings: settings, under: destination)
                try environment.existingSession(for: item.noteId)?.flush()
                staged.append(try await build(
                    item, settings: settings, exporter: exporter, stage: stage, hrefs: hrefs,
                    mayWrite: { !isCancelled() && !Task.isCancelled }))
            } catch is CancellationError {
                cancelled = true
                break
            } catch RenderError.cancelled {
                cancelled = true
                break
            } catch ExportError.noteLocked {
                // Locked after the plan was made: skipped and counted, like a locked note in the plan.
                report.skippedLocked += 1
            } catch {
                report.errors.append("\(item.stem): \(Self.message(error))")
            }
            progress(index + 1, total)
            // Building runs on the main actor (M8-R68): give the progress sheet and its Cancel a turn.
            await Task.yield()
        }
        if !cancelled, isCancelled() || Task.isCancelled { cancelled = true }

        if !cancelled {
            var placements: [Placement] = []
            for entry in staged {
                // Checked before every item: the run's output is all or nothing (M8-R65).
                if isCancelled() || Task.isCancelled {
                    cancelled = true
                    break
                }
                do {
                    placements.append(try place(entry, from: stage, to: destination))
                } catch {
                    report.errors.append("\(entry.item.stem): \(Self.message(error))")
                }
            }
            if cancelled {
                for placement in placements.reversed() { Self.undo(placement) }
            } else {
                report.exported = placements.count
                report.missingAttachments = placements.flatMap(\.entry.missing)
                Self.dateCreatedFolders(placements, under: destination)
            }
        }
        try? fm.removeItem(at: stage)
        if createdDestination, report.exported == 0,
           (try? fm.contentsOfDirectory(atPath: destination.path))?.isEmpty == true {
            try? fm.removeItem(at: destination)
        }
        return report
    }

    // MARK: - Building

    private func build(
        _ item: ExportItem, settings: ExportSettings, exporter: NoteExporter, stage: URL, hrefs: [String: [ExportItem]],
        mayWrite: @MainActor () -> Bool
    ) async throws -> Staged {
        /// Rendering is asynchronous and can finish after the lock engaged: every write into the
        /// stage asks again right before it happens (M9M-R81). A stale run stops as cancelled.
        func checkpoint(_ url: URL) throws {
            guard mayWrite() else { throw CancellationError() }
            beforeStageWrite(url)
        }
        let options = ExportOptions(
            keepTags: settings.keepTags, includeAttachments: settings.includeAttachments,
            embedImages: settings.markdownEmbedImages)
        guard let note = try environment.store.note(id: item.noteId) else { throw StoreError.noteNotFound(id: item.noteId) }
        if note.isLocked { throw ExportError.noteLocked(id: note.id) }
        if let fileFormat = settings.format.fileFormat {
            let files = try exporter.write(item, format: fileFormat, under: stage, options: options)
            var units = [files.primary.lastPathComponent]
            if fileFormat == .markdown, let folder = files.attachmentsFolder { units.append(folder.lastPathComponent) }
            return Staged(
                item: item, units: units, missing: files.missingAttachments, createdAt: note.createdAt,
                modifiedAt: note.modifiedAt)
        }

        let folder = item.folder.reduce(stage) { $0.appendingPathComponent($1, isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let builder = RenderRequestBuilder(store: environment.store, paths: environment.paths)
        var units: [String] = []
        var missing: [String] = []

        switch settings.format {
        case .html:
            let look = environment.appearance.exportLook(themeId: nil)
            let request = try builder.request(
                for: note, mode: .document, theme: look.theme, appearance: look.appearance, typography: look.typography,
                attachments: !settings.includeAttachments
                    ? .none : settings.htmlEmbedImages ? .inlineImages(folder: item.stem) : .relative(folder: item.stem),
                wikiLinks: settings.htmlLinksBetweenNotes
                    ? .exported(Self.relativeHrefs(from: item, targets: hrefs)) : WikiLinkTargets.none,
                keepTags: settings.keepTags)
            let result = try await renderer.render(request)
            let file = folder.appendingPathComponent(item.stem + ".html")
            try checkpoint(file)
            // Left out on purpose is not "missing": no dashed card.
            let html = settings.includeAttachments
                ? result.html
                : result.html.replacingOccurrences(of: #"class="(bc-file[^"]*) bc-missing""#, with: "class=\"$1\"", options: .regularExpression)
            try Data(html.utf8).write(to: file)
            units = [file.lastPathComponent]
            let assets = folder.appendingPathComponent(item.stem, isDirectory: true)
            if settings.includeAttachments, try copyReferencedFiles(of: note, request: request, into: assets, missing: &missing, checkpoint: checkpoint) {
                units.append(assets.lastPathComponent)
            }
        case .pdf:
            let look = environment.appearance.exportLook(themeId: settings.pdfThemeId)
            let request = try builder.request(
                for: note, mode: .document, theme: look.theme, appearance: look.appearance, typography: look.typography,
                attachments: .assetURLs, wikiLinks: .sameNote, keepTags: settings.keepTags)
            let file = folder.appendingPathComponent(item.stem + ".pdf")
            _ = try await renderer.writePDF(request, to: file, mayProceed: {
                guard mayWrite() else { return false }
                beforeStageWrite(file)
                return true
            })
            units = [file.lastPathComponent]
        case .rtf, .docx:
            let look = environment.appearance.exportLook(themeId: nil)
            let request = try builder.request(
                for: note, mode: .richText, theme: look.theme, appearance: look.appearance, typography: look.typography,
                attachments: .none, wikiLinks: WikiLinkTargets.none, keepTags: settings.keepTags)
            let result = try await renderer.render(request)
            let file = folder.appendingPathComponent(item.stem + "." + settings.format.fileExtension)
            try checkpoint(file)
            let data = settings.format == .docx
                ? try RichText.docxData(fromFragment: result.html) : try RichText.rtfData(fromFragment: result.html)
            try data.write(to: file)
            units = [file.lastPathComponent]
        case .markdown, .textBundle, .plainText:
            break
        }
        for unit in units { try NoteExporter.applyDates(of: note, to: folder.appendingPathComponent(unit)) }
        return Staged(
            item: item, units: units, missing: missing, createdAt: note.createdAt, modifiedAt: note.modifiedAt)
    }

    /// Copies the files an HTML page links by a relative source (the renderer put them under
    /// `<stem>/`); inlined images are in the page and are not copied. Returns whether the folder
    /// was created.
    private func copyReferencedFiles(
        of note: Note, request: RenderRequest, into folder: URL, missing: inout [String],
        checkpoint: (URL) throws -> Void
    ) throws -> Bool {
        let fm = FileManager.default
        let attachments = AttachmentStore(paths: environment.paths, database: environment.database)
        var seen = Set<String>()
        var created = false
        for attachment in NoteParser.metadata(for: request.text).attachments {
            let name = attachment.filename
            guard seen.insert(AttachmentFiles.fileSystemKey(name)).inserted else { continue }
            guard let source = request.attachmentSources[name] else {
                missing.append("\(note.id)/\(name)")
                continue
            }
            if source.hasPrefix("data:") { continue }
            guard let from = attachments.url(for: name, noteId: note.id) else {
                missing.append("\(note.id)/\(name)")
                continue
            }
            try checkpoint(folder)
            if !created {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                created = true
            }
            try fm.copyItem(at: from, to: URL(fileURLWithPath: folder.path + "/" + name))
        }
        return created
    }

    // MARK: - Placing

    /// Moves a staged item into `destination`: folders are walked with `lstat` (a link or a file in
    /// the way is refused), nothing existing is replaced, and a failure takes back what this item
    /// moved or created.
    private func place(_ entry: Staged, from stage: URL, to destination: URL) throws -> Placement {
        let fm = FileManager.default
        var placement = Placement(entry: entry, placed: [], createdFolders: [])
        do {
            var folder = destination
            var staged = stage
            for name in entry.item.folder {
                folder = folder.appendingPathComponent(name, isDirectory: true)
                staged = staged.appendingPathComponent(name, isDirectory: true)
                switch Self.kind(at: folder) {
                case .directory: continue
                case nil:
                    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                    placement.createdFolders.append(folder)
                case .link?, .other?: throw ExportError.notAPlainFolder(name)
                }
            }
            for unit in entry.units where Self.kind(at: folder.appendingPathComponent(unit)) != nil {
                throw ExportError.destinationExists(unit)
            }
            for unit in entry.units {
                let target = folder.appendingPathComponent(unit)
                try fm.moveItem(at: staged.appendingPathComponent(unit), to: target)
                placement.placed.append(target)
            }
        } catch {
            Self.undo(placement)
            throw error
        }
        return placement
    }

    /// Takes back what `place` did: the moved files, then the folders it created (only while empty).
    private static func undo(_ placement: Placement) {
        let fm = FileManager.default
        for url in placement.placed { try? fm.removeItem(at: url) }
        for url in placement.createdFolders.reversed()
        where (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
            try? fm.removeItem(at: url)
        }
    }

    /// Gives each folder this run created the oldest `createdAt` and the newest `modifiedAt` of
    /// the exported notes below it (M8-R65). Folders that were already there are left alone.
    private static func dateCreatedFolders(_ placements: [Placement], under destination: URL) {
        var dates: [String: (url: URL, created: Date, modified: Date)] = [:]
        for placement in placements {
            for folder in placement.createdFolders {
                let old = dates[folder.path]
                dates[folder.path] = (folder, old.map { min($0.created, placement.entry.createdAt) } ?? placement.entry.createdAt,
                                      old.map { max($0.modified, placement.entry.modifiedAt) } ?? placement.entry.modifiedAt)
            }
        }
        // A folder also covers the notes placed in the folders below it.
        for placement in placements {
            var folder = destination
            for name in placement.entry.item.folder {
                folder = folder.appendingPathComponent(name, isDirectory: true)
                guard let old = dates[folder.path] else { continue }
                dates[folder.path] = (old.url, min(old.created, placement.entry.createdAt), max(old.modified, placement.entry.modifiedAt))
            }
        }
        for (_, entry) in dates.sorted(by: { $0.key.count > $1.key.count }) {
            var values = URLResourceValues()
            values.creationDate = entry.created
            values.contentModificationDate = entry.modified
            var url = entry.url
            try? url.setResourceValues(values)
        }
    }

    // MARK: - Checks

    private static func checkNames(_ item: ExportItem) throws {
        for name in item.folder + [item.stem] {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.unicodeScalars.contains("\u{0}")
            else { throw ExportError.unsafeName(name) }
        }
    }

    /// Fails early, before rendering, when the destination already holds a name this item would take.
    private static func checkFree(_ item: ExportItem, settings: ExportSettings, under destination: URL) throws {
        let format = settings.format
        var folder = destination
        for name in item.folder {
            folder = folder.appendingPathComponent(name, isDirectory: true)
            switch kind(at: folder) {
            case .directory: continue
            case nil: return
            case .link?, .other?: throw ExportError.notAPlainFolder(name)
            }
        }
        var names = [item.stem + "." + format.fileExtension]
        // The folder next to the file only exists when attachments go with it.
        if (format == .markdown || format == .html) && settings.includeAttachments { names.append(item.stem) }
        for name in names where kind(at: folder.appendingPathComponent(name)) != nil {
            throw ExportError.destinationExists(name)
        }
    }

    private enum EntryKind { case directory, link, other }

    /// What `url` is, without following a final symbolic link; nil when nothing is there.
    private static func kind(at url: URL) -> EntryKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .link
        default: return .other
        }
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? any LocalizedError, let text = error.errorDescription { return text }
        if let error = error as? RenderError {
            switch error {
            case .timedOut: return "the note took too long to render"
            case .pageUnavailable: return "the export page is not available"
            case .pageCrashed: return "the export page crashed"
            case .invalidResult: return "the export page returned no result"
            case .printFailed(let reason): return "printing failed: \(reason)"
            case .cancelled: return "cancelled"
            }
        }
        if error is CocoaError || error is DecodingError || error is EncodingError { return error.localizedDescription }
        if let error = error as? CustomStringConvertible { return error.description }
        return error.localizedDescription
    }

    // MARK: - HTML links between notes

    private static func htmlTargets(_ items: [ExportItem]) -> [String: [ExportItem]] {
        Dictionary(grouping: items, by: \.noteId)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    /// For every planned note, the href from `item`'s page to its page: `..` up to the common
    /// folder, then down, then `<enc(stem)>.html`. A note planned in several folders (one per
    /// tag) is reached through the copy that shares the longest folder prefix with `item`, the
    /// first in plan order on a tie (M8-R66).
    private static func relativeHrefs(from item: ExportItem, targets: [String: [ExportItem]]) -> [String: String] {
        var result: [String: String] = [:]
        for (noteId, copies) in targets {
            var best: (shared: Int, copy: ExportItem)?
            for copy in copies {
                var shared = 0
                while shared < item.folder.count, shared < copy.folder.count, item.folder[shared] == copy.folder[shared] {
                    shared += 1
                }
                if best == nil || shared > best!.shared { best = (shared, copy) }
            }
            guard let target = best?.copy, let shared = best?.shared else { continue }
            let parts = Array(repeating: "..", count: item.folder.count - shared)
                + target.folder.dropFirst(shared).map(encode) + [encode(target.stem) + ".html"]
            result[noteId] = parts.joined(separator: "/")
        }
        return result
    }
}
