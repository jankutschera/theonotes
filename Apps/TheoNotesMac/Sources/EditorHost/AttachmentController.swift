// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import UniformTypeIdentifiers

/// The host side of editor attachments (spec §4.4, inventory §2.12): stores dropped, pasted and
/// ⇧⌘V-chosen files (`AttachmentStore`) and inserts their Bear Markdown, shows Quick Look, and
/// runs the attachment context menu (Open, Open With, Show in Finder, Rename, Save As, Delete,
/// PDF preview). Text changes go through the editor (`applyCommand`), so each is one undo step
/// there and reaches the store like typing does.
@MainActor
final class AttachmentController {
    /// What a context menu acts on: the attachment's source text at `[from, to)` when opened.
    struct Target: Equatable {
        var noteId: String
        var filename: String
        var from: Int
        var to: Int
        var source: String
    }

    weak var editor: EditorBridgeController?
    let store: AttachmentStore
    /// The decrypted attachments of locked notes (memory only) and the access that stores new ones.
    weak var lockedAttachments: LockedAttachmentMemory?
    let quickLook = QuickLookController()

    // Seams (tests replace the panels and the workspace).
    var chooseFiles: @MainActor () -> [URL]? = AttachmentController.runOpenPanel
    var askForName: @MainActor (_ current: String) -> String? = AttachmentController.runRenameAlert
    var chooseDestination: @MainActor (_ suggested: String) -> URL? = AttachmentController.runSavePanel
    var popUp: @MainActor (NSMenu) -> Void = { _ in }
    var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var openWith: @MainActor (URL, URL) -> Void = { file, app in
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Tells the user why a file was shown in Finder instead of opened.
    var refuseOpening: @MainActor (_ filename: String) -> Void = AttachmentController.runRefusedAlert
    lazy var preview: @MainActor (URL) -> Void = { [quickLook] in quickLook.show($0) }

    init(store: AttachmentStore) {
        self.store = store
    }

    /// The note the editor shows, when it is `noteId` and editable.
    private func editableNote(_ noteId: String) -> Bool {
        guard let editor, editor.session?.noteId == noteId else { return false }
        return editor.status.isEditable
    }

    // MARK: - Inserting

    /// Where a note's new files go: the plain store, or the vault's access for a locked note
    /// (encrypted on arrival; no plaintext file is ever written for it).
    private enum Sink: Sendable {
        case plain(AttachmentStore)
        case locked(LockedNoteAccess)

        func add(data: Data, filename: String, to noteId: String) throws -> String {
            switch self {
            case .plain(let store): try store.add(data: data, filename: filename, to: noteId)
            case .locked(let access): try access.addAttachment(data: data, filename: filename, to: noteId)
            }
        }

        func add(fileAt url: URL, to noteId: String) throws -> String {
            switch self {
            case .plain(let store): try store.add(fileAt: url, to: noteId)
            case .locked(let access): try access.addAttachment(fileAt: url, to: noteId)
            }
        }
    }

    /// Whether `noteId` is a locked note.
    private func isLocked(_ noteId: String) -> Bool {
        ((try? notes?.note(id: noteId)) ?? nil)?.isLocked == true
    }

    /// The sink for `noteId`; nil for a locked note while the vault is locked.
    private func sink(for noteId: String) -> Sink? {
        guard isLocked(noteId) else { return .plain(store) }
        return lockedAttachments?.access.map(Sink.locked)
    }

    /// What storing produced: the Markdown to insert and the names the files got.
    private struct Stored: Sendable {
        var text: String
        var names: [String]
    }

    /// The decoding and storing in flight (tests await it).
    private(set) var pendingWork: Task<Void, Never>?

    /// Files dropped or pasted in the editor: decoded and stored off the main actor under unique
    /// names, then their Markdown (one per line) fills the editor's pending insert `insertId`.
    /// Undecodable items are skipped. The bridge decoder already refused anything over the caps.
    func insert(_ uploads: [AttachmentUpload], insertId: String, noteId: String) {
        guard editableNote(noteId), let sink = sink(for: noteId) else {
            editorLogger.error("insertAttachments for note \(noteId, privacy: .public) ignored: not the editable note shown")
            return
        }
        run(noteId: noteId, insertId: insertId) {
            let names = uploads.compactMap { upload -> String? in
                guard let data = Data(base64Encoded: upload.dataBase64) else {
                    editorLogger.error("note \(noteId, privacy: .public): attachment with invalid base64 skipped")
                    return nil
                }
                return Self.attempt(noteId) { try sink.add(data: data, filename: upload.filename, to: noteId) }
            }
            return Stored(text: names.map(AttachmentMarkdown.link(for:)).joined(separator: "\n"), names: names)
        }
    }

    /// Files from Format ▸ File… (⇧⌘V), copied off the main actor and inserted over the selection.
    /// No size cap: this path reads the files natively.
    func insertFiles(_ urls: [URL], noteId: String) {
        guard editableNote(noteId), let sink = sink(for: noteId) else { return }
        run(noteId: noteId, insertId: nil) {
            let names = urls.compactMap { url in Self.attempt(noteId) { try sink.add(fileAt: url, to: noteId) } }
            return Stored(text: names.map(AttachmentMarkdown.link(for:)).joined(separator: "\n"), names: names)
        }
    }

    /// Attachment links pasted from another note: each file is copied into this note (unique
    /// name, staged, quarantined like its source) and the links renamed where a name was taken.
    /// A file the source no longer has keeps its link as is.
    /// The source must be a note that exists and is not locked; otherwise nothing is copied and
    /// the pending insert is dropped. Pasting into the source note goes through the same queue,
    /// so it lands after inserts still being stored.
    func paste(text: String, items: [PastedAttachment], from sourceNoteId: String, insertId: String, noteId: String) {
        guard editableNote(noteId) else { return }
        // Files cannot be copied between notes into a locked one: the sealed payload names them.
        guard !isLocked(noteId) else {
            editorLogger.error("pasteAttachments into locked note \(noteId, privacy: .public) refused")
            return cancelInsert(insertId)
        }
        guard sourceNoteId != noteId else {
            run(noteId: noteId, insertId: insertId) { Stored(text: text, names: []) }
            return
        }
        guard let source = (try? notes?.note(id: sourceNoteId)) ?? nil, !source.isLocked else {
            editorLogger.error("pasteAttachments from note \(sourceNoteId, privacy: .public) refused: missing or locked")
            return cancelInsert(insertId)
        }
        let store = store
        run(noteId: noteId, insertId: insertId) {
            var renamed: [String: String] = [:]
            for name in Set(items.map(\.filename)) {
                renamed[name] = Self.attempt(noteId) { try store.copy(name, from: sourceNoteId, to: noteId) }
            }
            return Stored(
                text: AttachmentMarkdown.rewriting(text, items: items, renamed: renamed), names: renamed.values.compactMap { $0 })
        }
    }

    /// Attachment links copied or cut in `noteId` (ruling R30): their mtime restarts the cleanup's
    /// grace period, and the files are held while the pasteboard still has this copy (its change
    /// count, taken once the copy reached the pasteboard) and at most 24 h.
    func copied(_ filenames: [String], noteId: String) {
        guard editor?.session?.noteId == noteId, let retention = notes?.retention else { return }
        let urls = filenames.compactMap { store.url(for: $0, noteId: noteId) }
        guard !urls.isEmpty else { return }
        for url in urls {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        retention.holdFiles(urls.map(\.lastPathComponent), of: noteId)
        settleHeldFiles { retention.settleHeldFiles() }
    }

    /// Runs the settling once WebKit has written the copy to the pasteboard (tests run it now).
    var settleHeldFiles: @MainActor (@escaping @MainActor () -> Void) -> Void = { settle in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { settle() } }
    }

    /// The note store (sources of pasted links, the copy hold of R30).
    weak var notes: NoteStore?

    /// Tells the editor its pending insert gets nothing (it drops it).
    private func cancelInsert(_ insertId: String) {
        editor?.apply(.insertText, args: ["text": .string(""), "insertId": .string(insertId)])
    }

    /// Dropped or pasted files over the caps (attachments.ts and the bridge decoder).
    func refused(_ filenames: [String], noteId: String) {
        guard editor?.session?.noteId == noteId else { return }
        tooLarge(filenames)
    }

    /// Called once files stored for `noteId` have their link in the editor (OCR for search).
    var stored: @MainActor (_ noteId: String, _ filenames: [String]) -> Void = { _, _ in }

    var tooLarge: @MainActor ([String]) -> Void = AttachmentController.runTooLargeAlert

    /// ⇧⌘V: an open panel for any files.
    func presentInsertFilePanel() {
        guard let noteId = editor?.session?.noteId, editableNote(noteId), let urls = chooseFiles(), !urls.isEmpty else { return }
        insertFiles(urls, noteId: noteId)
    }

    /// Runs `work` (file IO) off the main actor, then inserts its text, if any, while `noteId`
    /// is still the editable note shown. Otherwise the stored files stay unlinked and the
    /// cleanup removes them after the grace period.
    private func run(noteId: String, insertId: String?, _ work: @escaping @Sendable () -> Stored) {
        let previous = pendingWork
        pendingWork = Task { [weak self] in
            await previous?.value
            let stored = await Task.detached(priority: .userInitiated, operation: work).value
            let text = stored.text
            guard let self, self.editableNote(noteId) else { return }
            // Nothing stored: the empty text drops the pending insert.
            if text.isEmpty, insertId == nil { return }
            var args: [String: CommandArgument] = ["text": .string(text)]
            if let insertId { args["insertId"] = .string(insertId) }
            self.editor?.apply(.insertText, args: args)
            if !stored.names.isEmpty { self.stored(noteId, stored.names) }
        }
    }

    private nonisolated static func attempt(_ noteId: String, _ body: () throws -> String) -> String? {
        do {
            return try body()
        } catch {
            // A locked note's errors name files: log the case only.
            if error is NotePrivacyError || error is CryptoError {
                editorLogger.error("note \(noteId, privacy: .public): attachment not stored: \(PrivacyErrorCode.code(for: error), privacy: .public)")
            } else {
                editorLogger.error("note \(noteId, privacy: .public): attachment not stored: \(error)")
            }
            return nil
        }
    }

    // MARK: - Quick Look

    func showQuickLook(noteId: String, filename: String) {
        // A locked note's files exist only as ciphertext: nothing to preview from disk.
        guard !isLocked(noteId), editor?.session?.noteId == noteId, let url = store.url(for: filename, noteId: noteId) else { return }
        preview(url)
    }

    // MARK: - Context menu

    func showMenu(for target: Target) {
        guard editor?.session?.noteId == target.noteId else { return }
        popUp(menu(for: target))
    }

    enum Action: Equatable {
        case open, openWith(URL), reveal, rename, saveAs, delete, setPreview(Bool)
    }

    /// The menu's items in order (titles and actions); a read-only note offers no edits.
    func menuItems(for target: Target) -> [(title: String, action: Action?)] {
        if isLocked(target.noteId) { return lockedMenuItems(for: target) }
        guard let file = store.url(for: target.filename, noteId: target.noteId) else { return [] }
        let editable = editableNote(target.noteId)
        var items: [(String, Action?)] = [("Open", .open)]
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: file).prefix(12)
        if !apps.isEmpty { items.append(("Open With", nil)) }
        items.append(("Show in Finder", .reveal))
        items.append(("Save As…", .saveAs))
        if editable {
            items.append(("Rename…", .rename))
            if (target.filename as NSString).pathExtension.lowercased() == "pdf" {
                let shown = AttachmentMarkdown.metadata(target.source)["preview"] != "false"
                items.append((shown ? "Hide Preview" : "Show Preview", .setPreview(!shown)))
            }
            items.append(("Delete", .delete))
        }
        return items
    }

    /// A locked note's attachment can be saved to a chosen place (an explicit decrypted copy) or
    /// its link removed; nothing that needs a file on disk (Open, Open With, Show in Finder,
    /// Quick Look).
    private func lockedMenuItems(for target: Target) -> [(title: String, action: Action?)] {
        guard lockedAttachments?.access != nil else { return [] }
        var items: [(String, Action?)] = [("Save As…", .saveAs)]
        if editableNote(target.noteId) { items.append(("Delete", .delete)) }
        return items
    }

    func menu(for target: Target) -> NSMenu {
        let menu = NSMenu()
        let file = store.url(for: target.filename, noteId: target.noteId)
        guard file != nil || isLocked(target.noteId) else { return menu }
        for (title, action) in menuItems(for: target) {
            if title == "Open With", let file {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for app in NSWorkspace.shared.urlsForApplications(toOpen: file).prefix(12) {
                    let entry = ClosureMenuItem(title: FileManager.default.displayName(atPath: app.path)) { [weak self] in
                        self?.perform(.openWith(app), on: target)
                    }
                    entry.image = NSWorkspace.shared.icon(forFile: app.path)
                    entry.image?.size = NSSize(width: 16, height: 16)
                    submenu.addItem(entry)
                }
                item.submenu = submenu
                menu.addItem(item)
                continue
            }
            if title == "Rename…" || title == "Delete" { menu.addItem(.separator()) }
            guard let action else { continue }
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.perform(action, on: target) })
        }
        return menu
    }

    /// Runs one menu action. Text edits (rename, delete, preview) are replaced only while the
    /// note still has `target.source` at `[from, to)`.
    func perform(_ action: Action, on target: Target) {
        if isLocked(target.noteId) { return performLocked(action, on: target) }
        guard let file = store.url(for: target.filename, noteId: target.noteId) else { return }
        switch action {
        case .open, .openWith:
            switch Self.openDecision(for: file) {
            case .open:
                if case .openWith(let app) = action { openWith(file, app) } else { open(file) }
            case .quickLook:
                // Web documents would run their scripts in a browser: preview them instead.
                preview(file)
            case .reveal:
                // Apps, scripts, installers and shortcuts would run code: Finder (and Gatekeeper) only.
                reveal(file)
                refuseOpening(target.filename)
            }
        case .reveal:
            reveal(file)
        case .saveAs:
            guard let destination = chooseDestination(target.filename) else { return }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    // Copy beside it, then swap: the old file stays if the copy fails.
                    let temporary = destination.deletingLastPathComponent()
                        .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
                    try fm.copyItem(at: file, to: temporary)
                    _ = try fm.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fm.copyItem(at: file, to: destination)
                }
            } catch {
                editorLogger.error("attachment not saved: \(error)")
            }
        case .rename:
            // The link must be one we can rewrite before a second name is made.
            guard editableNote(target.noteId), AttachmentMarkdown.renaming(target.source, to: target.filename) != nil,
                  let name = askForName(target.filename)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name != target.filename else { return }
            do {
                let newName = try store.rename(target.filename, to: name, in: target.noteId)
                guard let source = AttachmentMarkdown.renaming(target.source, to: newName) else { return }
                replace(target, with: source)
            } catch {
                editorLogger.error("note \(target.noteId, privacy: .public): attachment not renamed: \(error)")
            }
        case .delete:
            // The link goes (undoable); the file follows once the note is committed and closed.
            guard editableNote(target.noteId) else { return }
            replace(target, with: "")
        case .setPreview(let on):
            guard editableNote(target.noteId),
                  let source = AttachmentMarkdown.settingMetadata(target.source, "preview", on ? "true" : "false") else { return }
            replace(target, with: source)
        }
    }

    private func performLocked(_ action: Action, on target: Target) {
        switch action {
        case .saveAs:
            guard let memory = lockedAttachments, let destination = chooseDestination(target.filename) else { return }
            Task { @MainActor in
                guard let data = await memory.data(noteId: target.noteId, filename: target.filename) else { return }
                do {
                    try data.write(to: destination, options: .atomic)
                } catch {
                    editorLogger.error("attachment of a locked note not saved: \(PrivacyErrorCode.code(for: error), privacy: .public)")
                }
            }
        case .delete:
            guard editableNote(target.noteId) else { return }
            replace(target, with: "")
        case .open, .openWith, .reveal, .rename, .setPreview:
            break
        }
    }

    private func replace(_ target: Target, with text: String) {
        editor?.apply(.replaceRange, args: [
            "from": .int(target.from), "to": .int(target.to), "expect": .string(target.source), "text": .string(text),
        ])
    }

    // MARK: - Open guard (ruling R25b: an allowlist)

    /// Types Open / Open With may hand to their app: documents that do not run code.
    private static let openableTypes: [UTType] = [
        .image, .pdf, .audio, .movie, .audiovisualContent, .plainText, .rtf, .rtfd, .spreadsheet, .presentation, .epub,
        // Archive Utility only extracts. Zip only: `.archive` also covers installer packages.
        .zip,
    ] + [
        "com.microsoft.word.doc", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt",
        "org.openxmlformats.wordprocessingml.document", "org.openxmlformats.spreadsheetml.sheet",
        "org.openxmlformats.presentationml.presentation", "org.oasis-open.opendocument.text",
        "org.oasis-open.opendocument.spreadsheet", "org.oasis-open.opendocument.presentation",
        "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.keynote.sffkey",
    ].compactMap { UTType($0) }

    /// Never opened even when they also conform to an openable type (SVG is an image, HTML text):
    /// browsers run their scripts, or they run code themselves.
    private static let excludedTypes: [UTType] = [
        .html, .xml, .svg, .sourceCode, .script, .shellScript, .executable, .application, .applicationBundle, .package,
        .webArchive, .aliasFile, .internetShortcut, .symbolicLink,
    ] + ["com.apple.installer-package-archive", "org.ietf.mhtml"].compactMap { UTType($0) }

    /// Documents that may be previewed instead (web pages, feeds, SVG): Quick Look runs no script.
    private static let previewTypes: [UTType] = [.html, .xml, .svg, .webArchive] + ["org.ietf.mhtml"].compactMap { UTType($0) }
    private static let previewExtensions: Set<String> = ["mht", "mhtml", "rss", "atom", "xsl", "xslt", "xhtml", "xht", "svgz"]

    enum OpenDecision: Equatable { case open, quickLook, reveal }

    private static func openable(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return openableTypes.contains { type.conforms(to: $0) } && !excludedTypes.contains { type.conforms(to: $0) }
    }

    /// What every open path (the context menu's Open and Open With, ⌘-click on an attachment link)
    /// does with a file: open it only when it is a regular, non-executable file and BOTH its
    /// extension's UTType and its content type (`URLResourceValues.contentType`) are on the
    /// allowlist, and text does not start like markup. Otherwise web documents are previewed in
    /// Quick Look and everything else is revealed in Finder.
    ///
    /// A `.txt` holding HTML: `contentType` reports `public.plain-text` (Launch Services goes by
    /// the extension), so both checks pass; a sniff of the first bytes catches the markup.
    static func openDecision(for url: URL) -> OpenDecision {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true,
              !FileManager.default.isExecutableFile(atPath: url.path) else { return .reveal }
        let ext = url.pathExtension.lowercased()
        let byExtension = UTType(filenameExtension: ext)
        let byContent = values.contentType
        let types = [byExtension, byContent].compactMap { $0 }
        if openable(byExtension), openable(byContent), !(types.contains { $0.conforms(to: .text) } && looksLikeMarkup(url)) {
            return .open
        }
        if previewExtensions.contains(ext) || types.contains(where: { type in previewTypes.contains { type.conforms(to: $0) } })
            || (types.contains { $0.conforms(to: .text) } && looksLikeMarkup(url)) {
            return .quickLook
        }
        return .reveal
    }

    /// Whether an attachment may be opened in its app (`openDecision == .open`).
    static func isSafeToOpen(_ url: URL) -> Bool { openDecision(for: url) == .open }

    /// The first KB of a text file starts like HTML, SVG or XML.
    /// Any tag a browser or HTML-rendering Markdown app would parse, anywhere in the head: `<` right
    /// before a tag name (`<div `, `</p>`, `<br/>`), `<!doctype`, `<?xml`. Prose (`a < b`), autolinks
    /// (`<https://…>`, `<a@b.c>`) and Bear's `<!-- {…} -->` comment are not tags.
    private static let markupTag = try! NSRegularExpression(
        pattern: #"<(!doctype|\?xml|/?[a-z][a-z0-9-]*[\s/>])"#,
        options: [.caseInsensitive])

    /// Whether the first KB of a text file holds markup (also `.md`, which apps render as HTML):
    /// a tag anywhere (after a BOM, text or a comment), or NUL bytes (UTF-16, which the tag search
    /// cannot read, and binary). Unreadable counts as markup.
    static func looksLikeMarkup(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        var head: Data
        do {
            head = try handle.read(upToCount: 1024) ?? Data()  // nil at end of file: empty, no markup
        } catch {
            return true
        }
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { head.removeFirst(3) }
        if head.contains(0) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return true }
        let text = String(decoding: head, as: UTF8.self)
        return markupTag.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// ⌘-click on an attachment link (`LinkRouter`): the same guard as Open.
    func openLinked(_ target: String, noteId: String) {
        var raw = target
        if raw.hasPrefix("<"), raw.hasSuffix(">") { raw = String(raw.dropFirst().dropLast()) }
        let filename = raw.removingPercentEncoding ?? raw
        guard !isLocked(noteId), editor?.session?.noteId == noteId, store.url(for: filename, noteId: noteId) != nil else { return }
        perform(.open, on: Target(noteId: noteId, filename: filename, from: 0, to: 0, source: ""))
    }

    static func runRefusedAlert(_ filename: String) {
        let alert = NSAlert()
        alert.messageText = "“\(filename)” can’t be opened from Theo Notes"
        alert.informativeText = "Only documents such as images, PDFs, text and office files open in their app. This file is shown in Finder instead."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func runTooLargeAlert(_ filenames: [String]) {
        let alert = NSAlert()
        alert.messageText = filenames.count == 1
            ? "“\(filenames[0])” is too large to drop or paste"
            : "These files are too large to drop or paste together"
        alert.informativeText = "Dropped and pasted files can be up to 50 MB each and 100 MB together. Use Format ▸ File… (⇧⌘V) for larger files."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Panels

    static func runOpenPanel() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Insert"
        return panel.runModal() == .OK ? panel.urls : nil
    }

    static func runRenameAlert(_ current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Attachment"
        alert.informativeText = "Enter a new name for “\(current)”."
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func runSavePanel(_ suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
