// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Note ▸ Note History…: the title, and when the command is off.
enum NoteHistoryMenu {
    static let title = "Note History…"

    /// Off without an app, while App Lock is engaged, and without exactly one note to show.
    @MainActor
    static func isDisabled(app: AppModel?, hasMainWindow: Bool, hasNoteWindow: Bool, state: NoteCommandState) -> Bool {
        guard let app, !app.isLocked else { return true }
        if hasNoteWindow { return false }
        return !(hasMainWindow && state.canShowHistory)
    }
}

extension AppModel {
    /// Note ▸ Note History…: in a main window the note its editor shows (else the selected one), in a
    /// note window its note. Shown as a sheet over that window.
    func showNoteHistory(main: MainWindowState?, noteWindow: NoteWindowState?) {
        guard !isLocked else { return }
        if let main {
            guard let noteId = main.editor.session?.noteId ?? main.model.selectedNoteIDs.first else { return }
            presentHistory(noteId: noteId, over: main.window)
        } else if let noteWindow {
            presentHistory(noteId: noteWindow.noteId, over: noteWindow.hostWindow)
        }
    }

    private func presentHistory(noteId: String, over parent: NSWindow?) {
        // Opening writes nothing: no flush, no eviction. Replace saves this note's typing itself.
        let model = NoteHistoryModel(noteId: noteId, environment: environment)
        model.openNote = { [weak self] in self?.openNoteInNewWindow(id: $0) ?? false }
        NoteHistoryPresenter.present(model: model, over: parent)
    }
}

/// The list of versions, the chosen version's text, and the two actions.
struct NoteHistorySheet: View {
    @ObservedObject var model: NoteHistoryModel
    let onClose: () -> Void
    @State private var selection: String?

    private var selected: NoteSnapshot? { model.items.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            Text(NoteHistoryModel.title).font(.headline).padding(.vertical, 12)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 420)
        .onChange(of: model.items, initial: true) { _, items in
            if !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
        }
        .onChange(of: selection, initial: true) { _, id in
            if let item = model.items.first(where: { $0.id == id }) { model.preview(item) }
        }
        .onChange(of: model.isAppLocked) { _, locked in
            if locked { onClose() }
        }
    }

    @ViewBuilder private var content: some View {
        if model.isAppLocked {
            Color.clear
        } else if model.needsVault {
            placeholder(NoteHistoryModel.needsVaultText)
        } else if model.items.isEmpty {
            placeholder(NoteHistoryModel.emptyText)
        } else {
            HStack(spacing: 0) {
                List(model.items, id: \.id, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.takenAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                        Text(item.preview ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.vertical, 2)
                }
                .frame(width: 220)
                Divider()
                ScrollView {
                    Text(model.previewText ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .accessibilityLabel("Version text")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            Button(NoteHistoryModel.restoreTitle) {
                if let selected { model.restoreAsCopy(selected) }
            }
            .disabled(selected == nil)
            Button(NoteHistoryModel.replaceTitle) {
                guard let selected else { return }
                Task { if await model.replace(selected) { onClose() } }
            }
            .disabled(selected == nil)
        }
        .padding(12)
    }
}

/// Shows the sheet over a window (or alone when none is up) and ends it on Close.
@MainActor
enum NoteHistoryPresenter {
    @discardableResult
    static func present(model: NoteHistoryModel, over parent: NSWindow?) -> NSWindow {
        var panel: NSWindow?
        let finish = {
            model.close()
            if let panel {
                if let parent, parent.sheets.contains(panel) { parent.endSheet(panel) } else { panel.close() }
            }
            panel = nil
        }
        model.confirmReplace = { askToReplace(over: panel ?? parent) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: NoteHistorySheet(model: model, onClose: finish)))
        window.styleMask = [.titled]
        window.title = NoteHistoryModel.title
        panel = window
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }

    /// "Replace the note with this version? The current text is kept in the history."
    static func askToReplace(over window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = NoteHistoryModel.replaceQuestion
        alert.addButton(withTitle: NoteHistoryModel.replaceConfirmTitle)
        alert.addButton(withTitle: NoteHistoryModel.cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
