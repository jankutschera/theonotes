// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation

/// What one editor's links do (spec §4.4, inventory §2.2.1), for main and note windows alike:
/// wiki links show their note (created when missing, Bear), tags select the tag in a sidebar, URLs
/// go through `LinkRouting` (only http, https and mailto leave the app; Bear note URLs open the
/// imported note), and ⌘K shows the link panel. The window decides how a note is shown.
@MainActor
final class LinkRouter {
    let environment: AppEnvironment
    let editor: EditorBridgeController

    /// The note this window's editor shows.
    var shownNoteId: () -> String? = { nil }
    /// Shows a linked note in this window (`caret` for a note the link just created); false when it
    /// could not.
    var showNote: (_ noteId: String, _ caret: Int?) -> Bool = { _, _ in false }
    /// Selects a tag in a sidebar (a note window uses the frontmost main window's); false when none has it.
    var selectTag: (_ name: String) -> Bool = { _ in false }
    /// The window's workspace: a note a wiki link creates gets its tag (R31). A note window has none.
    var workspace: () -> Workspace? = { nil }
    /// Opens a note (scrolled to a heading) in a new window (`AppModel`). Nil: in this window.
    var openNoteInNewWindow: ((_ noteId: String, _ headingIndex: Int?) -> Void)?
    /// Shows the ⌘K panel; nil: the popover anchored at the caret (tests replace it).
    var presentLinkPanel: ((LinkPanelModel, CaretRect) -> Void)?
    let panel = LinkPanel()

    init(environment: AppEnvironment, editor: EditorBridgeController) {
        self.environment = environment
        self.editor = editor
        editor.onOpenLink = { [weak self] in self?.open($0) }
        editor.onEditLink = { [weak self] in self?.editLink($0) }
    }

    private var store: NoteStore { environment.store }

    // MARK: - Opening

    func open(_ request: OpenLinkRequest) {
        switch request.kind {
        case .url, .bearURL:
            openURL(request.target)
        case .wiki:
            openWikiLink(request)
        case .tag:
            // A tag typed a moment ago is only in the sidebar once its note is committed.
            environment.flushAll()
            if !selectTag(request.target) {
                appLogger.notice("tag link: no such tag in the sidebar")
            }
        case .attachment:
            // Through the attachment open guard (R25b): documents open, web documents preview,
            // anything else is shown in Finder.
            editor.attachments.openLinked(request.target, noteId: request.noteId)
        }
    }

    private func openURL(_ raw: String) {
        switch LinkRouting.action(for: raw) {
        case .openExternally(let url):
            editor.openExternally(url)
        case let .openBearNote(bearId, header, fallbackURL):
            guard let noteId = try? store.noteId(forBearId: bearId) else {
                // Rebuilt from the validated id only (never the note's URL with its parameters).
                return editor.openExternally(fallbackURL)
            }
            environment.flushAll()
            let index = header.flatMap { try? store.headingIndex(noteId: noteId, heading: $0) }
            show(noteId, headingIndex: index, caret: nil, newWindow: false)
        case .ignore:
            appLogger.notice("link not opened: only http, https and mailto URLs leave the app")
        }
    }

    private func openWikiLink(_ request: OpenLinkRequest) {
        // Commit the open notes first so titles and headings are current in the index.
        environment.flushAll()
        do {
            let target = try store.resolveOrCreateWikiLink(
                title: request.target, heading: request.heading, from: request.noteId, workspace: workspace())
            show(target.noteId, headingIndex: target.headingIndex, caret: target.caretOffset, newWindow: request.newWindow)
        } catch {
            appLogger.error("wiki link could not be opened: \(error)")
        }
    }

    /// Shows the note in this window (or a new one) and puts the caret on the heading.
    private func show(_ noteId: String, headingIndex: Int?, caret: Int?, newWindow: Bool) {
        let shown = shownNoteId()
        if newWindow, noteId != shown, let openNoteInNewWindow {
            openNoteInNewWindow(noteId, headingIndex)
            return
        }
        if noteId != shown || editor.session?.noteId != noteId {
            guard showNote(noteId, caret) else { return }
        }
        // Delivered after that note's loadNote (queued while the editor boots).
        if let headingIndex { editor.scrollToHeading(headingIndex) }
        editor.focusEditor()
    }

    // MARK: - Link panel

    /// ⌘K: the link panel for the request; its answer becomes `setLink{requestId, …}` in the same note.
    func editLink(_ request: EditLinkRequest) {
        let model = LinkPanelModel(title: request.title, url: request.url, editing: request.editing) { [weak self] result in
            self?.finishLinkPanel(request, result)
        }
        if let presentLinkPanel {
            presentLinkPanel(model, request.caretRect)
        } else {
            panel.present(model, at: request.caretRect, in: editor.webView)
        }
    }

    private func finishLinkPanel(_ request: EditLinkRequest, _ result: LinkPanelModel.Result) {
        defer { editor.focusEditor() }
        // The request lives in the editor of the note it was made for.
        guard editor.session?.noteId == request.noteId else { return }
        let fields: (title: String, url: String)
        switch result {
        case .cancel: return
        case let .apply(title, url): fields = (title, url)
        case .remove: fields = (request.title, "")
        }
        editor.apply(.setLink, args: [
            "requestId": .string(request.requestId), "title": .string(fields.title), "url": .string(fields.url),
        ])
    }
}
