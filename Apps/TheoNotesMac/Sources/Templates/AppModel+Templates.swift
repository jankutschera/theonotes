// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// What `AppModel.createNoteFromTemplate` did.
enum TemplateOutcome: Equatable {
    case created(noteId: String, caret: Int?)
    /// The `{{title}}` prompt was cancelled: nothing was made.
    case cancelled
    /// The template is gone or locked (`noteNotFound`, `noteLocked`); nothing was made.
    case unavailable
    /// Anything else went wrong (busy database, an unusable tag); the template may be fine.
    case failed
}

extension AppModel {
    // MARK: - Making a note from a template

    /// A new note from template `id` (placeholders expanded, `#template` removed), its caret,
    /// `extraTags` (the selected tag and search tags of a window's ⌘N) and, in `workspace`, the
    /// workspace's tag (unless the note has a tag inside it), all in one write. The single entry
    /// point for templates opened from the app: Quick Open (`+`, `/template`), the picker (⇧⌘N)
    /// and "Start new notes with" (⌘N, ⌥⌘N). A template with `{{title}}` asks for the title first
    /// (trimmed; cancelling or a blank one makes nothing); the note is made from the text that was
    /// checked, even if the template changed behind the prompt. A made note counts as a use (the
    /// picker lists the recently used first). The CLI / MCP (M5) call `NoteStore.createFromTemplate`.
    func createNoteFromTemplate(
        id: String, workspace: Workspace? = nil, extraTags: [String] = [], now: Date = .now
    ) -> TemplateOutcome {
        do {
            guard let template = try environment.store.note(id: id), !template.isLocked else { return .unavailable }
            var context = TemplateContext(now: now, clipboard: clipboardText())
            if Templates.instantiate(templateText: template.text, context: context).needsTitle {
                guard let answer = askForTemplateTitle(template.title), let title = Self.templateTitle(from: answer)
                else { return .cancelled }
                context.title = title
            }
            let (note, caret) = try environment.store.createFromTemplate(
                templateText: template.text, context: context, workspace: workspace,
                tagPosition: TheoNotesCore.Settings(db: environment.database).tagPosition, extraTags: extraTags)
            templateRecents.markUsed(id, at: now)
            return .created(noteId: note.id, caret: caret)
        } catch StoreError.noteNotFound, StoreError.noteLocked {
            return .unavailable
        } catch {
            appLogger.error("could not create a note from template \(id, privacy: .public): \(error)")
            return .failed
        }
    }

    /// The title as typed, trimmed; nil when there is nothing but whitespace.
    static func templateTitle(from typed: String) -> String? {
        let title = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// The title prompt: a small alert with a text field; Create waits for a title. nil when cancelled.
    static func promptForTemplateTitle(_ templateTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Title for the new note"
        alert.informativeText = templateTitle.isEmpty
            ? "This template asks for a title."
            : "The template “\(templateTitle)” asks for a title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Title"
        field.setAccessibilityLabel("Title")
        alert.accessoryView = field
        let create = alert.addButton(withTitle: "Create")
        create.isEnabled = false
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let watcher = TitleWatcher(button: create)
        field.delegate = watcher  // weak: kept alive for the modal run below
        defer { field.delegate = nil }
        let response = withExtendedLifetime(watcher) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        return Self.templateTitle(from: field.stringValue)
    }

    // MARK: - File ▸ New Note from Template… (⇧⌘N)

    /// The picker: the Quick Open panel listing templates, recently used first. It works from a
    /// main window and from a note window; a chosen template goes through `performQuickOpen`, so
    /// the note opens where the picker was opened (⌘↩: in a new window).
    func showTemplatePicker(main: MainWindowState?, noteWindow: NoteWindowState?) {
        guard !isLocked else { return }
        if templatePicker.isShown { return templatePicker.focusField() }
        present(
            QuickOpenModel(index: nil, recentTemplates: templateRecents.all()),
            in: templatePicker, main: main, noteWindow: noteWindow)
    }

    // MARK: - Start new notes with: Template…

    /// The template ⌘N starts from: the setting, while that note is still a template in Notes
    /// (not deleted, trashed, archived, locked or stripped of its tag). Otherwise nil, and a set
    /// but unusable template is cleared so the setting never points at nothing.
    func startTemplateId() -> String? {
        let id = settings.snapshot.startNoteTemplate
        guard !id.isEmpty else { return nil }
        guard let usable = try? environment.database.pool.read({ db in
            try Templates.list(db: db).contains { $0.id == id }
        }) else { return nil }
        if usable { return id }
        clearStartTemplate()
        return nil
    }

    private func clearStartTemplate() {
        settings.set(.startNoteTemplate, "")
    }

    /// ⌘N in `main`: the note from the start template, tagged like a plain new note (the selected
    /// tag, the search's tags, the workspace's tag). nil when there is no usable start template
    /// (a plain note follows). A template that vanished clears the setting and also gives a plain
    /// note; a failure keeps the setting, makes nothing and beeps.
    func startNoteFromTemplate(in main: MainWindowState) -> TemplateOutcome? {
        startNote(workspace: main.model.workspace, tags: { try main.model.newNoteTagPaths() })
    }

    /// ⌥⌘N: the same, for the note window it opens (`main`: the window it was pressed in).
    func startNoteFromTemplateInNewWindow(from main: MainWindowState?) -> Bool {
        let outcome = startNote(workspace: main?.model.workspace, tags: { try main?.model.newNoteTagPaths() ?? [] })
        switch outcome {
        case .created(let noteId, let caret)?:
            openNoteInNewWindow(id: noteId, caret: caret)
            return true
        case .cancelled?:
            return true
        case .unavailable?, .failed?, nil:
            return false  // the caller makes a plain note (R35)
        }
    }

    private func startNote(workspace: Workspace?, tags: () throws -> [String]) -> TemplateOutcome? {
        guard let id = startTemplateId() else { return nil }
        let outcome: TemplateOutcome
        do {
            outcome = createNoteFromTemplate(id: id, workspace: workspace, extraTags: try tags())
        } catch {
            appLogger.error("could not tag a note from template \(id, privacy: .public): \(error)")
            outcome = .failed
        }
        // `.failed`: the caller falls back to a plain note (R35) and keeps the setting.
        if case .unavailable = outcome { clearStartTemplate() }
        return outcome
    }
}

/// Enables the title prompt's Create button while the field holds a title.
@MainActor
private final class TitleWatcher: NSObject, NSTextFieldDelegate {
    private let button: NSButton

    init(button: NSButton) {
        self.button = button
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button.isEnabled = AppModel.templateTitle(from: field.stringValue) != nil
    }
}

/// How a template reads in Settings' list.
enum TemplateChoice {
    /// The title; with its tag when another template has the same title.
    static func label(for template: TemplateInfo, among all: [TemplateInfo]) -> String {
        let title = template.title.isEmpty ? "Untitled" : template.title
        let isAmbiguous = all.contains { $0.id != template.id && $0.title == template.title }
        return isAmbiguous ? "\(title) (#\(template.tagPath))" : title
    }
}
