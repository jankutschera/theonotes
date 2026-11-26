// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI

enum CopyAsFormat: CaseIterable, Identifiable {
    case markdown, plainText, html, richText

    var id: Self { self }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        case .html: "HTML"
        case .richText: "Rich Text"
        }
    }

    /// ⇧⌘C copies as Rich Text (A10).
    var shortcut: KeyboardShortcut? {
        self == .richText ? KeyboardShortcut("c", modifiers: [.command, .shift]) : nil
    }
}

/// What Copy As copies: the editor's selection, or whole notes in the order given.
enum CopyTarget: Equatable {
    case selection(noteId: String, text: String)
    case notes([String])
}

/// Edit ▸ Copy As ▸ Markdown / Plain Text / HTML / Rich Text and the note list's and the editor's
/// Copy As submenus (M8 Task 14, A10).
///
/// Pasteboard types: Markdown writes `.string` (the text as stored). Plain Text writes `.string`
/// (the text without its markup, as the Plain Text export). HTML writes `.string`
/// (the HTML source) and `.html`. Rich Text writes `.rtf`, `.html` and `.string` (plain text,
///). Notes are joined with a blank line (Markdown, plain text) or `<hr>` (HTML). "Keep tags
/// when exporting" (Settings, the Keep Tags item of the submenu) applies, read when a run starts
///. A locked note is skipped and counted (`notifyLocked` gets the
/// count); when nothing is left, or anything else fails, nothing is written and the app beeps
///.
@MainActor
struct CopyAs {
    private let environment: AppEnvironment
    private let renderer: NoteRenderer
    private let pasteboard: NSPasteboard
    private let beep: @MainActor () -> Void
    private let notifyLocked: @MainActor (Int) -> Void
    /// Runs right before the pasteboard check and write (a test seam: the lock engages here).
    private let beforeWrite: @MainActor () -> Void
    private let keepTags: @MainActor () -> Bool

    init(
        environment: AppEnvironment, renderer: NoteRenderer, pasteboard: NSPasteboard = .general,
        beep: @escaping @MainActor () -> Void = { NSSound.beep() },
        notifyLocked: @escaping @MainActor (Int) -> Void = { _ in },
        beforeWrite: @escaping @MainActor () -> Void = {},
        keepTags: @escaping @MainActor () -> Bool = { true }
    ) {
        self.keepTags = keepTags
        self.beforeWrite = beforeWrite
        self.environment = environment
        self.renderer = renderer
        self.pasteboard = pasteboard
        self.beep = beep
        self.notifyLocked = notifyLocked
    }

    /// What one run did: whether the pasteboard was written, and how many locked notes it left out.
    struct Outcome: Equatable {
        var wrote: Bool
        var skippedLocked: Int
    }

    /// One note (or selection) ready to be copied.
    private struct Source {
        var note: Note
        /// The text to copy: the note's, or the editor selection of it.
        var text: String
    }

    /// Returns whether the pasteboard was written.
    @discardableResult
    func copy(_ format: CopyAsFormat, target: CopyTarget) async -> Bool {
        await perform(format, target: target).wrote
    }

    /// Bumped by every run: a run whose number is no longer the latest, or whose task was cancelled,
    /// has been superseded and neither writes the pasteboard, beeps nor reports.
    private static var latestRun = 0

    func perform(_ format: CopyAsFormat, target: CopyTarget) async -> Outcome {
        Self.latestRun += 1
        let mine = Self.latestRun
        // App Lock: a run that started before the lock engaged, or while it is engaged, writes nothing.
        let appLock = environment.appLock
        let generation = appLock.generation
        func superseded() -> Bool { Self.latestRun != mine || Task.isCancelled || !appLock.isCurrent(generation) }
        let gone = Outcome(wrote: false, skippedLocked: 0)
        var skippedLocked = 0
        if superseded() { return gone }
        do {
            let found = try self.sources(of: target)
            var sources = found.sources
            let locked = found.skippedLocked
            if !keepTags() {
                sources = sources.map { Source(note: $0.note, text: ExportText.removingTags($0.text)) }
            }
            skippedLocked = locked
            guard !sources.isEmpty else {
                if locked > 0 { notifyLocked(locked) }
                beep()
                return Outcome(wrote: false, skippedLocked: locked)
            }
            let strings: [NSPasteboard.PasteboardType: String]
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            switch format {
            case .markdown:
                strings = [.string: sources.map(\.text).joined(separator: "\n\n")]
            case .plainText:
                strings = [.string: sources.map { PlainTextExport.text($0.text) }.joined(separator: "\n\n")]
            case .html:
                var fragments: [String] = []
                for source in sources {
                    fragments.append(try await fragment(of: source, mode: .document))
                    if superseded() { return gone }
                }
                let html = fragments.joined(separator: "\n<hr>\n")
                strings = [.string: html, .html: html]
            case .richText:
                var fragments: [String] = []
                for source in sources {
                    fragments.append(try await fragment(of: source, mode: .richText))
                    if superseded() { return gone }
                }
                let html = fragments.joined(separator: "\n<hr>\n")
                data[.rtf] = try RichText.rtfData(fromFragment: html)
                let plain = sources.map { PlainTextExport.text($0.text) }.joined(separator: "\n\n")
                strings = [.string: plain, .html: Self.page(around: html)]
            }
            beforeWrite()
            if superseded() { return gone }
            if locked > 0 { notifyLocked(locked) }
            write(strings: strings, data: data)
            return Outcome(wrote: true, skippedLocked: skippedLocked)
        } catch {
            if superseded() { return gone }
            appLogger.error("copy as failed: \(String(describing: error))")
            beep()
            return Outcome(wrote: false, skippedLocked: skippedLocked)
        }
    }

    // MARK: - Sources

    /// The notes to copy and how many locked ones were left out. An open editor's acknowledged
    /// text is committed first, so a note copies as the editor shows it.
    private func sources(of target: CopyTarget) throws -> (sources: [Source], skippedLocked: Int) {
        switch target {
        case .selection(let noteId, let text):
            guard !text.isEmpty, let note = try environment.store.note(id: noteId) else { return ([], 0) }
            return note.isLocked ? ([], 1) : ([Source(note: note, text: text)], 0)
        case .notes(let ids):
            var result: [Source] = []
            var locked = 0
            for id in ids {
                try environment.existingSession(for: id)?.flush()
                guard let note = try environment.store.note(id: id) else { continue }
                if note.isLocked {
                    locked += 1
                } else {
                    result.append(Source(note: note, text: note.text))
                }
            }
            return (result, locked)
        }
    }

    private func fragment(of source: Source, mode: RenderMode) async throws -> String {
        var note = source.note
        note.text = source.text
        let look = environment.appearance.exportLook(themeId: nil)
        let request = try RenderRequestBuilder(store: environment.store, paths: environment.paths).request(
            for: note, mode: mode, theme: look.theme, appearance: look.appearance, typography: look.typography,
            attachments: .none, wikiLinks: mode == .document ? .sameNote : WikiLinkTargets.none, keepTags: true)
        let result = try await renderer.render(request)
        guard mode == .document else { return result.html }
        guard let body = Self.bodyFragment(ofDocument: result.html) else { throw RenderError.invalidResult }
        return body
    }

    // MARK: - HTML

    private static let mainOpen = "<main class=\"bc-export\">\n"
    private static let mainClose = "</main>"

    /// What is inside `<main class="bc-export">` of a `document`-mode page: the note's body with its
    /// classes, without the `<style>`, the `<head>` and the page wrapper. Note text is escaped by
    /// the renderer, so the last `</main>` is the page's own.
    static func bodyFragment(ofDocument html: String) -> String? {
        guard let open = html.range(of: mainOpen), let close = html.range(of: mainClose, options: .backwards),
              open.upperBound <= close.lowerBound
        else { return nil }
        var body = String(html[open.upperBound..<close.lowerBound])
        if body.hasSuffix("\n") { body.removeLast() }
        return body
    }

    /// The `.html` flavour of a rich-text copy: the fragment in a minimal page, so a reader knows it is UTF-8.
    private static func page(around fragment: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(fragment)</body></html>"
    }

    // MARK: - Pasteboard

    private func write(strings: [NSPasteboard.PasteboardType: String], data: [NSPasteboard.PasteboardType: Data]) {
        // clearContents drops whatever flavours the last copy left.
        pasteboard.clearContents()
        for (type, value) in data { pasteboard.setData(value, forType: type) }
        for (type, value) in strings { pasteboard.setString(value, forType: type) }
    }
}

// MARK: - Resolving the target

extension CopyAs {
    /// The selection while the editor is focused and the selection is non-empty (UTF-16 offsets
    /// into the shown note's acknowledged text), otherwise the selected notes in list order; nil
    /// when there is neither.
    static func target(
        editorFocused: Bool, shown: (noteId: String, text: String)?, selection: SelectionRange?,
        selectedNoteIDs: [String]
    ) -> CopyTarget? {
        if editorFocused, let shown, let selection {
            let text = shown.text as NSString
            let start = min(max(0, min(selection.anchor, selection.head)), text.length)
            let end = min(max(0, max(selection.anchor, selection.head)), text.length)
            if end > start {
                return .selection(
                    noteId: shown.noteId, text: text.substring(with: NSRange(location: start, length: end - start)))
            }
        }
        return selectedNoteIDs.isEmpty ? nil : .notes(selectedNoteIDs)
    }

    /// Main window: the editor selection or the selected notes.
    static func target(window: MainWindowState) -> CopyTarget? {
        target(
            editorFocused: window.isEditorFocused,
            shown: window.editor.session.map { ($0.noteId, $0.text) }, selection: window.editor.status.selection,
            selectedNoteIDs: window.selectedNoteIDsInListOrder)
    }

    /// Note window: the editor selection, otherwise the note it shows.
    static func target(window: NoteWindowState) -> CopyTarget? {
        guard window.noteExists else { return nil }
        return target(
            editorFocused: window.isEditorFocused,
            shown: window.editor.session.map { ($0.noteId, $0.text) }, selection: window.editor.status.selection,
            selectedNoteIDs: [window.noteId])
    }

    /// Whether `target(window:)` would find something, without cutting a selection out of a large note.
    static func hasTarget(window: MainWindowState) -> Bool {
        if window.isEditorFocused, let range = window.editor.status.selection, range.anchor != range.head,
           window.editor.session != nil { return true }
        return !window.model.selectedNoteIDs.isEmpty
    }

    static func hasTarget(window: NoteWindowState) -> Bool {
        window.noteExists
    }
}
